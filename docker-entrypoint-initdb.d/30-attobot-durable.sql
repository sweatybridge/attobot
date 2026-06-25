-- ============================================================================
-- Trigger-driven agent loop
--   Primary: an AFTER INSERT STATEMENT trigger on attobot.messages starts a
--   bounded df.loop whenever a role='user' row for the primary agent lands.
--   Each iteration: compose → LLM http → record assistant → run tool calls as
--   per-call instances under the acting role → loop until no tool calls or
--   max_turn. Outbound delivery is a separate row-level trigger (below).
-- ============================================================================

CREATE OR REPLACE FUNCTION attobot.start_agent_loop(
  p_agent_slug text,
  p_trigger_message_id bigint,
  p_requesting_user_id bigint DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = attobot, attotools, public, pg_temp
AS $$
DECLARE
  v_agent_id bigint := attobot.agent_id(p_agent_slug);
  v_label text := format('attobot:%s:loop', p_agent_slug);
  v_existing text;
  v_max_turn integer;
  v_acting_role text;
  v_ext_id text;
  v_user_id text;
  v_channel text;
  v_chat_id text;
  v_body text;
  v_cond text;
  v_instance text;
BEGIN
  -- gate: a single loop per agent at a time (a running loop reads recent
  -- history, so it absorbs messages that arrive mid-turn)
  SELECT id INTO v_existing
    FROM df.instances
    WHERE label = v_label AND status IN ('pending', 'running')
    LIMIT 1;
  IF v_existing IS NOT NULL THEN
    RETURN v_existing;
  END IF;

  SELECT max_turn INTO v_max_turn FROM attobot.agents WHERE id = v_agent_id;

  -- SECURITY INVOKER: this runs as the entry-starter's owner (attobot_agent_primary
  -- via the inbox/user-message trigger, attobot_agent_subconscious via the cron
  -- loop). Bind the agent GUC for this session so the agent-scoped reads below
  -- resolve under RLS (no service bypass anymore).
  PERFORM set_config('attobot.current_agent_id', v_agent_id::text, true);

  -- acting role + user context. Primary user turns drop tool calls to the
  -- requesting user's tier; subconscious (no requesting user) drops to
  -- attobot_service (broad, secret-free) so it can review any agent; otherwise
  -- tools run at the agent's own role.
  IF p_requesting_user_id IS NOT NULL THEN
    SELECT 'attobot_' || u.tier, u.external_id, u.id::text
      INTO v_acting_role, v_ext_id, v_user_id
      FROM attobot.users u WHERE u.id = p_requesting_user_id;
    v_channel := 'telegram';
    SELECT chat_id INTO v_chat_id FROM attobot.messages WHERE id = p_trigger_message_id;
  ELSIF p_agent_slug = 'subconscious' THEN
    v_acting_role := 'attobot_service';
  ELSE
    v_acting_role := 'attobot_agent_' || p_agent_slug;
  END IF;

  v_body :=
    format('SELECT attobot.compose_llm_request(%L)::text AS body', p_agent_slug) |=> 'request'
    ~> df.http(attobot._llm_url(p_agent_slug), 'POST', '$request',
               attobot._llm_headers(p_agent_slug), 120) |=> 'response'
    ~> df.if(
         'SELECT attobot._http_status($response::jsonb) >= 200 AND attobot._http_status($response::jsonb) < 300',
         format('SELECT attobot.record_assistant(%L, $response::jsonb, %s, %L, %L)::jsonb AS assistant',
                p_agent_slug, coalesce(p_requesting_user_id::text, 'NULL'), v_channel, v_chat_id),
         format('SELECT attobot.append_message(%L, ''system'', format(''[llm http error %%s]'', attobot._http_status($response::jsonb)))::text AS e',
                p_agent_slug)
           ~> df.break('llm_error')
       )
    ~> df.if(
         'SELECT coalesce(jsonb_array_length(($assistant::jsonb)->''tool_calls''), 0) > 0',
         format('SELECT attotools.run_tool_calls(%L, ($assistant::jsonb)->>''message_id'', ($assistant::jsonb)->''tool_calls'', %L, %L, %L, %s)::text AS tools',
                p_agent_slug, v_acting_role, coalesce(v_ext_id, ''), coalesce(v_chat_id, ''), coalesce(v_user_id, 'NULL')),
         df.break('done')
       );

  -- The loop condition runs as its own statement in the instance, so bind the
  -- agent GUC inline (FROM is evaluated before WHERE) before the messages count.
  v_cond := format(
    'SELECT (SELECT count(*) FROM attobot.messages CROSS JOIN (SELECT set_config(''attobot.current_agent_id'', %L, true)) AS cfg WHERE agent_id = %s AND role = ''assistant'' AND id > %s) < coalesce((SELECT max_turn FROM attobot.agents WHERE id = %s), 1)',
    v_agent_id::text, v_agent_id, p_trigger_message_id, v_agent_id
  );

  SELECT df.start(df.loop(v_body, v_cond), v_label) INTO v_instance;
  RETURN v_instance;
END;
$$;

-- AFTER INSERT STATEMENT trigger: start the primary loop when user messages land
CREATE OR REPLACE FUNCTION attobot.after_user_message_loop()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = attobot, attotools, public, pg_temp
AS $$
DECLARE
  v_primary_id bigint;
  v_trigger_id bigint;
  v_from_id text;
  v_req_user_id bigint;
BEGIN
  SELECT id INTO v_primary_id FROM attobot.agents WHERE slug = 'primary';
  IF v_primary_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM new_rows WHERE role = 'user' AND agent_id = v_primary_id
  ) THEN
    RETURN NULL;
  END IF;

  SELECT id, payload #>> '{telegram_update,message,from,id}'
    INTO v_trigger_id, v_from_id
    FROM new_rows
    WHERE role = 'user' AND agent_id = v_primary_id
    ORDER BY id DESC LIMIT 1;

  IF v_from_id IS NOT NULL THEN
    SELECT id INTO v_req_user_id FROM attobot.users
      WHERE channel = 'telegram' AND external_id = v_from_id;
  END IF;

  PERFORM attobot.start_agent_loop('primary', v_trigger_id, v_req_user_id);
  RETURN NULL;
END;
$$;

CREATE TRIGGER messages_user_loop_trigger
AFTER INSERT ON attobot.messages
REFERENCING NEW TABLE AS new_rows
FOR EACH STATEMENT
EXECUTE FUNCTION attobot.after_user_message_loop();

-- ============================================================================
-- Outbound delivery trigger (replaces the outbox)
--   role in ('assistant','system') + channel='telegram' → df.start a send
-- ============================================================================

CREATE OR REPLACE FUNCTION attobot.after_outbound_message_send()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = attobot, attotools, public, pg_temp
AS $$
BEGIN
  -- Bind the agent GUC so send_message_future's build-time read of the outbound
  -- message resolves under primary scope (no service bypass).
  PERFORM set_config('attobot.current_agent_id', NEW.agent_id::text, true);
  PERFORM df.start(attobot.send_message_future(NEW.id), format('attobot:send:%s', NEW.id));
  RETURN NULL;
END;
$$;

CREATE TRIGGER messages_outbound_send_trigger
AFTER INSERT ON attobot.messages
FOR EACH ROW
WHEN (NEW.role IN ('assistant', 'system') AND NEW.channel = 'telegram')
EXECUTE FUNCTION attobot.after_outbound_message_send();

-- ============================================================================
-- Inbound long-poll loop (Telegram getUpdates → poll_messages → trigger)
-- ============================================================================

CREATE OR REPLACE FUNCTION attobot.ensure_telegram_inbox_loop(
  p_agent_slug text DEFAULT 'primary',
  p_timeout integer DEFAULT 60
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = attobot, attotools, public, pg_temp
AS $$
DECLARE
  v_label text := format('attobot:%s:inbox', p_agent_slug);
  v_existing text;
  v_future text;
  v_instance text;
BEGIN
  SELECT id INTO v_existing
    FROM df.instances WHERE label = v_label AND status IN ('pending', 'running') LIMIT 1;
  IF v_existing IS NOT NULL THEN
    RETURN v_existing;
  END IF;

  v_future := df.loop(
    format('SELECT attobot.telegram_get_updates_body(%L, %s)::text AS body', p_agent_slug, p_timeout) |=> 'req'
    ~> df.http(attobot._telegram_api_url(p_agent_slug, 'getUpdates'), 'POST', '$req',
               attobot._telegram_headers(), p_timeout + 10) |=> 'resp'
    ~> format('SELECT attobot.poll_messages(%L, $resp::jsonb)::jsonb AS result', p_agent_slug)
  );

  SELECT df.start(v_future, v_label) INTO v_instance;
  RETURN v_instance;
END;
$$;

-- ============================================================================
-- Cron-driven agent loop (subconscious): on schedule, append a system prompt
-- and start that agent's loop (tools run as the agent's own role)
-- ============================================================================

CREATE OR REPLACE FUNCTION attobot.ensure_agent_cron_loop(
  p_agent_slug text DEFAULT 'subconscious',
  p_name text DEFAULT 'review',
  p_cron text DEFAULT '*/10 * * * *',
  p_message text DEFAULT 'review agent streams for actionable memory corrections'
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = attobot, attotools, public, pg_temp
AS $$
DECLARE
  v_label text := format('attobot:%s:cron:%s', p_agent_slug, p_name);
  v_existing text;
  v_future text;
  v_instance text;
BEGIN
  SELECT id INTO v_existing
    FROM df.instances WHERE label = v_label AND status IN ('pending', 'running') LIMIT 1;
  IF v_existing IS NOT NULL THEN
    RETURN v_existing;
  END IF;

  v_future := df.loop(
    df.wait_for_schedule(p_cron)
    ~> format('SELECT attobot.append_message(%L, ''system'', %L)::bigint AS m',
              p_agent_slug, format('[schedule %s] %s', p_name, p_message)) |=> 'm'
    ~> format('SELECT attobot.start_agent_loop(%L, $m, NULL)::text AS loop_id', p_agent_slug)
  );

  SELECT df.start(v_future, v_label) INTO v_instance;
  RETURN v_instance;
END;
$$;
