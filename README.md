# attobot

attobot is now a Postgres-resident agent harness. Agent state, turns, tool calls,
triggers, blobs, and outbound messages live in PostgreSQL tables under the
`attobot` schema. `pg_durable` owns the durable workflow execution, so a turn can
survive database restarts and resume from its last checkpoint.

The old filesystem loop is gone. `agent.py` is only a thin client for inserting
messages and inspecting database state.

## Architecture

```
operator/client
  -> attobot.append_user_message(...)
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
agents with an LLM key:

```bash
ATTOBOT_API_KEY=sk-... docker compose up -d
```

You can also override `ATTOBOT_MODEL` and `ATTOBOT_API_BASE`.

To update an agent later:

```bash
docker compose exec db psql -U postgres -d postgres
```

```sql
SELECT attobot.ensure_agent(
  p_slug => 'primary',
  p_soul => $$
You are a persistent agent running inside PostgreSQL.
Be direct. Use tools when you need to act on stored state.
Queue operator-facing messages with SEND_CHAT.
$$,
  p_api_key => 'sk-...'
);
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

The default DSN is `postgresql://postgres:secret@localhost:5432/postgres`.
Override it with `--dsn` or `ATTOBOT_DSN`.

## Telegram

Configure Telegram for an agent:

```bash
python agent.py telegram-config --token 123:abc --chat-id -1001234567
```

For a forum topic, include `--thread-id 42`.

Start the durable Telegram ingress and egress loops:

```bash
python agent.py telegram-start
```

The inbox loop calls Telegram `getUpdates` through `pg_durable` and appends
accepted messages as `[telegram <update_id>] ...` user messages. It accepts only
the configured chat, and the configured topic when `telegram_thread_id` is set.

The outbox loop drains pending `attobot.outbox` rows with channel `chat` or
`telegram` through Telegram `sendMessage`. The `SEND_CHAT` tool still only queues
messages; Telegram delivery is handled by the durable outbox loop.

## Durable Loops

Start a cron wake loop with `pg_durable`:

```sql
SELECT attobot.start_agent_loop('primary', '*/5 * * * *');
```

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
- `attobot.config`: per-agent configuration and secrets.
- `attobot.messages`: canonical conversation stream.
- `attobot.tool_requests`: pending/running/completed tool calls.
- `attobot.outbox`: outbound messages for chat relays or clients.
- `attobot.blobs`: content-addressed large text storage.
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
`pg-durable-postgresql-18_0.2.2-1_amd64.deb` from the
`sweatybridge/pg_durable` `v0.2.2` GitHub release. The Dockerfile verifies the
published SHA256 digest before installing the package.

`shared_preload_libraries = 'pg_durable'` is written into the base sample config
so new clusters load the background worker before init SQL runs.
