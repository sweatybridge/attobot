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
    WHERE agent_id = v_agent_id AND key = 'telegram_thread_id';
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

CREATE OR REPLACE FUNCTION attobot.telegram_get_updates_body(p_agent_slug text, p_timeout integer)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v_agent_id bigint := attobot.agent_id(p_agent_slug);
  v_offset bigint;
BEGIN
  -- Bind the agent GUC before reading config: this runs as the agent role in the
  -- inbox loop, so RLS on attobot.config binds us (config_agent_read_own requires
  -- current_agent_id). Without it the offset read returns NULL and falls back to
  -- 0 every cycle, re-fetching the same updates forever. Mirrors poll_messages
  -- (line 128 below). Mutating a session GUC is a side effect, so this is no
  -- longer STABLE.
  PERFORM set_config('attobot.current_agent_id', v_agent_id::text, true);
  v_offset := coalesce(attobot._config_text(v_agent_id, 'telegram_update_offset', '0')::bigint, 0);
  RETURN jsonb_build_object(
    'offset', v_offset,
    'timeout', p_timeout,
    'allowed_updates', jsonb_build_array('message')
  );
END;
$$;

CREATE OR REPLACE FUNCTION attobot._telegram_attachment_filename(
  p_filename text,
  p_hash text
)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_filename text := coalesce(nullif(btrim(p_filename), ''), 'blob-' || p_hash || '.bin');
BEGIN
  v_filename := regexp_replace(v_filename, '[^A-Za-z0-9._-]+', '_', 'g');
  v_filename := left(v_filename, 160);
  IF v_filename = '' OR v_filename IN ('.', '..') THEN
    v_filename := 'blob-' || p_hash || '.bin';
  END IF;
  IF left(v_filename, 1) = '.' THEN
    v_filename := 'blob-' || p_hash || v_filename;
  END IF;
  RETURN v_filename;
END;
$$;

-- Long-poll intake: parse Telegram getUpdates, track senders, and batch-insert
-- user messages (channel='telegram', chat_id set). The insert fires the
-- user→loop trigger; no explicit start_turn. Returns {accepted, ignored}.
CREATE OR REPLACE FUNCTION attobot.poll_messages(
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
  v_chat_id text;
  v_thread_id text;
  v_message jsonb;
  v_message_chat_id text;
  v_message_thread_id text;
  v_text text;
  v_from_id text;
  v_accepted jsonb := '[]'::jsonb;
  v_accepted_count integer := 0;
  v_ignored integer := 0;
BEGIN
  -- Bind the agent GUC (the inbox loop runs as the agent role, not
  -- service-bypass) before any agent-scoped config/message read.
  PERFORM set_config('attobot.current_agent_id', v_agent_id::text, true);
  v_chat_id := attobot._config_text(v_agent_id, 'telegram_chat_id');
  v_thread_id := attobot._config_text(v_agent_id, 'telegram_thread_id');

  v_status := attobot._http_status(p_http_response);
  v_body := attobot._http_body_json(p_http_response);

  IF v_status < 200 OR v_status >= 300 OR coalesce((v_body->>'ok')::boolean, false) IS NOT TRUE THEN
    PERFORM attobot.log_event(
      v_agent_id, 'telegram.poll.error',
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

    -- track the sender (channel-agnostic ledger)
    v_from_id := v_message #>> '{from,id}';
    IF v_from_id IS NOT NULL AND v_from_id <> '' THEN
      PERFORM attobot.upsert_user(
        'telegram', v_from_id,
        v_message #>> '{from,username}',
        v_message #>> '{from,first_name}',
        v_message->'from'
      );
    END IF;

    v_accepted := v_accepted || jsonb_build_array(jsonb_build_object(
      'update_id', v_update_id,
      'text', v_text,
      'chat_id', v_message_chat_id,
      'update', v_update
    ));
    v_accepted_count := v_accepted_count + 1;
  END LOOP;

  -- batch insert (one statement → one user→loop trigger fire)
  IF v_accepted_count > 0 THEN
    INSERT INTO attobot.messages(agent_id, role, content, payload, channel, chat_id)
    SELECT v_agent_id, 'user',
           format('[telegram %s] %s', (e->>'update_id')::bigint, e->>'text'),
           jsonb_build_object('telegram_update', e->'update'),
           'telegram', e->>'chat_id'
    FROM jsonb_array_elements(v_accepted) AS e
    ON CONFLICT DO NOTHING;
  END IF;

  IF v_max_update_id IS NOT NULL THEN
    PERFORM attobot.set_config(p_agent_slug, 'telegram_update_offset', to_jsonb(v_max_update_id + 1));
  END IF;

  PERFORM attobot.log_event(
    v_agent_id, 'telegram.poll',
    jsonb_build_object('accepted', v_accepted_count, 'ignored', v_ignored)
  );

  RETURN jsonb_build_object('accepted', v_accepted_count, 'ignored', v_ignored, 'error', false);
END;
$$;

-- Queue an outbound attachment by appending a system message (channel='telegram')
-- that the outbound trigger delivers. SECURITY DEFINER owner attobot_service so
-- it works even when called from the anonymous acting role inside a tool call.
CREATE OR REPLACE FUNCTION attobot.queue_outbound_attachment(
  p_agent_slug text,
  p_blob_hash text,
  p_filename text DEFAULT NULL,
  p_caption text DEFAULT NULL,
  p_mime_type text DEFAULT NULL,
  p_chat_id text DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = attobot, attotools, pg_temp
AS $$
DECLARE
  v_agent_id bigint := attobot.agent_id(p_agent_slug);
  v_id bigint;
BEGIN
  IF p_chat_id IS NULL OR p_chat_id = '' THEN
    p_chat_id := attobot._config_text(v_agent_id, 'telegram_chat_id');
  END IF;

  INSERT INTO attobot.messages(agent_id, role, content, payload, channel, chat_id)
  VALUES (
    v_agent_id, 'system', '',
    jsonb_strip_nulls(jsonb_build_object(
      'attachment', jsonb_strip_nulls(jsonb_build_object(
        'blob_hash', p_blob_hash,
        'filename', nullif(p_filename, ''),
        'caption', nullif(p_caption, ''),
        'mime_type', nullif(p_mime_type, '')
      ))
    )),
    'telegram', p_chat_id
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

-- Send one outbound message via Telegram and record the outcome in lifecycle.
-- Called inside a send instance (df.start from the outbound trigger). A text
-- reply is delivered upstream by df.http (sendMessage) in the send graph and
-- only logged here (p_http_response carries that result); an attachment is
-- uploaded here via curl (sendDocument) and then logged.
--
-- SELF-BINDS the agent GUC: the send instance runs in its own transaction,
-- separate from the outbound trigger whose is_local bind does not survive into
-- here, so the agent-scoped reads (messages/config/blobs) and the lifecycle
-- write resolve under RLS. The slug is threaded in (rather than read from the
-- message) so the GUC can be bound before the agent-scoped message read.
CREATE OR REPLACE FUNCTION attobot.send_message(
  p_agent_slug text,
  p_message_id bigint,
  p_http_response jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = attobot, attotools, public, pg_temp
AS $$
DECLARE
  v_agent_id bigint := attobot.agent_id(p_agent_slug);
  v_msg attobot.messages%ROWTYPE;
  v_chat_id text;
  v_thread_id text;
  v_blob_hash text;
  v_content bytea;
  v_filename text;
  v_mime_type text;
  v_caption text;
  v_url text;
  v_oid oid;
  v_path text;
  v_command text;
  v_output text;
  v_status integer := 0;
  v_response_text text := '';
BEGIN
  PERFORM set_config('attobot.current_agent_id', v_agent_id::text, true);

  -- Text reply: df.http already delivered it upstream; record the status only.
  -- (p_http_response non-NULL is the text-path signal; attachments omit it.)
  IF p_http_response IS NOT NULL THEN
    v_status := attobot._http_status(p_http_response);
    PERFORM attobot.log_event(v_agent_id, 'telegram.send',
      jsonb_build_object('message_id', p_message_id, 'kind', 'text', 'status', v_status));
    RETURN jsonb_build_object('sent', v_status >= 200 AND v_status < 300, 'status', v_status);
  END IF;

  -- Attachment via curl multipart.
  SELECT * INTO v_msg FROM attobot.messages WHERE id = p_message_id;
  IF v_msg.id IS NULL THEN
    RETURN jsonb_build_object('sent', false, 'reason', 'message not found');
  END IF;
  v_blob_hash := v_msg.payload #>> '{attachment,blob_hash}';

  SELECT content INTO v_content FROM attotools.blobs WHERE agent_id = v_agent_id AND hash = v_blob_hash;
  IF v_content IS NULL THEN
    PERFORM attobot.log_event(v_agent_id, 'telegram.send.error', jsonb_build_object('message_id', p_message_id, 'error', 'blob not found'));
    RETURN jsonb_build_object('sent', false, 'reason', 'blob not found');
  END IF;

  v_chat_id := coalesce(nullif(v_msg.chat_id, ''), attobot._config_text(v_agent_id, 'telegram_chat_id'));
  v_thread_id := attobot._config_text(v_agent_id, 'telegram_thread_id');
  v_filename := attobot._telegram_attachment_filename(v_msg.payload #>> '{attachment,filename}', v_blob_hash);
  v_mime_type := coalesce(nullif(btrim(v_msg.payload #>> '{attachment,mime_type}'), ''), 'application/octet-stream');
  IF v_mime_type !~ '^[A-Za-z0-9.+-]+/[A-Za-z0-9.+-]+$' THEN
    v_mime_type := 'application/octet-stream';
  END IF;
  v_caption := left(coalesce(v_msg.payload #>> '{attachment,caption}', ''), 1024);
  v_url := attobot._telegram_api_url(p_agent_slug, 'sendDocument');

  PERFORM attobot._program_output('mkdir -p /tmp/attobot-telegram');
  v_oid := lo_from_bytea(0, v_content);
  v_path := '/tmp/attobot-telegram/' || p_message_id || '-' || v_filename;
  PERFORM lo_export(v_oid, v_path);

  v_command :=
    'curl --silent --show-error --request POST --write-out ' || attobot._shell_quote(E'\n%{http_code}') ||
    ' ' || attobot._shell_quote(v_url) ||
    ' --form-string ' || attobot._shell_quote('chat_id=' || v_chat_id) ||
    CASE WHEN v_thread_id IS NOT NULL AND v_thread_id <> ''
      THEN ' --form-string ' || attobot._shell_quote('message_thread_id=' || v_thread_id) ELSE '' END ||
    CASE WHEN v_caption <> ''
      THEN ' --form-string ' || attobot._shell_quote('caption=' || v_caption) ELSE '' END ||
    ' --form ' || attobot._shell_quote('document=@' || v_path || ';filename=' || v_filename || ';type=' || v_mime_type);

  BEGIN
    v_output := attobot._program_output(v_command);
    v_status := coalesce(nullif(substring(v_output from '([0-9]{3})\s*$'), '')::integer, 0);
    v_response_text := regexp_replace(v_output, E'\n[0-9]{3}\\s*$', '');
  EXCEPTION WHEN others THEN
    v_response_text := SQLERRM;
  END;

  BEGIN IF v_oid IS NOT NULL THEN PERFORM lo_unlink(v_oid); END IF; EXCEPTION WHEN others THEN NULL; END;
  BEGIN PERFORM attobot._program_output('rm -f -- ' || attobot._shell_quote(v_path)); EXCEPTION WHEN others THEN NULL; END;

  PERFORM attobot.log_event(v_agent_id, 'telegram.send',
    jsonb_build_object('message_id', p_message_id, 'kind', 'attachment', 'status', v_status));
  RETURN jsonb_build_object('sent', v_status >= 200 AND v_status < 300, 'status', v_status);
END;
$$;

-- Build the send-graph for an outbound message. Text → df.http sendMessage then
-- send_message (logs the status); attachment → send_message (curl + log). Used
-- by the outbound trigger to df.start a send instance. SELF-BINDS the agent GUC
-- for the build-time message read; send_message re-binds it at execution time,
-- so no graph node depends on session state carried over from the trigger.
CREATE OR REPLACE FUNCTION attobot.send_message_future(p_agent_slug text, p_message_id bigint)
RETURNS text
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = attobot, attotools, public, pg_temp
AS $$
DECLARE
  v_agent_id bigint := attobot.agent_id(p_agent_slug);
  v_msg attobot.messages%ROWTYPE;
  v_chat_id text;
  v_thread_id text;
  v_blob_hash text;
  v_body jsonb;
BEGIN
  PERFORM set_config('attobot.current_agent_id', v_agent_id::text, true);

  SELECT * INTO v_msg FROM attobot.messages WHERE id = p_message_id;
  v_chat_id := coalesce(nullif(v_msg.chat_id, ''), attobot._config_text(v_agent_id, 'telegram_chat_id'));
  v_thread_id := attobot._config_text(v_agent_id, 'telegram_thread_id');
  v_blob_hash := v_msg.payload #>> '{attachment,blob_hash}';

  IF v_blob_hash IS NOT NULL THEN
    -- attachment: send_message uploads via curl and logs (self-binds the GUC)
    RETURN format('SELECT attobot.send_message(%L, %s)::jsonb AS result', p_agent_slug, p_message_id);
  END IF;

  -- text: df.http sends via sendMessage, then send_message logs the status
  v_body := jsonb_build_object('chat_id', v_chat_id, 'text', left(coalesce(v_msg.content, ''), 4096));
  IF v_thread_id IS NOT NULL AND v_thread_id <> '' THEN
    v_body := v_body || jsonb_build_object('message_thread_id', v_thread_id::bigint);
  END IF;

  RETURN df.http(
    attobot._telegram_api_url(p_agent_slug, 'sendMessage'), 'POST', v_body::text,
    attobot._telegram_headers(), 30
  ) |=> 'r'
    ~> format(
      'SELECT attobot.send_message(%L, %s, $r::jsonb)::jsonb AS result',
      p_agent_slug, p_message_id
    );
END;
$$;
