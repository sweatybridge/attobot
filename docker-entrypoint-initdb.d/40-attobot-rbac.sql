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
GRANT USAGE ON SEQUENCE attobot.outbox_id_seq
  TO attobot_agent_primary, attobot_service, attobot_admin;
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
--   primary owns its memory; subconscious reads primary + writes corrections
--   into primary and updates its own; service/admin full.
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

-- subconscious can read everything the primary owns...
DROP POLICY IF EXISTS memory_subconscious_read_primary ON attobot.memory;
CREATE POLICY memory_subconscious_read_primary ON attobot.memory
  FOR SELECT TO attobot_agent_subconscious
  USING (agent_id = (SELECT id FROM attobot.agents WHERE slug = 'primary'));

-- ...insert corrections into the primary's memory...
DROP POLICY IF EXISTS memory_subconscious_insert_primary ON attobot.memory;
CREATE POLICY memory_subconscious_insert_primary ON attobot.memory
  FOR INSERT TO attobot_agent_subconscious
  WITH CHECK (agent_id = (SELECT id FROM attobot.agents WHERE slug = 'primary'));

-- ...and update its own memory rows.
DROP POLICY IF EXISTS memory_subconscious_update_own ON attobot.memory;
CREATE POLICY memory_subconscious_update_own ON attobot.memory
  FOR UPDATE TO attobot_agent_subconscious
  USING (agent_id = NULLIF(current_setting('attobot.current_agent_id', true), '')::bigint)
  WITH CHECK (agent_id = NULLIF(current_setting('attobot.current_agent_id', true), '')::bigint);

DROP POLICY IF EXISTS memory_service_bypass ON attobot.memory;
CREATE POLICY memory_service_bypass ON attobot.memory
  FOR ALL TO attobot_service, attobot_admin USING (true) WITH CHECK (true);

-- ============================================================================
-- TABLE: attobot.config
--   Agent roles can SELECT their own NON-SECRET config only. All writes go
--   through attobot.set_config (a function), so agents get no direct
--   INSERT/UPDATE/DELETE on the table. service/admin see everything.
--   NOTE (Phase 3 dependency): secret values (api_key, telegram_token) are
--   read by _llm_headers / _telegram_api_url via _config_text. Those helpers
--   must be converted to SECURITY DEFINER (Phase 3) before agent roles can
--   run turns non-superuser, else they resolve to NULL.
-- ============================================================================

GRANT SELECT ON attobot.config
  TO attobot_agent_primary, attobot_agent_subconscious;  -- RLS hides secrets
GRANT SELECT, INSERT, UPDATE, DELETE ON attobot.config TO attobot_service, attobot_admin;

ALTER TABLE attobot.config ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS config_agent_read_own_nonsecret ON attobot.config;
CREATE POLICY config_agent_read_own_nonsecret ON attobot.config
  FOR SELECT TO attobot_agent_primary, attobot_agent_subconscious
  USING (
        agent_id = NULLIF(current_setting('attobot.current_agent_id', true), '')::bigint
    AND secret = false
  );

DROP POLICY IF EXISTS config_service_bypass ON attobot.config;
CREATE POLICY config_service_bypass ON attobot.config
  FOR ALL TO attobot_service, attobot_admin USING (true) WITH CHECK (true);

-- ============================================================================
-- TABLE: attobot.outbox
--   primary can enqueue/update its own; subconscious cannot send; service/admin full.
-- ============================================================================

GRANT SELECT, INSERT, UPDATE ON attobot.outbox TO attobot_agent_primary;   -- no DELETE
GRANT SELECT, INSERT, UPDATE, DELETE ON attobot.outbox TO attobot_service, attobot_admin;

ALTER TABLE attobot.outbox ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS outbox_primary_all_own ON attobot.outbox;
CREATE POLICY outbox_primary_all_own ON attobot.outbox
  FOR ALL TO attobot_agent_primary
  USING (agent_id = NULLIF(current_setting('attobot.current_agent_id', true), '')::bigint)
  WITH CHECK (agent_id = NULLIF(current_setting('attobot.current_agent_id', true), '')::bigint);

DROP POLICY IF EXISTS outbox_service_bypass ON attobot.outbox;
CREATE POLICY outbox_service_bypass ON attobot.outbox
  FOR ALL TO attobot_service, attobot_admin USING (true) WITH CHECK (true);

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
--   requesting user during a turn); service inserts (ensure_user); admin
--   manages the ledger incl. promoting tier anonymous -> authenticated.
-- ============================================================================

GRANT SELECT ON attobot.users
  TO attobot_anonymous, attobot_authenticated,
     attobot_agent_primary, attobot_agent_subconscious, attobot_service;
GRANT INSERT ON attobot.users TO attobot_service;
GRANT SELECT, INSERT, UPDATE ON attobot.users TO attobot_admin;
GRANT USAGE ON SEQUENCE attobot.users_id_seq TO attobot_service, attobot_admin;

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

-- Telegram intake entrypoint — the one function anonymous may call.
GRANT EXECUTE ON FUNCTION attobot.process_telegram_updates(text, jsonb) TO attobot_anonymous;

-- Agent-turn functions (verified signatures).
GRANT EXECUTE ON FUNCTION attobot.agent_id(text)
  TO attobot_agent_primary, attobot_agent_subconscious, attobot_service, attobot_admin;
GRANT EXECUTE ON FUNCTION attobot.append_message(text, text, text, jsonb, text)
  TO attobot_agent_primary, attobot_agent_subconscious, attobot_service;
GRANT EXECUTE ON FUNCTION attobot.start_turn(text, bigint)
  TO attobot_agent_primary, attobot_service;
GRANT EXECUTE ON FUNCTION attobot.ensure_user(text, text, text, text, jsonb)
  TO attobot_service, attobot_admin;
GRANT EXECUTE ON FUNCTION attobot.finish_turn(text, bigint)
  TO attobot_agent_primary, attobot_service;
GRANT EXECUTE ON FUNCTION attobot.compose_llm_request(text)
  TO attobot_agent_primary, attobot_service;
GRANT EXECUTE ON FUNCTION attobot._config_text(bigint, text, text)
  TO attobot_agent_primary, attobot_agent_subconscious, attobot_service;
GRANT EXECUTE ON FUNCTION attobot._system_prompt(bigint)
  TO attobot_agent_primary, attobot_agent_subconscious, attobot_service;
GRANT EXECUTE ON FUNCTION attobot._memory_prompt(bigint)
  TO attobot_agent_primary, attobot_agent_subconscious, attobot_service;
GRANT EXECUTE ON FUNCTION attobot._message_for_openai(attobot.messages)
  TO attobot_agent_primary, attobot_agent_subconscious, attobot_service;
GRANT EXECUTE ON FUNCTION attobot.log_event(bigint, text, jsonb)
  TO attobot_agent_primary, attobot_agent_subconscious, attobot_service, attobot_admin;

-- Config writes go through set_config (admin/service bootstrap; agents call it
-- for their own config, enforced inside the function in Phase 3).
GRANT EXECUTE ON FUNCTION attobot.set_config(text, text, jsonb, boolean)
  TO attobot_service, attobot_admin;

-- Bootstrap / configuration (admin + service).
GRANT EXECUTE ON FUNCTION attobot.ensure_model(text, text, numeric, text, integer, boolean)
  TO attobot_admin, attobot_service;
GRANT EXECUTE ON FUNCTION attobot.ensure_agent(text, text, text, bigint)
  TO attobot_admin, attobot_service;
GRANT EXECUTE ON FUNCTION attobot.configure_telegram(text, text, text, text, text)
  TO attobot_admin, attobot_service;

-- Durable workflow control (service + admin).
GRANT EXECUTE ON FUNCTION attobot.ensure_scheduled_message_loop(text, text, text, text)
  TO attobot_service, attobot_admin;
GRANT EXECUTE ON FUNCTION attobot.ensure_telegram_inbox_loop(text, integer)
  TO attobot_service, attobot_admin;
GRANT EXECUTE ON FUNCTION attobot.start_telegram_outbox_send(text, bigint)
  TO attobot_service, attobot_admin;

-- The trusted backend needs the full attobot function surface.
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA attobot TO attobot_service;

-- Agent tooling surface (attotools). Bounded at the data layer by RLS on
-- blobs/messages; the SQL tool itself runs as the agent role and is therefore
-- RLS-bounded too.
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA attotools
  TO attobot_agent_primary, attobot_agent_subconscious, attobot_service;

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
