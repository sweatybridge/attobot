# ABAC / Row-Level Security Design for AttoBot

**Status:** Proposed — for review
**Target branch:** `develop`
**Supersedes:** the stale `feature/abac-rls-security` branch (commit `80039aa`, never merged; see [§11 — Prior attempt & why this is different](#11-prior-attempt--why-this-is-different))

---

## 1. Summary

AttoBot is a Postgres-resident agent harness: agent state, the conversation
stream, tool calls, memory, and the outbound queue live in tables under the
`attobot` schema; blob storage lives under `attotools`. The whole system is
driven by PL/pgSQL functions and `pg_durable` workflows that run **inside the
database backend**.

Today there is exactly one database principal: the `postgres` superuser.
`agent-init` connects with `PGUSER: postgres`; the durable loops
(`ensure_telegram_inbox_loop`, scheduled heartbeats, outbox sender) execute as
that same session role. There are no roles, no grants, and **no row-level
security** — every connection sees and mutates everything.

This document proposes an **Attribute-Based Access Control (ABAC)** layer built
on PostgreSQL **Row-Level Security (RLS)** that follows least privilege:

- a **separate role per agent** (`attobot_agent_primary`,
  `attobot_agent_subconscious`), plus principal tiers for telegram users
  (`attobot_anonymous`, `attobot_authenticated`), the durable backend
  (`attobot_service`), and bootstrap/maintenance (`attobot_admin`);
- **attributes** carried as session GUCs (`current_setting(...)`) that RLS
  policies consult — the "A" in ABAC;
- a **table-by-table least-privilege matrix** and the matching policies;
- the worked example from the request: *an anonymous telegram user in a group
  chat may **INSERT** into `messages`, **UPDATE** their own rows, and can **never
  DELETE**.*

A runnable, non-breaking **Phase 1** artifact ships with this design as
`docker-entrypoint-initdb.d/40-attobot-rbac.sql`. Enforcement — actually
connecting under these roles — is a later, separately-reviewable phase
([§9](#9-enforcement--phased-rollout)).

---

## 2. Goals & non-goals

**Goals**

- Least-privilege isolation between agents, between telegram users, and between
  users and the backend.
- The anonymous-group-chat example enforced at the database layer.
- A design that is **non-breaking** to apply today (the live system keeps
  working) and **enforceable** once the connection layer is wired.
- Reproducible: adding a future agent follows a fixed recipe.

**Non-goals (for this PR)**

- Re-architecting telegram intake away from `pg_durable`.
- Network/transport security (TLS to Telegram, secret rotation).
- Encrypting `attobot.config.value` at rest.
- A full connection-pooler rollout. We describe the integration point but do
  not pick a pooler here.

---

## 3. Threat model & trust boundaries

| Boundary | Trusted? | Implication |
|---|---|---|
| Telegram servers → webhook/getUpdates | **Yes (signed by bot token)** | A message's `from.id` and `chat.id` are trustworthy once delivered to us over the authenticated Bot API. |
| The DB backend (`pg_durable`, triggers) | **Yes (trusted compute)** | Runs our own functions in-process. This is where `attobot_service` lives. |
| Operators / admins | **Yes, but audited** | They hold `attobot_admin`. Their actions land in `attobot.lifecycle`. |
| A telegram user in the group | **No** | They can only do what RLS allows, scoped to their own rows. |

The key honest point: **RLS only constrains principals that are *not* the table
owner and *not* superuser.** Postgres superusers and table owners bypass RLS
unless `FORCE ROW LEVEL SECURITY` is set. Because the live system connects as
`postgres` (superuser), enabling RLS today is a **no-op for the running
harness** — it becomes binding only when a connection actually `SET ROLE`s into
one of the least-privilege roles. [§9](#9-enforcement--phased-rollout) is about
closing that gap deliberately, in stages, rather than pretending a `CREATE
POLICY` alone secures anything.

---

## 4. Roles

All roles are `NOLOGIN` by default — they are *capabilities*, not connection
identities. A real connection connects as a `LOGIN` principal that is a member
of (and can `SET ROLE` into) the appropriate capability role.

```text
attobot_admin                 # bootstrap + maintenance; can do everything service can
└── attobot_service           # the durable backend / pg_durable workflows / cron

attobot_agent_primary         # the primary agent's turn execution
attobot_agent_subconscious    # the review/meta agent; never talks to operators

attobot_authenticated         # a registered telegram operator (reserved escalation tier)
attobot_anonymous             # any telegram user in the configured group chat
```

**Why a separate role per agent.** It makes each agent's privileges individually
auditable, revocable, and grantable to a dedicated connection principal. Row
isolation *between* agents is then enforced two ways: by the role itself, and by
the `attobot.current_agent_id` attribute ([§5](#5-attributes-the-a-in-abac)).

**Membership rule (for enforcement).** The eventual non-superuser connection
principal must be a **member** of every role it needs to `SET ROLE` into. For
example, the backend principal joins `attobot_service`; a per-agent turn
principal joins `attobot_agent_primary`. This membership is configured in
Phase 2/3 — it is not required for the non-breaking Phase 1 artifact.

---

## 5. Attributes (the "A" in ABAC)

RLS predicates read session attributes set via custom GUCs. They are set by the
trusted intake/turn bootstrap (and reset on connection checkout).

| GUC | Type | Set by | Meaning |
|---|---|---|---|
| `attobot.current_role` | text | bootstrap | Mirrors the active capability role (audit/defense-in-depth). |
| `attobot.current_agent_id` | bigint | turn bootstrap | Which agent a turn is executing for. |
| `attobot.current_telegram_user_id` | text | intake | `from.id` from the telegram update. |
| `attobot.current_telegram_chat_id` | text | intake | `chat.id` from the telegram update. |

Policies read them fail-closed:

```sql
NULLIF(current_setting('attobot.current_agent_id', true), '')::bigint
payload #>> '{telegram_update,message,from,id}'
  = current_setting('attobot.current_telegram_user_id', true)
```

`current_setting(..., true)` returns `NULL` when unset; `NULL = anything` is
`NULL`, which RLS treats as **deny**. So a session that forgot to set context
sees **nothing**, never everything.

A single helper, `attobot.set_context(...)`, sets the GUCs (and, when called by
a principal that is a member, `SET LOCAL ROLE`). It is `SECURITY INVOKER` and
documented in [§10.2](#102-context-helper). The connection layer is responsible
for calling it and for resetting on checkout (`DISCARD ALL` or explicit
`RESET ROLE` + `set_config(..., '', true)`).

---

## 6. Least-privilege access matrix

"own" for a telegram user means
`payload #>> '{telegram_update,message,from,id}' = current_setting('attobot.current_telegram_user_id')`.
"own agent" for an agent role means
`agent_id = current_setting('attobot.current_agent_id')::bigint`.

| Table | `anonymous` | `authenticated` | `agent_primary` | `agent_subconscious` | `service` | `admin` |
|---|---|---|---|---|---|---|
| `attobot.agents` | SELECT | SELECT | SELECT | SELECT | SELECT | ALL |
| `attobot.models` | SELECT | SELECT | SELECT | SELECT | SELECT | ALL |
| `attobot.messages` | **INSERT own, UPDATE own, SELECT own; no DELETE** | same | SELECT/INSERT/UPDATE own agent; no DELETE | SELECT primary agent only | ALL | ALL |
| `attobot.memory` | — | — | ALL own agent | SELECT primary; INSERT into primary; UPDATE own | ALL | ALL |
| `attobot.config` | — | — | SELECT **non-secret** own | SELECT non-secret own | ALL | ALL |
| `attobot.outbox` | — | — | INSERT/UPDATE own agent | — | ALL | ALL |
| `attobot.lifecycle` | — | — | SELECT; INSERT own events | SELECT; INSERT own events | SELECT/INSERT/UPDATE | ALL |
| `attotools.blobs` | — | — | SELECT/INSERT/UPDATE own agent | SELECT own | ALL | ALL |

Two least-privilege decisions worth calling out:

- **Secrets are never readable by agent roles.** `config` rows where
  `secret = true` (the `api_key`, `telegram_token`) are hidden from
  `attobot_agent_*` even on their own `agent_id`. Only `service`/`admin` see
  secrets. (The prior attempt gave agents `ALL` on `config`, exposing them.)
- **The subconscious agent cannot write the outbox.** Per its SOUL it never
  talks to operators; it influences the primary through `memory` and triggers
  only.

---

## 7. The worked example: anonymous group-chat user on `messages`

> "allow anonymous users in a group chat **insert** to `messages`, **update**
> their own rows, and **no deletes**."

Three policies + matching column privileges. The `WITH CHECK` on INSERT/UPDATE
pins every row's recorded sender to the session's `current_telegram_user_id`,
so a user can only create or modify rows attributed to themselves. There is
**no DELETE policy** and **no `DELETE` privilege granted**, so deletion is
impossible regardless of how the row was created.

```sql
-- INSERT: may create a row only if it is attributed to themselves
CREATE POLICY messages_anon_insert ON attobot.messages
  FOR INSERT TO attobot_anonymous
  WITH CHECK (
    payload #>> '{telegram_update,message,from,id}'
      = current_setting('attobot.current_telegram_user_id', true)
  );

-- UPDATE: may touch only rows they sent, and cannot re-attribute them away
CREATE POLICY messages_anon_update ON attobot.messages
  FOR UPDATE TO attobot_anonymous
  USING (
    payload #>> '{telegram_update,message,from,id}'
      = current_setting('attobot.current_telegram_user_id', true)
  )
  WITH CHECK (
    payload #>> '{telegram_update,message,from,id}'
      = current_setting('attobot.current_telegram_user_id', true)
  );

-- SELECT: may read only their own rows (least privilege; widen deliberately)
CREATE POLICY messages_anon_select ON attobot.messages
  FOR SELECT TO attobot_anonymous
  USING (
    payload #>> '{telegram_update,message,from,id}'
      = current_setting('attobot.current_telegram_user_id', true)
  );

-- Column privileges match the policies exactly: insert+update+select, NO delete
GRANT INSERT, UPDATE, SELECT ON attobot.messages TO attobot_anonymous;
```

This implements the example at the table level. See [§9.2](#92-phase-2--wire-up-enforcement)
for how telegram intake sets `attobot.current_telegram_user_id` per update so
these policies are actually exercised.

---

## 8. Full RLS policy catalog

Conventions: every table gets `ENABLE ROW LEVEL SECURITY` (never `FORCE` — see
[§3](#3-threat-model--trust-boundaries)). `service`/`admin` get a broad bypass
policy because they are trusted compute; everything else is scoped.

> **Gotcha (validated).** A `bigserial` primary key is backed by a
> `<table>_<col>_seq` sequence, and `INSERT` needs `USAGE` on that sequence
> (to call `nextval`) **in addition to** `INSERT` on the table. Without it the
> insert dies on the sequence before the RLS `WITH CHECK` ever runs — so the
> policy looks correct but silently blocks all inserts. The SQL artifact grants
> `USAGE` on each sequence only to the roles that insert into that table.

### 8.1 `attobot.messages`

- **anonymous / authenticated**: as [§7](#7-the-worked-example-anonymous-group-chat-user-on-messages).
- **agent roles**: `SELECT/INSERT/UPDATE` where
  `agent_id = current_setting('attobot.current_agent_id')::bigint`,
  `WITH CHECK` the same. No DELETE.
- **service / admin**: `FOR ALL USING (true) WITH CHECK (true)`.

### 8.2 `attobot.memory`

- **agent_primary**: `FOR ALL` on `agent_id = current_agent_id`.
- **agent_subconscious**: `SELECT` where
  `agent_id = (SELECT id FROM attobot.agents WHERE slug='primary')`
  (it reads the primary's memory), `INSERT` with the same `WITH CHECK`
  (it writes corrections into the primary's memory), and `UPDATE` on its *own*
  `agent_id` rows.
- **service / admin**: bypass.

### 8.3 `attobot.config`

- **agent roles**: `SELECT` where
  `agent_id = current_agent_id AND secret = false` — secrets are invisible.
  Writes to `config` go through the trusted `set_config` function
  ([§10.1](#101-function-privileges)), not direct table access, so agent roles
  get **no INSERT/UPDATE/DELETE** on the table itself.
- **service / admin**: bypass (admin sets secrets during bootstrap).

### 8.4 `attobot.outbox`

- **agent_primary**: `INSERT/UPDATE` where `agent_id = current_agent_id`,
  `WITH CHECK` the same.
- **agent_subconscious**: none (cannot send).
- **service / admin**: bypass (the durable outbox sender runs as `service`).

### 8.5 `attobot.lifecycle`

- **agent roles**: `SELECT` all (audit log is shared) + `INSERT`
  (`WITH CHECK true`, for `log_event`).
- **service**: `SELECT/INSERT/UPDATE` (instance/status tracking).
- **admin**: bypass.
- **anonymous / authenticated**: none — the audit log is internal.

### 8.6 `attobot.agents` / `attobot.models`

- All roles: `SELECT`. Only `admin`: `INSERT/UPDATE/DELETE` (via `ensure_agent`
  / `ensure_model`). `service` gets `SELECT` only.

### 8.7 `attotools.blobs`

- **agent roles**: `SELECT/INSERT/UPDATE` where `agent_id = current_agent_id`.
- **service / admin**: bypass.

---

## 9. Enforcement & phased rollout

`CREATE POLICY` alone secures nothing while the only connector is the
superuser. We roll out in four independently-reviewable phases.

### 9.1 Phase 1 — Define the layer (this PR, non-breaking)

Ships as `docker-entrypoint-initdb.d/40-attobot-rbac.sql`:

- creates the roles (`NOLOGIN`);
- grants schema usage, table column privileges, and `EXECUTE` on functions —
  **column privileges match the policies** (e.g. anonymous gets
  `INSERT,UPDATE,SELECT` on `messages`, never `DELETE`);
- `ENABLE ROW LEVEL SECURITY` on every table (**not** `FORCE`);
- creates all policies from [§8](#8-full-rls-policy-catalog);
- adds the `attobot.set_context` helper.

Because the only connector is still `postgres` (superuser, `BYPASSRLS`), the
live harness, `agent-init`, and the durable loops are **completely unaffected**.
A fresh `docker compose up` continues to boot and seed cleanly.

### 9.2 Phase 2 — Wire up enforcement (follow-up PR)

Make the connection layer actually drop privileges. Two integration points:

1. **Telegram intake** — the durable `ensure_telegram_inbox_loop` currently
   runs `process_telegram_updates` as `postgres`. To exercise the anonymous
   policies, process each accepted update under the user's identity:

   ```sql
   -- inside the per-update loop, before append_message:
   PERFORM attobot.set_context(
     p_role          := 'attobot_anonymous',
     p_telegram_user_id := (v_update #>> '{message,from,id}')::text,
     p_telegram_chat_id := (v_update #>> '{message,chat,id}')::text
   );
   ```

   `process_telegram_updates` becomes `SECURITY DEFINER` owned by
   `attobot_admin` (or stays superuser-owned during transition) and switches
   role per update, so each `INSERT` hits the [§7](#7-the-worked-example-anonymous-group-chat-user-on-messages)
   policy and is bound to the real sender.

2. **Agent turns** — the durable turn executor sets
   `attobot.current_agent_id` and `SET ROLE attobot_agent_<slug>` before
   composing the LLM request, so message/memory/outbox access is scoped to
   that agent.

**Decision requested:** whether to (a) keep intake as a single trusted
`SECURITY DEFINER` function that sets context per-update (simpler, one trust
boundary), or (b) push role-switching down into `pg_durable` per workflow
(more isolated, more plumbing). This design recommends **(a)** for Phase 2.

### 9.3 Phase 3 — Drop the superuser dependency (follow-up PR)

- Move ownership of write-path functions to `attobot_admin` and mark them
  `SECURITY DEFINER` with a pinned `search_path` (the prior attempt bundled
  this into the policy file and re-defined the function bodies inline — that
  is rejected here as a drift hazard; see [§11](#11-prior-attempt--why-this-is-different)).
- **Secret-reading helpers must become `SECURITY DEFINER`.** Because [§8.3](#83-attobotconfig)
  hides `secret = true` config from agent roles, the functions that consume
  secrets — `_llm_headers` (reads `api_key`) and `_telegram_api_url` (reads
  `telegram_token`), both via `_config_text` — would resolve to `NULL` when run
  by an agent role. They must therefore be converted to `SECURITY DEFINER`
  owned by `attobot_admin`/`attobot_service` **before** agent turns can execute
  non-superuser. (Today this is moot: superuser bypasses RLS, so `_config_text`
  sees secrets fine.)
- Connect `agent-init` and the durable backend as a `LOGIN` principal that is a
  member of the needed roles, instead of `postgres`.
- Add `attobot_admin` (not `postgres`) as the bootstrap owner.

### 9.4 Phase 4 — Tests & audit (follow-up PR)

- A test fixture that connects as each role and asserts the matrix in [§6](#6-least-privilege-access-matrix)
  (try every CRUD op on every table; expect allow/deny per the matrix).
- A negative test: an unset context sees zero rows.
- Confirm `lifecycle` records role/agent for sensitive writes.

---

## 10. Functions

### 10.1 Function privileges

`EXECUTE` is granted to match least privilege. Highlights (full list in the SQL
artifact):

| Function | Granted to |
|---|---|
| `process_telegram_updates` | `anonymous` (intake entrypoint) |
| `append_message`, `start_turn`, `finish_turn`, `compose_llm_request` | `agent_primary`, `service` |
| `set_config` | `service`, `admin` (agent roles write config **through** it, not directly) |
| `ensure_agent`, `ensure_model`, `configure_telegram` | `admin`, `service` |
| `ensure_scheduled_message_loop`, `ensure_telegram_inbox_loop`, `start_telegram_outbox_send` | `service`, `admin` |
| `agent_id`, `_config_text`, `_system_prompt`, `_memory_prompt` | agent roles + `service` |
| `log_event` | agent roles + `service` + `admin` |
| `attotools.*` tool functions | `service` (+ read helpers to agent roles) |

### 10.2 Context helper

```sql
CREATE OR REPLACE FUNCTION attobot.set_context(
  p_role text,
  p_agent_id bigint DEFAULT NULL,
  p_telegram_user_id text DEFAULT NULL,
  p_telegram_chat_id text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = attobot, attotools, pg_temp
AS $$
BEGIN
  PERFORM set_config('attobot.current_role', p_role, true);
  PERFORM set_config('attobot.current_agent_id',
                     COALESCE(p_agent_id::text, ''), true);
  PERFORM set_config('attobot.current_telegram_user_id',
                     COALESCE(p_telegram_user_id, ''), true);
  PERFORM set_config('attobot.current_telegram_chat_id',
                     COALESCE(p_telegram_chat_id, ''), true);
END;
$$;
```

Notes:
- Uses the **3-argument** built-in `set_config(name, value, is_local)` — the
  prior attempt called a non-existent 2-argument form.
- Role-switching is intentionally **not** baked in here (doing `SET ROLE` inside
  a `SECURITY DEFINER` function is fragile and membership-dependent). The
  connection layer / intake loop performs `SET LOCAL ROLE` after calling this.
  Phase 3 may fold a guarded `SET ROLE` in once function ownership is migrated.

---

## 11. Prior attempt & why this is different

A prior implementation lives on branch `feature/abac-rls-security`
(commit `80039aa`). It was never merged. This design supersedes it. Concrete
defects in that attempt, all fixed here:

1. **Privilege/policy mismatch.** It `GRANT`s only `SELECT` on every table but
   declares `FOR ALL` (insert/update/delete) policies. RLS policies do not
   confer privileges — `GRANT` does — so under a non-superuser connection,
   **no write would ever succeed**. This design grants the exact column
   privileges each policy implies (and deliberately *omits* `DELETE` for the
  anonymous example).
2. **Inline function re-definition.** It re-declares `append_message`,
  `process_telegram_updates`, `ensure_agent`, `set_config`, and
  `configure_telegram` with `CREATE OR REPLACE ... SECURITY DEFINER` directly in
  the policy file. That duplicates function bodies that already live in
  `20-attobot-core.sql` / `23-attobot-telegram.sql`, guaranteeing silent drift
  the next time those functions change. This design **never redefines existing
  functions** in the policy file; SECURITY DEFINER conversion is a separate,
  owned step in Phase 3.
3. **Broken context helper.** Its `set_context` calls `set_config(name, value)`
  (2-arg, does not exist as the built-in needs a third `is_local` argument).
  Fixed to the 3-arg form.
4. **Secrets exposed to agents.** Its `config_agent_all_own` policy gives agent
  roles `FOR ALL` on their `config` — including `secret = true` rows
  (`api_key`, `telegram_token`). This design hides `secret` rows from agent
  roles and routes writes through `set_config`.
5. **No enforcement story.** It documents `SET ROLE` snippets but never addresses
  that *nothing connects as these roles today*, so the policies were inert. This
  design is explicit about the superuser-bypass reality and the phased plan to
  make enforcement real.

---

## 12. Migration safety & rollback

- **Idempotent.** Role creation is guarded by `pg_roles` checks; policies use
  `DROP POLICY IF EXISTS` before `CREATE`; `ENABLE ROW LEVEL SECURITY` is
  repeatable. Re-running `40-attobot-rbac.sql` is safe.
- **Non-breaking today.** `ENABLE` (not `FORCE`) + superuser connector = the
  live harness is untouched.
- **Ordering.** The file runs last (`40-`) so all tables/functions exist first.
- **Rollback.** `DISABLE ROW LEVEL SECURITY` per table, `DROP POLICY` per
  policy, `REVOKE` grants, `DROP ROLE` the `attobot_*` roles. None of these
  touch user data.

---

## 13. Open questions (for review)

1. **Intake trust model** — confirm we take approach (a) in [§9.2](#92-phase-2--wire-up-enforcement)
   (single `SECURITY DEFINER` intake that sets context per update).
2. **Authenticated tier** — is `attobot_authenticated` wanted now (parity with
   anonymous, reserved for known operators), or should we ship anonymous-only
   and add it later? This design keeps it as a parity tier.
3. **SELECT scope for anonymous** — confirm least-privilege "own rows only" is
   acceptable for the group-chat UX, vs. widening to "all messages in the
   configured chat".
4. **Connection principal** — do we introduce a single `LOGIN` principal per
   concern now, or wait until Phase 3?

---

## Appendix A — Reference SQL

The Phase 1 artifact is `docker-entrypoint-initdb.d/40-attobot-rbac.sql`. It
contains exactly the roles, privileges, RLS policies, and `set_context` helper
described above, and nothing that redefines existing functions.

## Appendix B — End-to-end: a telegram user sends a message (target state)

1. Durable inbox loop polls Telegram over the authenticated Bot API. An update
   arrives for the configured `chat_id`.
2. `process_telegram_updates` (SECURITY DEFINER) calls
   `set_context('attobot_anonymous', telegram_user_id=>from.id,
   telegram_chat_id=>chat.id)` and `SET LOCAL ROLE attobot_anonymous`.
3. It inserts the message. The `messages_anon_insert` `WITH CHECK` verifies the
   row's `payload ... from.id` equals the session user — it does, so the insert
   succeeds. (Any attempt to forge a different sender is rejected at the DB.)
4. The user may later `UPDATE` only that row (`messages_anon_update`), and can
   never `DELETE` it (no policy, no privilege).
5. The turn then runs as `attobot_agent_primary` with
   `current_agent_id` set, so the agent sees/appends only its own conversation
   and writes its reply to `outbox`; the durable sender dispatches it back to
   Telegram.
