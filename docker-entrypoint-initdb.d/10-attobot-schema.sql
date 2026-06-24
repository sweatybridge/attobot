CREATE SCHEMA IF NOT EXISTS attobot;
CREATE SCHEMA IF NOT EXISTS attotools;

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
  max_turn integer NOT NULL DEFAULT 10,
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
  channel text,
  chat_id text,
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

CREATE TABLE IF NOT EXISTS attobot.memory (
  id bigserial PRIMARY KEY,
  agent_id bigint NOT NULL REFERENCES attobot.agents(id) ON DELETE CASCADE,
  content text NOT NULL,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  enabled boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (btrim(content) <> '')
);

CREATE INDEX IF NOT EXISTS memory_agent_enabled_id_idx
  ON attobot.memory(agent_id, enabled, id);

-- Referential-integrity backing for the (agent_id, id) pairs the composite
-- foreign keys below target. id is already the primary key, so these unique
-- constraints add no new uniqueness; they exist only as FK targets.
ALTER TABLE attobot.messages ADD CONSTRAINT messages_agent_id_id_key UNIQUE (agent_id, id);
ALTER TABLE attobot.memory   ADD CONSTRAINT memory_id_agent_key     UNIQUE (id, agent_id);

-- Junction table replacing memory.source_message_ids. The two composite foreign
-- keys force memory.agent_id == messages.agent_id declaratively (same-agent
-- integrity, with no trigger), and both cascade on delete of either parent. A
-- memory may legitimately have zero sources.
CREATE TABLE IF NOT EXISTS attobot.memory_sources (
  memory_id  bigint NOT NULL,
  agent_id   bigint NOT NULL,
  message_id bigint NOT NULL,
  PRIMARY KEY (memory_id, message_id),
  FOREIGN KEY (memory_id, agent_id)
    REFERENCES attobot.memory(id, agent_id) ON DELETE CASCADE,
  FOREIGN KEY (agent_id, message_id)
    REFERENCES attobot.messages(agent_id, id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS attobot.lifecycle (
  id bigserial PRIMARY KEY,
  agent_id bigint REFERENCES attobot.agents(id) ON DELETE CASCADE,
  event text NOT NULL,
  detail jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Channel-agnostic identity ledger. One row per (channel, external_id); today
-- only 'telegram' is populated (by process_telegram_updates), but the shape
-- supports future channels (discord, whatsapp) by new channel values.
-- `tier` maps the user to an RLS role suffix (attobot_<tier>); it defaults to
-- 'anonymous' and is promoted to 'authenticated' by an operator.
CREATE TABLE IF NOT EXISTS attobot.users (
  id bigserial PRIMARY KEY,
  channel text NOT NULL CHECK (channel IN ('telegram', 'discord', 'whatsapp')),
  external_id text NOT NULL,
  username text,
  display_name text,
  tier text NOT NULL DEFAULT 'anonymous' CHECK (tier IN ('anonymous', 'authenticated')),
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (channel, external_id)
);
