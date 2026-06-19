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

CREATE OR REPLACE FUNCTION attobot.ensure_agent(
  p_slug text DEFAULT 'primary',
  p_soul text DEFAULT '',
  p_api_key text DEFAULT NULL,
  p_model text DEFAULT 'deepseek-v4-pro',
  p_api_base text DEFAULT 'https://api.deepseek.com/v1'
)
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  v_id bigint;
  v_model_id bigint;
BEGIN
  INSERT INTO attobot.models(name, api_base)
  VALUES (p_model, p_api_base)
  ON CONFLICT (name, api_base, temperature, reasoning_effort, context_tokens) DO UPDATE
    SET updated_at = now()
  RETURNING id INTO v_model_id;

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
