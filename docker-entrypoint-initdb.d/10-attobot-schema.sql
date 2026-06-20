CREATE SCHEMA IF NOT EXISTS attobot;

CREATE TABLE IF NOT EXISTS attobot.models (
  id bigserial PRIMARY KEY,
  name text NOT NULL DEFAULT 'deepseek-v4-pro',
  api_base text NOT NULL DEFAULT 'https://api.deepseek.com/v1',
  temperature numeric NOT NULL DEFAULT 1.0,
  reasoning_effort text NOT NULL DEFAULT 'medium',
  context_tokens integer NOT NULL DEFAULT 1000000,
  multimodal_support boolean NOT NULL DEFAULT false,
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (name, api_base, temperature, reasoning_effort, context_tokens, multimodal_support)
);

CREATE TABLE IF NOT EXISTS attobot.agents (
  id bigserial PRIMARY KEY,
  slug text NOT NULL UNIQUE,
  soul text NOT NULL DEFAULT '',
  model_id bigint NOT NULL REFERENCES attobot.models(id) ON DELETE RESTRICT,
  enabled boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS attobot.config (
  agent_id bigint NOT NULL REFERENCES attobot.agents(id) ON DELETE CASCADE,
  key text NOT NULL,
  value jsonb NOT NULL,
  secret boolean NOT NULL DEFAULT false,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (agent_id, key)
);

CREATE TABLE IF NOT EXISTS attobot.messages (
  id bigserial PRIMARY KEY,
  agent_id bigint NOT NULL REFERENCES attobot.agents(id) ON DELETE CASCADE,
  role text NOT NULL CHECK (role IN ('system', 'user', 'assistant', 'tool')),
  content text NOT NULL DEFAULT '',
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  tool_call_id text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS messages_agent_id_id_idx ON attobot.messages(agent_id, id);

CREATE UNIQUE INDEX IF NOT EXISTS messages_telegram_update_agent_idx
  ON attobot.messages(agent_id, ((payload #>> '{telegram_update,update_id}')))
  WHERE payload #>> '{telegram_update,update_id}' IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS messages_tool_call_agent_idx
  ON attobot.messages(agent_id, tool_call_id)
  WHERE role = 'tool' AND tool_call_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS attobot.outbox (
  id bigserial PRIMARY KEY,
  agent_id bigint NOT NULL REFERENCES attobot.agents(id) ON DELETE CASCADE,
  channel text NOT NULL DEFAULT 'chat',
  body jsonb NOT NULL,
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'sending', 'sent', 'failed')),
  created_at timestamptz NOT NULL DEFAULT now(),
  sent_at timestamptz
);

CREATE INDEX IF NOT EXISTS outbox_agent_status_idx ON attobot.outbox(agent_id, status, id);

CREATE TABLE IF NOT EXISTS attobot.blobs (
  agent_id bigint NOT NULL REFERENCES attobot.agents(id) ON DELETE CASCADE,
  hash text NOT NULL,
  content bytea NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (agent_id, hash)
);

ALTER TABLE attobot.blobs ALTER COLUMN content SET STORAGE EXTERNAL;

CREATE TABLE IF NOT EXISTS attobot.lifecycle (
  id bigserial PRIMARY KEY,
  agent_id bigint REFERENCES attobot.agents(id) ON DELETE CASCADE,
  event text NOT NULL,
  detail jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);
