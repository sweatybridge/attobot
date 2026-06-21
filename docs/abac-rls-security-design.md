# ABAC and RLS Security Design for AttoBot

## Executive Summary

This document outlines an Attribute-Based Access Control (ABAC) system using PostgreSQL Row-Level Security (RLS) to control Telegram user and agent access to AttoBot database objects. The design follows the principle of least privilege, separating concerns between different agent types and user contexts.

## Roles and Responsibilities

### 1. Database Roles

```sql
-- Base roles
CREATE ROLE attobot_anonymous;  -- Unauthenticated Telegram users in group chats
CREATE ROLE attobot_authenticated;  -- Known Telegram users (identified by user_id)
CREATE ROLE attobot_service;  -- Internal services (durable functions, cron jobs)
CREATE ROLE attobot_admin;  -- Database administrators

-- Agent-specific roles
CREATE ROLE attobot_agent_primary;  -- Primary agent functions
CREATE ROLE attobot_agent_subconscious;  -- Subconscious agent functions
```

### Role Hierarchy

```
attobot_admin
  ├── attobot_service
  ├── attobot_agent_primary
  └── attobot_agent_subconscious
attobot_authenticated
  └── (inherits attobot_anonymous permissions)
attobot_anonymous
```

## User Context Attributes

User context is set via `SET LOCAL` or `SET` configuration parameters at session start:

```sql
-- Set user context (called by connection pooler or session init)
SET LOCAL attobot.current_role = 'attobot_anonymous';
SET LOCAL attobot.current_agent_id = '123';  -- For agent roles
SET LOCAL attobot.current_telegram_user_id = '456';  -- For Telegram users
SET LOCAL attobot.current_telegram_chat_id = '-1001234567890';  -- For group chat context
```

## Table-by-Table RLS Policies

### attobot.messages

**Purpose**: Store conversation messages for each agent.

**Access Requirements**:
- Anonymous Telegram users: INSERT only (via telegram intake), SELECT own messages
- Authenticated users: SELECT own messages, INSERT via agent functions
- Agent roles: Full access to their agent's messages
- Service roles: Full access for processing

```sql
-- Enable RLS
ALTER TABLE attobot.messages ENABLE ROW LEVEL SECURITY;

-- Policy: Anonymous users can only read messages they created
CREATE POLICY messages_anon_read ON attobot.messages
  FOR SELECT
  TO attobot_anonymous
  USING (
    payload #>> '{telegram_update,message,from,id}' = current_setting('attobot.current_telegram_user_id', true)
  );

-- Policy: Anonymous users can insert via telegram (handled by function, not direct)
-- No direct INSERT policy - must use attobot.append_message

-- Policy: Authenticated users can read their agent's messages
CREATE POLICY messages_auth_read ON attobot.messages
  FOR SELECT
  TO attobot_authenticated
  USING (
    agent_id = current_setting('attobot.current_agent_id', true)::bigint
  );

-- Policy: Agent roles have full access to their agent's messages
CREATE POLICY messages_agent_all ON attobot.messages
  FOR ALL
  TO attobot_agent_primary, attobot_agent_subconscious
  USING (
    agent_id = current_setting('attobot.current_agent_id', true)::bigint
  )
  WITH CHECK (
    agent_id = current_setting('attobot.current_agent_id', true)::bigint
  );

-- Policy: Service roles bypass RLS
CREATE POLICY messages_service_bypass ON attobot.messages
  FOR ALL
  TO attobot_service
  USING (true)
  WITH CHECK (true);
```

### attobot.agents

**Purpose**: Define agent configurations.

**Access Requirements**:
- All roles: SELECT only (read-only access)
- Admin only: INSERT, UPDATE, DELETE

```sql
ALTER TABLE attobot.agents ENABLE ROW LEVEL SECURITY;

-- Policy: All roles can read agents
CREATE POLICY agents_read ON attobot.agents
  FOR SELECT
  TO PUBLIC
  USING (true);

-- Policy: Only admin can modify
CREATE POLICY agents_admin_write ON attobot.agents
  FOR ALL
  TO attobot_admin
  USING (true)
  WITH CHECK (true);
```

### attobot.config

**Purpose**: Store agent configuration (API keys, settings).

**Access Requirements**:
- Agent roles: Full access to their agent's config
- Service roles: Full access
- All others: No access (except via security-definer functions)

```sql
ALTER TABLE attobot.config ENABLE ROW LEVEL SECURITY;

-- Policy: Agent roles can manage their config
CREATE POLICY config_agent_all ON attobot.config
  FOR ALL
  TO attobot_agent_primary, attobot_agent_subconscious
  USING (
    agent_id = current_setting('attobot.current_agent_id', true)::bigint
  )
  WITH CHECK (
    agent_id = current_setting('attobot.current_agent_id', true)::bigint
  );

-- Policy: Service roles bypass RLS
CREATE POLICY config_service_bypass ON attobot.config
  FOR ALL
  TO attobot_service
  USING (true)
  WITH CHECK (true);
```

### attotools.blobs

**Purpose**: Store binary content (attachments, documents).

**Access Requirements**:
- Agent roles: Full access to their agent's blobs
- Service roles: Full access
- All others: No access

```sql
ALTER TABLE attotools.blobs ENABLE ROW LEVEL SECURITY;

-- Policy: Agent roles can manage their blobs
CREATE POLICY blobs_agent_all ON attotools.blobs
  FOR ALL
  TO attobot_agent_primary, attobot_agent_subconscious
  USING (
    agent_id = current_setting('attobot.current_agent_id', true)::bigint
  )
  WITH CHECK (
    agent_id = current_setting('attobot.current_agent_id', true)::bigint
  );

-- Policy: Service roles bypass RLS
CREATE POLICY blobs_service_bypass ON attotools.blobs
  FOR ALL
  TO attobot_service
  USING (true)
  WITH CHECK (true);
```

### attobot.outbox

**Purpose**: Queue outgoing messages (Telegram responses).

**Access Requirements**:
- Agent roles: INSERT, UPDATE their agent's outbox entries
- Service roles: Full access (for telegram sender)
- Anonymous/Authenticated: No direct access (via functions only)

```sql
ALTER TABLE attobot.outbox ENABLE ROW LEVEL SECURITY;

-- Policy: Agent roles can manage their outbox
CREATE POLICY outbox_agent_all ON attobot.outbox
  FOR ALL
  TO attobot_agent_primary, attobot_agent_subconscious
  USING (
    agent_id = current_setting('attobot.current_agent_id', true)::bigint
  )
  WITH CHECK (
    agent_id = current_setting('attobot.current_agent_id', true)::bigint
  );

-- Policy: Service roles bypass RLS
CREATE POLICY outbox_service_bypass ON attobot.outbox
  FOR ALL
  TO attobot_service
  USING (true)
  WITH CHECK (true);
```

### attobot.memory

**Purpose**: Store agent memory and learnings.

**Access Requirements**:
- Agent roles: Full access to their agent's memory
- Subconscious agent: Read primary's memory, write to primary's memory
- Service roles: Full access

```sql
ALTER TABLE attobot.memory ENABLE ROW LEVEL SECURITY;

-- Policy: Primary agent manages its memory
CREATE POLICY memory_primary_all ON attobot.memory
  FOR ALL
  TO attobot_agent_primary
  USING (
    agent_id = current_setting('attobot.current_agent_id', true)::bigint
  )
  WITH CHECK (
    agent_id = current_setting('attobot.current_agent_id', true)::bigint
  );

-- Policy: Subconscious can read primary's memory
CREATE POLICY memory_subconscious_read ON attobot.memory
  FOR SELECT
  TO attobot_agent_subconscious
  USING (
    agent_id = (
      SELECT id FROM attobot.agents WHERE slug = 'primary'
    )
  );

-- Policy: Subconscious can write to primary's memory (for corrections)
CREATE POLICY memory_subconscious_write ON attobot.memory
  FOR INSERT
  TO attobot_agent_subconscious
  WITH CHECK (
    agent_id = (
      SELECT id FROM attobot.agents WHERE slug = 'primary'
    )
  );

-- Policy: Service roles bypass RLS
CREATE POLICY memory_service_bypass ON attobot.memory
  FOR ALL
  TO attobot_service
  USING (true)
  WITH CHECK (true);
```

### attobot.lifecycle

**Purpose**: Audit log of agent events.

**Access Requirements**:
- All roles: SELECT (read-only audit log)
- Service roles: INSERT (for logging functions)

```sql
ALTER TABLE attobot.lifecycle ENABLE ROW LEVEL SECURITY;

-- Policy: All roles can read lifecycle
CREATE POLICY lifecycle_read ON attobot.lifecycle
  FOR SELECT
  TO PUBLIC
  USING (true);

-- Policy: Service roles can insert
CREATE POLICY lifecycle_service_insert ON attobot.lifecycle
  FOR INSERT
  TO attobot_service
  WITH CHECK (true);
```

### attobot.models

**Purpose**: Available AI model configurations.

**Access Requirements**:
- All roles: SELECT only
- Admin only: INSERT, UPDATE, DELETE

```sql
ALTER TABLE attobot.models ENABLE ROW LEVEL SECURITY;

-- Policy: All can read models
CREATE POLICY models_read ON attobot.models
  FOR SELECT
  TO PUBLIC
  USING (true);

-- Policy: Admin can modify
CREATE POLICY models_admin_write ON attobot.models
  FOR ALL
  TO attobot_admin
  USING (true)
  WITH CHECK (true);
```

## Function Security

### Security-Definer Functions

Functions that write to protected tables should be `SECURITY DEFINER` with explicit role checks:

```sql
-- Example: append_message with security
CREATE OR REPLACE FUNCTION attobot.append_message(
  p_agent_slug text,
  p_role text,
  p_content text,
  p_payload jsonb DEFAULT '{}'::jsonb,
  p_tool_call_id text DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = attobot, attotools, pg_temp
AS $$
DECLARE
  v_agent_id bigint := attobot.agent_id(p_agent_slug);
  v_id bigint;
BEGIN
  -- Security check: allow if service role or if accessing own agent
  IF NOT (
    current_user = 'attobot_service' OR
    current_user = 'attobot_agent_' || p_agent_slug OR
    current_setting('attobot.current_agent_id', true)::bigint = v_agent_id
  ) THEN
    RAISE EXCEPTION 'permission denied for append_message on agent %', p_agent_slug;
  END IF;

  -- Original function logic...
END;
$$;
```

### Function Execution Permissions

Grant execute permissions by role:

```sql
-- Public functions (Telegram intake)
GRANT EXECUTE ON FUNCTION attobot.process_telegram_updates TO attobot_anonymous;

-- Agent functions
GRANT EXECUTE ON FUNCTION attobot.append_message TO attobot_agent_primary, attobot_agent_subconscious;
GRANT EXECUTE ON FUNCTION attobot.start_turn TO attobot_agent_primary;

-- Service functions
GRANT EXECUTE ON FUNCTION attobot.log_event TO attobot_service;

-- Admin functions
GRANT EXECUTE ON FUNCTION attobot.ensure_agent TO attobot_admin;
GRANT EXECUTE ON FUNCTION attobot.configure_telegram TO attobot_admin;
```

## Session Initialization

When a connection is established, set the appropriate context:

```sql
-- For service connections (durable functions)
SET LOCAL attobot.current_role = 'attobot_service';
SET ROLE attobot_service;

-- For agent execution (primary agent)
SET LOCAL attobot.current_role = 'attobot_agent_primary';
SET LOCAL attobot.current_agent_id = '1';
SET ROLE attobot_agent_primary;

-- For Telegram anonymous user in group chat
SET LOCAL attobot.current_role = 'attobot_anonymous';
SET LOCAL attobot.current_telegram_user_id = '123456789';
SET ROLE attobot_anonymous;
```

## Implementation Plan

### Phase 1: Infrastructure
1. Create base roles
2. Create role hierarchy with inheritance
3. Create user context parameter documentation

### Phase 2: Table RLS
1. Enable RLS on all attobot and attotools tables
2. Create policies for each table
3. Test policies with different roles

### Phase 3: Function Security
1. Mark sensitive functions as SECURITY DEFINER
2. Add role checks within functions
3. Grant execute permissions appropriately

### Phase 4: Session Management
1. Create session initialization function
2. Update connection pooler to call init function
3. Document role switching procedures

### Phase 5: Testing and Validation
1. Create test suite for each role
2. Verify least privilege for each role
3. Audit function access patterns

## Security Considerations

### Potential Risks

1. **SQL Injection in dynamic SQL**: All functions use `format()` with parameterized `%L` - safe
2. **Role escalation**: Protect role-switching functions with admin-only access
3. **Context confusion**: Ensure context parameters are reset on connection checkout
4. **Function side effects**: Some functions modify state - document clearly

### Mitigations

1. **Connection pooling**: Use `DISCARD ALL` or explicit context reset on checkout
2. **Audit logging**: lifecycle table logs all sensitive operations
3. **Function ownership**: Own functions by attobot_admin, not postgres
4. **Search path**: Always set explicit search_path in SECURITY DEFINER functions

## Migration Strategy

1. **Create new roles alongside existing setup**
2. **Gradually enable RLS per table**
3. **Update functions to SECURITY DEFINER**
4. **Switch connections to use new roles**
5. **Remove legacy permissions**

## Example Usage Scenarios

### Scenario 1: Telegram User Sends Message

```sql
-- Connection initialized as anonymous user
SET ROLE attobot_anonymous;
SET LOCAL attobot.current_telegram_user_id = '123456789';

-- Call intake function (public)
SELECT attobot.process_telegram_updates('primary', $http_response);

-- Function internally runs as service role to write to messages
-- RLS allows because function is SECURITY DEFINER
```

### Scenario 2: Agent Processes Turn

```sql
-- Connection initialized as primary agent
SET ROLE attobot_agent_primary;
SET LOCAL attobot.current_agent_id = '1';

-- Agent reads its messages (RLS filters to agent_id = 1)
SELECT * FROM attobot.messages ORDER BY id DESC LIMIT 10;

-- Agent appends new message (RLS allows insert with agent_id = 1)
SELECT attobot.append_message('primary', 'user', 'Hello world');

-- Service triggers turn processing (switches role internally)
```

### Scenario 3: Admin Configures Agent

```sql
-- Admin connection
SET ROLE attobot_admin;

-- Create or modify agent
SELECT attobot.ensure_agent('new-agent', $soul, $api_key, $model_id);

-- Configure Telegram
SELECT attobot.configure_telegram('new-agent', $token, $chat_id);
```

## Appendix: Complete SQL Migration Script

See `docker-entrypoint-initdb.d/40-attobot-rbac.sql` for the complete implementation.
