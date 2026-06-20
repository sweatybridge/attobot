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

CREATE OR REPLACE FUNCTION attotools._tool_schemas()
RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
  SELECT jsonb_build_array(
    jsonb_build_object(
      'type', 'function',
      'function', jsonb_build_object(
        'name', 'SEARCH',
        'description', 'Search the public web and return a JSON list of result titles, URLs, and snippets.',
        'parameters', jsonb_build_object(
          'type', 'object',
          'properties', jsonb_build_object(
            'query', jsonb_build_object('type', 'string'),
            'limit', jsonb_build_object('type', 'integer')
          ),
          'required', jsonb_build_array('query')
        )
      )
    ),
    jsonb_build_object(
      'type', 'function',
      'function', jsonb_build_object(
        'name', 'WEBFETCH',
        'description', 'Fetch an HTTP or HTTPS URL and return status, content type, effective URL, and a truncated text body.',
        'parameters', jsonb_build_object(
          'type', 'object',
          'properties', jsonb_build_object(
            'url', jsonb_build_object('type', 'string'),
            'max_bytes', jsonb_build_object('type', 'integer')
          ),
          'required', jsonb_build_array('url')
        )
      )
    ),
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
        'name', 'SEND_ATTACHMENT',
        'description', 'Send blob content as a Telegram document attachment. Use WRITE_BLOB first, then pass the returned hash.',
        'parameters', jsonb_build_object(
          'type', 'object',
          'properties', jsonb_build_object(
            'hash', jsonb_build_object('type', 'string'),
            'filename', jsonb_build_object('type', 'string'),
            'caption', jsonb_build_object('type', 'string'),
            'mime_type', jsonb_build_object('type', 'string')
          ),
          'required', jsonb_build_array('hash')
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
        'name', 'WRITE_BLOB',
        'description', 'Write data to attotools.blobs. The content is decoded using encoding: base64, hex, escape, or a PostgreSQL text encoding such as UTF8, LATIN1, or WIN1252.',
        'parameters', jsonb_build_object(
          'type', 'object',
          'properties', jsonb_build_object(
            'content', jsonb_build_object('type', 'string'),
            'encoding', jsonb_build_object('type', 'string')
          ),
          'required', jsonb_build_array('content', 'encoding')
        )
      )
    ),
    jsonb_build_object(
      'type', 'function',
      'function', jsonb_build_object(
        'name', 'READ_BLOB',
        'description', 'Read blob data by hash. The result is encoded using encoding: base64, hex, escape, or a PostgreSQL text encoding such as UTF8.',
        'parameters', jsonb_build_object(
          'type', 'object',
          'properties', jsonb_build_object(
            'hash', jsonb_build_object('type', 'string'),
            'encoding', jsonb_build_object('type', 'string')
          ),
          'required', jsonb_build_array('hash')
        )
      )
    )
  );
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
        id,
        array_to_string(source_message_ids, ','),
        content
      ),
      E'\n'
      ORDER BY id
    ),
    ''
  )
  FROM attobot.memory
  WHERE agent_id = p_agent_id
    AND enabled;
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
queued automatically in attobot.outbox.
Do not claim that external delivery happened; attobot.outbox is only a delivery
queue.
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
    'tools', attotools._tool_schemas()
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
  p_http_response jsonb,
  p_turn_id bigint DEFAULT NULL
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
  v_outbox_id bigint;
  v_content text;
  v_call jsonb;
  v_payload jsonb;
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
  v_tool_calls := CASE
    WHEN jsonb_typeof(v_message->'tool_calls') = 'array' THEN v_message->'tool_calls'
    ELSE '[]'::jsonb
  END;

  FOR v_call IN SELECT value FROM jsonb_array_elements(v_tool_calls)
  LOOP
    v_count := v_count + 1;
  END LOOP;

  v_payload := jsonb_build_object('raw', v_message, 'tool_calls', v_tool_calls);
  IF v_count > 0 AND p_turn_id IS NOT NULL THEN
    v_payload := v_payload || jsonb_build_object(
      'turn_id', p_turn_id,
      'tool_signal_name', format('attobot:%s:turn:%s:tools', p_agent_slug, p_turn_id)
    );
  END IF;

  v_message_id := attobot.append_message(
    p_agent_slug,
    'assistant',
    v_content,
    v_payload
  );

  IF v_count = 0 AND v_content <> '' THEN
    INSERT INTO attobot.outbox(agent_id, channel, body)
    VALUES (v_agent_id, 'chat', jsonb_build_object('text', v_content))
    RETURNING id INTO v_outbox_id;
  END IF;

  RETURN jsonb_strip_nulls(jsonb_build_object(
    'message_id', v_message_id,
    'tool_calls', v_count,
    'outbox_id', v_outbox_id,
    'error', false
  ));
END;
$$;
