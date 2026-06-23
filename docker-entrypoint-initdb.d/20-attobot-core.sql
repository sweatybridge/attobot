CREATE OR REPLACE FUNCTION attobot.agent_id(p_slug text)
RETURNS bigint
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_id bigint;
BEGIN
  SELECT id INTO v_id FROM attobot.agents WHERE slug = p_slug;
  IF v_id IS NULL THEN
    RAISE EXCEPTION 'unknown attobot agent: %', p_slug;
  END IF;
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION attobot.log_event(
  p_agent_id bigint,
  p_event text,
  p_detail jsonb DEFAULT '{}'::jsonb
)
RETURNS bigint
LANGUAGE sql
AS $$
  INSERT INTO attobot.lifecycle(agent_id, event, detail)
  VALUES (p_agent_id, p_event, p_detail)
  RETURNING id;
$$;

CREATE OR REPLACE FUNCTION attobot.ensure_model(
  p_model text DEFAULT 'deepseek-v4-pro',
  p_api_base text DEFAULT 'https://api.deepseek.com/v1',
  p_temperature numeric DEFAULT 1.0,
  p_reasoning_effort text DEFAULT 'medium',
  p_context_tokens integer DEFAULT 1000000,
  p_multimodal_support boolean DEFAULT false
)
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  v_model_id bigint;
BEGIN
  INSERT INTO attobot.models(name, api_base, temperature, reasoning_effort, context_tokens, multimodal_support)
  VALUES (
    COALESCE(NULLIF(p_model, ''), 'deepseek-v4-pro'),
    COALESCE(NULLIF(p_api_base, ''), 'https://api.deepseek.com/v1'),
    COALESCE(p_temperature, 1.0),
    COALESCE(p_reasoning_effort, 'medium'),
    COALESCE(p_context_tokens, 1000000),
    COALESCE(p_multimodal_support, false)
  )
  ON CONFLICT (name, api_base, temperature, reasoning_effort, context_tokens, multimodal_support) DO UPDATE
    SET updated_at = now()
  RETURNING id INTO v_model_id;

  RETURN v_model_id;
END;
$$;

CREATE OR REPLACE FUNCTION attobot.ensure_agent(
  p_slug text DEFAULT 'primary',
  p_soul text DEFAULT '',
  p_api_key text DEFAULT NULL,
  p_model_id bigint DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  v_id bigint;
  v_model_id bigint := p_model_id;
BEGIN
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

-- Upsert a channel user by (channel, external_id), refreshing profile fields,
-- and return its internal id + tier. Called by intake to auto-track telegram
-- users; tier is whatever is stored (default 'anonymous').
CREATE OR REPLACE FUNCTION attobot.ensure_user(
  p_channel text,
  p_external_id text,
  p_username text DEFAULT NULL,
  p_display_name text DEFAULT NULL,
  p_payload jsonb DEFAULT '{}'::jsonb
)
RETURNS TABLE(id bigint, tier text)
LANGUAGE plpgsql
AS $$
DECLARE
  v_id bigint;
  v_tier text;
BEGIN
  INSERT INTO attobot.users(channel, external_id, username, display_name, payload)
  VALUES (p_channel, p_external_id, p_username, p_display_name, p_payload)
  ON CONFLICT (channel, external_id) DO UPDATE
    SET username = EXCLUDED.username,
        display_name = EXCLUDED.display_name,
        payload = EXCLUDED.payload,
        updated_at = now()
  RETURNING attobot.users.id INTO v_id;

  -- QUALIFY: the RETURNS TABLE columns (id, tier) shadow table column names.
  SELECT u.tier INTO v_tier FROM attobot.users u WHERE u.id = v_id;

  RETURN QUERY SELECT v_id, v_tier;
END;
$$;

CREATE OR REPLACE FUNCTION attobot.set_config(
  p_agent_slug text,
  p_key text,
  p_value jsonb,
  p_secret boolean DEFAULT false
)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  v_agent_id bigint := attobot.agent_id(p_agent_slug);
BEGIN
  INSERT INTO attobot.config(agent_id, key, value, secret)
  VALUES (v_agent_id, p_key, p_value, p_secret)
  ON CONFLICT (agent_id, key) DO UPDATE
    SET value = EXCLUDED.value,
        secret = EXCLUDED.secret,
        updated_at = now();
END;
$$;

CREATE OR REPLACE FUNCTION attobot._config_text(
  p_agent_id bigint,
  p_key text,
  p_default text DEFAULT NULL
)
RETURNS text
LANGUAGE sql
STABLE
AS $$
  SELECT coalesce((
    SELECT value #>> '{}'
    FROM attobot.config
    WHERE agent_id = p_agent_id AND key = p_key
  ), p_default);
$$;

CREATE OR REPLACE FUNCTION attobot.append_message(
  p_agent_slug text,
  p_role text,
  p_content text,
  p_payload jsonb DEFAULT '{}'::jsonb,
  p_tool_call_id text DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  v_agent_id bigint := attobot.agent_id(p_agent_slug);
  v_id bigint;
BEGIN
  INSERT INTO attobot.messages(agent_id, role, content, payload, tool_call_id)
  VALUES (v_agent_id, p_role, coalesce(p_content, ''), coalesce(p_payload, '{}'::jsonb), p_tool_call_id)
  RETURNING id INTO v_id;

  PERFORM attobot.log_event(
    v_agent_id,
    'message.append',
    jsonb_build_object('message_id', v_id, 'role', p_role)
  );
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION attobot._validate_memory_source_messages()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_missing bigint[];
BEGIN
  SELECT array_agg(source_id ORDER BY source_id)
  INTO v_missing
  FROM unnest(NEW.source_message_ids) AS source_id
  WHERE NOT EXISTS (
    SELECT 1
    FROM attobot.messages
    WHERE id = source_id
      AND agent_id = NEW.agent_id
  );

  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION 'memory source_message_ids must reference messages for the same agent: %', v_missing;
  END IF;

  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

-- TODO: separate relationship table for memory source messages to enforce referential integrity
CREATE OR REPLACE TRIGGER memory_validate_source_messages_trigger
BEFORE INSERT OR UPDATE OF agent_id, content, source_message_ids, payload, enabled ON attobot.memory
FOR EACH ROW
EXECUTE FUNCTION attobot._validate_memory_source_messages();

CREATE OR REPLACE FUNCTION attobot._try_jsonb(p_text text)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
  IF p_text IS NULL OR btrim(p_text) = '' THEN
    RETURN '{}'::jsonb;
  END IF;
  RETURN p_text::jsonb;
EXCEPTION WHEN others THEN
  RETURN jsonb_build_object('_raw', p_text);
END;
$$;

CREATE OR REPLACE FUNCTION attobot._http_status(p_http_response jsonb)
RETURNS integer
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT coalesce((p_http_response->>'status')::integer, 0);
$$;

CREATE OR REPLACE FUNCTION attobot._http_body_json(p_http_response jsonb)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT attobot._try_jsonb(coalesce(p_http_response->>'body', ''));
$$;

CREATE OR REPLACE FUNCTION attobot._shell_quote(p_text text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
  RETURN '''' || replace(coalesce(p_text, ''), '''', '''"''"''') || '''';
END;
$$;

CREATE OR REPLACE FUNCTION attobot._program_output(p_command text)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  v_output text;
BEGIN
  CREATE TEMP TABLE IF NOT EXISTS attobot_program_output(
    seq bigserial,
    line text
  ) ON COMMIT DROP;

  TRUNCATE attobot_program_output RESTART IDENTITY;
  EXECUTE format('COPY attobot_program_output(line) FROM PROGRAM %L', p_command);

  SELECT string_agg(line, E'\n' ORDER BY seq)
  INTO v_output
  FROM attobot_program_output;

  RETURN coalesce(v_output, '');
END;
$$;
