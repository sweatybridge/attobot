-- ============================================================================
-- AttoBot ABAC / Row-Level Security — Phase 1 (define the layer)
-- ============================================================================
-- Companion to docs/abac-rls-security-design.md. Read that doc first.
--
-- What this file does:
--   * Creates the capability roles (NOLOGIN).
--   * Grants schema usage + table column privileges + EXECUTE on functions,
--     with column privileges that EXACTLY match the policies below
--     (e.g. attobot_anonymous gets INSERT,UPDATE,SELECT on messages — never
--     DELETE; RLS policies do not confer privileges, GRANT does).
--   * ENABLE ROW LEVEL SECURITY on every table (never FORCE).
--   * Creates the least-privilege policies from the design's access matrix.
--   * Adds attobot.set_context(...) for session attribute bootstrap.
--
-- What this file deliberately does NOT do:
--   * It does NOT redefine any existing function (append_message,
--     process_telegram_updates, ensure_agent, set_config, configure_telegram,
--     ...). SECURITY DEFINER conversion is Phase 3, owned separately, to avoid
--     the inline-duplication drift hazard of the prior attempt.
--   * It does NOT FORCE RLS, so the table owner / superuser still bypasses it.
--
-- Why this is non-breaking today: the only connector is `postgres` (superuser,
-- BYPASSRLS). Enabling RLS therefore has no effect on the live harness, on
-- agent-init, or on the pg_durable workflows. The policies only become binding
-- once a connection actually SET ROLEs into one of these roles — see Phase 2.
--
-- Idempotent: guarded role creation, DROP POLICY IF EXISTS before CREATE,
-- repeatable ENABLE ROW LEVEL SECURITY. Safe to re-run.
-- ============================================================================

-- ============================================================================
-- ROLES
-- ============================================================================

DO $$
BEGIN
  -- Principal tiers
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'attobot_admin') THEN
    CREATE ROLE attobot_admin NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'attobot_service') THEN
    CREATE ROLE attobot_service NOLOGIN;
  END IF;

  -- One role per agent
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'attobot_agent_primary') THEN
    CREATE ROLE attobot_agent_primary NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'attobot_agent_subconscious') THEN
    CREATE ROLE attobot_agent_subconscious NOLOGIN;
  END IF;

  -- Telegram user tiers
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'attobot_authenticated') THEN
    CREATE ROLE attobot_authenticated NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'attobot_anonymous') THEN
    CREATE ROLE attobot_anonymous NOLOGIN;
  END IF;
END $$;

-- Agent roles run their own loops now: the pg_durable worker connects as the
-- submitted role (the agent role), so they must be LOGIN (non-superuser, so
-- enable_superuser_instances=off is satisfied). attobot_service is no longer the
-- orchestrator — it is only the subconscious's broad, secret-free SET ROLE
-- target — so it is NOLOGIN.
ALTER ROLE attobot_agent_primary LOGIN;
ALTER ROLE attobot_agent_subconscious LOGIN;
ALTER ROLE attobot_service NOLOGIN;

-- ============================================================================
-- SCHEMA USAGE
-- ============================================================================

GRANT USAGE ON SCHEMA attobot
  TO attobot_admin, attobot_service,
     attobot_agent_primary, attobot_agent_subconscious,
     attobot_authenticated, attobot_anonymous;

GRANT USAGE ON SCHEMA attotools
  TO attobot_admin, attobot_service,
     attobot_agent_primary, attobot_agent_subconscious;

-- ============================================================================
-- SEQUENCES
--   bigserial PKs back onto a <table>_<col>_seq; INSERT needs USAGE on the
--   sequence (nextval) as well as INSERT on the table. Grant per inserting
--   role only — a role with no INSERT on a table gets no USAGE on its seq.
-- ============================================================================
GRANT USAGE ON SEQUENCE attobot.messages_id_seq
  TO attobot_anonymous, attobot_authenticated,
     attobot_agent_primary, attobot_agent_subconscious, attobot_service, attobot_admin;
GRANT USAGE ON SEQUENCE attobot.memory_id_seq
  TO attobot_agent_primary, attobot_agent_subconscious, attobot_service, attobot_admin;
GRANT USAGE ON SEQUENCE attobot.lifecycle_id_seq
  TO attobot_agent_primary, attobot_agent_subconscious, attobot_service, attobot_admin;
GRANT USAGE ON SEQUENCE attobot.agents_id_seq, attobot.models_id_seq
  TO attobot_service, attobot_admin;

-- ============================================================================
-- TABLE: attobot.agents   (everyone reads; only admin writes)
-- ============================================================================

GRANT SELECT ON attobot.agents
  TO attobot_anonymous, attobot_authenticated,
     attobot_agent_primary, attobot_agent_subconscious, attobot_service;
GRANT SELECT, INSERT, UPDATE, DELETE ON attobot.agents TO attobot_admin;

ALTER TABLE attobot.agents ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS agents_read_all ON attobot.agents;
CREATE POLICY agents_read_all ON attobot.agents
  FOR SELECT TO PUBLIC USING (true);

DROP POLICY IF EXISTS agents_admin_write ON attobot.agents;
CREATE POLICY agents_admin_write ON attobot.agents
  FOR ALL TO attobot_admin USING (true) WITH CHECK (true);

-- ============================================================================
-- TABLE: attobot.models   (everyone reads; only admin writes)
-- ============================================================================

GRANT SELECT ON attobot.models
  TO attobot_anonymous, attobot_authenticated,
     attobot_agent_primary, attobot_agent_subconscious, attobot_service;
GRANT SELECT, INSERT, UPDATE, DELETE ON attobot.models TO attobot_admin;

ALTER TABLE attobot.models ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS models_read_all ON attobot.models;
CREATE POLICY models_read_all ON attobot.models
  FOR SELECT TO PUBLIC USING (true);

DROP POLICY IF EXISTS models_admin_write ON attobot.models;
CREATE POLICY models_admin_write ON attobot.models
  FOR ALL TO attobot_admin USING (true) WITH CHECK (true);

-- ============================================================================
-- TABLE: attobot.messages
--   Anonymous/authenticated: SELECT the whole configured chat (all messages for
--   the agent whose chat they are in), INSERT/UPDATE only their own rows, NEVER
--   delete. Agent roles scope to current_agent_id.
-- ============================================================================

GRANT SELECT, INSERT, UPDATE ON attobot.messages
  TO attobot_anonymous, attobot_authenticated;            -- NOTE: no DELETE
GRANT SELECT, INSERT, UPDATE ON attobot.messages
  TO attobot_agent_primary, attobot_agent_subconscious;   -- NOTE: no DELETE
GRANT SELECT, INSERT, UPDATE, DELETE ON attobot.messages
  TO attobot_service, attobot_admin;

ALTER TABLE attobot.messages ENABLE ROW LEVEL SECURITY;

-- anonymous / authenticated: SELECT is chat-wide (expanded scope). The whole
-- conversation belongs to one configured chat = one agent, so scope by
-- current_agent_id. INSERT/UPDATE below stay pinned to their own from.id.
DROP POLICY IF EXISTS messages_user_select ON attobot.messages;
CREATE POLICY messages_user_select ON attobot.messages
  FOR SELECT TO attobot_anonymous, attobot_authenticated
  USING (
    agent_id = NULLIF(current_setting('attobot.current_agent_id', true), '')::bigint
  );

DROP POLICY IF EXISTS messages_user_insert ON attobot.messages;
CREATE POLICY messages_user_insert ON attobot.messages
  FOR INSERT TO attobot_anonymous, attobot_authenticated
  WITH CHECK (
    payload #>> '{telegram_update,message,from,id}'
      = current_setting('attobot.current_telegram_user_id', true)
  );

DROP POLICY IF EXISTS messages_user_update ON attobot.messages;
CREATE POLICY messages_user_update ON attobot.messages
  FOR UPDATE TO attobot_anonymous, attobot_authenticated
  USING (
    payload #>> '{telegram_update,message,from,id}'
      = current_setting('attobot.current_telegram_user_id', true)
  )
  WITH CHECK (
    payload #>> '{telegram_update,message,from,id}'
      = current_setting('attobot.current_telegram_user_id', true)
  );

-- agent roles: their own agent_id; insert+update only, no delete
DROP POLICY IF EXISTS messages_agent_all_own ON attobot.messages;
CREATE POLICY messages_agent_all_own ON attobot.messages
  FOR ALL TO attobot_agent_primary, attobot_agent_subconscious
  USING (agent_id = NULLIF(current_setting('attobot.current_agent_id', true), '')::bigint)
  WITH CHECK (agent_id = NULLIF(current_setting('attobot.current_agent_id', true), '')::bigint);

-- trusted compute: full access
DROP POLICY IF EXISTS messages_service_bypass ON attobot.messages;
CREATE POLICY messages_service_bypass ON attobot.messages
  FOR ALL TO attobot_service, attobot_admin USING (true) WITH CHECK (true);

-- ============================================================================
-- TABLE: attobot.memory
--   primary owns its memory; subconscious reviews and corrects memory across
--   ALL agents (read + insert + update); service/admin full. No DELETE by agents.
-- ============================================================================

GRANT SELECT, INSERT, UPDATE ON attobot.memory
  TO attobot_agent_primary, attobot_agent_subconscious;   -- no DELETE by agents
GRANT SELECT, INSERT, UPDATE, DELETE ON attobot.memory TO attobot_service, attobot_admin;

ALTER TABLE attobot.memory ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS memory_primary_all_own ON attobot.memory;
CREATE POLICY memory_primary_all_own ON attobot.memory
  FOR ALL TO attobot_agent_primary
  USING (agent_id = NULLIF(current_setting('attobot.current_agent_id', true), '')::bigint)
  WITH CHECK (agent_id = NULLIF(current_setting('attobot.current_agent_id', true), '')::bigint);

-- subconscious reads every agent's memory (to review)...
DROP POLICY IF EXISTS memory_subconscious_read_primary ON attobot.memory;
DROP POLICY IF EXISTS memory_subconscious_read_all ON attobot.memory;
CREATE POLICY memory_subconscious_read_all ON attobot.memory
  FOR SELECT TO attobot_agent_subconscious USING (true);

-- ...inserts corrections into any agent's memory...
DROP POLICY IF EXISTS memory_subconscious_insert_primary ON attobot.memory;
DROP POLICY IF EXISTS memory_subconscious_insert_all ON attobot.memory;
CREATE POLICY memory_subconscious_insert_all ON attobot.memory
  FOR INSERT TO attobot_agent_subconscious WITH CHECK (true);

-- ...and updates any agent's memory.
DROP POLICY IF EXISTS memory_subconscious_update_own ON attobot.memory;
DROP POLICY IF EXISTS memory_subconscious_update_all ON attobot.memory;
CREATE POLICY memory_subconscious_update_all ON attobot.memory
  FOR UPDATE TO attobot_agent_subconscious USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS memory_service_bypass ON attobot.memory;
CREATE POLICY memory_service_bypass ON attobot.memory
  FOR ALL TO attobot_service, attobot_admin USING (true) WITH CHECK (true);

-- ============================================================================
-- TABLE: attobot.memory_sources
--   Junction backing memory's source messages (the composite FKs enforce
--   same-agent integrity and cascade). Ownership mirrors attobot.memory: primary
--   owns its own, subconscious reads and corrects source links across ALL agents,
--   service/admin full.
-- ============================================================================

GRANT SELECT, INSERT, UPDATE ON attobot.memory_sources
  TO attobot_agent_primary, attobot_agent_subconscious;   -- no DELETE by agents
GRANT SELECT, INSERT, UPDATE, DELETE ON attobot.memory_sources TO attobot_service, attobot_admin;

ALTER TABLE attobot.memory_sources ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS memory_sources_primary_all_own ON attobot.memory_sources;
CREATE POLICY memory_sources_primary_all_own ON attobot.memory_sources
  FOR ALL TO attobot_agent_primary
  USING (agent_id = NULLIF(current_setting('attobot.current_agent_id', true), '')::bigint)
  WITH CHECK (agent_id = NULLIF(current_setting('attobot.current_agent_id', true), '')::bigint);

-- subconscious reads every agent's source links...
DROP POLICY IF EXISTS memory_sources_subconscious_read_primary ON attobot.memory_sources;
DROP POLICY IF EXISTS memory_sources_subconscious_read_all ON attobot.memory_sources;
CREATE POLICY memory_sources_subconscious_read_all ON attobot.memory_sources
  FOR SELECT TO attobot_agent_subconscious USING (true);

-- ...inserts source links for any agent...
DROP POLICY IF EXISTS memory_sources_subconscious_insert_primary ON attobot.memory_sources;
DROP POLICY IF EXISTS memory_sources_subconscious_insert_all ON attobot.memory_sources;
CREATE POLICY memory_sources_subconscious_insert_all ON attobot.memory_sources
  FOR INSERT TO attobot_agent_subconscious WITH CHECK (true);

-- ...and updates any agent's source links.
DROP POLICY IF EXISTS memory_sources_subconscious_update_own ON attobot.memory_sources;
DROP POLICY IF EXISTS memory_sources_subconscious_update_all ON attobot.memory_sources;
CREATE POLICY memory_sources_subconscious_update_all ON attobot.memory_sources
  FOR UPDATE TO attobot_agent_subconscious USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS memory_sources_service_bypass ON attobot.memory_sources;
CREATE POLICY memory_sources_service_bypass ON attobot.memory_sources
  FOR ALL TO attobot_service, attobot_admin USING (true) WITH CHECK (true);

-- ============================================================================
-- TABLE: attobot.config
--   Agent roles SELECT their own config INCLUDING secrets: the loop body runs as
--   the agent role and needs api_key / telegram_token to call the model and send.
--   This is safe because the LLM never executes as an agent role — only fixed
--   loop code does. LLM-authored SQL runs as the user tier (primary) or
--   attobot_service (subconscious), neither of which can read secrets.
--   attobot_service is the subconscious's broad, secret-free tool scope, so it
--   gets non-secret SELECT only. All writes go through attobot.set_config (a
--   function) as superuser/admin, so only admin gets direct table writes.
-- ============================================================================

GRANT SELECT ON attobot.config
  TO attobot_agent_primary, attobot_agent_subconscious, attobot_service;
GRANT SELECT, INSERT, UPDATE, DELETE ON attobot.config TO attobot_admin;

ALTER TABLE attobot.config ENABLE ROW LEVEL SECURITY;

-- agent roles: their own config rows (incl. secrets) — fixed loop code only
DROP POLICY IF EXISTS config_agent_read_own_nonsecret ON attobot.config;
DROP POLICY IF EXISTS config_agent_read_own ON attobot.config;
CREATE POLICY config_agent_read_own ON attobot.config
  FOR SELECT TO attobot_agent_primary, attobot_agent_subconscious
  USING (agent_id = NULLIF(current_setting('attobot.current_agent_id', true), '')::bigint);

-- attobot_service: the subconscious's broad, secret-free tool scope
DROP POLICY IF EXISTS config_service_bypass ON attobot.config;
DROP POLICY IF EXISTS config_service_read_nonsecret ON attobot.config;
CREATE POLICY config_service_read_nonsecret ON attobot.config
  FOR SELECT TO attobot_service USING (secret = false);

-- admin: full bypass (all rows incl. secrets, all commands)
DROP POLICY IF EXISTS config_admin_bypass ON attobot.config;
CREATE POLICY config_admin_bypass ON attobot.config
  FOR ALL TO attobot_admin USING (true) WITH CHECK (true);

-- ============================================================================
-- TABLE: attobot.lifecycle   (audit log — internal; agents append+read, service tracks)
-- ============================================================================

GRANT SELECT, INSERT ON attobot.lifecycle
  TO attobot_agent_primary, attobot_agent_subconscious;
GRANT SELECT, INSERT, UPDATE ON attobot.lifecycle TO attobot_service;
GRANT SELECT, INSERT, UPDATE, DELETE ON attobot.lifecycle TO attobot_admin;

ALTER TABLE attobot.lifecycle ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS lifecycle_agent_read ON attobot.lifecycle;
CREATE POLICY lifecycle_agent_read ON attobot.lifecycle
  FOR SELECT TO attobot_agent_primary, attobot_agent_subconscious USING (true);

DROP POLICY IF EXISTS lifecycle_agent_insert ON attobot.lifecycle;
CREATE POLICY lifecycle_agent_insert ON attobot.lifecycle
  FOR INSERT TO attobot_agent_primary, attobot_agent_subconscious WITH CHECK (true);

-- Postgres CREATE POLICY targets a single command; split per command.
-- (No DELETE policy for service -> deletes denied even though the bypass
--  predicates are true, because attobot_service is not granted DELETE here.)
DROP POLICY IF EXISTS lifecycle_service_select ON attobot.lifecycle;
CREATE POLICY lifecycle_service_select ON attobot.lifecycle
  FOR SELECT TO attobot_service USING (true);

DROP POLICY IF EXISTS lifecycle_service_insert ON attobot.lifecycle;
CREATE POLICY lifecycle_service_insert ON attobot.lifecycle
  FOR INSERT TO attobot_service WITH CHECK (true);

DROP POLICY IF EXISTS lifecycle_service_update ON attobot.lifecycle;
CREATE POLICY lifecycle_service_update ON attobot.lifecycle
  FOR UPDATE TO attobot_service USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS lifecycle_admin_bypass ON attobot.lifecycle;
CREATE POLICY lifecycle_admin_bypass ON attobot.lifecycle
  FOR ALL TO attobot_admin USING (true) WITH CHECK (true);

-- ============================================================================
-- TABLE: attotools.blobs   (agent-scoped content store)
-- ============================================================================

GRANT SELECT, INSERT, UPDATE ON attotools.blobs
  TO attobot_agent_primary, attobot_agent_subconscious;   -- no DELETE
GRANT SELECT, INSERT, UPDATE, DELETE ON attotools.blobs TO attobot_service, attobot_admin;

ALTER TABLE attotools.blobs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS blobs_agent_all_own ON attotools.blobs;
CREATE POLICY blobs_agent_all_own ON attotools.blobs
  FOR ALL TO attobot_agent_primary, attobot_agent_subconscious
  USING (agent_id = NULLIF(current_setting('attobot.current_agent_id', true), '')::bigint)
  WITH CHECK (agent_id = NULLIF(current_setting('attobot.current_agent_id', true), '')::bigint);

DROP POLICY IF EXISTS blobs_service_bypass ON attotools.blobs;
CREATE POLICY blobs_service_bypass ON attotools.blobs
  FOR ALL TO attobot_service, attobot_admin USING (true) WITH CHECK (true);

-- ============================================================================
-- TABLE: attobot.users   (channel identity ledger; intake upserts telegram users)
--   A user reads only their own row; agent/service read all (to resolve the
--   requesting user during a turn); service inserts (ensure_user); the primary
--   agent role may also create and edit users (insert/update, no delete — e.g.
--   to promote tier); admin manages the ledger incl. promoting tier
--   anonymous -> authenticated.
-- ============================================================================

GRANT SELECT ON attobot.users
  TO attobot_anonymous, attobot_authenticated,
     attobot_agent_primary, attobot_agent_subconscious, attobot_service;
GRANT INSERT, UPDATE ON attobot.users TO attobot_agent_primary;
GRANT INSERT ON attobot.users TO attobot_service;
GRANT SELECT, INSERT, UPDATE ON attobot.users TO attobot_admin;
GRANT USAGE ON SEQUENCE attobot.users_id_seq
  TO attobot_agent_primary, attobot_service, attobot_admin;

ALTER TABLE attobot.users ENABLE ROW LEVEL SECURITY;

-- a user sees only their own row (resolved by the internal id in their session)
DROP POLICY IF EXISTS users_user_select_own ON attobot.users;
CREATE POLICY users_user_select_own ON attobot.users
  FOR SELECT TO attobot_anonymous, attobot_authenticated
  USING (id = NULLIF(current_setting('attobot.current_user_id', true), '')::bigint);

-- agent + service read all users (resolve the requesting user during a turn)
DROP POLICY IF EXISTS users_agent_service_read ON attobot.users;
CREATE POLICY users_agent_service_read ON attobot.users
  FOR SELECT TO attobot_agent_primary, attobot_agent_subconscious, attobot_service
  USING (true);

-- service inserts new users (ensure_user from intake)
DROP POLICY IF EXISTS users_service_insert ON attobot.users;
CREATE POLICY users_service_insert ON attobot.users
  FOR INSERT TO attobot_service WITH CHECK (true);

-- attobot_agent_primary creates and edits users (no DELETE). The ledger has no
-- agent_id, so management is global; it can promote tier, but not delete rows.
DROP POLICY IF EXISTS users_primary_insert ON attobot.users;
CREATE POLICY users_primary_insert ON attobot.users
  FOR INSERT TO attobot_agent_primary WITH CHECK (true);

DROP POLICY IF EXISTS users_primary_update ON attobot.users;
CREATE POLICY users_primary_update ON attobot.users
  FOR UPDATE TO attobot_agent_primary USING (true) WITH CHECK (true);

-- admin manages the ledger (incl. promoting tier)
DROP POLICY IF EXISTS users_admin_all ON attobot.users;
CREATE POLICY users_admin_all ON attobot.users
  FOR ALL TO attobot_admin USING (true) WITH CHECK (true);

-- ============================================================================
-- FUNCTION EXECUTE PRIVILEGES
--   Per-function for the verified attobot entrypoints (least privilege, and
--   to document the intent). Schema-wide for attotools (the agent tooling
--   surface) and for the trusted service role.
-- ============================================================================

-- Trusted backend (attobot_service runs every durable instance) + admin: full
-- function surface.
-- Agent roles now run their own loops, so they also need the full attobot
-- function surface (compose_llm_request, record_assistant, poll_messages,
-- ensure_user, helpers, ...).
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA attobot
  TO attobot_service, attobot_admin, attobot_agent_primary, attobot_agent_subconscious;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA attotools TO attobot_service, attobot_admin;

-- Acting roles (user tiers + per-agent roles) run tool functions inside
-- per-call tool instances. EXECUTE is broad but contained: row-level security
-- on the underlying tables bounds what they can actually read or write.
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA attotools
  TO attobot_agent_primary, attobot_agent_subconscious, attobot_anonymous, attobot_authenticated;
GRANT EXECUTE ON FUNCTION attobot.append_message(text, text, text, jsonb, text, text, text)
  TO attobot_agent_primary, attobot_agent_subconscious, attobot_anonymous, attobot_authenticated;
GRANT EXECUTE ON FUNCTION attobot.queue_outbound_attachment(text, text, text, text, text, text)
  TO attobot_anonymous, attobot_authenticated;

-- ============================================================================
-- DURABLE FRAMEWORK ACCESS (pg_durable)
--   pg_durable.enable_superuser_instances is OFF (default), so durable instances
--   may NOT be owned by a superuser. The workflow-starting functions in
--   30-attobot-durable.sql are SECURITY DEFINER owned by the agent roles (or
--   SECURITY INVOKER for the shared start_agent_loop), so every df.start submits
--   as the acting agent role (a non-superuser). The agent roles run df.http
--   (LLM call, Telegram poll/send) and manage per-call tool instances, so they
--   get include_http. attobot_service no longer submits workflows, so it gets no
--   df access.
--   (attobot_anonymous / attobot_authenticated are intentionally NOT granted df
--    access: end users interact through the agent, not by submitting durable
--    workflows themselves.)
-- ============================================================================
SELECT df.grant_usage('attobot_admin',              include_http => true);
SELECT df.grant_usage('attobot_agent_primary',      include_http => true);
SELECT df.grant_usage('attobot_agent_subconscious', include_http => true);

-- The durable worker connects as the submitted role (now an agent role, made
-- LOGIN above) to execute instance SQL. Per-call tool instances are submitted
-- by the agent role, and run_tool_call_as_role SET ROLEs down to the acting
-- tool scope inside them, so RESET ROLE restores to the agent role (no
-- escalation). Each agent role must be a member of its tool-scope role:
--   primary      -> the requesting user's tier (anonymous / authenticated)
--   subconscious -> attobot_service (broad, secret-free)
REVOKE attobot_anonymous FROM attobot_service;
REVOKE attobot_authenticated FROM attobot_service;
GRANT attobot_anonymous TO attobot_agent_primary;
GRANT attobot_authenticated TO attobot_agent_primary;
GRANT attobot_service TO attobot_agent_subconscious;

-- Entry-point SECURITY DEFINER starters: owned by the agent whose context they
-- submit as (df.start submits as the owner). start_agent_loop is SECURITY
-- INVOKER (shared by both agents; it inherits the caller's identity), so it is
-- not re-owned here. Telegram inbox + outbound paths belong to primary; the
-- cron loop belongs to subconscious.
ALTER FUNCTION attobot.ensure_telegram_inbox_loop(text, integer)       OWNER TO attobot_agent_primary;
ALTER FUNCTION attobot.ensure_agent_cron_loop(text, text, text, text)  OWNER TO attobot_agent_subconscious;
ALTER FUNCTION attobot.after_user_message_loop()                       OWNER TO attobot_agent_primary;
ALTER FUNCTION attobot.after_outbound_message_send()                   OWNER TO attobot_agent_primary;
ALTER FUNCTION attobot.send_message(bigint)                            OWNER TO attobot_agent_primary;
ALTER FUNCTION attobot.send_message_future(bigint)                     OWNER TO attobot_agent_primary;
ALTER FUNCTION attobot.queue_outbound_attachment(text, text, text, text, text, text) OWNER TO attobot_agent_primary;

-- ============================================================================
-- CONTEXT HELPER  (sets the ABAC session attributes; see design §10.2)
--   Uses the 3-argument built-in set_config(name, value, is_local).
--   Role switching is performed by the connection layer / intake loop after
--   calling this (SET LOCAL ROLE), not baked in here.
-- ============================================================================

CREATE OR REPLACE FUNCTION attobot.set_context(
  p_role text,
  p_agent_id bigint DEFAULT NULL,
  p_telegram_user_id text DEFAULT NULL,
  p_telegram_chat_id text DEFAULT NULL,
  p_user_id bigint DEFAULT NULL,
  p_channel text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = attobot, attotools, pg_temp
AS $$
BEGIN
  PERFORM set_config('attobot.current_role', p_role, true);
  PERFORM set_config('attobot.current_agent_id', COALESCE(p_agent_id::text, ''), true);
  PERFORM set_config('attobot.current_telegram_user_id', COALESCE(p_telegram_user_id, ''), true);
  PERFORM set_config('attobot.current_telegram_chat_id', COALESCE(p_telegram_chat_id, ''), true);
  PERFORM set_config('attobot.current_user_id', COALESCE(p_user_id::text, ''), true);
  PERFORM set_config('attobot.current_channel', COALESCE(p_channel, ''), true);
END;
$$;

-- ============================================================================
-- Phase 1 marker
-- ============================================================================

DO $$
DECLARE
  v_agent_id bigint;
BEGIN
  SELECT id INTO v_agent_id FROM attobot.agents WHERE slug = 'primary' LIMIT 1;
  IF v_agent_id IS NOT NULL THEN
    INSERT INTO attobot.lifecycle(agent_id, event, detail)
    VALUES (v_agent_id, 'security.rls.phase1', jsonb_build_object('note', 'roles + RLS policies defined; enforcement deferred to Phase 2'));
  END IF;
END $$;
