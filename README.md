# attobot

attobot is a Postgres-resident agent harness. Agent state, turns, tool calls,
memory, and outbound delivery all live in PostgreSQL tables under the `attobot`
schema; tool-owned blob storage lives under `attotools`. Agents point at shared
rows in `attobot.models`, so multiple agents can reuse the same model
configuration. `pg_durable` owns the durable workflow execution, so a turn can
survive database restarts and resume from its last checkpoint.

There is no filesystem loop and no external agent process. Everything is
PL/pgSQL functions, `pg_durable` workflows, and triggers running inside
Postgres. The only other container is the one-shot `agent-init` seed job.

## Architecture

The primary agent is driven by a trigger on the messages table.

```
-> trigger after insert on messages for each statement when role = 'user' and agent = 'primary'
  -> attobot.start_agent_loop('primary', trigger_message_id, requesting_user_id)
     (gate: one loop per agent at a time; a running loop absorbs mid-turn messages)
    -> df.loop until (assistant messages since trigger >= agents.max_turn) as primary:
      -> attobot.compose_llm_request() as request
         (select soul + memory + last n messages in chat, plus attotools.tool_schemas())
      -> df.http(POST /chat/completions, $request, 120) as response
         -> on error attobot.append_message(role => 'system') + df.break
      -> attobot.record_assistant($response) as assistant
         (append assistant message; stamp payload.requesting_user_id for tool scoping)
      -> df.if($assistant.tool_calls)
         -> attotools.run_tool_calls(...) as primary
            (start each call as its own df instance in parallel, await with timeout,
             cancel on timeout, append each result as role => 'tool')
         -> else df.break
```

Outbound delivery is a separate row-level trigger (this replaces a separate
outbox table):

```
-> trigger after insert on messages for each row
   when role in ('assistant', 'system') and channel = 'telegram'
  -> df.start(attobot.send_message_future(id))
     -> text reply:      df.http(sendMessage)
     -> attachment row:  attobot.send_message() — export blob to a temp file, curl sendDocument
```

Communication to the outside world is driven by long polling Telegram.

```
-> df.loop (attobot.ensure_telegram_inbox_loop) as primary
  -> df.http(getUpdates)
    -> attobot.poll_messages() as primary
       -> track each sender with attobot.upsert_user() (channel identity ledger)
       -> batch-insert accepted messages as role => 'user', channel => 'telegram'
          (one statement -> one user->loop trigger fire)
-> trigger after insert on messages for each row
   when role in ('assistant', 'system') and channel = 'telegram'
  -> telegram delivery (see above)
```

The subconscious agent shares the same loop design as primary but is driven by a
cron schedule. Its tool calls run as the `attobot_agent_subconscious` role
instead of a user tier.

```
-> df.loop (attobot.ensure_agent_cron_loop) as subconscious
  -> df.wait_for_schedule(cron)
  -> attobot.append_message(role => 'system', '[schedule ...] review ...')
  -> attobot.start_agent_loop('subconscious', trigger_message_id, NULL)
```

The durable turn workflow is SQL:

- `compose_llm_request` builds an OpenAI-compatible `/chat/completions` body and
  sends it through `df.http`.
- Assistant messages are stored in `attobot.messages` via `record_assistant`,
  with the parsed `tool_calls` on the payload.
- Tool calls run as **per-call durable instances** (started in parallel, awaited
  with a timeout, cancelled on timeout), not as child workflows that signal a
  parent. The orchestrator appends each result as a `tool` message as
  `attobot_service`.
- Assistant replies with no tool calls are delivered by the outbound trigger
  when `channel = 'telegram'`; otherwise they simply stay in `attobot.messages`.
- `SEND_ATTACHMENT` queues an attachment by inserting a `system` message
  (channel `telegram`) whose payload references a stored blob; the outbound
  trigger then delivers it.
- The Telegram inbox loop uses `df.http` to poll `getUpdates` into
  `attobot.messages` (which fires the user→loop trigger); outbound delivery uses
  `df.http` `sendMessage` for text and `curl sendDocument` for attachments.


## Least-privilege access matrix

"own" for a telegram user =
`payload #>> '{telegram_update,message,from,id}' = current_setting('attobot.current_telegram_user_id')`.
"own agent" for an agent role =
`agent_id = current_setting('attobot.current_agent_id')::bigint`.

Each agent's **loop** (compose, model call, record, orchestrate) runs as that
agent's own role — fixed, trusted code that needs the api_key, so the agent role
reads its own config including secrets. **Tool calls** drop out of the loop role
into a secret-free scope: the requesting user's tier (`anonymous`/`authenticated`)
for primary, and `attobot_service` (broad, secret-free) for the subconscious. So
no LLM-authored SQL ever runs with secret access. See
`docs/abac-rls-security-design.md` for the full design.

Only the durable framework makes http calls. The primary agent polls telegram,
appends new messages, and calls its own model. All assistant/system messages on
`channel = 'telegram'` are forwarded to the chat; `tool` messages are not.

The primary agent role runs the loop: it reads the shared `agents`/`models`
rows, all `users` (and may create and edit users, but not delete them), its own
`messages`, `memory`, `memory_sources`, `attotools.blobs` (SELECT/INSERT/UPDATE,
never DELETE), its own `config` (including secrets — needed to call the model),
and appends + reads `lifecycle` events. It cannot delete rows or modify
`agents`/`models`. Its tool calls drop to the requesting user's tier, which
cannot read secrets. A running loop may be interrupted or cancelled.

The subconscious agent role runs its loop the same way (reading its own secrets
to call its model). Its tool calls drop to `attobot_service` — a broad but
secret-free scope — so it can read every agent's `messages`/`memory` and insert
or update any agent's `memory`/`memory_sources` (never delete) to review and
correct them, without ever seeing secrets.

| Table | `anonymous` | `authenticated` | `agent_primary` | `agent_subconscious` | `service` | `admin` |
|---|---|---|---|---|---|---|
| `agents` | SELECT | SELECT | SELECT | SELECT | SELECT | ALL |
| `models` | SELECT | SELECT | SELECT | SELECT | SELECT | ALL |
| `messages` | **SELECT chat-wide**; INSERT/UPDATE own; **no DELETE** | same | SELECT/INSERT/UPDATE own agent; no DELETE | SELECT/INSERT/UPDATE own agent; no DELETE | ALL | ALL |
| `memory` | — | — | ALL own agent | **SELECT/INSERT/UPDATE all agents** | ALL | ALL |
| `memory_sources` | — | — | ALL own agent | SELECT/INSERT/UPDATE all agents | ALL | ALL |
| `config` | — | — | SELECT own (incl. secrets) | SELECT own (incl. secrets) | SELECT non-secret | ALL |
| `lifecycle` | — | — | SELECT; INSERT | SELECT; INSERT | SELECT/INSERT/UPDATE | ALL |
| `attotools.blobs` | — | — | SELECT/INSERT/UPDATE own agent | SELECT/INSERT/UPDATE own agent | ALL | ALL |
| `users` | SELECT own row | SELECT own row | SELECT all; INSERT/UPDATE | SELECT all | SELECT all; INSERT | ALL |

Two least-privilege decisions:

- **Secrets are kept out of every LLM-tool scope.** Agent roles read their own
  `secret = true` config (`api_key`, `telegram_token`) — but only from fixed loop
  code that needs the key to call the model. The scopes the LLM actually authors
  SQL in (the user tier for primary, `attobot_service` for the subconscious)
  cannot read secrets, so the model cannot exfiltrate them. Only `admin` sees all
  secrets directly.
- **`messages` SELECT is chat-wide for users.** The whole conversation belongs
  to one configured chat = one agent, so a user sees all of it (including other
  users' messages and the agent's replies). INSERT/UPDATE stay pinned to their
  own `from.id`; DELETE remains impossible.


## Run

Build the Postgres 18 image with `pg_durable` installed from the
`sweatybridge/pg_durable` GitHub release Debian package:

```bash
docker compose build
docker compose up -d
```

Fresh containers initialize the database schema in the Docker entrypoint. After
Postgres passes its healthcheck, the one-shot `agent-init` service runs `psql`
against the `harness` service and loads the mounted `agents.sql` seed file. That
job creates the `primary` and `subconscious` agents. Set `ATTOBOT_API_KEY`
before first boot, or rerun `agent-init` later, to seed both agents with an LLM
key. Secrets are stored in agent-scoped `attobot.config` rows:

```bash
ATTOBOT_API_KEY=sk-... docker compose up -d
```

You can also override the shared model with `ATTOBOT_MODEL`,
`ATTOBOT_API_BASE`, `ATTOBOT_TEMPERATURE`, `ATTOBOT_REASONING_EFFORT`,
`ATTOBOT_CONTEXT_TOKENS`, and `ATTOBOT_MULTIMODAL_SUPPORT`. Compose passes
these values to `psql` as variables for the seed SQL. The `agent-init` job
configures the model before creating agents, then assigns both seeded agents to
the configured model row.

To create a new agent, configure a model first and pass its id:

```bash
docker compose exec harness psql -U postgres -d postgres
```

```sql
WITH model AS (
  SELECT attobot.upsert_model(
    p_model => 'deepseek-v4-pro',
    p_api_base => 'https://api.deepseek.com/v1',
    p_temperature => 1.0,
    p_reasoning_effort => 'medium',
    p_context_tokens => 1000000,
    p_multimodal_support => false
  ) AS id
)
SELECT attobot.upsert_agent(
  p_slug => 'primary',
  p_soul => $$
You are a persistent agent running inside PostgreSQL.
Be direct. Use tools when you need to act on stored state.
Reply directly when no tool action is needed.
$$,
  p_api_key => 'sk-...',
  p_model_id => (SELECT id FROM model)
);
```

To update only a secret:

```sql
SELECT attobot.set_config('primary', 'api_key', to_jsonb('sk-...'::text));
```

The `subconscious` agent is also seeded with a `primary-review` durable schedule
that wakes it every 10 minutes.

To run the agent seed job again after changing environment values:

```bash
docker compose run --rm agent-init
```

There is no client binary; interact with the agent by inserting a user message
directly, which fires the user→loop trigger:

```bash
docker compose exec harness psql -U postgres -d postgres
```

```sql
INSERT INTO attobot.messages(agent_id, role, content)
VALUES (attobot.agent_id('primary'), 'user', 'Introduce yourself');
```

The assistant reply lands back in `attobot.messages`. (A message inserted
without a telegram channel is not auto-delivered, so read it back directly.)

```sql
SELECT role, content, created_at
FROM attobot.messages
WHERE agent_id = attobot.agent_id('primary')
ORDER BY id DESC LIMIT 10;
```

Turn progress is visible in `attobot.lifecycle` (operational events) and
`df.instances` (durable instances).

## Telegram

For a clean database, configure and start the primary agent's durable Telegram
inbox loop from the `agent-init` job:

```bash
ATTOBOT_TELEGRAM_TOKEN=123:abc \
ATTOBOT_TELEGRAM_CHAT_ID=-1001234567 \
docker compose up -d
```

For a forum topic, also set `ATTOBOT_TELEGRAM_THREAD_ID=42`. Override the
poll timeout with `ATTOBOT_TELEGRAM_POLL_TIMEOUT`; the default is `60` seconds.
If you add or change Telegram settings after the stack is already running,
rerun `docker compose run --rm agent-init` so the seed SQL updates the stored
configuration and ensures the inbox loop exists.

To update stored Telegram settings later, call `attobot.configure_telegram`
from `psql`. It stores the token and chat metadata as agent-scoped
`attobot.config` rows:

```sql
SELECT attobot.configure_telegram(
  p_agent_slug => 'primary',
  p_token  => '123:abc',
  p_chat_id => '-1001234567',
  p_thread_id => NULL
);
```

The inbox loop calls Telegram `getUpdates` through `pg_durable` and appends
accepted messages as `[telegram <update_id>] ...` user messages. It accepts only
the configured chat, and the configured topic when `telegram_thread_id` is set.

Outbound delivery is trigger-driven: any `assistant` or `system` row inserted
into `attobot.messages` with `channel = 'telegram'` fires a row-level trigger
that starts a one-shot durable send workflow for that message. Text replies go
out via `sendMessage`; a row whose payload carries an `attachment` (e.g. queued
by `SEND_ATTACHMENT`) goes out as a document.

Attachment delivery exports the blob to a temporary file inside the Postgres
container, then uploads it with Telegram `sendDocument` using `curl`.

## Durable Loops

Start a cron-driven schedule that appends a system message and starts the
subconscious agent's loop:

```sql
SELECT attobot.ensure_agent_cron_loop(
  p_agent_slug => 'subconscious',
  p_name => 'heartbeat',
  p_cron => '*/5 * * * *',
  p_message => 'tick'
);
```

## Tables

- `attobot.agents`: one row per agent.
- `attobot.models`: reusable model, endpoint, temperature, reasoning, context, and modality configuration.
- `attobot.config`: per-agent configuration and secrets.
- `attobot.messages`: canonical conversation stream — user, assistant, system,
  and tool rows. Outbound delivery is trigger-driven off this table, so there is
  no separate outbox.
- `attobot.memory`: agent-scoped durable memories forwarded to the LLM. Each row
  links to the messages it was constructed from via `attobot.memory_sources`.
- `attobot.memory_sources`: junction table backing memory's source messages;
  composite foreign keys force same-agent integrity and cascade on delete.
- `attobot.lifecycle`: append-only audit log of operational events (agent
  ensure, message appends, telegram poll/send outcomes, security markers).
- `attobot.users`: channel-agnostic identity ledger. One row per
  `(channel, external_id)`; telegram intake (`poll_messages` → `upsert_user`)
  upserts senders, and `tier` maps a user to an RLS role suffix
  (`anonymous` / `authenticated`).
- `attotools.blobs`: content-addressed large content storage as external `bytea`.

## Built-In Tools

The LLM sees these database-native tools (schemas are introspected from the
`attotools._tool_*` functions):

- `SEARCH`: search the public web and return result titles, URLs, and snippets.
- `WEBFETCH`: fetch a public HTTP(S) URL and return status, content type, effective URL, and a truncated text body.
- `SQL`: run a single SQL query that returns rows.
- `SEND_ATTACHMENT`: send a stored blob as a Telegram document attachment.
- `WRITE_BLOB`: write large or binary content into `attotools.blobs` using an explicit encoding.
- `READ_BLOB`: read blob content by hash as `UTF8` text, `base64`, `hex`, `escape`, or another PostgreSQL text encoding.

Tool calls are not queued in a separate request table. The parent turn stores
tool calls on the assistant message, then `attotools.run_tool_calls` starts each
call as its own durable instance (all started before awaiting, so they run in
parallel) and polls `df.status` per call with a timeout. A call that does not
finish in time is cancelled with `df.cancel` and its `tool` message records the
timeout/error. `SEARCH` and `WEBFETCH` are themselves `df.http` graphs;
`SEARCH` queries Bing's HTML endpoint and returns up to 10 parsed results.
`WEBFETCH` is limited to public `http` and `https` URLs and blocks obvious
local/private hosts. Synchronous tools (`SQL`, the blob tools,
`SEND_ATTACHMENT`) run under the acting role via `SET ROLE` + session GUCs, so
row-level security binds for their data access; results are appended as
`role = 'tool'` messages by `attobot_service`.

`WRITE_BLOB` accepts `content` plus `encoding`. Use `base64`, `hex`, or `escape`
for raw binary data; use PostgreSQL text encodings such as `UTF8`, `LATIN1`, or
`WIN1252` when the content should be converted from text into bytes. It returns
a JSON object with the blob hash, byte count, and marker.

`SEND_ATTACHMENT` accepts a blob `hash`, plus optional `filename`, `caption`, and
`mime_type`. It validates the blob, then queues an outbound `system` message
(channel `telegram`) whose payload references the blob; the outbound trigger
delivers it as a Telegram document.

`SQL` intentionally accepts only one semicolon-free query and wraps it as a
subquery. For writes, use a data-modifying CTE with `RETURNING`, for example:

```sql
WITH ins AS (
  INSERT INTO some_table(value) VALUES ('x')
  RETURNING *
)
SELECT * FROM ins
```

## Docker Image

The image uses `postgres:18-trixie` as its base and installs
`pg-durable-postgresql-18_0.2.3-1_amd64.deb` from the
`sweatybridge/pg_durable` `v0.2.3` GitHub release. The Dockerfile verifies the
published SHA256 digest before installing the package.

`shared_preload_libraries = 'pg_durable'` (plus `pg_durable.database` and
`pg_durable.worker_role`) is written into the base sample config so new clusters
load the background worker before init SQL runs.

The `harness` service uses this image. The `agent-init` service uses the stock
Postgres client image, mounts `agents.sql` read-only, waits for `harness` to be
healthy, and runs `psql --no-psqlrc --single-transaction --set=ON_ERROR_STOP=1 --set=... --file=/attobot/agents.sql`.
