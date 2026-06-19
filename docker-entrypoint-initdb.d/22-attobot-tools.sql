CREATE OR REPLACE FUNCTION attobot._has_pending_tool_requests(p_agent_slug text)
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

CREATE OR REPLACE FUNCTION attobot._tool_send_chat(p_req attobot.tool_requests)
RETURNS text
LANGUAGE plpgsql
AS $$
BEGIN
  INSERT INTO attobot.outbox(agent_id, channel, body)
  VALUES (
    p_req.agent_id,
    coalesce(p_req.arguments->>'channel', 'chat'),
    jsonb_build_object('text', coalesce(p_req.arguments->>'text', ''))
  );
  RETURN 'queued';
END;
$$;

CREATE OR REPLACE FUNCTION attobot._tool_append_message(
  p_req attobot.tool_requests,
  p_agent_slug text
)
RETURNS text
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM attobot.append_message(
    coalesce(p_req.arguments->>'agent', p_agent_slug),
    coalesce(p_req.arguments->>'role', 'system'),
    coalesce(p_req.arguments->>'content', '')
  );
  RETURN 'appended';
END;
$$;

CREATE OR REPLACE FUNCTION attobot._tool_stash(p_req attobot.tool_requests)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  v_hash text;
BEGIN
  v_hash := left(md5(coalesce(p_req.arguments->>'content', '')), 12);
  INSERT INTO attobot.blobs(agent_id, hash, content)
  VALUES (p_req.agent_id, v_hash, convert_to(coalesce(p_req.arguments->>'content', ''), 'UTF8'))
  ON CONFLICT (agent_id, hash) DO NOTHING;
  RETURN '[stash ' || v_hash || ']';
END;
$$;

CREATE OR REPLACE FUNCTION attobot._tool_read_blob(p_req attobot.tool_requests)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  v_result text;
BEGIN
  SELECT convert_from(content, 'UTF8') INTO v_result
  FROM attobot.blobs
  WHERE agent_id = p_req.agent_id
    AND hash = p_req.arguments->>'hash';

  RETURN coalesce(v_result, 'error: blob not found');
END;
$$;

CREATE OR REPLACE FUNCTION attobot._tool_sql(p_req attobot.tool_requests)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  v_query text;
  v_rows jsonb;
BEGIN
  v_query := btrim(coalesce(p_req.arguments->>'query', ''));
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

  RETURN jsonb_pretty(jsonb_build_object(
    'rows', coalesce(v_rows, '[]'::jsonb),
    'row_count', jsonb_array_length(coalesce(v_rows, '[]'::jsonb))
  ));
END;
$$;

CREATE OR REPLACE FUNCTION attobot._complete_tool_request(
  p_request_id bigint,
  p_agent_id bigint,
  p_tool_call_id text,
  p_result text
)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  INSERT INTO attobot.messages(agent_id, role, content, tool_call_id)
  VALUES (p_agent_id, 'tool', p_result, p_tool_call_id);

  UPDATE attobot.tool_requests
  SET status = 'completed',
      result = p_result,
      updated_at = now()
  WHERE id = p_request_id;
END;
$$;

CREATE OR REPLACE FUNCTION attobot._fail_tool_request(
  p_request_id bigint,
  p_agent_id bigint,
  p_tool_call_id text,
  p_result text,
  p_error text
)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  INSERT INTO attobot.messages(agent_id, role, content, tool_call_id)
  VALUES (p_agent_id, 'tool', p_result, p_tool_call_id);

  UPDATE attobot.tool_requests
  SET status = 'failed',
      error = p_error,
      result = p_result,
      updated_at = now()
  WHERE id = p_request_id;
END;
$$;

CREATE OR REPLACE FUNCTION attobot._execute_tool_request(p_request_id bigint)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  v_req attobot.tool_requests%ROWTYPE;
  v_agent_slug text;
  v_result text;
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

  v_result := CASE v_req.name
    WHEN 'SEND_CHAT' THEN attobot._tool_send_chat(v_req)
    WHEN 'APPEND_MESSAGE' THEN attobot._tool_append_message(v_req, v_agent_slug)
    WHEN 'STASH' THEN attobot._tool_stash(v_req)
    WHEN 'READ_BLOB' THEN attobot._tool_read_blob(v_req)
    WHEN 'SQL' THEN attobot._tool_sql(v_req)
    ELSE NULL
  END;

  IF v_result IS NULL THEN
    RAISE EXCEPTION 'unknown tool: %', v_req.name;
  END IF;

  PERFORM attobot._complete_tool_request(v_req.id, v_req.agent_id, v_req.tool_call_id, v_result);
  RETURN v_result;

EXCEPTION WHEN others THEN
  v_result := 'error: ' || SQLERRM;

  IF v_req.id IS NOT NULL THEN
    PERFORM attobot._fail_tool_request(
      v_req.id,
      v_req.agent_id,
      v_req.tool_call_id,
      v_result,
      SQLERRM
    );
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
    v_result := attobot._execute_tool_request(v_req.id);
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
