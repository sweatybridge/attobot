-- ABAC and RLS Security for AttoBot
-- This script implements role-based access control with row-level security
-- following the principle of least privilege.

-- ============================================================================
-- ROLES
-- ============================================================================

-- Base roles
DO $$
BEGIN
  -- Create base roles if they don't exist
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'attobot_anonymous') THEN
    CREATE ROLE attobot_anonymous NOINHERIT;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'attobot_authenticated') THEN
    CREATE ROLE attobot_authenticated NOINHERIT;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'attobot_service') THEN
    CREATE ROLE attobot_service NOINHERIT;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'attobot_admin') THEN
    CREATE ROLE attobot_admin NOINHERIT;
  END IF;

  -- Agent-specific roles
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'attobot_agent_primary') THEN
    CREATE ROLE attobot_agent_primary NOINHERIT;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'attobot_agent_subconscious') THEN
    CREATE ROLE attobot_agent_subconscious NOINHERIT;
  END IF;

  -- Role hierarchy: authenticated inherits anonymous
  -- (Not implemented with INHERIT to avoid privilege cascading;
  --  instead, we grant both roles where needed)

EXCEPTION WHEN duplicate_object THEN
  -- Roles already exist, continue
  NULL;
END $$;

-- ============================================================================
-- SCHEMA PERMISSIONS
-- ============================================================================

-- Grant usage on schemas
GRANT USAGE ON SCHEMA attobot TO attobot_anonymous, attobot_authenticated, attobot_service, attobot_admin, attobot_agent_primary, attobot_agent_subconscious;
GRANT USAGE ON SCHEMA attotools TO attobot_service, attobot_admin, attobot_agent_primary, attobot_agent_subconscious;

-- ============================================================================
-- TABLE PERMISSIONS - attobot.agents
-- ============================================================================

ALTER TABLE attobot.agents ENABLE ROW LEVEL SECURITY;

-- All roles can read agents
CREATE POLICY agents_read_all ON attobot.agents
  FOR SELECT
  TO PUBLIC
  USING (true);

-- Only admin can modify agents
CREATE POLICY agents_admin_write ON attobot.agents
  FOR ALL
  TO attobot_admin
  USING (true)
  WITH CHECK (true);

GRANT SELECT ON attobot.agents TO attobot_anonymous, attobot_authenticated, attobot_agent_primary, attobot_agent_subconscious, attobot_service;

-- ============================================================================
-- TABLE PERMISSIONS - attobot.models
-- ============================================================================

ALTER TABLE attobot.models ENABLE ROW LEVEL SECURITY;

-- All roles can read models
CREATE POLICY models_read_all ON attobot.models
  FOR SELECT
  TO PUBLIC
  USING (true);

-- Only admin can modify models
CREATE POLICY models_admin_write ON attobot.models
  FOR ALL
  TO attobot_admin
  USING (true)
  WITH CHECK (true);

GRANT SELECT ON attobot.models TO attobot_anonymous, attobot_authenticated, attobot_agent_primary, attobot_agent_subconscious, attobot_service;

-- ============================================================================
-- TABLE PERMISSIONS - attobot.messages
-- ============================================================================

ALTER TABLE attobot.messages ENABLE ROW LEVEL SECURITY;

-- Anonymous users can read messages from their telegram user_id
CREATE POLICY messages_anon_read_own ON attobot.messages
  FOR SELECT
  TO attobot_anonymous
  USING (
    payload #>> '{telegram_update,message,from,id}' = current_setting('attobot.current_telegram_user_id', true)
  );

-- Authenticated users can read their agent's messages
CREATE POLICY messages_auth_read_agent ON attobot.messages
  FOR SELECT
  TO attobot_authenticated
  USING (
    agent_id = NULLIF(current_setting('attobot.current_agent_id', true), '')::bigint
  );

-- Agent roles have full access to their agent's messages
CREATE POLICY messages_agent_all_own ON attobot.messages
  FOR ALL
  TO attobot_agent_primary, attobot_agent_subconscious
  USING (
    agent_id = NULLIF(current_setting('attobot.current_agent_id', true), '')::bigint
  )
  WITH CHECK (
    agent_id = NULLIF(current_setting('attobot.current_agent_id', true), '')::bigint
  );

-- Service roles bypass RLS
CREATE POLICY messages_service_bypass ON attobot.messages
  FOR ALL
  TO attobot_service
  USING (true)
  WITH CHECK (true);

GRANT SELECT ON attobot.messages TO attobot_anonymous, attobot_authenticated, attobot_agent_primary, attobot_agent_subconscious, attobot_service;

-- ============================================================================
-- TABLE PERMISSIONS - attobot.config
-- ============================================================================

ALTER TABLE attobot.config ENABLE ROW LEVEL SECURITY;

-- Agent roles can manage their agent's config
CREATE POLICY config_agent_all_own ON attobot.config
  FOR ALL
  TO attobot_agent_primary, attobot_agent_subconscious
  USING (
    agent_id = NULLIF(current_setting('attobot.current_agent_id', true), '')::bigint
  )
  WITH CHECK (
    agent_id = NULLIF(current_setting('attobot.current_agent_id', true), '')::bigint
  );

-- Service roles bypass RLS
CREATE POLICY config_service_bypass ON attobot.config
  FOR ALL
  TO attobot_service
  USING (true)
  WITH CHECK (true);

GRANT SELECT ON attobot.config TO attobot_agent_primary, attobot_agent_subconscious, attobot_service;

-- ============================================================================
-- TABLE PERMISSIONS - attotools.blobs
-- ============================================================================

ALTER TABLE attotools.blobs ENABLE ROW LEVEL SECURITY;

-- Agent roles can manage their agent's blobs
CREATE POLICY blobs_agent_all_own ON attotools.blobs
  FOR ALL
  TO attobot_agent_primary, attobot_agent_subconscious
  USING (
    agent_id = NULLIF(current_setting('attobot.current_agent_id', true), '')::bigint
  )
  WITH CHECK (
    agent_id = NULLIF(current_setting('attobot.current_agent_id', true), '')::bigint
  );

-- Service roles bypass RLS
CREATE POLICY blobs_service_bypass ON attotools.blobs
  FOR ALL
  TO attobot_service
  USING (true)
  WITH CHECK (true);

GRANT SELECT ON attotools.blobs TO attobot_agent_primary, attobot_agent_subconscious, attobot_service;

-- ============================================================================
-- TABLE PERMISSIONS - attobot.outbox
-- ============================================================================

ALTER TABLE attobot.outbox ENABLE ROW LEVEL SECURITY;

-- Agent roles can manage their agent's outbox
CREATE POLICY outbox_agent_all_own ON attobot.outbox
  FOR ALL
  TO attobot_agent_primary, attobot_agent_subconscious
  USING (
    agent_id = NULLIF(current_setting('attobot.current_agent_id', true), '')::bigint
  )
  WITH CHECK (
    agent_id = NULLIF(current_setting('attobot.current_agent_id', true), '')::bigint
  );

-- Service roles bypass RLS
CREATE POLICY outbox_service_bypass ON attobot.outbox
  FOR ALL
  TO attobot_service
  USING (true)
  WITH CHECK (true);

GRANT SELECT ON attobot.outbox TO attobot_agent_primary, attobot_agent_subconscious, attobot_service;

-- ============================================================================
-- TABLE PERMISSIONS - attobot.memory
-- ============================================================================

ALTER TABLE attobot.memory ENABLE ROW LEVEL SECURITY;

-- Primary agent manages its memory
CREATE POLICY memory_primary_all_own ON attobot.memory
  FOR ALL
  TO attobot_agent_primary
  USING (
    agent_id = NULLIF(current_setting('attobot.current_agent_id', true), '')::bigint
  )
  WITH CHECK (
    agent_id = NULLIF(current_setting('attobot.current_agent_id', true), '')::bigint
  );

-- Subconscious can read primary's memory
CREATE POLICY memory_subconscious_read_primary ON attobot.memory
  FOR SELECT
  TO attobot_agent_subconscious
  USING (
    agent_id = (SELECT id FROM attobot.agents WHERE slug = 'primary')
  );

-- Subconscious can write to primary's memory (for corrections)
CREATE POLICY memory_subconscious_write_primary ON attobot.memory
  FOR INSERT
  TO attobot_agent_subconscious
  WITH CHECK (
    agent_id = (SELECT id FROM attobot.agents WHERE slug = 'primary')
  );

-- Subconscious can update its own memory entries
CREATE POLICY memory_subconscious_update_own ON attobot.memory
  FOR UPDATE
  TO attobot_agent_subconscious
  USING (
    agent_id = NULLIF(current_setting('attobot.current_agent_id', true), '')::bigint
  )
  WITH CHECK (
    agent_id = NULLIF(current_setting('attobot.current_agent_id', true), '')::bigint
  );

-- Service roles bypass RLS
CREATE POLICY memory_service_bypass ON attobot.memory
  FOR ALL
  TO attobot_service
  USING (true)
  WITH CHECK (true);

GRANT SELECT ON attobot.memory TO attobot_agent_primary, attobot_agent_subconscious, attobot_service;

-- ============================================================================
-- TABLE PERMISSIONS - attobot.lifecycle
-- ============================================================================

ALTER TABLE attobot.lifecycle ENABLE ROW LEVEL SECURITY;

-- All roles can read lifecycle (audit log)
CREATE POLICY lifecycle_read_all ON attobot.lifecycle
  FOR SELECT
  TO PUBLIC
  USING (true);

-- Service roles can insert
CREATE POLICY lifecycle_service_insert ON attobot.lifecycle
  FOR INSERT
  TO attobot_service
  WITH CHECK (true);

-- Service roles can update (for durable instance tracking)
CREATE POLICY lifecycle_service_update ON attobot.lifecycle
  FOR UPDATE
  TO attobot_service
  USING (true)
  WITH CHECK (true);

GRANT SELECT ON attobot.lifecycle TO attobot_anonymous, attobot_authenticated, attobot_agent_primary, attobot_agent_subconscious, attobot_service;

-- ============================================================================
-- FUNCTION PERMISSIONS
-- ============================================================================

-- Grant execute permissions for functions

-- Public functions (Telegram intake) - anonymous users can call these
GRANT EXECUTE ON FUNCTION attobot.process_telegram_updates(text, jsonb) TO attobot_anonymous;

-- Agent functions
GRANT EXECUTE ON FUNCTION attobot.agent_id(text) TO attobot_agent_primary, attobot_agent_subconscious, attobot_service, attobot_admin;
GRANT EXECUTE ON FUNCTION attobot.append_message(text, text, text, jsonb, text) TO attobot_agent_primary, attobot_agent_subconscious, attobot_service;
GRANT EXECUTE ON FUNCTION attobot.start_turn(text) TO attobot_agent_primary, attobot_service;
GRANT EXECUTE ON FUNCTION attobot.finish_turn(text, bigint) TO attobot_agent_primary, attobot_service;
GRANT EXECUTE ON FUNCTION attobot.compose_llm_request(text) TO attobot_agent_primary, attobot_service;

-- Config functions
GRANT EXECUTE ON FUNCTION attobot._config_text(bigint, text, text) TO attobot_agent_primary, attobot_agent_subconscious, attobot_service;
GRANT EXECUTE ON FUNCTION attobot._system_prompt(bigint) TO attobot_agent_primary, attobot_agent_subconscious, attobot_service;

-- Logging functions
GRANT EXECUTE ON FUNCTION attobot.log_event(bigint, text, jsonb) TO attobot_service, attobot_admin, attobot_agent_primary, attobot_agent_subconscious;

-- Model and agent setup functions (admin only)
GRANT EXECUTE ON FUNCTION attobot.ensure_model(text, text, numeric, text, integer, boolean) TO attobot_admin, attobot_service;
GRANT EXECUTE ON FUNCTION attobot.ensure_agent(text, text, text, bigint) TO attobot_admin, attobot_service;

-- Telegram configuration (admin only)
GRANT EXECUTE ON FUNCTION attobot.configure_telegram(text, text, text, text, text) TO attobot_admin, attobot_service;
GRANT EXECUTE ON FUNCTION attobot._telegram_api_url(text, text) TO attobot_service, attobot_agent_primary, attobot_agent_subconscious;
GRANT EXECUTE ON FUNCTION attobot.telegram_get_updates_body(text, integer) TO attobot_service, attobot_agent_primary;
GRANT EXECUTE ON FUNCTION attobot._telegram_claim_outbox(text, bigint) TO attobot_service;
GRANT EXECUTE ON FUNCTION attobot.record_telegram_send_result(text, bigint, jsonb) TO attobot_service;

-- Durable functions (service only)
GRANT EXECUTE ON FUNCTION attobot.ensure_scheduled_message_loop(text, text, text, text) TO attobot_service, attobot_admin;
GRANT EXECUTE ON FUNCTION attobot.ensure_telegram_inbox_loop(text, integer) TO attobot_service, attobot_admin;
GRANT EXECUTE ON FUNCTION attobot.start_telegram_outbox_send(text, bigint) TO attobot_service;

-- Tools functions
GRANT EXECUTE ON FUNCTION attotools.tool_signal_name(text, bigint) TO attobot_service, attobot_agent_primary, attobot_agent_subconscious;
GRANT EXECUTE ON FUNCTION attotools.start_tool_signal_executor(text, bigint, bigint) TO attobot_service;
GRANT EXECUTE ON FUNCTION attotools.record_tool_signal(text, bigint, jsonb) TO attobot_service;

-- HTTP helpers
GRANT EXECUTE ON FUNCTION attobot._try_jsonb(text) TO attobot_anonymous, attobot_authenticated, attobot_agent_primary, attobot_agent_subconscious, attobot_service;
GRANT EXECUTE ON FUNCTION attobot._http_status(jsonb) TO attobot_anonymous, attobot_authenticated, attobot_agent_primary, attobot_agent_subconscious, attobot_service;
GRANT EXECUTE ON FUNCTION attobot._http_body_json(jsonb) TO attobot_anonymous, attobot_authenticated, attobot_agent_primary, attobot_agent_subconscious, attobot_service;
GRANT EXECUTE ON FUNCTION attobot._message_for_openai(attobot.messages) TO attobot_agent_primary, attobot_agent_subconscious, attobot_service;
GRANT EXECUTE ON FUNCTION attobot._memory_prompt(bigint) TO attobot_agent_primary, attobot_agent_subconscious, attobot_service;
GRANT EXECUTE ON FUNCTION attotools._tool_schemas() TO attobot_agent_primary, attobot_agent_subconscious, attobot_service;

-- ============================================================================
-- SECURITY DEFINER FUNCTIONS
-- ============================================================================

-- Mark sensitive functions as SECURITY DEFINER with explicit search_path

-- append_message - already handles agent_id internally
-- No changes needed - uses attobot.agent_id which resolves slug to id

-- configure_telegram - should be security definer to protect secrets
CREATE OR REPLACE FUNCTION attobot.configure_telegram(
  p_agent_slug text,
  p_token text,
  p_chat_id text,
  p_thread_id text DEFAULT NULL,
  p_api_base text DEFAULT 'https://api.telegram.org'
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = attobot, attotools, pg_temp
AS $$
DECLARE
  v_agent_id bigint := attobot.agent_id(p_agent_slug);
BEGIN
  -- Security check: only admin or service role
  IF current_user NOT IN ('attobot_admin', 'attobot_service', 'postgres') THEN
    RAISE EXCEPTION 'permission denied for configure_telegram';
  END IF;

  PERFORM attobot.set_config(p_agent_slug, 'telegram_token', to_jsonb(p_token), true);
  PERFORM attobot.set_config(p_agent_slug, 'telegram_chat_id', to_jsonb(p_chat_id));
  PERFORM attobot.set_config(p_agent_slug, 'telegram_api_base', to_jsonb(p_api_base));
  PERFORM attobot.set_config(p_agent_slug, 'telegram_update_offset', to_jsonb(0));

  IF p_thread_id IS NULL OR p_thread_id = '' THEN
    DELETE FROM attobot.config
    WHERE agent_id = v_agent_id
      AND key = 'telegram_thread_id';
  ELSE
    PERFORM attobot.set_config(p_agent_slug, 'telegram_thread_id', to_jsonb(p_thread_id));
  END IF;

  PERFORM attobot.log_event(v_agent_id, 'telegram.configure', jsonb_build_object('chat_id', p_chat_id));
END;
$$;

-- ensure_agent - should be security definer
CREATE OR REPLACE FUNCTION attobot.ensure_agent(
  p_slug text DEFAULT 'primary',
  p_soul text DEFAULT '',
  p_api_key text DEFAULT NULL,
  p_model_id bigint DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = attobot, attotools, pg_temp
AS $$
DECLARE
  v_id bigint;
  v_model_id bigint := p_model_id;
BEGIN
  -- Security check: only admin or service role
  IF current_user NOT IN ('attobot_admin', 'attobot_service', 'postgres') THEN
    RAISE EXCEPTION 'permission denied for ensure_agent';
  END IF;

  IF v_model_id IS NULL THEN
    SELECT model_id INTO v_model_id
    FROM attobot.agents
    WHERE slug = p_slug;
  END IF;

  IF v_model_id IS NULL THEN
    RAISE EXCEPTION 'agent % requires p_model_id; configure a model with attobot.ensure_model first', p_slug;
  END IF;

  INSERT INTO attobot.agents(slug, soul, model_id)
  VALUES (p_slug, p_soul, v_model_id)
  ON CONFLICT (slug) DO UPDATE
    SET soul = EXCLUDED.soul,
        model_id = EXCLUDED.model_id,
        updated_at = now()
  RETURNING id INTO v_id;

  IF p_api_key IS NOT NULL THEN
    PERFORM attobot.set_config(p_slug, 'api_key', to_jsonb(p_api_key), true);
  END IF;

  PERFORM attobot.log_event(v_id, 'agent.ensure', jsonb_build_object('slug', p_slug));
  RETURN v_id;
END;
$$;

-- process_telegram_updates - security definer to handle message insertion
CREATE OR REPLACE FUNCTION attobot.process_telegram_updates(
  p_agent_slug text,
  p_http_response jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = attobot, attotools, pg_temp
AS $$
DECLARE
  v_agent_id bigint := attobot.agent_id(p_agent_slug);
  v_status integer;
  v_body jsonb;
  v_update jsonb;
  v_update_id bigint;
  v_max_update_id bigint := NULL;
  v_chat_id text := attobot._config_text(v_agent_id, 'telegram_chat_id');
  v_thread_id text := attobot._config_text(v_agent_id, 'telegram_thread_id');
  v_message jsonb;
  v_message_chat_id text;
  v_message_thread_id text;
  v_text text;
  v_seen boolean;
  v_accepted integer := 0;
  v_ignored integer := 0;
BEGIN
  -- No security check needed - anonymous users can call this
  -- Function only inserts to messages, with proper agent_id

  v_status := attobot._http_status(p_http_response);
  v_body := attobot._http_body_json(p_http_response);

  IF v_status < 200 OR v_status >= 300 OR coalesce((v_body->>'ok')::boolean, false) IS NOT TRUE THEN
    PERFORM attobot.log_event(
      v_agent_id,
      'telegram.poll.error',
      jsonb_build_object('status', v_status, 'body', v_body)
    );
    RETURN jsonb_build_object('accepted', 0, 'ignored', 0, 'error', true);
  END IF;

  FOR v_update IN SELECT value FROM jsonb_array_elements(coalesce(v_body->'result', '[]'::jsonb))
  LOOP
    v_update_id := (v_update->>'update_id')::bigint;
    v_max_update_id := greatest(coalesce(v_max_update_id, v_update_id), v_update_id);
    v_message := v_update->'message';

    IF v_message IS NULL OR v_message = 'null'::jsonb THEN
      v_ignored := v_ignored + 1;
      CONTINUE;
    END IF;

    v_message_chat_id := v_message #>> '{chat,id}';
    v_message_thread_id := v_message->>'message_thread_id';
    v_text := coalesce(v_message->>'text', v_message->>'caption', '');

    IF v_message_chat_id IS DISTINCT FROM v_chat_id
       OR (v_thread_id IS NOT NULL AND v_message_thread_id IS DISTINCT FROM v_thread_id)
       OR v_text = '' THEN
      v_ignored := v_ignored + 1;
      CONTINUE;
    END IF;

    SELECT EXISTS (
      SELECT 1
      FROM attobot.messages
      WHERE agent_id = v_agent_id
        AND payload #>> '{telegram_update,update_id}' = v_update_id::text
    )
    INTO v_seen;

    IF v_seen THEN
      CONTINUE;
    END IF;

    BEGIN
      PERFORM attobot.append_message(
        p_agent_slug,
        'user',
        format('[telegram %s] %s', v_update_id, v_text),
        jsonb_build_object('telegram_update', v_update)
      );
    EXCEPTION WHEN unique_violation THEN
      CONTINUE;
    END;

    v_accepted := v_accepted + 1;
  END LOOP;

  IF v_max_update_id IS NOT NULL THEN
    PERFORM attobot.set_config(
      p_agent_slug,
      'telegram_update_offset',
      to_jsonb(v_max_update_id + 1)
    );
  END IF;

  IF v_accepted > 0 THEN
    PERFORM attobot.start_turn(p_agent_slug);
  END IF;

  PERFORM attobot.log_event(
    v_agent_id,
    'telegram.poll',
    jsonb_build_object('accepted', v_accepted, 'ignored', v_ignored)
  );

  RETURN jsonb_build_object('accepted', v_accepted, 'ignored', v_ignored, 'error', false);
END;
$$;

-- set_config - security definer to protect secret config
CREATE OR REPLACE FUNCTION attobot.set_config(
  p_agent_slug text,
  p_key text,
  p_value jsonb,
  p_secret boolean DEFAULT false
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = attobot, attotools, pg_temp
AS $$
DECLARE
  v_agent_id bigint := attobot.agent_id(p_agent_slug);
BEGIN
  -- Security check: allow if service role or if accessing own agent
  IF current_user NOT IN ('attobot_admin', 'attobot_service', 'postgres', 'attobot_agent_primary', 'attobot_agent_subconscious') THEN
    RAISE EXCEPTION 'permission denied for set_config';
  END IF;

  -- Additional check: agent roles can only modify their own config
  IF current_user IN ('attobot_agent_primary', 'attobot_agent_subconscious') THEN
    IF current_user <> 'attobot_agent_' || p_agent_slug THEN
      RAISE EXCEPTION 'agent % cannot modify config for agent %', current_user, p_agent_slug;
    END IF;
  END IF;

  INSERT INTO attobot.config(agent_id, key, value, secret)
  VALUES (v_agent_id, p_key, p_value, p_secret)
  ON CONFLICT (agent_id, key) DO UPDATE
    SET value = EXCLUDED.value,
        secret = EXCLUDED.secret,
        updated_at = now();
END;
$$;

-- ============================================================================
-- SESSION HELPER FUNCTION
-- ============================================================================

-- Helper function to set user context for a session
CREATE OR REPLACE FUNCTION attobot.set_context(
  p_role text,
  p_agent_id bigint DEFAULT NULL,
  p_telegram_user_id text DEFAULT NULL,
  p_telegram_chat_id text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = attobot, attotools, pg_temp
AS $$
BEGIN
  -- Set context parameters
  PERFORM set_config('attobot.current_role', p_role);

  IF p_agent_id IS NOT NULL THEN
    PERFORM set_config('attobot.current_agent_id', p_agent_id::text);
  END IF;

  IF p_telegram_user_id IS NOT NULL THEN
    PERFORM set_config('attobot.current_telegram_user_id', p_telegram_user_id);
  END IF;

  IF p_telegram_chat_id IS NOT NULL THEN
    PERFORM set_config('attobot.current_telegram_chat_id', p_telegram_chat_id);
  END IF;

  -- Switch role
  EXECUTE format('SET ROLE %I', p_role);
END;
$$;

-- ============================================================================
-- COMPLETE
-- ============================================================================

-- Log the security setup
DO $$
DECLARE
  v_agent_id bigint;
BEGIN
  SELECT id INTO v_agent_id FROM attobot.agents WHERE slug = 'primary' LIMIT 1;
  IF v_agent_id IS NOT NULL THEN
    PERFORM attobot.log_event(v_agent_id, 'security.rls.enabled', jsonb_build_object('timestamp', now()));
  END IF;
END $$;
