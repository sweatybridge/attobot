-- Agent-scoped, content-addressed blob store. Large/binary content is kept out
-- of the message stream and referenced by hash. EXTERNAL storage so bytea is
-- neither compressed nor inlined.
CREATE TABLE IF NOT EXISTS attotools.blobs (
  agent_id bigint NOT NULL REFERENCES attobot.agents(id) ON DELETE CASCADE,
  hash text NOT NULL,
  content bytea NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (agent_id, hash)
);

ALTER TABLE attotools.blobs ALTER COLUMN content SET STORAGE EXTERNAL;

CREATE OR REPLACE FUNCTION attotools._append_tool_message(
  p_agent_id bigint,
  p_tool_call_id text,
  p_result text
)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  -- Bind the agent GUC so the INSERT satisfies the agent-scoped WITH CHECK
  -- policy (run_tool_calls runs as the loop/agent role, not service-bypass).
  PERFORM set_config('attobot.current_agent_id', p_agent_id::text, true);

  INSERT INTO attobot.messages(agent_id, role, content, tool_call_id)
  VALUES (p_agent_id, 'tool', coalesce(p_result, ''), p_tool_call_id)
  ON CONFLICT (agent_id, tool_call_id)
    WHERE role = 'tool' AND tool_call_id IS NOT NULL
    DO NOTHING;
END;
$$;

-- SEND_ATTACHMENT: validate the blob (read as the acting role) and queue an
-- outbound system message (channel='telegram') that the outbound trigger
-- delivers. No outbox. queue_outbound_attachment (SECURITY DEFINER, owner
-- attobot_service) does the privileged append so this works even when the
-- caller is the anonymous acting role.
CREATE OR REPLACE FUNCTION attotools._tool_send_attachment(
  p_hash text,
  p_filename text DEFAULT '',
  p_caption text DEFAULT '',
  p_mime_type text DEFAULT ''
)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  v_agent_id bigint := nullif(current_setting('attobot.current_agent_id', true), '')::bigint;
  v_hash text := btrim(coalesce(p_hash, ''));
  v_slug text;
  v_chat_id text;
BEGIN
  IF v_agent_id IS NULL THEN
    RAISE EXCEPTION 'SEND_ATTACHMENT has no current agent context';
  END IF;
  IF v_hash = '' THEN
    RAISE EXCEPTION 'SEND_ATTACHMENT requires hash';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM attotools.blobs WHERE agent_id = v_agent_id AND hash = v_hash
  ) THEN
    RAISE EXCEPTION 'blob not found: %', v_hash;
  END IF;

  SELECT slug, chat_id INTO v_slug, v_chat_id
  FROM attobot.messages m JOIN attobot.agents a ON a.id = m.agent_id
  WHERE m.agent_id = v_agent_id AND m.role = 'user'
  ORDER BY m.id DESC LIMIT 1;

  PERFORM attobot.queue_outbound_attachment(
    v_slug, v_hash,
    nullif(p_filename, ''),
    nullif(p_caption, ''),
    nullif(p_mime_type, ''),
    v_chat_id
  );

  RETURN jsonb_build_object('queued', true, 'blob_hash', v_hash)::text;
END;
$$;
COMMENT ON FUNCTION attotools._tool_send_attachment(text, text, text, text) IS 'Send blob content as a Telegram document attachment. Use WRITE_BLOB first, then pass the returned hash.';

CREATE OR REPLACE FUNCTION attotools._blob_decode_content(
  p_content text,
  p_encoding text
)
RETURNS bytea
LANGUAGE plpgsql
AS $$
DECLARE
  v_encoding text := btrim(coalesce(p_encoding, ''));
  v_format text := lower(btrim(coalesce(p_encoding, '')));
BEGIN
  IF p_content IS NULL THEN
    RAISE EXCEPTION 'content is required';
  END IF;
  IF v_encoding = '' THEN
    RAISE EXCEPTION 'encoding is required';
  END IF;

  IF v_format IN ('base64', 'hex', 'escape') THEN
    RETURN decode(p_content, v_format);
  END IF;

  RETURN convert_to(p_content, v_encoding);

EXCEPTION WHEN others THEN
  RAISE EXCEPTION 'could not decode blob content with encoding "%": %', v_encoding, SQLERRM;
END;
$$;

CREATE OR REPLACE FUNCTION attotools._blob_encode_content(
  p_content bytea,
  p_encoding text DEFAULT 'UTF8'
)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  v_encoding text := btrim(coalesce(p_encoding, 'UTF8'));
  v_format text := lower(btrim(coalesce(p_encoding, 'UTF8')));
BEGIN
  IF p_content IS NULL THEN
    RETURN NULL;
  END IF;
  IF v_encoding = '' THEN
    v_encoding := 'UTF8';
    v_format := 'utf8';
  END IF;

  IF v_format IN ('base64', 'hex', 'escape') THEN
    RETURN encode(p_content, v_format);
  END IF;

  RETURN convert_from(p_content, v_encoding);

EXCEPTION WHEN others THEN
  RAISE EXCEPTION 'could not encode blob content with encoding "%": %', v_encoding, SQLERRM;
END;
$$;

CREATE OR REPLACE FUNCTION attotools._tool_write_blob(
  p_content text,
  p_encoding text
)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  v_agent_id bigint := nullif(current_setting('attobot.current_agent_id', true), '')::bigint;
  v_bytes bytea;
  v_hash text;
BEGIN
  v_bytes := attotools._blob_decode_content(p_content, p_encoding);
  v_hash := left(md5(v_bytes), 12);

  INSERT INTO attotools.blobs(agent_id, hash, content)
  VALUES (v_agent_id, v_hash, v_bytes)
  ON CONFLICT (agent_id, hash) DO NOTHING;

  RETURN jsonb_build_object(
    'hash', v_hash,
    'bytes', length(v_bytes),
    'marker', '[blob ' || v_hash || ']'
  )::text;
END;
$$;
COMMENT ON FUNCTION attotools._tool_write_blob(text, text) IS 'Write data to attotools.blobs. The content is decoded using encoding: base64, hex, escape, or a PostgreSQL text encoding such as UTF8, LATIN1, or WIN1252.';

CREATE OR REPLACE FUNCTION attotools._tool_read_blob(
  p_hash text,
  p_encoding text DEFAULT 'UTF8'
)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  v_agent_id bigint := nullif(current_setting('attobot.current_agent_id', true), '')::bigint;
  v_content bytea;
BEGIN
  SELECT content INTO v_content
  FROM attotools.blobs
  WHERE agent_id = v_agent_id AND hash = p_hash;

  IF v_content IS NULL THEN
    RETURN 'error: blob not found';
  END IF;

  RETURN attotools._blob_encode_content(v_content, coalesce(p_encoding, 'UTF8'));
END;
$$;
COMMENT ON FUNCTION attotools._tool_read_blob(text, text) IS 'Read blob data by hash. The result is encoded using encoding: base64, hex, escape, or a PostgreSQL text encoding such as UTF8.';

CREATE OR REPLACE FUNCTION attotools._url_decode(p_text text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_text text := replace(coalesce(p_text, ''), '+', ' ');
  v_result text := '';
  v_index integer := 1;
  v_char text;
  v_hex text;
BEGIN
  WHILE v_index <= length(v_text) LOOP
    v_char := substr(v_text, v_index, 1);
    v_hex := substr(v_text, v_index + 1, 2);

    IF v_char = '%' AND v_hex ~ '^[0-9A-Fa-f]{2}$' THEN
      v_result := v_result || convert_from(decode(v_hex, 'hex'), 'UTF8');
      v_index := v_index + 3;
    ELSE
      v_result := v_result || v_char;
      v_index := v_index + 1;
    END IF;
  END LOOP;

  RETURN v_result;
EXCEPTION WHEN others THEN
  RETURN coalesce(p_text, '');
END;
$$;

CREATE OR REPLACE FUNCTION attotools._url_encode(p_text text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_text text := coalesce(p_text, '');
  v_result text := '';
  v_index integer := 1;
  v_char text;
  v_hex text;
  v_hex_index integer;
BEGIN
  WHILE v_index <= length(v_text) LOOP
    v_char := substr(v_text, v_index, 1);

    IF v_char ~ '^[A-Za-z0-9._~-]$' THEN
      v_result := v_result || v_char;
    ELSIF v_char = ' ' THEN
      v_result := v_result || '+';
    ELSE
      v_hex := encode(convert_to(v_char, 'UTF8'), 'hex');
      v_hex_index := 1;
      WHILE v_hex_index <= length(v_hex) LOOP
        v_result := v_result || '%' || upper(substr(v_hex, v_hex_index, 2));
        v_hex_index := v_hex_index + 2;
      END LOOP;
    END IF;

    v_index := v_index + 1;
  END LOOP;

  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION attotools._html_text(p_html text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_text text := coalesce(p_html, '');
BEGIN
  v_text := regexp_replace(v_text, '<[^>]+>', ' ', 'g');
  v_text := replace(v_text, '&amp;', '&');
  v_text := replace(v_text, '&lt;', '<');
  v_text := replace(v_text, '&gt;', '>');
  v_text := replace(v_text, '&quot;', '"');
  v_text := replace(v_text, '&#39;', '''');
  v_text := replace(v_text, '&apos;', '''');
  v_text := regexp_replace(v_text, '\s+', ' ', 'g');
  RETURN btrim(v_text);
END;
$$;

CREATE OR REPLACE FUNCTION attotools._http_url_allowed(p_url text)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_url text := btrim(coalesce(p_url, ''));
  v_host text;
BEGIN
  IF v_url !~* '^https?://' THEN
    RETURN false;
  END IF;

  v_host := lower(substring(v_url from '^[Hh][Tt][Tt][Pp][Ss]?://([^/@:?#]+|\[[^]]+\])'));
  IF v_host IS NULL OR v_host = '' THEN
    RETURN false;
  END IF;

  v_host := trim(both '[]' from v_host);

  IF v_host IN ('localhost', 'ip6-localhost', 'ip6-loopback')
     OR v_host LIKE '%.localhost'
     OR v_host ~ '(^|:)(::1|fc[0-9a-f]|fd[0-9a-f])'
     OR v_host ~ '^(0|10|127)\.'
     OR v_host ~ '^169\.254\.'
     OR v_host ~ '^192\.168\.'
     OR v_host ~ '^172\.(1[6-9]|2[0-9]|3[0-1])\.' THEN
    RETURN false;
  END IF;

  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION attotools._tool_sql(p_query text)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  v_query text;
  v_rows jsonb;
BEGIN
  v_query := btrim(coalesce(p_query, ''));
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
COMMENT ON FUNCTION attotools._tool_sql(text) IS 'Run one semicolon-free SQL query inside PostgreSQL. The query must return rows. For writes, use a data-modifying CTE with RETURNING.';

-- Build the result text of a WEBFETCH from its http response (no append).
CREATE OR REPLACE FUNCTION attotools._webfetch_result(
  p_args jsonb,
  p_http_response jsonb
)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  v_max_bytes integer;
  v_headers jsonb;
  v_body text;
BEGIN
  v_max_bytes := least(greatest(coalesce((p_args->>'max_bytes')::integer, 20000), 1000), 200000);
  v_headers := coalesce(p_http_response->'headers', '{}'::jsonb);
  v_body := left(coalesce(p_http_response->>'body', ''), v_max_bytes);

  RETURN jsonb_build_object(
    'url', p_args->>'url',
    'effective_url', p_args->>'url',
    'status', coalesce((p_http_response->>'status')::integer, 0),
    'content_type', coalesce(v_headers->>'content-type', v_headers->>'Content-Type', ''),
    'bytes_returned', length(v_body),
    'truncated', length(coalesce(p_http_response->>'body', '')) > length(v_body),
    'body', v_body
  )::text;
END;
$$;

-- Build the result text of a SEARCH from its Exa JSON http response (no append).
CREATE OR REPLACE FUNCTION attotools._search_result(
  p_args jsonb,
  p_http_response jsonb
)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  v_limit integer := least(greatest(coalesce((p_args->>'limit')::integer, 5), 1), 10);
  v_body jsonb;
  v_row jsonb;
  v_results jsonb := '[]'::jsonb;
BEGIN
  v_body := attobot._try_jsonb(coalesce(p_http_response->>'body', ''));

  -- Gracefully surface a non-JSON / unexpected Exa body instead of crashing the
  -- turn (e.g. bad key -> 401, or a stray HTML error page). _try_jsonb never
  -- returns NULL (it yields {} or {"_raw": ...}), so test the results array
  -- directly: IS DISTINCT FROM catches missing/null/non-array alike.
  IF jsonb_typeof(v_body->'results') IS DISTINCT FROM 'array' THEN
    RETURN jsonb_build_object(
      'query', p_args->>'query',
      'results', '[]'::jsonb,
      'result_count', 0,
      'status', coalesce((p_http_response->>'status')::integer, 0),
      'error', 'exa returned no parseable results'
    )::text;
  END IF;

  FOR v_row IN
    SELECT value FROM jsonb_array_elements(v_body->'results') LIMIT v_limit
  LOOP
    v_results := v_results || jsonb_build_array(jsonb_build_object(
      'title',   coalesce(v_row->>'title', ''),
      'url',     coalesce(v_row->>'url', ''),
      'snippet', left(coalesce(v_row->>'text', ''), 500)
    ));
  END LOOP;

  RETURN (jsonb_build_object(
    'query', p_args->>'query',
    'results', v_results,
    'result_count', jsonb_array_length(v_results)
  ) || jsonb_build_object('status', coalesce((p_http_response->>'status')::integer, 0)))::text;
END;
$$;

-- Build the SEARCH future (a df http graph) against the Exa search API. Returns
-- the graph text, or an error result text when the query is empty or the agent
-- has no exa_api_key. Introspected as the SEARCH tool schema.
CREATE OR REPLACE FUNCTION attotools._tool_search(
  p_query text,
  p_limit integer DEFAULT 5
)
RETURNS text
LANGUAGE plpgsql
SET search_path = attobot, attotools, public, pg_temp
AS $$
DECLARE
  v_limit integer := least(greatest(coalesce(p_limit, 5), 1), 10);
  v_agent_id bigint;
  v_key text;
  v_body text;
BEGIN
  IF btrim(coalesce(p_query, '')) = '' THEN
    RETURN format('SELECT %L::text AS result', 'error: SEARCH requires query');
  END IF;

  -- Agent context reaches the tool via GUC (there are no agent params: the
  -- signature is introspected as the LLM-facing schema). start_tool_calls binds
  -- it for this path; the agent role can SELECT its own secret config under RLS.
  v_agent_id := nullif(current_setting('attobot.current_agent_id', true), '')::bigint;
  v_key := attobot._config_text(v_agent_id, 'exa_api_key');
  IF v_key IS NULL OR v_key = '' THEN
    RETURN format('SELECT %L::text AS result', 'error: SEARCH requires exa_api_key config');
  END IF;

  v_body := jsonb_build_object(
    'query', p_query,
    'numResults', v_limit,
    'contents', jsonb_build_object('text', jsonb_build_object('maxCharacters', 500))
  )::text;

  RETURN format('SELECT %L::text AS body', v_body) |=> 'request'
    ~> df.http(
      'https://api.exa.ai/search', 'POST', '$request',
      jsonb_build_object('x-api-key', v_key, 'Content-Type', 'application/json'),
      30
    ) |=> 'http'
    ~> format(
      'SELECT attotools._search_result(%L::jsonb, $http::jsonb)::text AS result',
      jsonb_build_object('query', p_query, 'limit', v_limit)::text
    );
END;
$$;
COMMENT ON FUNCTION attotools._tool_search(text, integer) IS 'Search the public web and return a JSON list of result titles, URLs, and snippets.';

-- Build the WEBFETCH future (a df http graph). Returns the graph text, or an
-- error result text for non-public URLs. Introspected as the WEBFETCH tool schema.
CREATE OR REPLACE FUNCTION attotools._tool_webfetch(
  p_url text,
  p_max_bytes integer DEFAULT 20000
)
RETURNS text
LANGUAGE plpgsql
SET search_path = attobot, attotools, public, pg_temp
AS $$
BEGIN
  IF NOT attotools._http_url_allowed(p_url) THEN
    RETURN format('SELECT %L::text AS result', 'error: WEBFETCH requires a public http(s) URL');
  END IF;

  RETURN df.http(
    p_url, 'GET', '',
    jsonb_build_object(
      'User-Agent', 'attobot-webfetch/1.0',
      'Accept', 'text/html,application/xhtml+xml,application/xml,text/plain,*/*;q=0.8'
    ), 30
  ) |=> 'http'
    ~> format(
      'SELECT attotools._webfetch_result(%L::jsonb, $http::jsonb)::text AS result',
      jsonb_build_object('url', p_url, 'max_bytes', p_max_bytes)::text
    );
END;
$$;
COMMENT ON FUNCTION attotools._tool_webfetch(text, integer) IS 'Fetch an HTTP or HTTPS URL and return status, content type, effective URL, and a truncated text body.';

-- Run one synchronous tool's WORK under the acting role (SET ROLE + GUCs), then
-- RESET. SECURITY INVOKER — SET ROLE is forbidden inside SECURITY DEFINER. The
-- instance that calls this is submitted by attobot_service; we drop to the
-- acting role (the requesting user's tier, or the subconscious role) so RLS
-- binds for the tool's data access. Returns the result text; the orchestrator
-- appends the role='tool' message as service.
CREATE OR REPLACE FUNCTION attotools.run_tool_call_as_role(
  p_name text,
  p_args jsonb,
  p_acting_role text,
  p_agent_id bigint,
  p_agent_slug text,
  p_user_external_id text DEFAULT NULL,
  p_chat_id text DEFAULT NULL,
  p_user_id bigint DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = attobot, attotools, public, pg_temp
AS $$
DECLARE
  v_result text;
  v_err text;
BEGIN
  EXECUTE format('SET ROLE %I', p_acting_role);
  PERFORM set_config('attobot.current_agent_id', p_agent_id::text, true);
  PERFORM set_config('attobot.current_chat_id', coalesce(p_chat_id, ''), true);
  PERFORM set_config('attobot.current_user_id', coalesce(p_user_id::text, ''), true);
  BEGIN
    -- Agent context reaches the tool functions via GUCs (they no longer take an
    -- agent_id/agent_slug param, so every parameter is LLM-facing & introspectable).
    v_result := CASE p_name
      WHEN 'SQL' THEN attotools._tool_sql(coalesce(p_args->>'query', ''))
      WHEN 'SEND_ATTACHMENT' THEN attotools._tool_send_attachment(
            coalesce(p_args->>'hash', ''),
            coalesce(p_args->>'filename', ''),
            coalesce(p_args->>'caption', ''),
            coalesce(p_args->>'mime_type', ''))
      WHEN 'WRITE_BLOB' THEN attotools._tool_write_blob(
            coalesce(p_args->>'content', ''), coalesce(p_args->>'encoding', ''))
      WHEN 'READ_BLOB' THEN attotools._tool_read_blob(
            coalesce(p_args->>'hash', ''), coalesce(p_args->>'encoding', 'UTF8'))
      ELSE NULL
    END;
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
    EXECUTE 'RESET ROLE';
    v_result := 'error: ' || v_err;
  END;
  EXECUTE 'RESET ROLE';

  IF v_result IS NULL THEN
    v_result := 'error: unknown synchronous tool: ' || p_name;
  END IF;
  RETURN v_result;
END;
$$;

-- Build the df future for one tool call (the body of its tc instance).
-- SEARCH/WEBFETCH become an http graph; the rest run synchronously as the
-- acting role. Returns a df graph text.
CREATE OR REPLACE FUNCTION attotools.tool_call_future(
  p_name text,
  p_args jsonb,
  p_acting_role text,
  p_agent_id bigint,
  p_agent_slug text,
  p_user_external_id text DEFAULT NULL,
  p_chat_id text DEFAULT NULL,
  p_user_id bigint DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = attobot, attotools, public, pg_temp
AS $$
DECLARE
  v_limit text;
  v_max_bytes text;
BEGIN
  IF p_name = 'WEBFETCH' THEN
    -- Safe integer parse: a malformed max_bytes must not abort the whole turn.
    v_max_bytes := p_args->>'max_bytes';
    RETURN attotools._tool_webfetch(
      btrim(coalesce(p_args->>'url', '')),
      CASE WHEN v_max_bytes ~ '^[0-9]+$' THEN v_max_bytes::integer ELSE 20000 END
    );
  ELSIF p_name = 'SEARCH' THEN
    v_limit := p_args->>'limit';
    RETURN attotools._tool_search(
      coalesce(p_args->>'query', ''),
      CASE WHEN v_limit ~ '^[0-9]+$' THEN v_limit::integer ELSE 5 END
    );
  END IF;

  -- synchronous tools run as the acting role
  RETURN format(
    'SELECT attotools.run_tool_call_as_role(%L, %L::jsonb, %L, %s, %L, %L, %L, %s)::text AS result',
    p_name, p_args::text, p_acting_role, p_agent_id, p_agent_slug,
    coalesce(p_user_external_id, ''), coalesce(p_chat_id, ''),
    coalesce(p_user_id::text, 'NULL')
  );
END;
$$;

-- Orchestrator for an assistant message's tool calls, split across TWO graph
-- nodes so the per-call durable instances actually run:
--   start_tool_calls: df.start every call (parallel), return [{id,tc_id},...].
--     Its transaction commits when the node ends, so workers can SEE and run the
--     instances. (Starting and awaiting in the SAME node left the starts
--     uncommitted in that node's transaction, so no worker picked them up and
--     every call timed out as "Instance not found".)
--   await_tool_calls: poll df.status per call (cancel on timeout) and append each
--     result as role='tool'. Runs in the NEXT node, by which point the starts are
--     committed and the tool instances are executing on other workers.
CREATE OR REPLACE FUNCTION attotools.start_tool_calls(
  p_agent_slug text,
  p_message_id bigint,
  p_tool_calls jsonb,
  p_acting_role text,
  p_user_external_id text DEFAULT NULL,
  p_chat_id text DEFAULT NULL,
  p_user_id bigint DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = attobot, attotools, public, pg_temp
AS $$
DECLARE
  v_agent_id bigint := attobot.agent_id(p_agent_slug);
  v_call jsonb;
  v_tool_call_id text;
  v_name text;
  v_args jsonb;
  v_future text;
  v_tc text;
  v_started jsonb := '[]'::jsonb;
BEGIN
  -- Bind agent context so the SEARCH graph builder (_tool_search) can read the
  -- agent's own secret config (exa_api_key) under RLS. The synchronous tools
  -- bind it again inside run_tool_call_as_role; setting it here is harmless.
  PERFORM set_config('attobot.current_agent_id', v_agent_id::text, true);

  IF p_acting_role IS NULL OR p_acting_role = '' THEN
    p_acting_role := 'attobot_agent_primary';
  END IF;

  -- start every tool call as its own instance (all started before any awaiting)
  FOR v_call IN SELECT value FROM jsonb_array_elements(coalesce(p_tool_calls, '[]'::jsonb))
  LOOP
    v_tool_call_id := coalesce(v_call->>'id', 'call_' || md5(v_call::text));
    v_name := v_call #>> '{function,name}';
    v_args := attobot._try_jsonb(v_call #>> '{function,arguments}');
    v_future := attotools.tool_call_future(
      v_name, v_args, p_acting_role, v_agent_id, p_agent_slug,
      p_user_external_id, p_chat_id, p_user_id
    );
    SELECT df.start(v_future, format('attobot:tool:%s:%s', p_message_id, v_tool_call_id)) INTO v_tc;
    v_started := v_started || jsonb_build_array(
      jsonb_build_object('id', v_tc, 'tc_id', v_tool_call_id)
    );
  END LOOP;

  RETURN v_started::text;
END;
$$;

CREATE OR REPLACE FUNCTION attotools.await_tool_calls(
  p_agent_slug text,
  p_started text,
  p_timeout integer DEFAULT 120
)
RETURNS text
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = attobot, attotools, public, pg_temp
AS $$
DECLARE
  v_agent_id bigint := attobot.agent_id(p_agent_slug);
  v_item jsonb;
  v_id text;
  v_tcid text;
  v_status text;
  v_result text;
  v_deadline timestamptz;
  v_count integer := 0;
BEGIN
  FOR v_item IN SELECT value FROM jsonb_array_elements(
    coalesce(attobot._try_jsonb(p_started), '[]'::jsonb)
  )
  LOOP
    v_count := v_count + 1;
    v_id := v_item->>'id';
    v_tcid := v_item->>'tc_id';
    v_deadline := clock_timestamp() + make_interval(secs => p_timeout);
    v_status := NULL;
    LOOP
      BEGIN
        SELECT df.status(v_id) INTO v_status;
      EXCEPTION WHEN OTHERS THEN
        v_status := 'error';
      END;
      EXIT WHEN v_status IN ('completed', 'failed', 'cancelled', 'error');
      IF clock_timestamp() >= v_deadline THEN
        BEGIN
          PERFORM df.cancel(v_id, 'tool call timeout');
        EXCEPTION WHEN OTHERS THEN
          NULL;
        END;
        v_status := 'cancelled';
        EXIT;
      END IF;
      PERFORM pg_sleep(0.5);
    END LOOP;

    BEGIN
      SELECT df.result(v_id) INTO v_result;
      v_result := coalesce((attobot._try_jsonb(v_result)->>'result'), v_result);
    EXCEPTION WHEN OTHERS THEN
      v_result := 'error: ' || SQLERRM;
    END;
    IF v_status <> 'completed' THEN
      v_result := coalesce(v_result, 'error: tool ' || v_status);
    END IF;

    PERFORM attotools._append_tool_message(v_agent_id, v_tcid, v_result);
  END LOOP;

  RETURN jsonb_build_object('tool_calls', v_count)::text;
END;
$$;
