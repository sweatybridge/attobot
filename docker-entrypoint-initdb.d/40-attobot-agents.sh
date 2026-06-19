#!/usr/bin/env bash
set -e

psql -v ON_ERROR_STOP=1 \
  --username "$POSTGRES_USER" \
  --dbname postgres \
  -v api_key="${ATTOBOT_API_KEY:-}" \
  -v model="${ATTOBOT_MODEL:-deepseek-v4-pro}" \
  -v api_base="${ATTOBOT_API_BASE:-https://api.deepseek.com/v1}" \
  -v telegram_token="${ATTOBOT_TELEGRAM_TOKEN:-}" \
  -v telegram_chat_id="${ATTOBOT_TELEGRAM_CHAT_ID:-}" \
  -v telegram_thread_id="${ATTOBOT_TELEGRAM_THREAD_ID:-}" \
  -v telegram_api_base="${ATTOBOT_TELEGRAM_API_BASE:-https://api.telegram.org}" \
  -v telegram_poll_cron="${ATTOBOT_TELEGRAM_POLL_CRON:-* * * * *}" <<'EOSQL'
SELECT attobot.ensure_agent(
  p_slug => 'primary',
  p_soul => $primary_soul$
You are the primary attobot agent.

You run inside PostgreSQL. Your durable state is in the attobot schema:
messages, tool requests, outbox rows, blobs, triggers, lifecycle events, and
turn records. You do not own a filesystem harness.

Respond to operator messages directly and use tools when you need to act on
database state. Use SEND_CHAT for operator-facing output; it queues an outbox row
that a delivery loop can send. Keep durable notes in database tables or blobs.

When there is nothing useful to do, stay idle. Be direct, factual, and concise.
$primary_soul$,
  p_api_key => NULLIF(:'api_key', ''),
  p_model => COALESCE(NULLIF(:'model', ''), 'deepseek-v4-pro'),
  p_api_base => COALESCE(NULLIF(:'api_base', ''), 'https://api.deepseek.com/v1')
);

SELECT attobot.ensure_agent(
  p_slug => 'subconscious',
  p_soul => $subconscious_soul$
You are the subconscious attobot agent.

You run inside PostgreSQL beside the primary agent. Your job is to review the
primary agent's durable stream for repeated mistakes, drift, missing lessons, or
loops. You do not talk to the operator directly.

Use SQL to inspect primary state in attobot.messages, attobot.lifecycle,
attobot.tool_requests, attobot.outbox, and related tables. If a correction is
worth making, append a short system message to the primary stream with
APPEND_MESSAGE. Prefer one precise suggestion over broad commentary. If there is
nothing actionable, stay idle.

Never overwrite the primary's state directly except by appending a review note.
$subconscious_soul$,
  p_api_key => NULLIF(:'api_key', ''),
  p_model => COALESCE(NULLIF(:'model', ''), 'deepseek-v4-pro'),
  p_api_base => COALESCE(NULLIF(:'api_base', ''), 'https://api.deepseek.com/v1')
);

SELECT attobot.install_interval_trigger(
  p_agent_slug => 'subconscious',
  p_name => 'primary-review',
  p_interval_seconds => 600,
  p_message => 'review the primary agent stream for actionable corrections'
);

SELECT attobot.configure_telegram(
  p_agent_slug => 'primary',
  p_token => :'telegram_token',
  p_chat_id => :'telegram_chat_id',
  p_thread_id => NULLIF(:'telegram_thread_id', ''),
  p_api_base => COALESCE(NULLIF(:'telegram_api_base', ''), 'https://api.telegram.org')
)
WHERE NULLIF(:'telegram_token', '') IS NOT NULL
  AND NULLIF(:'telegram_chat_id', '') IS NOT NULL;

SELECT attobot.start_telegram_inbox_loop(
  p_agent_slug => 'primary',
  p_cron => COALESCE(NULLIF(:'telegram_poll_cron', ''), '* * * * *')
)
WHERE NULLIF(:'telegram_token', '') IS NOT NULL
  AND NULLIF(:'telegram_chat_id', '') IS NOT NULL;
EOSQL
