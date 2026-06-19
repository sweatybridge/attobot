CREATE OR REPLACE FUNCTION attobot.start_turn(p_agent_slug text DEFAULT 'primary')
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  v_agent_id bigint := attobot.agent_id(p_agent_slug);
  v_instance text;
  v_turn_id bigint;
BEGIN
  INSERT INTO attobot.turns(agent_id, status)
  VALUES (v_agent_id, 'started')
  RETURNING id INTO v_turn_id;

  SELECT df.start(
    format('SELECT attobot.compose_llm_request(%L)::text AS body', p_agent_slug) |=> 'request'
    ~> df.http(
      attobot.llm_url(p_agent_slug),
      'POST',
      '$request.body',
      attobot.llm_headers(p_agent_slug),
      120
    ) |=> 'http_response'
    ~> format('SELECT attobot.record_assistant_from_http(%L, $http_response::jsonb)::jsonb AS assistant', p_agent_slug)
    ~> df.if(
      format('SELECT attobot.has_pending_tool_requests(%L)', p_agent_slug),
      format('SELECT attobot.run_pending_tool_requests(%L)::jsonb AS tool_results', p_agent_slug)
        ~> format('SELECT attobot.start_turn(%L) AS next_instance', p_agent_slug),
      format('SELECT attobot.finish_turn(%L, %s) AS done', p_agent_slug, v_turn_id)
    ),
    format('attobot:%s:turn:%s', p_agent_slug, v_turn_id)
  )
  INTO v_instance;

  UPDATE attobot.turns
  SET durable_instance_id = v_instance,
      updated_at = now()
  WHERE id = v_turn_id;

  PERFORM attobot.log_event(
    v_agent_id,
    'turn.start',
    jsonb_build_object('turn_id', v_turn_id, 'durable_instance_id', v_instance)
  );

  RETURN v_instance;
END;
$$;

CREATE OR REPLACE FUNCTION attobot.start_agent_loop(
  p_agent_slug text DEFAULT 'primary',
  p_cron text DEFAULT '*/5 * * * *'
)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  v_instance text;
BEGIN
  SELECT df.start(
    df.loop(
      df.wait_for_schedule(p_cron)
      ~> format('SELECT attobot.append_system_message(%L, %L)::bigint AS message_id', p_agent_slug, '[trigger heartbeat] tick')
      ~> format('SELECT attobot.start_turn(%L) AS durable_instance_id', p_agent_slug)
    ),
    format('attobot:%s:agent-loop', p_agent_slug)
  )
  INTO v_instance;

  RETURN v_instance;
END;
$$;

CREATE OR REPLACE FUNCTION attobot.install_interval_trigger(
  p_agent_slug text,
  p_name text,
  p_interval_seconds integer,
  p_message text,
  p_start_after timestamptz DEFAULT now()
)
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  v_agent_id bigint := attobot.agent_id(p_agent_slug);
  v_id bigint;
BEGIN
  INSERT INTO attobot.triggers(agent_id, name, interval_seconds, message, next_after)
  VALUES (v_agent_id, p_name, p_interval_seconds, p_message, p_start_after)
  ON CONFLICT (agent_id, name) DO UPDATE
    SET interval_seconds = EXCLUDED.interval_seconds,
        message = EXCLUDED.message,
        next_after = EXCLUDED.next_after,
        enabled = true,
        updated_at = now()
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION attobot.fire_due_triggers(p_agent_slug text DEFAULT 'primary')
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v_agent_id bigint := attobot.agent_id(p_agent_slug);
  v_trigger record;
  v_fired jsonb := '[]'::jsonb;
BEGIN
  FOR v_trigger IN
    SELECT *
    FROM attobot.triggers
    WHERE agent_id = v_agent_id
      AND enabled
      AND next_after <= now()
    ORDER BY next_after, id
    FOR UPDATE
  LOOP
    PERFORM attobot.append_system_message(
      p_agent_slug,
      format('[trigger %s] %s', v_trigger.name, v_trigger.message)
    );

    UPDATE attobot.triggers
    SET last_fired_at = now(),
        next_after = now() + make_interval(secs => v_trigger.interval_seconds),
        updated_at = now()
    WHERE id = v_trigger.id;

    v_fired := v_fired || jsonb_build_array(v_trigger.name);
  END LOOP;

  IF jsonb_array_length(v_fired) > 0 THEN
    PERFORM attobot.start_turn(p_agent_slug);
  END IF;

  RETURN jsonb_build_object('fired', v_fired);
END;
$$;

CREATE OR REPLACE FUNCTION attobot.start_trigger_loop(
  p_agent_slug text DEFAULT 'primary',
  p_cron text DEFAULT '* * * * *'
)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  v_instance text;
BEGIN
  SELECT df.start(
    df.loop(
      df.wait_for_schedule(p_cron)
      ~> format('SELECT attobot.fire_due_triggers(%L)::jsonb AS fired', p_agent_slug)
    ),
    format('attobot:%s:trigger-loop', p_agent_slug)
  )
  INTO v_instance;

  RETURN v_instance;
END;
$$;
