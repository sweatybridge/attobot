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

CREATE OR REPLACE FUNCTION attobot._telegram_api_url(p_agent_slug text, p_method text)
RETURNS text
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_agent_id bigint := attobot.agent_id(p_agent_slug);
  v_token text;
  v_api_base text;
BEGIN
  v_token := attobot._config_text(v_agent_id, 'telegram_token');
  IF v_token IS NULL OR v_token = '' THEN
    RAISE EXCEPTION 'agent % has no telegram_token config', p_agent_slug;
  END IF;

  v_api_base := attobot._config_text(v_agent_id, 'telegram_api_base', 'https://api.telegram.org');
  RETURN rtrim(v_api_base, '/') || '/bot' || v_token || '/' || p_method;
END;
$$;

CREATE OR REPLACE FUNCTION attobot._telegram_headers()
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
  v_offset := coalesce(attobot._config_text(v_agent_id, 'telegram_update_offset', '0')::bigint, 0);
  RETURN jsonb_build_object(
    'offset', v_offset,
    'timeout', 0,
    'allowed_updates', jsonb_build_array('message')
  );
END;
$$;

CREATE OR REPLACE FUNCTION attobot.process_telegram_updates(
  p_agent_slug text,
  p_http_response jsonb
)
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
  v_chat_id text := attobot._config_text(v_agent_id, 'telegram_chat_id');
  v_thread_id text := attobot._config_text(v_agent_id, 'telegram_thread_id');
  v_message jsonb;
  v_message_chat_id text;
  v_message_thread_id text;
  v_text text;
  v_message_id bigint;
  v_seen boolean;
  v_accepted integer := 0;
  v_ignored integer := 0;
BEGIN
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

CREATE OR REPLACE FUNCTION attobot._telegram_claim_outbox(
  p_agent_slug text,
  p_outbox_id bigint DEFAULT NULL
)
RETURNS TABLE(outbox_id bigint, has_outbox boolean, request_body text, reason text)
LANGUAGE plpgsql
AS $$
DECLARE
  v_agent_id bigint := attobot.agent_id(p_agent_slug);
  v_chat_id text := attobot._config_text(v_agent_id, 'telegram_chat_id');
  v_thread_id text := attobot._config_text(v_agent_id, 'telegram_thread_id');
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
    AND (p_outbox_id IS NULL OR id = p_outbox_id)
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
  v_status := attobot._http_status(p_http_response);
  v_body := attobot._http_body_json(p_http_response);
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
