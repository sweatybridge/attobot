CREATE OR REPLACE FUNCTION attobot._message_for_openai(p_message attobot.messages)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
  SELECT jsonb_strip_nulls(
    jsonb_build_object(
      'role', p_message.role,
      'content', CASE WHEN p_message.content = '' AND p_message.role = 'assistant'
                      THEN NULL ELSE p_message.content END,
      'tool_call_id', p_message.tool_call_id
    )
    || CASE
      WHEN p_message.payload ? 'tool_calls'
      THEN jsonb_build_object('tool_calls', p_message.payload->'tool_calls')
      ELSE '{}'::jsonb
    END
  );
$$;

-- Tool schemas are inferred from the attotools._tool_* functions: parameter
-- names/types and required-vs-optional come from pg_proc (pronargdefaults marks
-- the trailing optional args), enum values from pg_enum, and the description
-- from COMMENT ON FUNCTION. Defined here in 21; the _tool_* functions live in 22
-- but are read from the catalog only at call time (during an agent turn), so the
-- load order is fine.
CREATE OR REPLACE FUNCTION attotools.tool_schemas()
RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
  WITH tools AS (
    SELECT
      p.oid,
      upper(substr(p.proname, 7))                     AS tool_name,
      p.pronargs,
      p.pronargdefaults,
      obj_description(p.oid, 'pg_proc')               AS description,
      coalesce(p.proallargtypes, p.proargtypes::oid[]) AS argtypes,
      p.proargnames
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'attotools'
      AND p.proname ~ '^_tool_'
  ),
  args AS (
    SELECT
      t.tool_name,
      t.description,
      a.ordinality                                      AS pos,
      an.argname,
      regexp_replace(an.argname, '^p_', '')             AS param_name,
      (a.ordinality <= t.pronargs - t.pronargdefaults)  AS required,
      CASE
        WHEN ty.typtype = 'e' THEN
          jsonb_build_object(
            'type', 'string',
            'enum', (SELECT jsonb_agg(e.enumlabel ORDER BY e.enumsortorder)
                     FROM pg_enum e WHERE e.enumtypid = ty.oid)
          )
        WHEN ty.typname IN ('int2', 'int4', 'int8')        THEN jsonb_build_object('type', 'integer')
        WHEN ty.typname = 'bool'                           THEN jsonb_build_object('type', 'boolean')
        WHEN ty.typname IN ('float4', 'float8', 'numeric') THEN jsonb_build_object('type', 'number')
        ELSE jsonb_build_object('type', 'string')
      END AS schema
    FROM tools t
    LEFT JOIN LATERAL unnest(t.argtypes) WITH ORDINALITY AS a(argtypeoid, ordinality) ON true
    LEFT JOIN LATERAL unnest(t.proargnames) WITH ORDINALITY AS an(argname, ordinality) ON an.ordinality = a.ordinality
    JOIN pg_type ty ON ty.oid = a.argtypeoid
  ),
  tool_obj AS (
    SELECT
      tool_name,
      jsonb_build_object(
        'type', 'function',
        'function', jsonb_build_object(
          'name', tool_name,
          'description', description,
          'parameters', jsonb_build_object(
            'type', 'object',
            'properties', coalesce(jsonb_object_agg(param_name, schema) FILTER (WHERE argname IS NOT NULL), '{}'::jsonb),
            'required',   coalesce(jsonb_agg(param_name ORDER BY pos) FILTER (WHERE required), '[]'::jsonb)
          )
        )
      ) AS obj
    FROM args
    GROUP BY tool_name, description
  )
  SELECT coalesce(jsonb_agg(obj ORDER BY tool_name), '[]'::jsonb)
  FROM tool_obj;
$$;

CREATE OR REPLACE FUNCTION attobot._memory_prompt(p_agent_id bigint)
RETURNS text
LANGUAGE sql
STABLE
AS $$
  SELECT coalesce(
    string_agg(
      format(
        '- memory_id=%s source_message_ids=[%s]: %s',
        m.id,
        (SELECT coalesce(string_agg(ms.message_id::text, ',' ORDER BY ms.message_id), '')
         FROM attobot.memory_sources ms WHERE ms.memory_id = m.id),
        m.content
      ),
      E'\n'
      ORDER BY m.id
    ),
    ''
  )
  FROM attobot.memory m
  WHERE m.agent_id = p_agent_id
    AND m.enabled;
$$;

CREATE OR REPLACE FUNCTION attobot._system_prompt(p_agent_id bigint)
RETURNS text
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_agent attobot.agents%ROWTYPE;
  v_memory text;
BEGIN
  SELECT * INTO v_agent FROM attobot.agents WHERE id = p_agent_id;
  v_memory := attobot._memory_prompt(p_agent_id);

  RETURN format(
    '<soul>%s</soul>%s

<harness>
You run inside PostgreSQL. Your canonical state is attobot.messages.
Use tool calls when you need to act. Final assistant text with no tool calls is
delivered to the operator automatically.
Use SEARCH for web discovery, WEBFETCH to read a URL, SQL for database work,
and WRITE_BLOB for large or binary content.
</harness>',
    v_agent.soul,
    CASE
      WHEN v_memory = '' THEN ''
      ELSE E'\n\n<memory>\n' || v_memory || E'\n</memory>'
    END
  );
END;
$$;

CREATE OR REPLACE FUNCTION attobot.compose_llm_request(p_agent_slug text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_agent attobot.agents%ROWTYPE;
  v_model attobot.models%ROWTYPE;
  v_history_limit integer;
  v_messages jsonb;
  v_body jsonb;
BEGIN
  SELECT * INTO v_agent FROM attobot.agents WHERE slug = p_agent_slug AND enabled;
  IF v_agent.id IS NULL THEN
    RAISE EXCEPTION 'agent is missing or disabled: %', p_agent_slug;
  END IF;

  SELECT m.*
  INTO v_model
  FROM attobot.models m
  WHERE m.id = v_agent.model_id;
  IF v_model.id IS NULL THEN
    RAISE EXCEPTION 'agent % has no model config', p_agent_slug;
  END IF;

  v_history_limit := coalesce(attobot._config_text(v_agent.id, 'history_limit', '200')::integer, 200);

  SELECT coalesce(jsonb_agg(attobot._message_for_openai(m) ORDER BY m.id), '[]'::jsonb)
  INTO v_messages
  FROM (
    SELECT *
    FROM attobot.messages
    WHERE agent_id = v_agent.id
    ORDER BY id DESC
    LIMIT v_history_limit
  ) AS m;

  v_body := jsonb_build_object(
    'model', v_model.name,
    'temperature', v_model.temperature,
    'messages',
      jsonb_build_array(jsonb_build_object(
        'role', 'system',
        'content', attobot._system_prompt(v_agent.id)
      )) || coalesce(v_messages, '[]'::jsonb),
    'tools', attotools.tool_schemas()
  );

  IF v_model.reasoning_effort <> '' THEN
    v_body := v_body || jsonb_build_object('reasoning_effort', v_model.reasoning_effort);
  END IF;

  RETURN v_body;
END;
$$;

CREATE OR REPLACE FUNCTION attobot._llm_url(p_agent_slug text)
RETURNS text
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_api_base text;
BEGIN
  SELECT m.api_base
  INTO v_api_base
  FROM attobot.agents a
  JOIN attobot.models m ON m.id = a.model_id
  WHERE a.slug = p_agent_slug;

  IF v_api_base IS NULL OR v_api_base = '' THEN
    RAISE EXCEPTION 'agent % has no model api_base', p_agent_slug;
  END IF;

  RETURN rtrim(v_api_base, '/') || '/chat/completions';
END;
$$;

CREATE OR REPLACE FUNCTION attobot._llm_headers(p_agent_slug text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_agent_id bigint := attobot.agent_id(p_agent_slug);
  v_api_key text;
BEGIN
  v_api_key := attobot._config_text(v_agent_id, 'api_key');
  IF v_api_key IS NULL OR v_api_key = '' THEN
    RAISE EXCEPTION 'agent % has no api_key config', p_agent_slug;
  END IF;

  RETURN jsonb_build_object(
    'Authorization', 'Bearer ' || v_api_key,
    'Content-Type', 'application/json'
  );
END;
$$;

-- Record the assistant turn from the LLM HTTP response: append the assistant
-- message (with channel/chat_id so the outbound trigger delivers it) and the
-- parsed tool_calls. No outbox — outbound delivery is trigger-driven.
CREATE OR REPLACE FUNCTION attobot.record_assistant(
  p_agent_slug text,
  p_http_response jsonb,
  p_requesting_user_id bigint DEFAULT NULL,
  p_channel text DEFAULT NULL,
  p_chat_id text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v_agent_id bigint := attobot.agent_id(p_agent_slug);
  v_status integer;
  v_body_text text;
  v_body jsonb;
  v_message jsonb;
  v_tool_calls jsonb;
  v_message_id bigint;
  v_content text;
  v_payload jsonb;
BEGIN
  v_status := attobot._http_status(p_http_response);
  v_body_text := coalesce(p_http_response->>'body', '');

  IF v_status < 200 OR v_status >= 300 THEN
    v_message_id := attobot.append_message(
      p_agent_slug, 'system',
      format('[llm http error %s] %s', v_status, left(v_body_text, 4000)),
      jsonb_build_object('http_response', p_http_response),
      NULL, p_channel, p_chat_id
    );
    RETURN jsonb_build_object('message_id', v_message_id, 'tool_calls', '[]'::jsonb, 'error', true);
  END IF;

  v_body := attobot._try_jsonb(v_body_text);
  v_message := v_body #> '{choices,0,message}';

  IF v_message IS NULL OR v_message = 'null'::jsonb THEN
    v_message_id := attobot.append_message(
      p_agent_slug, 'system',
      '[llm parse error] missing choices[0].message',
      jsonb_build_object('http_response', p_http_response),
      NULL, p_channel, p_chat_id
    );
    RETURN jsonb_build_object('message_id', v_message_id, 'tool_calls', '[]'::jsonb, 'error', true);
  END IF;

  v_content := coalesce(v_message->>'content', '');
  v_tool_calls := CASE
    WHEN jsonb_typeof(v_message->'tool_calls') = 'array' THEN v_message->'tool_calls'
    ELSE '[]'::jsonb
  END;

  v_payload := jsonb_build_object('raw', v_message, 'tool_calls', v_tool_calls)
    -- Stamp the requesting user so tool calls can run with that user's scope.
    || jsonb_build_object('requesting_user_id', p_requesting_user_id);

  v_message_id := attobot.append_message(
    p_agent_slug, 'assistant', v_content, v_payload,
    NULL, p_channel, p_chat_id
  );

  RETURN jsonb_strip_nulls(jsonb_build_object(
    'message_id', v_message_id,
    'tool_calls', v_tool_calls,
    'error', false
  ));
END;
$$;
