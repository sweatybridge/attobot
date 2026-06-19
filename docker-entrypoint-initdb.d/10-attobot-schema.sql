CREATE SCHEMA IF NOT EXISTS attobot;

CREATE TABLE IF NOT EXISTS attobot.agents (
  id bigserial PRIMARY KEY,
  slug text NOT NULL UNIQUE,
  soul text NOT NULL DEFAULT '',
  model text NOT NULL DEFAULT 'deepseek-v4-pro',
  api_base text NOT NULL DEFAULT 'https://api.deepseek.com/v1',
  temperature numeric NOT NULL DEFAULT 1.0,
  reasoning_effort text NOT NULL DEFAULT 'medium',
  context_tokens integer NOT NULL DEFAULT 1000000,
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

CREATE TABLE IF NOT EXISTS attobot.tool_requests (
  id bigserial PRIMARY KEY,
  agent_id bigint NOT NULL REFERENCES attobot.agents(id) ON DELETE CASCADE,
  message_id bigint REFERENCES attobot.messages(id) ON DELETE SET NULL,
  tool_call_id text NOT NULL,
  name text NOT NULL,
  arguments jsonb NOT NULL DEFAULT '{}'::jsonb,
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'running', 'completed', 'failed')),
  result text,
  error text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (agent_id, tool_call_id)
);

CREATE INDEX IF NOT EXISTS tool_requests_agent_status_idx
  ON attobot.tool_requests(agent_id, status, id);

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
  content text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (agent_id, hash)
);

CREATE TABLE IF NOT EXISTS attobot.triggers (
  id bigserial PRIMARY KEY,
  agent_id bigint NOT NULL REFERENCES attobot.agents(id) ON DELETE CASCADE,
  name text NOT NULL,
  interval_seconds integer NOT NULL CHECK (interval_seconds > 0),
  message text NOT NULL,
  enabled boolean NOT NULL DEFAULT true,
  next_after timestamptz NOT NULL DEFAULT now(),
  last_fired_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (agent_id, name)
);

CREATE TABLE IF NOT EXISTS attobot.telegram_updates (
  agent_id bigint NOT NULL REFERENCES attobot.agents(id) ON DELETE CASCADE,
  update_id bigint NOT NULL,
  payload jsonb NOT NULL,
  message_id bigint REFERENCES attobot.messages(id) ON DELETE SET NULL,
  received_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (agent_id, update_id)
);

CREATE INDEX IF NOT EXISTS telegram_updates_agent_received_idx
  ON attobot.telegram_updates(agent_id, received_at DESC);

CREATE TABLE IF NOT EXISTS attobot.turns (
  id bigserial PRIMARY KEY,
  agent_id bigint NOT NULL REFERENCES attobot.agents(id) ON DELETE CASCADE,
  durable_instance_id text,
  status text NOT NULL DEFAULT 'started'
    CHECK (status IN ('started', 'completed', 'failed')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS attobot.lifecycle (
  id bigserial PRIMARY KEY,
  agent_id bigint REFERENCES attobot.agents(id) ON DELETE CASCADE,
  event text NOT NULL,
  detail jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);
