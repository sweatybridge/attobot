# attobot

Minimal multi-agent system with forgetting. ~400 lines, no buses, no
queues, no dispatcher — just files and bridges.

> Agents today are bad at forgetting, and worse at remembering that
> they forgot. Forgetting is a *good* thing actually. Evolution didn't
> select for photographic memory in humans for a reason: when you're
> planning a trip to Japan and you're picking a seat on the flight,
> you don't need sushi restaurants in your head — and later, when
> you're planning meals, you can rehydrate that context on demand.
> attobot does the same: old context gets compacted — details fade
> but the gist remains, and the original is always one `UNCOMPACT` away.

```
agent.py              — the loop
inbox_watcher.py      — bridges file drops into bus streams
chat.py               — CLI to talk to a running agent
clean.py              — wipe runtime state

SOUL.md               — purpose + tool format (immutable)
blobs/                — content-addressed blob store (shared)

bus/                  — append-only line streams (any source)
  ├ chat/<id>.md      — shared rooms; anyone subscribes
  └ email_inbox/<self>.md  — per-agent inbox (consolidated mail log)

agents/<self>/        — per-identity dir; <self> = hash(SOUL + boot ts)
  ├ LIFE.md           — append-only event log (every turn, every tool)
  ├ MEMORY.md         — agent-editable working notes (capped at 10000ch)
  ├ context.md        — last live context (resume point)
  ├ email_inbox/      — file-drop folder; watcher → bus/email_inbox/<self>.md
  └ subs/             — bus subscriptions (symlinks into bus/)
```

## Design

- **SOUL / LIFE / MEMORY.** SOUL is the agent's purpose (immutable).
  LIFE is the append-only event log, per-identity; the last 50 lines
  are injected each turn. MEMORY is the agent's own scratchpad —
  learned preferences and notes it edits with `EDIT_FILE`.

- **Prompt order.** Each turn: `SOUL + harness + MEMORY + context + LIFE`.
  Stable prefix first, append-only context next, volatile tail last —
  optimised for LLM prompt caching.

- **Blobs are the substrate.** Every LLM response and every tool result
  is stashed as a blob under `blobs/`; the ref is appended to `LIFE.md`.
  Blobs are content-addressed (filename = sha256 prefix of the blob)
  and have a tiny frontmatter: `at`, `gist`, `parent`. Live memory
  holds content inline for free access; older content may only appear
  as a `◱hash=... gist=...◲` reference after compaction.

- **Halving compaction.** When context exceeds the limit, the first
  half of context (by line count) is dumped to a blob and replaced
  with a single ref. No LLM call, no chunking, no relevance scoring —
  just a clean fold. The agent can `UNCOMPACT` the ref to pull the
  original back inline, or `READ_BLOB` to peek without rehydrating.

- **Bus = files.** All inbound is `bus/<topic>/<id>.md`, append-only.
  Lines are tagged `[<sender_id> <ts>] <body>`. No special "user" or
  "agent" categories — every speaker is just an identity. Agents
  subscribe by symlinking into `agents/<self>/subs/`; the harness
  tails that dir each turn. Speaking is automatic: when the agent
  replies without calling a tool, its content auto-appends to
  `bus/chat/<self>.md`.

- **Email = file drop.** To message another agent, drop any file
  into `agents/<recipient>/email_inbox/`. Sender attribution is
  automatic and unforgeable — the watcher reads the file's owner UID
  via `stat()`. If the file contains a `Subject:` header followed by
  a blank line, the body is everything after; otherwise the whole
  file is the body. The watcher appends an email-shaped line to
  `bus/email_inbox/<recipient>.md`; the recipient sees it at the top
  of their next turn.

- **Transports are bridges.** Telegram, stdin, anything — independent
  processes that read/write the same files. The agent doesn't know or
  care about the transport.

## Running

```bash
pip install -r requirements.txt
export DEEPSEEK_API_KEY=...

# In one shell: the agent
python agent.py            # fresh boot: new identity
python agent.py <hash>     # resume an existing agent by its <self> hash

# In another shell: the email-inbox bridge (one process for all agents)
python inbox_watcher.py

# Talk to a running agent
python chat.py [room_id]
```

Defaults to `deepseek-v4-pro` via `api.deepseek.com`. Reasoning
content is captured and prepended to context inside `<reasoning>` tags.
Pass `--verbose` to print LIFE events to stdout.

Each fresh boot generates a new content-addressed identity: the agent
stashes a blob of its SOUL plus boot timestamp, and uses that hash as
its name. Two agents with the same SOUL booted at different times get
distinct identities; their state lives under `agents/<self>/`.

Edit `SOUL.md` to give the agent a purpose before running. Wipe runtime
state with `python clean.py`.

## Sending mail between agents

From inside an agent (via `BASH`):

```bash
cat > agents/<recipient_id>/email_inbox/$(date +%s) <<'EOF'
Subject: hello

body text, multi-line ok
EOF
```

Or from outside (operator, scripts):

```bash
echo "Subject: ping

are you alive?" > agents/<recipient>/email_inbox/$(date +%s)
```

Sender is whoever owns the file (the unix user running the script).
The watcher delivers within ~inotify latency; recipient sees it on
their next turn.
