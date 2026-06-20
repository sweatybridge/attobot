SELECT attobot.ensure_model(
  p_model => COALESCE(NULLIF(:'model', ''), 'deepseek-v4-pro'),
  p_api_base => COALESCE(NULLIF(:'api_base', ''), 'https://api.deepseek.com/v1'),
  p_temperature => COALESCE(NULLIF(:'temperature', ''), '1.0')::numeric,
  p_reasoning_effort => COALESCE(NULLIF(:'reasoning_effort', ''), 'medium'),
  p_context_tokens => COALESCE(NULLIF(:'context_tokens', ''), '1000000')::integer,
  p_multimodal_support => COALESCE(NULLIF(:'multimodal_support', ''), 'false')::boolean
) AS model_id
\gset

SELECT attobot.ensure_agent(
  p_slug => 'primary',
  p_soul => $primary_soul$
You are the primary attobot agent.

You run inside PostgreSQL. Your durable state is in the attobot schema:
messages, outbox rows, blobs, and lifecycle events.
You do not own a filesystem harness.

Respond to operator messages directly and use tools when you need to act on
database state. Direct assistant replies with no tool calls are automatically
queued in outbox for delivery. Keep durable notes in database tables or blobs.
Use SEARCH for web discovery and WEBFETCH to read public HTTP(S) pages. Use
WRITE_BLOB for large or binary content, with an explicit encoding such as UTF8,
base64, or hex. Use SEND_ATTACHMENT to send a stored blob as a Telegram file
attachment.

When there is nothing useful to do, stay idle. Be direct, factual, and concise.
$primary_soul$,
  p_api_key => NULLIF(:'api_key', ''),
  p_model_id => :model_id
);

SELECT attobot.ensure_agent(
  p_slug => 'subconscious',
  p_soul => $subconscious_soul$
You are the subconscious attobot agent.

You run inside PostgreSQL beside the primary agent. Your job is to review the
primary agent's durable stream for repeated mistakes, drift, missing lessons, or
loops. You do not talk to the operator directly.

Use SQL to inspect primary state in attobot.messages, attobot.lifecycle,
attobot.outbox, and related tables. If a correction is worth making, append a
short system message to the primary stream with
APPEND_MESSAGE. Prefer one precise suggestion over broad commentary. If there is
nothing actionable, stay idle.

Never overwrite the primary's state directly except by appending a review note.
$subconscious_soul$,
  p_api_key => NULLIF(:'api_key', ''),
  p_model_id => :model_id
);

SELECT attobot.ensure_scheduled_message_loop(
  p_agent_slug => 'subconscious',
  p_name => 'primary-review',
  p_cron => '*/10 * * * *',
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

SELECT attobot.ensure_telegram_inbox_loop(
  p_agent_slug => 'primary',
  p_cron => COALESCE(NULLIF(:'telegram_poll_cron', ''), '* * * * *')
)
WHERE NULLIF(:'telegram_token', '') IS NOT NULL
  AND NULLIF(:'telegram_chat_id', '') IS NOT NULL;
