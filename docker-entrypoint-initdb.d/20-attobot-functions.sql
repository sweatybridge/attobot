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

CREATE OR REPLACE FUNCTION attobot.log_event(p_agent_id bigint, p_event text, p_detail jsonb DEFAULT '{}'::jsonb)
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
BEGIN
  INSERT INTO attobot.agents(slug, soul, model, api_base)
  VALUES (p_slug, p_soul, p_model, p_api_base)
  ON CONFLICT (slug) DO UPDATE
    SET soul = EXCLUDED.soul,
        model = EXCLUDED.model,
        api_base = EXCLUDED.api_base,
        updated_at = now()
  RETURNING id INTO v_id;

  IF p_api_key IS NOT NULL THEN
    INSERT INTO attobot.config(agent_id, key, value, secret)
    VALUES (v_id, 'api_key', to_jsonb(p_api_key), true)
    ON CONFLICT (agent_id, key) DO UPDATE
      SET value = EXCLUDED.value,
          secret = true,
          updated_at = now();
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

CREATE OR REPLACE FUNCTION attobot.get_config_text(
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

CREATE OR REPLACE FUNCTION attobot.append_user_message(p_agent_slug text, p_content text)
RETURNS bigint
LANGUAGE sql
AS $$
  SELECT attobot.append_message(p_agent_slug, 'user', p_content);
$$;

CREATE OR REPLACE FUNCTION attobot.append_system_message(p_agent_slug text, p_content text)
RETURNS bigint
LANGUAGE sql
AS $$
  SELECT attobot.append_message(p_agent_slug, 'system', p_content);
$$;

CREATE OR REPLACE FUNCTION attobot.try_jsonb(p_text text)
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

CREATE OR REPLACE FUNCTION attobot.message_for_openai(p_message attobot.messages)
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

CREATE OR REPLACE FUNCTION attobot.tool_schemas()
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

CREATE OR REPLACE FUNCTION attobot.build_system_prompt(p_agent_id bigint)
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
  v_history_limit integer;
  v_messages jsonb;
  v_body jsonb;
BEGIN
  SELECT * INTO v_agent FROM attobot.agents WHERE slug = p_agent_slug AND enabled;
  IF v_agent.id IS NULL THEN
    RAISE EXCEPTION 'agent is missing or disabled: %', p_agent_slug;
  END IF;

  v_history_limit := coalesce(attobot.get_config_text(v_agent.id, 'history_limit', '200')::integer, 200);

  SELECT coalesce(jsonb_agg(attobot.message_for_openai(m) ORDER BY m.id), '[]'::jsonb)
  INTO v_messages
  FROM (
    SELECT *
    FROM attobot.messages
    WHERE agent_id = v_agent.id
    ORDER BY id DESC
    LIMIT v_history_limit
  ) AS m;

  v_body := jsonb_build_object(
    'model', v_agent.model,
    'temperature', v_agent.temperature,
    'messages',
      jsonb_build_array(jsonb_build_object(
        'role', 'system',
        'content', attobot.build_system_prompt(v_agent.id)
      )) || coalesce(v_messages, '[]'::jsonb),
    'tools', attobot.tool_schemas()
  );

  IF v_agent.reasoning_effort <> '' THEN
    v_body := v_body || jsonb_build_object('reasoning_effort', v_agent.reasoning_effort);
  END IF;

  RETURN v_body;
END;
$$;

CREATE OR REPLACE FUNCTION attobot.llm_url(p_agent_slug text)
RETURNS text
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_agent attobot.agents%ROWTYPE;
BEGIN
  SELECT * INTO v_agent FROM attobot.agents WHERE slug = p_agent_slug;
  RETURN rtrim(v_agent.api_base, '/') || '/chat/completions';
END;
$$;

CREATE OR REPLACE FUNCTION attobot.llm_headers(p_agent_slug text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_agent_id bigint := attobot.agent_id(p_agent_slug);
  v_api_key text;
BEGIN
  v_api_key := attobot.get_config_text(v_agent_id, 'api_key');
  IF v_api_key IS NULL OR v_api_key = '' THEN
    RAISE EXCEPTION 'agent % has no api_key config', p_agent_slug;
  END IF;

  RETURN jsonb_build_object(
    'Authorization', 'Bearer ' || v_api_key,
    'Content-Type', 'application/json'
  );
END;
$$;

CREATE OR REPLACE FUNCTION attobot.configure_telegram(
  p_agent_slug text,
  p_token text,
  p_chat_id text,
  p_thread_id text DEFAULT NULL,
  p_api_base text DEFAULT 'https://api.telegram.org'
)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  v_agent_id bigint := attobot.agent_id(p_agent_slug);
BEGIN
  PERFORM attobot.set_config(p_agent_slug, 'telegram_token', to_jsonb(p_token), true);
  PERFORM attobot.set_config(p_agent_slug, 'telegram_chat_id', to_jsonb(p_chat_id), false);
  PERFORM attobot.set_config(p_agent_slug, 'telegram_api_base', to_jsonb(p_api_base), false);
  PERFORM attobot.set_config(p_agent_slug, 'telegram_update_offset', to_jsonb(0), false);

  IF p_thread_id IS NULL OR p_thread_id = '' THEN
    DELETE FROM attobot.config
    WHERE agent_id = v_agent_id
      AND key = 'telegram_thread_id';
  ELSE
    PERFORM attobot.set_config(p_agent_slug, 'telegram_thread_id', to_jsonb(p_thread_id), false);
  END IF;

  PERFORM attobot.log_event(v_agent_id, 'telegram.configure', jsonb_build_object('chat_id', p_chat_id));
END;
$$;

CREATE OR REPLACE FUNCTION attobot.telegram_api_url(p_agent_slug text, p_method text)
RETURNS text
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_agent_id bigint := attobot.agent_id(p_agent_slug);
  v_token text;
  v_api_base text;
BEGIN
  v_token := attobot.get_config_text(v_agent_id, 'telegram_token');
  IF v_token IS NULL OR v_token = '' THEN
    RAISE EXCEPTION 'agent % has no telegram_token config', p_agent_slug;
  END IF;

  v_api_base := attobot.get_config_text(v_agent_id, 'telegram_api_base', 'https://api.telegram.org');
  RETURN rtrim(v_api_base, '/') || '/bot' || v_token || '/' || p_method;
END;
$$;

CREATE OR REPLACE FUNCTION attobot.telegram_headers()
RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
  SELECT jsonb_build_object('Content-Type', 'application/json');
$$;

CREATE OR REPLACE FUNCTION attobot.telegram_get_updates_body(p_agent_slug text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_agent_id bigint := attobot.agent_id(p_agent_slug);
  v_offset bigint;
BEGIN
  v_offset := coalesce(attobot.get_config_text(v_agent_id, 'telegram_update_offset', '0')::bigint, 0);
  RETURN jsonb_build_object(
    'offset', v_offset,
    'timeout', 0,
    'allowed_updates', jsonb_build_array('message')
  );
END;
$$;

CREATE OR REPLACE FUNCTION attobot.process_telegram_updates(p_agent_slug text, p_http_response jsonb)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v_agent_id bigint := attobot.agent_id(p_agent_slug);
  v_status integer;
  v_body jsonb;
  v_update jsonb;
  v_update_id bigint;
  v_max_update_id bigint := NULL;
  v_chat_id text := attobot.get_config_text(v_agent_id, 'telegram_chat_id');
  v_thread_id text := attobot.get_config_text(v_agent_id, 'telegram_thread_id');
  v_message jsonb;
  v_message_chat_id text;
  v_message_thread_id text;
  v_text text;
  v_message_id bigint;
  v_seen boolean;
  v_accepted integer := 0;
  v_ignored integer := 0;
BEGIN
  v_status := coalesce((p_http_response->>'status')::integer, 0);
  v_body := attobot.try_jsonb(coalesce(p_http_response->>'body', ''));

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
      FROM attobot.telegram_updates
      WHERE agent_id = v_agent_id
        AND update_id = v_update_id
    )
    INTO v_seen;

    IF v_seen THEN
      CONTINUE;
    END IF;

    v_message_id := attobot.append_message(
      p_agent_slug,
      'user',
      format('[telegram %s] %s', v_update_id, v_text),
      jsonb_build_object('telegram_update', v_update)
    );

    INSERT INTO attobot.telegram_updates(agent_id, update_id, payload, message_id)
    VALUES (v_agent_id, v_update_id, v_update, v_message_id)
    ON CONFLICT (agent_id, update_id) DO NOTHING;

    v_accepted := v_accepted + 1;
  END LOOP;

  IF v_max_update_id IS NOT NULL THEN
    PERFORM attobot.set_config(
      p_agent_slug,
      'telegram_update_offset',
      to_jsonb(v_max_update_id + 1),
      false
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

CREATE OR REPLACE FUNCTION attobot.telegram_claim_outbox(p_agent_slug text)
RETURNS TABLE(outbox_id bigint, has_outbox boolean, request_body text, reason text)
LANGUAGE plpgsql
AS $$
DECLARE
  v_agent_id bigint := attobot.agent_id(p_agent_slug);
  v_chat_id text := attobot.get_config_text(v_agent_id, 'telegram_chat_id');
  v_thread_id text := attobot.get_config_text(v_agent_id, 'telegram_thread_id');
  v_outbox attobot.outbox%ROWTYPE;
  v_text text;
  v_request jsonb;
BEGIN
  IF v_chat_id IS NULL OR v_chat_id = '' THEN
    outbox_id := NULL;
    has_outbox := false;
    request_body := NULL;
    reason := 'telegram not configured';
    RETURN NEXT;
    RETURN;
  END IF;

  SELECT *
  INTO v_outbox
  FROM attobot.outbox
  WHERE agent_id = v_agent_id
    AND status = 'pending'
    AND channel IN ('chat', 'telegram')
  ORDER BY id
  LIMIT 1
  FOR UPDATE SKIP LOCKED;

  IF v_outbox.id IS NULL THEN
    outbox_id := NULL;
    has_outbox := false;
    request_body := NULL;
    reason := 'empty';
    RETURN NEXT;
    RETURN;
  END IF;

  v_text := left(coalesce(v_outbox.body->>'text', ''), 4096);
  v_request := jsonb_build_object('chat_id', v_chat_id, 'text', v_text);

  IF v_thread_id IS NOT NULL AND v_thread_id <> '' THEN
    v_request := v_request || jsonb_build_object('message_thread_id', v_thread_id::bigint);
  END IF;

  UPDATE attobot.outbox
  SET status = 'sending',
      body = body || jsonb_build_object('telegram_claimed_at', now())
  WHERE id = v_outbox.id;

  outbox_id := v_outbox.id;
  has_outbox := true;
  request_body := v_request::text;
  reason := NULL;
  RETURN NEXT;
END;
$$;

CREATE OR REPLACE FUNCTION attobot.record_telegram_send_result(
  p_agent_slug text,
  p_outbox_id bigint,
  p_http_response jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v_agent_id bigint := attobot.agent_id(p_agent_slug);
  v_outbox_id bigint;
  v_status integer;
  v_body jsonb;
  v_ok boolean;
BEGIN
  IF p_outbox_id IS NULL THEN
    RETURN jsonb_build_object('sent', false, 'reason', 'empty');
  END IF;

  v_outbox_id := p_outbox_id;
  v_status := coalesce((p_http_response->>'status')::integer, 0);
  v_body := attobot.try_jsonb(coalesce(p_http_response->>'body', ''));
  v_ok := v_status >= 200 AND v_status < 300 AND coalesce((v_body->>'ok')::boolean, false);

  UPDATE attobot.outbox
  SET status = CASE WHEN v_ok THEN 'sent' ELSE 'failed' END,
      sent_at = CASE WHEN v_ok THEN now() ELSE sent_at END,
      body = body || jsonb_build_object(
        'telegram_http_status', v_status,
        'telegram_response', v_body
      )
  WHERE id = v_outbox_id
    AND agent_id = v_agent_id;

  PERFORM attobot.log_event(
    v_agent_id,
    CASE WHEN v_ok THEN 'telegram.send' ELSE 'telegram.send.error' END,
    jsonb_build_object('outbox_id', v_outbox_id, 'status', v_status, 'body', v_body)
  );

  RETURN jsonb_build_object('sent', v_ok, 'outbox_id', v_outbox_id, 'status', v_status);
END;
$$;

CREATE OR REPLACE FUNCTION attobot.record_assistant_from_http(p_agent_slug text, p_http_response jsonb)
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
  v_status := coalesce((p_http_response->>'status')::integer, 0);
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

  v_body := attobot.try_jsonb(v_body_text);
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
      attobot.try_jsonb(v_call #>> '{function,arguments}')
    )
    ON CONFLICT (agent_id, tool_call_id) DO NOTHING;
    v_count := v_count + 1;
  END LOOP;

  RETURN jsonb_build_object('message_id', v_message_id, 'tool_calls', v_count, 'error', false);
END;
$$;

CREATE OR REPLACE FUNCTION attobot.has_pending_tool_requests(p_agent_slug text)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM attobot.tool_requests
    WHERE agent_id = attobot.agent_id(p_agent_slug)
      AND status = 'pending'
  );
$$;

CREATE OR REPLACE FUNCTION attobot.execute_tool_request(p_request_id bigint)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  v_req attobot.tool_requests%ROWTYPE;
  v_agent_slug text;
  v_result text;
  v_query text;
  v_rows jsonb;
  v_hash text;
BEGIN
  SELECT * INTO v_req
  FROM attobot.tool_requests
  WHERE id = p_request_id
  FOR UPDATE;

  IF v_req.id IS NULL THEN
    RAISE EXCEPTION 'unknown tool request %', p_request_id;
  END IF;

  SELECT slug INTO v_agent_slug FROM attobot.agents WHERE id = v_req.agent_id;

  UPDATE attobot.tool_requests
  SET status = 'running', updated_at = now()
  WHERE id = v_req.id;

  IF v_req.name = 'SEND_CHAT' THEN
    INSERT INTO attobot.outbox(agent_id, channel, body)
    VALUES (
      v_req.agent_id,
      coalesce(v_req.arguments->>'channel', 'chat'),
      jsonb_build_object('text', coalesce(v_req.arguments->>'text', ''))
    );
    v_result := 'queued';

  ELSIF v_req.name = 'APPEND_MESSAGE' THEN
    PERFORM attobot.append_message(
      coalesce(v_req.arguments->>'agent', v_agent_slug),
      coalesce(v_req.arguments->>'role', 'system'),
      coalesce(v_req.arguments->>'content', '')
    );
    v_result := 'appended';

  ELSIF v_req.name = 'STASH' THEN
    v_hash := left(md5(coalesce(v_req.arguments->>'content', '')), 12);
    INSERT INTO attobot.blobs(agent_id, hash, content)
    VALUES (v_req.agent_id, v_hash, coalesce(v_req.arguments->>'content', ''))
    ON CONFLICT (agent_id, hash) DO NOTHING;
    v_result := '[stash ' || v_hash || ']';

  ELSIF v_req.name = 'READ_BLOB' THEN
    SELECT content INTO v_result
    FROM attobot.blobs
    WHERE agent_id = v_req.agent_id
      AND hash = v_req.arguments->>'hash';
    v_result := coalesce(v_result, 'error: blob not found');

  ELSIF v_req.name = 'SQL' THEN
    v_query := btrim(coalesce(v_req.arguments->>'query', ''));
    IF v_query = '' THEN
      RAISE EXCEPTION 'SQL tool requires query';
    END IF;
    IF position(';' IN v_query) > 0 THEN
      RAISE EXCEPTION 'SQL tool accepts one semicolon-free query';
    END IF;

    EXECUTE format(
      'SELECT coalesce(jsonb_agg(to_jsonb(q)), ''[]''::jsonb) FROM (%s) AS q',
      v_query
    )
    INTO v_rows;

    v_result := jsonb_pretty(jsonb_build_object(
      'rows', coalesce(v_rows, '[]'::jsonb),
      'row_count', jsonb_array_length(coalesce(v_rows, '[]'::jsonb))
    ));

  ELSE
    RAISE EXCEPTION 'unknown tool: %', v_req.name;
  END IF;

  INSERT INTO attobot.messages(agent_id, role, content, tool_call_id)
  VALUES (v_req.agent_id, 'tool', v_result, v_req.tool_call_id);

  UPDATE attobot.tool_requests
  SET status = 'completed',
      result = v_result,
      updated_at = now()
  WHERE id = v_req.id;

  RETURN v_result;

EXCEPTION WHEN others THEN
  v_result := 'error: ' || SQLERRM;

  IF v_req.id IS NOT NULL THEN
    INSERT INTO attobot.messages(agent_id, role, content, tool_call_id)
    VALUES (v_req.agent_id, 'tool', v_result, v_req.tool_call_id);

    UPDATE attobot.tool_requests
    SET status = 'failed',
        error = SQLERRM,
        result = v_result,
        updated_at = now()
    WHERE id = v_req.id;
  END IF;

  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION attobot.run_pending_tool_requests(p_agent_slug text)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v_agent_id bigint := attobot.agent_id(p_agent_slug);
  v_req record;
  v_results jsonb := '[]'::jsonb;
  v_result text;
BEGIN
  FOR v_req IN
    SELECT id, tool_call_id, name
    FROM attobot.tool_requests
    WHERE agent_id = v_agent_id
      AND status = 'pending'
    ORDER BY id
  LOOP
    v_result := attobot.execute_tool_request(v_req.id);
    v_results := v_results || jsonb_build_array(jsonb_build_object(
      'tool_request_id', v_req.id,
      'tool_call_id', v_req.tool_call_id,
      'name', v_req.name,
      'result', v_result
    ));
  END LOOP;

  RETURN v_results;
END;
$$;

CREATE OR REPLACE FUNCTION attobot.finish_turn(p_agent_slug text, p_turn_id bigint DEFAULT NULL)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  v_agent_id bigint := attobot.agent_id(p_agent_slug);
BEGIN
  IF p_turn_id IS NOT NULL THEN
    UPDATE attobot.turns
    SET status = 'completed',
        updated_at = now()
    WHERE id = p_turn_id
      AND agent_id = v_agent_id;
  END IF;

  PERFORM attobot.log_event(v_agent_id, 'turn.complete', '{}'::jsonb);
  RETURN 'completed';
END;
$$;
