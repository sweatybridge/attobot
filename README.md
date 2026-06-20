# attobot

attobot is now a Postgres-resident agent harness. Agent state, turns, tool
calls, and outbound messages live in PostgreSQL tables under the `attobot`
schema; tool-owned blob storage lives under `attotools`. Agents point at shared
rows in `attobot.models`, so multiple agents can reuse the same model
configuration. `pg_durable` owns the durable workflow execution, so a turn can
survive database restarts and resume from its last checkpoint.

The old filesystem loop is gone. `agent.py` is only a thin client for inserting
messages and inspecting database state.

## Architecture

```
operator/client
  -> attobot.append_message(..., 'user', ...)
  -> attobot.start_turn(...)
  -> pg_durable workflow
       -> attobot.compose_llm_request(...)
       -> df.http(... /chat/completions ...)
       -> attobot.record_assistant_from_http(...)
       -> attotools.start_tool_signal_executor(...)
       -> df.wait_for_signal(... tool results ...)
       -> attobot.start_turn(...) after successful tool results
  -> attobot.outbox
```

The durable turn workflow is SQL:

- `df.http` calls an OpenAI-compatible `/chat/completions` endpoint.
- Assistant messages are stored in `attobot.messages`.
- Tool calls are stored on assistant message payloads.
- Database-native tools run in child durable workflows that signal the parent
  turn with `df.wait_for_signal`.
- Tool signal timeouts write timeout tool messages and cancel stale tool
  executor work as cleanup.
- Assistant replies with no tool calls are queued in `attobot.outbox`.
- The `SEND_ATTACHMENT` tool queues stored blobs as Telegram document attachments.
- Optional Telegram loops use `df.http` to poll `getUpdates` into
  `attobot.messages` and deliver `attobot.outbox` rows with `sendMessage` or
  `sendDocument`.

## Run

Build the Postgres 18 image with `pg_durable` installed from the
`sweatybridge/pg_durable` GitHub release Debian package:

```bash
docker compose build
docker compose up -d
```

Fresh containers initialize the database schema in the Docker entrypoint. After
Postgres passes its healthcheck, the one-shot `agent-init` service runs `psql`
against the `harness` service and loads the mounted `agents.sql` seed file. That
job creates the `primary` and `subconscious` agents. Set `ATTOBOT_API_KEY`
before first boot, or rerun `agent-init` later, to seed both agents with an LLM
key. Secrets are stored in agent-scoped `attobot.config` rows:

```bash
ATTOBOT_API_KEY=sk-... docker compose up -d
```

You can also override the shared model with `ATTOBOT_MODEL`,
`ATTOBOT_API_BASE`, `ATTOBOT_TEMPERATURE`, `ATTOBOT_REASONING_EFFORT`,
`ATTOBOT_CONTEXT_TOKENS`, and `ATTOBOT_MULTIMODAL_SUPPORT`. Compose passes
these values to `psql` as variables for the seed SQL. The `agent-init` job
configures the model before creating agents, then assigns both seeded agents to
the configured model row.

To create a new agent, configure a model first and pass its id:

```bash
docker compose exec harness psql -U postgres -d postgres
```

```sql
WITH model AS (
  SELECT attobot.ensure_model(
    p_model => 'deepseek-v4-pro',
    p_api_base => 'https://api.deepseek.com/v1',
    p_temperature => 1.0,
    p_reasoning_effort => 'medium',
    p_context_tokens => 1000000,
    p_multimodal_support => false
  ) AS id
)
SELECT attobot.ensure_agent(
  p_slug => 'primary',
  p_soul => $$
You are a persistent agent running inside PostgreSQL.
Be direct. Use tools when you need to act on stored state.
Reply directly when no tool action is needed.
$$,
  p_api_key => 'sk-...',
  p_model_id => (SELECT id FROM model)
);
```

To update only a secret:

```sql
SELECT attobot.set_config('primary', 'api_key', to_jsonb('sk-...'::text));
```

The `subconscious` agent is also seeded with a `primary-review` durable schedule
that wakes it every 10 minutes.

To run the agent seed job again after changing environment values:

```bash
docker compose run --rm agent-init
```

Send a message:

```bash
python agent.py send "Introduce yourself"
```

Read queued outbound messages:

```bash
python agent.py outbox
```

The default DSN is `postgresql://postgres:postgres@127.0.0.1:5432/postgres`.
Override it with `--dsn` or `ATTOBOT_DSN`.

## Telegram

For a clean database, configure and start the primary agent's durable Telegram
inbox loop from the `agent-init` job:

```bash
ATTOBOT_TELEGRAM_TOKEN=123:abc \
ATTOBOT_TELEGRAM_CHAT_ID=-1001234567 \
docker compose up -d
```

For a forum topic, also set `ATTOBOT_TELEGRAM_THREAD_ID=42`. Override the
poll timeout with `ATTOBOT_TELEGRAM_POLL_TIMEOUT`; the default is `60` seconds.
If you add or change Telegram settings after the stack is already running,
rerun `docker compose run --rm agent-init` so the seed SQL updates the stored
configuration and ensures the inbox loop exists.

To update stored Telegram settings later, use `python agent.py telegram-config`.
It stores the token and chat metadata as agent-scoped `attobot.config` rows.

The inbox loop calls Telegram `getUpdates` through `pg_durable` and appends
accepted messages as `[telegram <update_id>] ...` user messages. It accepts only
the configured chat, and the configured topic when `telegram_thread_id` is set.

When Telegram is configured, pending `chat`, `telegram`, or
`telegram_attachment` rows inserted into
`attobot.outbox` automatically fire a PostgreSQL trigger that starts a one-shot
durable Telegram send workflow for that row.

Attachment delivery exports the blob to a temporary file inside the Postgres
container, then uploads it with Telegram `sendDocument` using `curl`.

## Durable Loops

Start a durable schedule that appends a system message and starts a turn:

```sql
SELECT attobot.ensure_scheduled_message_loop(
  p_agent_slug => 'primary',
  p_name => 'heartbeat',
  p_cron => '*/5 * * * *',
  p_message => 'tick'
);
```

## Tables

- `attobot.agents`: one row per agent.
- `attobot.models`: reusable model, endpoint, temperature, reasoning, context, and modality configuration.
- `attobot.config`: per-agent configuration and secrets.
- `attobot.messages`: canonical conversation stream.
- `attobot.memory`: agent-scoped durable memories forwarded to the LLM; each
  row stores `source_message_ids` for the messages it was constructed from.
- `attobot.outbox`: outbound messages for chat relays or clients.
- `attotools.blobs`: content-addressed large content storage as external `bytea`.
- `attobot.lifecycle`: append-only operational events, including turn start,
  durable instance, completion, and tool-signal records.

## Built-In Tools

The LLM sees these database-native tools:

- `SEARCH`: search the public web and return result titles, URLs, and snippets.
- `WEBFETCH`: fetch a public HTTP(S) URL and return status, content type, effective URL, and a truncated text body.
- `SQL`: run a single SQL query that returns rows.
- `SEND_ATTACHMENT`: send a stored blob as a Telegram document attachment.
- `APPEND_MESSAGE`: append a message to an agent stream.
- `WRITE_BLOB`: write large or binary content into `attotools.blobs` using an explicit encoding.
- `READ_BLOB`: read blob content by hash as `UTF8` text, `base64`, `hex`, `escape`, or another PostgreSQL text encoding.

Tool calls are not queued in a separate request table. The parent turn stores
tool calls on the assistant message, starts a child durable tool workflow, and
waits on `df.wait_for_signal`. The child workflow writes `tool` messages and
signals the parent turn. `SEARCH` and `WEBFETCH` use `df.http`; `SEARCH` queries
Bing's HTML endpoint and returns up to 10 parsed results. `WEBFETCH` is limited
to public `http` and `https` URLs and blocks obvious local/private hosts. If the
parent wait times out, attobot writes timeout tool responses so the next LLM
request has a valid tool-message sequence, and cancels stale tool executor work
to free resources.

`WRITE_BLOB` accepts `content` plus `encoding`. Use `base64`, `hex`, or `escape`
for raw binary data; use PostgreSQL text encodings such as `UTF8`, `LATIN1`, or
`WIN1252` when the content should be converted from text into bytes. It returns
a JSON object with the blob hash, byte count, and marker.

`SEND_ATTACHMENT` accepts a blob `hash`, plus optional `filename`, `caption`, and
`mime_type`. It queues a `telegram_attachment` outbox row; the Telegram outbox
workflow uploads the stored blob bytes as the document body.

`SQL` intentionally accepts only one semicolon-free query and wraps it as a
subquery. For writes, use a data-modifying CTE with `RETURNING`, for example:

```sql
WITH ins AS (
  INSERT INTO some_table(value) VALUES ('x')
  RETURNING *
)
SELECT * FROM ins
```

## Docker Image

The image uses `postgres:18-trixie` as its base and installs
`pg-durable-postgresql-18_0.2.3-1_amd64.deb` from the
`sweatybridge/pg_durable` `v0.2.3` GitHub release. The Dockerfile verifies the
published SHA256 digest before installing the package.

`shared_preload_libraries = 'pg_durable'` is written into the base sample config
so new clusters load the background worker before init SQL runs.

The `harness` service uses this image. The `agent-init` service uses the stock
Postgres client image, mounts `agents.sql` read-only, waits for `harness` to be
healthy, and runs `psql --single-transaction --set=... --file=/attobot/agents.sql`.
