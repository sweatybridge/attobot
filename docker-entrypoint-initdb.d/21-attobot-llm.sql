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

CREATE OR REPLACE FUNCTION attobot._tool_schemas()
RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
  SELECT jsonb_build_array(
    jsonb_build_object(
      'type', 'function',
      'function', jsonb_build_object(
        'name', 'SQL',
        'description', 'Run one semicolon-free SQL query inside PostgreSQL. The query must return rows. For writes, use a data-modifying CTE with RETURNING.',
        'parameters', jsonb_build_object(
          'type', 'object',
          'properties', jsonb_build_object(
            'query', jsonb_build_object('type', 'string')
          ),
          'required', jsonb_build_array('query')
        )
      )
    ),
    jsonb_build_object(
      'type', 'function',
      'function', jsonb_build_object(
        'name', 'SEND_CHAT',
        'description', 'Queue text for the operator in attobot.outbox.',
        'parameters', jsonb_build_object(
          'type', 'object',
          'properties', jsonb_build_object('text', jsonb_build_object('type', 'string')),
          'required', jsonb_build_array('text')
        )
      )
    ),
    jsonb_build_object(
      'type', 'function',
      'function', jsonb_build_object(
        'name', 'APPEND_MESSAGE',
        'description', 'Append a message to an agent stream.',
        'parameters', jsonb_build_object(
          'type', 'object',
          'properties', jsonb_build_object(
            'agent', jsonb_build_object('type', 'string'),
            'role', jsonb_build_object('type', 'string', 'enum', jsonb_build_array('system', 'user')),
            'content', jsonb_build_object('type', 'string')
          ),
          'required', jsonb_build_array('content')
        )
      )
    ),
    jsonb_build_object(
      'type', 'function',
      'function', jsonb_build_object(
        'name', 'STASH',
        'description', 'Save large text in attobot.blobs and return a stash marker.',
        'parameters', jsonb_build_object(
          'type', 'object',
          'properties', jsonb_build_object('content', jsonb_build_object('type', 'string')),
          'required', jsonb_build_array('content')
        )
      )
    ),
    jsonb_build_object(
      'type', 'function',
      'function', jsonb_build_object(
        'name', 'READ_BLOB',
        'description', 'Read stashed text by hash.',
        'parameters', jsonb_build_object(
          'type', 'object',
          'properties', jsonb_build_object('hash', jsonb_build_object('type', 'string')),
          'required', jsonb_build_array('hash')
        )
      )
    )
  );
$$;

CREATE OR REPLACE FUNCTION attobot._system_prompt(p_agent_id bigint)
RETURNS text
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_agent attobot.agents%ROWTYPE;
BEGIN
  SELECT * INTO v_agent FROM attobot.agents WHERE id = p_agent_id;
  RETURN format(
    '<soul>%s</soul>

<harness>
You run inside PostgreSQL. Your canonical state is attobot.messages.
Use tool calls when you need to act. Queue final operator-facing text with SEND_CHAT.
Do not claim that external delivery happened; SEND_CHAT only writes attobot.outbox.
Use SQL for database work. Use STASH for large content.
</harness>',
    v_agent.soul
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
    'tools', attobot._tool_schemas()
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

CREATE OR REPLACE FUNCTION attobot.record_assistant_from_http(
  p_agent_slug text,
  p_http_response jsonb
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
  v_call jsonb;
  v_count integer := 0;
BEGIN
  v_status := attobot._http_status(p_http_response);
  v_body_text := coalesce(p_http_response->>'body', '');

  IF v_status < 200 OR v_status >= 300 THEN
    v_message_id := attobot.append_message(
      p_agent_slug,
      'system',
      format('[llm http error %s] %s', v_status, left(v_body_text, 4000)),
      jsonb_build_object('http_response', p_http_response)
    );
    RETURN jsonb_build_object('message_id', v_message_id, 'tool_calls', 0, 'error', true);
  END IF;

  v_body := attobot._try_jsonb(v_body_text);
  v_message := v_body #> '{choices,0,message}';

  IF v_message IS NULL OR v_message = 'null'::jsonb THEN
    v_message_id := attobot.append_message(
      p_agent_slug,
      'system',
      '[llm parse error] missing choices[0].message',
      jsonb_build_object('http_response', p_http_response)
    );
    RETURN jsonb_build_object('message_id', v_message_id, 'tool_calls', 0, 'error', true);
  END IF;

  v_content := coalesce(v_message->>'content', '');
  v_tool_calls := coalesce(v_message->'tool_calls', '[]'::jsonb);

  v_message_id := attobot.append_message(
    p_agent_slug,
    'assistant',
    v_content,
    jsonb_build_object('raw', v_message, 'tool_calls', v_tool_calls)
  );

  FOR v_call IN SELECT value FROM jsonb_array_elements(v_tool_calls)
  LOOP
    INSERT INTO attobot.tool_requests(
      agent_id,
      message_id,
      tool_call_id,
      name,
      arguments
    )
    VALUES (
      v_agent_id,
      v_message_id,
      v_call->>'id',
      v_call #>> '{function,name}',
      attobot._try_jsonb(v_call #>> '{function,arguments}')
    )
    ON CONFLICT (agent_id, tool_call_id) DO NOTHING;
    v_count := v_count + 1;
  END LOOP;

  RETURN jsonb_build_object('message_id', v_message_id, 'tool_calls', v_count, 'error', false);
END;
$$;
