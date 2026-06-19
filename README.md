# attobot

attobot is now a Postgres-resident agent harness. Agent state, turns, tool calls,
triggers, blobs, and outbound messages live in PostgreSQL tables under the
`attobot` schema. Agents point at shared rows in `attobot.models`, so multiple
agents can reuse the same model configuration. `pg_durable` owns the durable
workflow execution, so a turn can survive database restarts and resume from its
last checkpoint.

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
       -> attobot.run_pending_tool_requests(...)
       -> attobot.start_turn(...) while tool calls remain
  -> attobot.outbox
```

The durable turn workflow is SQL:

- `df.http` calls an OpenAI-compatible `/chat/completions` endpoint.
- Assistant messages are stored in `attobot.messages`.
- Tool calls are stored in `attobot.tool_requests`.
- Database-native tools are executed by `attobot.run_pending_tool_requests`.
- User-visible replies are queued in `attobot.outbox`.
- Optional Telegram loops use `df.http` to poll `getUpdates` into
  `attobot.messages` and deliver `attobot.outbox` rows with `sendMessage`.

## Run

Build the Postgres 18 image with `pg_durable` installed from the
`sweatybridge/pg_durable` GitHub release Debian package:

```bash
docker compose build
docker compose up -d
```

Fresh containers initialize `primary` and `subconscious` agents automatically in
the Docker entrypoint. Set `ATTOBOT_API_KEY` before first boot to seed both
agents with an LLM key. Secrets are stored in agent-scoped `attobot.config`
rows:

```bash
ATTOBOT_API_KEY=sk-... docker compose up -d
```

You can also override the shared model with `ATTOBOT_MODEL`,
`ATTOBOT_API_BASE`, `ATTOBOT_TEMPERATURE`, `ATTOBOT_REASONING_EFFORT`,
`ATTOBOT_CONTEXT_TOKENS`, and `ATTOBOT_MULTIMODAL_SUPPORT`. The entrypoint
configures that model before creating agents, then assigns both seeded agents to
the configured model row.

To create a new agent, configure a model first and pass its id:

```bash
docker compose exec db psql -U postgres -d postgres
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
Queue operator-facing messages with SEND_CHAT.
$$,
  p_api_key => 'sk-...',
  p_model_id => (SELECT id FROM model)
);
```

To update only a secret:

```sql
SELECT attobot.set_config('primary', 'api_key', to_jsonb('sk-...'::text));
```

The `subconscious` agent is also seeded with a `primary-review` interval trigger
that wakes it every 600 seconds when you run the trigger loop for that agent.

Send a message:

```bash
python agent.py send "Introduce yourself"
```

Read queued outbound messages:

```bash
python agent.py outbox
```

The default DSN is `postgresql://postgres:secret@127.0.0.1:5432/postgres`.
Override it with `--dsn` or `ATTOBOT_DSN`.

## Telegram

For a clean database, configure and start the primary agent's durable Telegram
inbox loop from the Docker entrypoint:

```bash
ATTOBOT_TELEGRAM_TOKEN=123:abc \
ATTOBOT_TELEGRAM_CHAT_ID=-1001234567 \
docker compose up -d
```

For a forum topic, also set `ATTOBOT_TELEGRAM_THREAD_ID=42`. Override the
poll schedule with `ATTOBOT_TELEGRAM_POLL_CRON`; the default is `* * * * *`.

To update stored Telegram settings later, use `python agent.py telegram-config`.
It stores the token and chat metadata as agent-scoped `attobot.config` rows.

The inbox loop calls Telegram `getUpdates` through `pg_durable` and appends
accepted messages as `[telegram <update_id>] ...` user messages. It accepts only
the configured chat, and the configured topic when `telegram_thread_id` is set.

When Telegram is configured, pending `chat` or `telegram` rows inserted into
`attobot.outbox` automatically fire a PostgreSQL trigger that starts a one-shot
durable `sendMessage` workflow for that row.

The `SEND_CHAT` tool still only queues messages; Telegram delivery is scheduled
by the outbox table trigger.

## Durable Loops

Install an interval trigger that appends a system message and starts a turn:

```sql
SELECT attobot.install_interval_trigger(
  p_agent_slug => 'primary',
  p_name => 'heartbeat',
  p_interval_seconds => 300,
  p_message => 'tick'
);

SELECT attobot.start_trigger_loop('primary');
```

## Tables

- `attobot.agents`: one row per agent.
- `attobot.models`: reusable model, endpoint, temperature, reasoning, context, and modality configuration.
- `attobot.config`: per-agent configuration and secrets.
- `attobot.messages`: canonical conversation stream.
- `attobot.tool_requests`: pending/running/completed tool calls.
- `attobot.outbox`: outbound messages for chat relays or clients.
- `attobot.blobs`: content-addressed large content storage as external `bytea`.
- `attobot.triggers`: interval triggers fired by a durable trigger loop.
- `attobot.telegram_updates`: accepted Telegram updates for idempotency/audit.
- `attobot.lifecycle`: append-only operational events.

## Built-In Tools

The LLM sees these database-native tools:

- `SQL`: run a single SQL query that returns rows.
- `SEND_CHAT`: queue an operator-facing message in `attobot.outbox`.
- `APPEND_MESSAGE`: append a message to an agent stream.
- `STASH`: save large text into `attobot.blobs`.
- `READ_BLOB`: read stashed content by hash.

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
