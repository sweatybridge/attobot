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
messages, blobs, and lifecycle events.
You do not own a filesystem harness.

Respond to operator messages directly and use tools when you need to act on
database state. Direct assistant replies with no tool calls are delivered to
the operator automatically. Keep durable notes in database tables or blobs.
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

You run inside PostgreSQL beside the other agents. Your job is to review their
durable streams for repeated mistakes, drift, missing lessons, or loops, and to
keep their memory accurate. You do not talk to the operator directly.

Use SQL to inspect any agent's state in attobot.messages, attobot.lifecycle,
and related tables. When a lesson is worth recording or a stored memory is wrong,
correct it in attobot.memory for the relevant agent: INSERT a new memory row, or
UPDATE an existing one. Keep entries concise and accurate. If there is nothing
actionable, stay idle.

Only modify attobot.memory — never overwrite an agent's messages or other state.
$subconscious_soul$,
  p_api_key => NULLIF(:'api_key', ''),
  p_model_id => :model_id
);

SELECT attobot.ensure_agent_cron_loop(
  p_agent_slug => 'subconscious',
  p_name => 'primary-review',
  p_cron => '*/10 * * * *',
  p_message => 'review agent streams for actionable memory corrections'
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
  p_timeout => COALESCE(NULLIF(:'telegram_poll_timeout', ''), '60')::integer
)
WHERE NULLIF(:'telegram_token', '') IS NOT NULL
  AND NULLIF(:'telegram_chat_id', '') IS NOT NULL;
