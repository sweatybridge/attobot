CREATE OR REPLACE FUNCTION attotools.tool_signal_name(
  p_agent_slug text,
  p_turn_id bigint
)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT format('attobot:%s:turn:%s:tools', p_agent_slug, p_turn_id);
$$;

CREATE OR REPLACE FUNCTION attotools._append_tool_message(
  p_agent_id bigint,
  p_tool_call_id text,
  p_result text
)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  INSERT INTO attobot.messages(agent_id, role, content, tool_call_id)
  VALUES (p_agent_id, 'tool', coalesce(p_result, ''), p_tool_call_id)
  ON CONFLICT (agent_id, tool_call_id)
    WHERE role = 'tool' AND tool_call_id IS NOT NULL
    DO NOTHING;
END;
$$;

CREATE OR REPLACE FUNCTION attotools._tool_send_attachment(
  p_agent_id bigint,
  p_args jsonb
)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  v_hash text := btrim(coalesce(p_args->>'hash', ''));
  v_outbox_id bigint;
BEGIN
  IF v_hash = '' THEN
    RAISE EXCEPTION 'SEND_ATTACHMENT requires hash';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM attotools.blobs
    WHERE agent_id = p_agent_id
      AND hash = v_hash
  ) THEN
    RAISE EXCEPTION 'blob not found: %', v_hash;
  END IF;

  INSERT INTO attobot.outbox(agent_id, channel, body)
  VALUES (
    p_agent_id,
    'telegram_attachment',
    jsonb_strip_nulls(jsonb_build_object(
      'blob_hash', v_hash,
      'filename', nullif(p_args->>'filename', ''),
      'caption', nullif(p_args->>'caption', ''),
      'mime_type', nullif(p_args->>'mime_type', '')
    ))
  )
  RETURNING id INTO v_outbox_id;

  RETURN jsonb_build_object(
    'queued', true,
    'outbox_id', v_outbox_id,
    'blob_hash', v_hash
  )::text;
END;
$$;

CREATE OR REPLACE FUNCTION attotools._tool_append_message(
  p_args jsonb,
  p_agent_slug text
)
RETURNS text
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM attobot.append_message(
    coalesce(p_args->>'agent', p_agent_slug),
    coalesce(p_args->>'role', 'system'),
    coalesce(p_args->>'content', '')
  );
  RETURN 'appended';
END;
$$;

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
  p_agent_id bigint,
  p_args jsonb
)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  v_bytes bytea;
  v_hash text;
BEGIN
  v_bytes := attotools._blob_decode_content(
    p_args->>'content',
    p_args->>'encoding'
  );
  v_hash := left(md5(v_bytes), 12);

  INSERT INTO attotools.blobs(agent_id, hash, content)
  VALUES (p_agent_id, v_hash, v_bytes)
  ON CONFLICT (agent_id, hash) DO NOTHING;

  RETURN jsonb_build_object(
    'hash', v_hash,
    'bytes', length(v_bytes),
    'marker', '[blob ' || v_hash || ']'
  )::text;
END;
$$;

CREATE OR REPLACE FUNCTION attotools._tool_read_blob(
  p_agent_id bigint,
  p_args jsonb
)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  v_content bytea;
BEGIN
  SELECT content INTO v_content
  FROM attotools.blobs
  WHERE agent_id = p_agent_id
    AND hash = p_args->>'hash';

  IF v_content IS NULL THEN
    RETURN 'error: blob not found';
  END IF;

  RETURN attotools._blob_encode_content(
    v_content,
    coalesce(p_args->>'encoding', 'UTF8')
  );
END;
$$;

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
      'title', v_title,
      'url', v_url,
      'snippet', v_snippet
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

CREATE OR REPLACE FUNCTION attotools._tool_sql(p_args jsonb)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  v_query text;
  v_rows jsonb;
BEGIN
  v_query := btrim(coalesce(p_args->>'query', ''));
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

CREATE OR REPLACE FUNCTION attotools._execute_sync_tool_call(
  p_agent_slug text,
  p_message_id bigint,
  p_tool_call_id text,
  p_name text,
  p_args jsonb
)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  v_agent_id bigint := attobot.agent_id(p_agent_slug);
  v_result text;
BEGIN
  v_result := CASE p_name
    WHEN 'SEARCH' THEN coalesce(p_args->>'error', 'error: SEARCH requires query')
    WHEN 'WEBFETCH' THEN coalesce(p_args->>'error', 'error: WEBFETCH requires a public http(s) URL')
    WHEN 'SEND_ATTACHMENT' THEN attotools._tool_send_attachment(v_agent_id, p_args)
    WHEN 'APPEND_MESSAGE' THEN attotools._tool_append_message(p_args, p_agent_slug)
    WHEN 'WRITE_BLOB' THEN attotools._tool_write_blob(v_agent_id, p_args)
    WHEN 'READ_BLOB' THEN attotools._tool_read_blob(v_agent_id, p_args)
    WHEN 'SQL' THEN attotools._tool_sql(p_args)
    ELSE NULL
  END;

  IF v_result IS NULL THEN
    RAISE EXCEPTION 'unknown synchronous tool: %', p_name;
  END IF;

  PERFORM attotools._append_tool_message(v_agent_id, p_tool_call_id, v_result);
  RETURN v_result;

EXCEPTION WHEN others THEN
  v_result := 'error: ' || SQLERRM;
  PERFORM attotools._append_tool_message(v_agent_id, p_tool_call_id, v_result);
  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION attotools._complete_webfetch_tool_from_http(
  p_agent_slug text,
  p_message_id bigint,
  p_tool_call_id text,
  p_args jsonb,
  p_http_response jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v_agent_id bigint := attobot.agent_id(p_agent_slug);
  v_max_bytes integer;
  v_headers jsonb;
  v_body text;
  v_result jsonb;
BEGIN
  v_max_bytes := least(greatest(coalesce((p_args->>'max_bytes')::integer, 20000), 1000), 200000);
  v_headers := coalesce(p_http_response->'headers', '{}'::jsonb);
  v_body := left(coalesce(p_http_response->>'body', ''), v_max_bytes);

  v_result := jsonb_build_object(
    'url', p_args->>'url',
    'effective_url', p_args->>'url',
    'status', coalesce((p_http_response->>'status')::integer, 0),
    'content_type', coalesce(v_headers->>'content-type', v_headers->>'Content-Type', ''),
    'bytes_returned', length(v_body),
    'truncated', length(coalesce(p_http_response->>'body', '')) > length(v_body),
    'body', v_body
  );

  PERFORM attotools._append_tool_message(v_agent_id, p_tool_call_id, v_result::text);
  RETURN jsonb_build_object('completed', true, 'tool_call_id', p_tool_call_id);
END;
$$;

CREATE OR REPLACE FUNCTION attotools._complete_search_tool_from_http(
  p_agent_slug text,
  p_message_id bigint,
  p_tool_call_id text,
  p_args jsonb,
  p_http_response jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v_agent_id bigint := attobot.agent_id(p_agent_slug);
  v_limit integer;
  v_result jsonb;
BEGIN
  v_limit := least(greatest(coalesce((p_args->>'limit')::integer, 5), 1), 10);
  v_result := attotools._search_results_from_html(
    p_args->>'query',
    v_limit,
    coalesce(p_http_response->>'body', '')
  ) || jsonb_build_object(
    'status', coalesce((p_http_response->>'status')::integer, 0)
  );

  PERFORM attotools._append_tool_message(v_agent_id, p_tool_call_id, v_result::text);
  RETURN jsonb_build_object('completed', true, 'tool_call_id', p_tool_call_id);
END;
$$;

CREATE OR REPLACE FUNCTION attotools._turn_durable_instance_id(p_turn_id bigint)
RETURNS text
LANGUAGE sql
STABLE
AS $$
  SELECT detail->>'durable_instance_id'
  FROM attobot.lifecycle
  WHERE event = 'turn.instance'
    AND (detail->>'turn_id')::bigint = p_turn_id
  ORDER BY id DESC
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION attotools._wait_until_turn_signal_ready(
  p_turn_id bigint,
  p_signal_name text,
  p_timeout_seconds integer DEFAULT 30
)
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
  v_instance_id text;
  v_deadline timestamptz := clock_timestamp() + make_interval(secs => p_timeout_seconds);
BEGIN
  LOOP
    v_instance_id := attotools._turn_durable_instance_id(p_turn_id);

    IF v_instance_id IS NOT NULL AND EXISTS (
      SELECT 1
      FROM df.instance_nodes(v_instance_id, 1)
      WHERE node_type = 'SIGNAL'
        AND status = 'running'
        AND query::text LIKE '%' || p_signal_name || '%'
    ) THEN
      RETURN true;
    END IF;

    IF clock_timestamp() >= v_deadline THEN
      RETURN false;
    END IF;

    PERFORM pg_sleep(0.25);
  END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION attotools._signal_turn_tools(
  p_turn_id bigint,
  p_signal_name text,
  p_message_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v_instance_id text;
  v_tool_count integer;
  v_signal_result text;
BEGIN
  v_instance_id := attotools._turn_durable_instance_id(p_turn_id);

  IF v_instance_id IS NULL THEN
    RAISE EXCEPTION 'turn % has no durable_instance_id', p_turn_id;
  END IF;

  SELECT count(*)
  INTO v_tool_count
  FROM attobot.messages a
  CROSS JOIN LATERAL jsonb_array_elements(coalesce(a.payload->'tool_calls', '[]'::jsonb)) AS call(value)
  JOIN attobot.messages t
    ON t.agent_id = a.agent_id
   AND t.role = 'tool'
   AND t.tool_call_id = call.value->>'id'
  WHERE a.id = p_message_id;

  v_signal_result := df.signal(
    v_instance_id,
    p_signal_name,
    jsonb_build_object(
      'message_id', p_message_id,
      'tool_results', v_tool_count
    )::text
  );

  UPDATE attobot.messages
  SET payload = payload || jsonb_build_object(
    'tool_signal_sent_at', now(),
    'tool_signal_result', v_signal_result
  )
  WHERE id = p_message_id;

  RETURN jsonb_build_object(
    'signaled', true,
    'signal_result', v_signal_result,
    'tool_results', v_tool_count
  );
END;
$$;

CREATE OR REPLACE FUNCTION attotools.compose_tool_signal_future(
  p_agent_slug text,
  p_message_id bigint,
  p_turn_id bigint
)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  v_message attobot.messages%ROWTYPE;
  v_signal_name text := attotools.tool_signal_name(p_agent_slug, p_turn_id);
  v_future text;
  v_step text;
  v_call jsonb;
  v_args jsonb;
  v_name text;
  v_tool_call_id text;
  v_index integer := 0;
  v_alias text;
  v_url text;
BEGIN
  SELECT *
  INTO v_message
  FROM attobot.messages
  WHERE id = p_message_id
    AND agent_id = attobot.agent_id(p_agent_slug)
    AND role = 'assistant';

  IF v_message.id IS NULL THEN
    RAISE EXCEPTION 'assistant message not found: %', p_message_id;
  END IF;

  v_future := format(
    'SELECT attotools._wait_until_turn_signal_ready(%s, %L, 30) AS signal_ready',
    p_turn_id,
    v_signal_name
  );

  FOR v_call IN SELECT value FROM jsonb_array_elements(coalesce(v_message.payload->'tool_calls', '[]'::jsonb))
  LOOP
    v_index := v_index + 1;
    v_tool_call_id := v_call->>'id';
    v_name := v_call #>> '{function,name}';
    v_args := attobot._try_jsonb(v_call #>> '{function,arguments}');

    IF v_name = 'WEBFETCH' THEN
      v_url := btrim(coalesce(v_args->>'url', ''));
      IF attotools._http_url_allowed(v_url) THEN
        v_alias := format('http_%s', v_index);
        v_step :=
          df.http(
            v_url,
            'GET',
            '',
            jsonb_build_object(
              'User-Agent', 'attobot-webfetch/1.0',
              'Accept', 'text/html,application/xhtml+xml,application/xml,text/plain,*/*;q=0.8'
            ),
            30
          ) |=> v_alias
          ~> format(
            'SELECT attotools._complete_webfetch_tool_from_http(%L, %s, %L, %L::jsonb, $%s::jsonb)::jsonb AS tool_%s',
            p_agent_slug,
            p_message_id,
            v_tool_call_id,
            v_args::text,
            v_alias,
            v_index
          );
      ELSE
        v_step := format(
          'SELECT attotools._execute_sync_tool_call(%L, %s, %L, %L, %L::jsonb)::text AS tool_%s',
          p_agent_slug,
          p_message_id,
          v_tool_call_id,
          'WEBFETCH',
          jsonb_build_object('error', 'WEBFETCH requires a public http(s) URL')::text,
          v_index
        );
      END IF;
    ELSIF v_name = 'SEARCH' THEN
      IF btrim(coalesce(v_args->>'query', '')) = '' THEN
        v_step := format(
          'SELECT attotools._execute_sync_tool_call(%L, %s, %L, %L, %L::jsonb)::text AS tool_%s',
          p_agent_slug,
          p_message_id,
          v_tool_call_id,
          'SEARCH',
          jsonb_build_object('error', 'SEARCH requires query')::text,
          v_index
        );
      ELSE
        v_alias := format('http_%s', v_index);
        v_url := 'https://www.bing.com/search?q=' || attotools._url_encode(v_args->>'query');
        v_step :=
          df.http(
            v_url,
            'GET',
            '',
            jsonb_build_object(
              'User-Agent', 'Mozilla/5.0 (compatible; attobot-search/1.0)',
              'Accept', 'text/html,application/xhtml+xml,application/xml,text/plain,*/*;q=0.8'
            ),
            30
          ) |=> v_alias
          ~> format(
            'SELECT attotools._complete_search_tool_from_http(%L, %s, %L, %L::jsonb, $%s::jsonb)::jsonb AS tool_%s',
            p_agent_slug,
            p_message_id,
            v_tool_call_id,
            v_args::text,
            v_alias,
            v_index
          );
      END IF;
    ELSE
      v_step := format(
        'SELECT attotools._execute_sync_tool_call(%L, %s, %L, %L, %L::jsonb)::text AS tool_%s',
        p_agent_slug,
        p_message_id,
        v_tool_call_id,
        v_name,
        v_args::text,
        v_index
      );
    END IF;

    v_future := v_future ~> v_step;
  END LOOP;

  v_future := v_future ~> format(
    'SELECT attotools._signal_turn_tools(%s, %L, %s)::jsonb AS signal',
    p_turn_id,
    v_signal_name,
    p_message_id
  );

  RETURN v_future;
END;
$$;

CREATE OR REPLACE FUNCTION attotools.start_tool_signal_executor(
  p_agent_slug text,
  p_message_id bigint,
  p_turn_id bigint
)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  v_instance text;
BEGIN
  SELECT df.start(
    attotools.compose_tool_signal_future(p_agent_slug, p_message_id, p_turn_id),
    format('attobot:%s:tools:%s:%s', p_agent_slug, p_message_id, txid_current())
  )
  INTO v_instance;

  UPDATE attobot.messages
  SET payload = payload || jsonb_build_object('tool_executor_instance_id', v_instance)
  WHERE id = p_message_id;

  RETURN v_instance;
END;
$$;

CREATE OR REPLACE FUNCTION attotools.record_tool_signal(
  p_agent_slug text,
  p_turn_id bigint,
  p_signal jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v_agent_id bigint := attobot.agent_id(p_agent_slug);
  v_message attobot.messages%ROWTYPE;
  v_reason text := format('tool signal timed out for turn %s', p_turn_id);
  v_call jsonb;
  v_timed_out boolean := coalesce((p_signal->>'timed_out')::boolean, false);
  v_timeout_tool_results integer := 0;
  v_executor_instance_id text;
  v_executor_cancel_result text;
BEGIN
  IF v_timed_out THEN
    SELECT *
    INTO v_message
    FROM attobot.messages
    WHERE agent_id = v_agent_id
      AND role = 'assistant'
      AND (payload->>'turn_id')::bigint = p_turn_id
    ORDER BY id DESC
    LIMIT 1;

    v_executor_instance_id := nullif(v_message.payload->>'tool_executor_instance_id', '');

    IF v_executor_instance_id IS NOT NULL THEN
      BEGIN
        v_executor_cancel_result := df.cancel(v_executor_instance_id, v_reason);
      EXCEPTION WHEN OTHERS THEN
        v_executor_cancel_result := format('error: %s', SQLERRM);
      END;
    END IF;

    FOR v_call IN SELECT value FROM jsonb_array_elements(coalesce(v_message.payload->'tool_calls', '[]'::jsonb))
    LOOP
      PERFORM attotools._append_tool_message(v_agent_id, v_call->>'id', 'error: timed out waiting for tool signal');
      v_timeout_tool_results := v_timeout_tool_results + 1;
    END LOOP;
  END IF;

  PERFORM attobot.log_event(
    v_agent_id,
    'tool.signal',
    jsonb_build_object(
      'turn_id', p_turn_id,
      'signal', p_signal,
      'tool_executor_instance_id', v_executor_instance_id,
      'tool_executor_cancel_result', v_executor_cancel_result,
      'timeout_tool_results', v_timeout_tool_results
    )
  );

  RETURN jsonb_build_object(
    'turn_id', p_turn_id,
    'timed_out', v_timed_out,
    'data', p_signal->'data',
    'tool_executor_cancel_result', v_executor_cancel_result,
    'timeout_tool_results', v_timeout_tool_results
  );
END;
$$;
