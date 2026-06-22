CREATE OR REPLACE FUNCTION attobot.finish_turn(p_agent_slug text, p_turn_id bigint DEFAULT NULL)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  v_agent_id bigint := attobot.agent_id(p_agent_slug);
BEGIN
  PERFORM attobot.log_event(
    v_agent_id,
    'turn.complete',
    jsonb_strip_nulls(jsonb_build_object('turn_id', p_turn_id))
  );
  RETURN 'completed';
END;
$$;

CREATE OR REPLACE FUNCTION attobot.start_turn(
  p_agent_slug text DEFAULT 'primary',
  p_requesting_user_id bigint DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  v_agent_id bigint := attobot.agent_id(p_agent_slug);
  v_instance text;
  v_turn_id bigint;
BEGIN
  SELECT attobot.log_event(
    v_agent_id,
    'turn.start',
    jsonb_build_object('status', 'started')
  )
  INTO v_turn_id;

  SELECT df.start(
    format('SELECT attobot.compose_llm_request(%L)::text AS body', p_agent_slug) |=> 'request'
    ~> df.http(
      attobot._llm_url(p_agent_slug),
      'POST',
      '$request.body',
      attobot._llm_headers(p_agent_slug),
      120
    ) |=> 'http_response'
    ~> format('SELECT attobot.record_assistant_from_http(%L, $http_response::jsonb, %s, %L)::jsonb AS assistant', p_agent_slug, v_turn_id, p_requesting_user_id)
    ~> df.if(
      'SELECT ($assistant.tool_calls)::integer > 0',
      format('SELECT attotools.start_tool_signal_executor(%L, ($assistant.message_id)::bigint, %s) AS tool_executor', p_agent_slug, v_turn_id)
        ~> (df.wait_for_signal(attotools.tool_signal_name(p_agent_slug, v_turn_id), 900) |=> 'tool_signal')
        ~> format('SELECT attotools.record_tool_signal(%L, %s, $tool_signal::jsonb)::jsonb AS tool_signal_result', p_agent_slug, v_turn_id)
        ~> format('SELECT attobot.finish_turn(%L, %s) AS done', p_agent_slug, v_turn_id)
        ~> format('SELECT attobot.start_turn(%L, %L) AS next_instance', p_agent_slug, p_requesting_user_id),
      format('SELECT attobot.finish_turn(%L, %s) AS done', p_agent_slug, v_turn_id)
    ),
    format('attobot:%s:turn:%s', p_agent_slug, v_turn_id)
  )
  INTO v_instance;

  PERFORM attobot.log_event(
    v_agent_id,
    'turn.instance',
    jsonb_build_object('turn_id', v_turn_id, 'durable_instance_id', v_instance)
  );

  RETURN v_instance;
END;
$$;

CREATE OR REPLACE FUNCTION attobot._start_durable_loop_once(
  p_label text,
  p_future text
)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  v_instance text;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended('attobot:durable-loop:' || p_label, 0));

  SELECT id INTO v_instance
  FROM df.instances
  WHERE label = p_label
    AND status IN ('pending', 'running')
  ORDER BY created_at DESC
  LIMIT 1;

  IF v_instance IS NOT NULL THEN
    RETURN v_instance;
  END IF;

  SELECT df.start(p_future, p_label)
  INTO v_instance;

  RETURN v_instance;
END;
$$;

CREATE OR REPLACE FUNCTION attobot.ensure_scheduled_message_loop(
  p_agent_slug text DEFAULT 'primary',
  p_name text DEFAULT 'heartbeat',
  p_cron text DEFAULT '* * * * *',
  p_message text DEFAULT 'tick'
)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  v_instance text;
  v_label text := format('attobot:%s:schedule:%s', p_agent_slug, p_name);
BEGIN
  SELECT attobot._start_durable_loop_once(
    v_label,
    df.loop(
      df.wait_for_schedule(p_cron)
      ~> format(
        'SELECT attobot.append_message(%L, %L, %L)::bigint AS message_id',
        p_agent_slug,
        'system',
        format('[schedule %s] %s', p_name, p_message)
      )
      ~> format('SELECT attobot.start_turn(%L) AS durable_instance_id', p_agent_slug)
    )
  )
  INTO v_instance;

  RETURN v_instance;
END;
$$;

CREATE OR REPLACE FUNCTION attobot.ensure_telegram_inbox_loop(
  p_agent_slug text DEFAULT 'primary',
  p_timeout integer DEFAULT 60
)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  v_instance text;
  v_label text := format('attobot:%s:telegram-inbox', p_agent_slug);
BEGIN
  SELECT attobot._start_durable_loop_once(
    v_label,
    df.loop(
      format('SELECT attobot.telegram_get_updates_body(%L, %s)::text AS body', p_agent_slug, p_timeout) |=> 'request'
      ~> df.http(
        attobot._telegram_api_url(p_agent_slug, 'getUpdates'),
        'POST',
        '$request.body',
        attobot._telegram_headers(),
        p_timeout + 10
      ) |=> 'http_response'
      ~> format('SELECT attobot.process_telegram_updates(%L, $http_response::jsonb)::jsonb AS result', p_agent_slug)
    )
  )
  INTO v_instance;

  RETURN v_instance;
END;
$$;

CREATE OR REPLACE FUNCTION attobot.start_telegram_outbox_send(
  p_agent_slug text DEFAULT 'primary',
  p_outbox_id bigint DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  v_instance text;
BEGIN
  IF p_outbox_id IS NULL THEN
    RAISE EXCEPTION 'p_outbox_id is required';
  END IF;

  SELECT df.start(
    format('SELECT * FROM attobot._telegram_claim_outbox(%L, %s)', p_agent_slug, p_outbox_id) |=> 'claim'
    ~> df.if(
      format(
        'SELECT $claim.has_outbox AND EXISTS (SELECT 1 FROM attobot.outbox WHERE id = $claim.outbox_id AND channel = %L)',
        'telegram_attachment'
      ),
      format('SELECT attobot.send_telegram_attachment_outbox(%L, $claim.outbox_id)::jsonb AS result', p_agent_slug),
      df.if(
        'SELECT $claim.has_outbox',
        df.http(
          attobot._telegram_api_url(p_agent_slug, 'sendMessage'),
          'POST',
          '$claim.request_body',
          attobot._telegram_headers(),
          30
        ) |=> 'http_response'
          ~> format('SELECT attobot.record_telegram_send_result(%L, $claim.outbox_id, $http_response::jsonb)::jsonb AS result', p_agent_slug),
        'SELECT jsonb_build_object(''sent'', false, ''reason'', coalesce($claim.reason, ''empty'')) AS result'
      )
    ),
    format('attobot:%s:telegram-outbox:%s:%s', p_agent_slug, p_outbox_id, txid_current())
  )
  INTO v_instance;

  RETURN v_instance;
END;
$$;

CREATE OR REPLACE FUNCTION attobot._outbox_trigger_telegram_send()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_agent_slug text;
  v_instance text;
BEGIN
  IF NEW.status <> 'pending'
     OR NEW.channel NOT IN ('chat', 'telegram', 'telegram_attachment')
     OR coalesce(attobot._config_text(NEW.agent_id, 'telegram_token'), '') = ''
     OR coalesce(attobot._config_text(NEW.agent_id, 'telegram_chat_id'), '') = '' THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'UPDATE'
     AND OLD.status IS NOT DISTINCT FROM NEW.status
     AND OLD.channel IS NOT DISTINCT FROM NEW.channel THEN
    RETURN NEW;
  END IF;

  SELECT slug INTO v_agent_slug
  FROM attobot.agents
  WHERE id = NEW.agent_id;

  IF v_agent_slug IS NULL THEN
    RETURN NEW;
  END IF;

  BEGIN
    v_instance := attobot.start_telegram_outbox_send(v_agent_slug, NEW.id);

    PERFORM attobot.log_event(
      NEW.agent_id,
      'telegram.outbox.trigger',
      jsonb_build_object('outbox_id', NEW.id, 'durable_instance_id', v_instance)
    );
  EXCEPTION WHEN others THEN
    PERFORM attobot.log_event(
      NEW.agent_id,
      'telegram.outbox.trigger.error',
      jsonb_build_object('outbox_id', NEW.id, 'error', SQLERRM)
    );
  END;

  RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER outbox_telegram_send_trigger
AFTER INSERT OR UPDATE OF status, channel ON attobot.outbox
FOR EACH ROW
EXECUTE FUNCTION attobot._outbox_trigger_telegram_send();
