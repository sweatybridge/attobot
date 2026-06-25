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

CREATE OR REPLACE FUNCTION attotools._search_result_url(p_href text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_href text := coalesce(p_href, '');
  v_uddg text;
  v_bing_u text;
  v_b64 text;
BEGIN
  v_href := replace(v_href, '&amp;', '&');
  v_uddg := substring(v_href from '[?&]uddg=([^&]+)');
  IF v_uddg IS NOT NULL THEN
    RETURN attotools._url_decode(v_uddg);
  END IF;

  v_bing_u := substring(v_href from '[?&]u=([^&]+)');
  IF v_bing_u IS NOT NULL AND v_bing_u LIKE 'a1%' THEN
    v_b64 := replace(replace(substr(v_bing_u, 3), '-', '+'), '_', '/');
    WHILE length(v_b64) % 4 <> 0 LOOP
      v_b64 := v_b64 || '=';
    END LOOP;
    RETURN convert_from(decode(v_b64, 'base64'), 'UTF8');
  END IF;

  IF v_href LIKE '//%' THEN
    RETURN 'https:' || v_href;
  END IF;
  RETURN v_href;
EXCEPTION WHEN others THEN
  RETURN v_href;
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

CREATE OR REPLACE FUNCTION attotools._search_results_from_html(
  p_query text,
  p_limit integer,
  p_html text
)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_limit integer := least(greatest(coalesce(p_limit, 5), 1), 10);
  v_results jsonb := '[]'::jsonb;
  v_count integer := 0;
  v_block text;
  v_h2 text;
  v_caption text;
  v_url text;
  v_title text;
  v_snippet text;
BEGIN
  FOR v_block IN
    SELECT block
    FROM unnest(regexp_split_to_array(coalesce(p_html, ''), '<li class="b_algo"')) WITH ORDINALITY AS t(block, ord)
    WHERE ord > 1
  LOOP
    v_h2 := substring(v_block from '<h2[^>]*>.*</h2>');
    IF v_h2 IS NULL THEN
      CONTINUE;
    END IF;

    v_url := attotools._search_result_url(substring(v_h2 from 'href="([^"]+)"'));
    v_title := attotools._html_text(v_h2);
    v_caption := substring(v_block from '<div class="b_caption"><p[^>]*>.*</p>');
    v_snippet := attotools._html_text(coalesce(v_caption, ''));

    IF v_url = '' OR v_title = '' THEN
      CONTINUE;
    END IF;

    v_results := v_results || jsonb_build_array(jsonb_build_object(
      'title', v_title, 'url', v_url, 'snippet', v_snippet
    ));

    v_count := v_count + 1;
    EXIT WHEN v_count >= v_limit;
  END LOOP;

  RETURN jsonb_build_object(
    'query', p_query,
    'results', v_results,
    'result_count', jsonb_array_length(v_results)
  );
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

-- Build the result text of a SEARCH from its http response (no append).
CREATE OR REPLACE FUNCTION attotools._search_result(
  p_args jsonb,
  p_http_response jsonb
)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  v_limit integer;
BEGIN
  v_limit := least(greatest(coalesce((p_args->>'limit')::integer, 5), 1), 10);
  RETURN (attotools._search_results_from_html(
    p_args->>'query', v_limit, coalesce(p_http_response->>'body', '')
  ) || jsonb_build_object('status', coalesce((p_http_response->>'status')::integer, 0)))::text;
END;
$$;

-- Build the SEARCH future (a df http graph). Returns the graph text, or an error
-- result text when the query is empty. Introspected as the SEARCH tool schema.
CREATE OR REPLACE FUNCTION attotools._tool_search(
  p_query text,
  p_limit integer DEFAULT 5
)
RETURNS text
LANGUAGE plpgsql
SET search_path = attobot, attotools, public, pg_temp
AS $$
DECLARE
  v_url text;
  v_limit integer := least(greatest(coalesce(p_limit, 5), 1), 10);
BEGIN
  IF btrim(coalesce(p_query, '')) = '' THEN
    RETURN format('SELECT %L::text AS result', 'error: SEARCH requires query');
  END IF;

  v_url := 'https://www.bing.com/search?q=' || attotools._url_encode(p_query);
  RETURN df.http(
    v_url, 'GET', '',
    jsonb_build_object(
      'User-Agent', 'Mozilla/5.0 (compatible; attobot-search/1.0)',
      'Accept', 'text/html,application/xhtml+xml,application/xml,text/plain,*/*;q=0.8'
    ), 30
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

-- Orchestrator: run all tool calls for an assistant message as per-call durable
-- instances, in parallel (start all before awaiting), with timeout + cancel,
-- then append each result as role='tool' (as service). Runs as attobot_service
-- inside the agent-loop instance. Returns a summary.
CREATE OR REPLACE FUNCTION attotools.run_tool_calls(
  p_agent_slug text,
  p_message_id bigint,
  p_tool_calls jsonb,
  p_acting_role text,
  p_user_external_id text DEFAULT NULL,
  p_chat_id text DEFAULT NULL,
  p_user_id bigint DEFAULT NULL,
  p_timeout integer DEFAULT 120
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
  v_ids text[] := '{}';
  v_callids text[] := '{}';
  v_status text;
  v_result text;
  v_deadline timestamptz;
  v_i integer;
BEGIN
  IF p_acting_role IS NULL OR p_acting_role = '' THEN
    p_acting_role := 'attobot_agent_primary';
  END IF;

  -- 1. start every tool call as its own instance (parallel: all started first)
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
    v_ids := array_append(v_ids, v_tc);
    v_callids := array_append(v_callids, v_tool_call_id);
  END LOOP;

  -- 2. await each (poll df.status, cancel on timeout), 3. append result as service
  FOR v_i IN 1..coalesce(array_length(v_ids, 1), 0)
  LOOP
    v_deadline := clock_timestamp() + make_interval(secs => p_timeout);
    v_status := NULL;
    LOOP
      BEGIN
        SELECT df.status(v_ids[v_i]) INTO v_status;
      EXCEPTION WHEN OTHERS THEN
        v_status := 'error';
      END;
      EXIT WHEN v_status IN ('completed', 'failed', 'cancelled', 'error');
      IF clock_timestamp() >= v_deadline THEN
        BEGIN
          PERFORM df.cancel(v_ids[v_i], 'tool call timeout');
        EXCEPTION WHEN OTHERS THEN
          NULL;
        END;
        v_status := 'cancelled';
        EXIT;
      END IF;
      PERFORM pg_sleep(0.5);
    END LOOP;

    BEGIN
      SELECT df.result(v_ids[v_i]) INTO v_result;
      v_result := coalesce((attobot._try_jsonb(v_result)->>'result'), v_result);
    EXCEPTION WHEN OTHERS THEN
      v_result := 'error: ' || SQLERRM;
    END;
    IF v_status <> 'completed' THEN
      v_result := coalesce(v_result, 'error: tool ' || v_status);
    END IF;

    PERFORM attotools._append_tool_message(v_agent_id, v_callids[v_i], v_result);
  END LOOP;

  RETURN jsonb_build_object('tool_calls', array_length(v_ids, 1))::text;
END;
$$;
