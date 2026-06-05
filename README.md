# attobot

A persistent agent in ~400 lines of Python.

One agent = one `agents/<self>/` directory + one process running `agent.py <self>`.
The process is a loop that re-runs the LLM every time `messages.jsonl` changes.

## The loop

```
hash messages.jsonl
  if unchanged: sleep
  if too long: STASH_MESSAGES
  llm(<soul> + <harness> + <memory> + <life-tail>, messages, tools)
  append assistant reply
  if tool_calls: run each via bg.run, append results
  else: SEND_CHAT(content)
```

That's `agent.py`. Everything else is plumbing around it.

## Channels in

Three background threads append to `messages.jsonl`:

- **telegram** — `chat.py` long-polls `getUpdates`. Inbound text → `{role:user, content:"[telegram <id>] …"}`. Discovers `chat_id` on first message, persists to `agents/<self>/telegram_chat`.
- **cron** — `cron.py` scans `agents/<self>/cron/*.json` every 30s. Job format: `{"next": <ts>, "repeat_s": <s?>, "message": "…"}`. Due jobs append `{role:system, content:"[cron <name>] …"}`. Repeating jobs reschedule; one-shots delete.
- **mail** — `inbox_watcher.py` polls `agents/<self>/mail_inbox/`. New files append `{role:system, content:"[mail from <unix-user>] <name>\n<preview>"}` and notify the operator via chat.

## Channel out

`SEND_CHAT` writes back to telegram. There is no other output channel. Reply with no `tool_calls` → content goes to chat automatically.

## Tools

Auto-discovered from `tools/*.py` — each module exports `SCHEMA` (OpenAI function-tool format) and `run(args)`.

| name | what |
|---|---|
| `APPEND_MESSAGE` | inject a message into `messages.jsonl` (used by channels) |
| `SEND_CHAT` | post to telegram |
| `READ_FILE` / `WRITE_FILE` / `EDIT_FILE` | filesystem (SOUL.md is immutable) |
| `BASH` | run a shell command (returns Popen → bg can background it) |
| `SEARCH` / `WEB_FETCH` | DuckDuckGo + plain HTML scrape |
| `STASH` | content-addressed save to `blobs/<hash>` |
| `STASH_MESSAGES` | move first half of `messages.jsonl` to a blob, leave a `[stash <hash>]` placeholder |

A tool may return a `subprocess.Popen` (or anything with `.pid` + `.communicate`); `bg.run` handles the lifecycle.

## Backgrounding

`bg.run` runs the tool in a thread with `TOOL_TIMEOUT` (30s). Finishes in time → inline result. Otherwise:

- registers `agents/<self>/bg/<id>.json` (with pid if known)
- returns `[backgrounded bg/<id> — rm … to kill]` to the assistant immediately
- spawns an emitter thread that appends `[bg <id> done, tc:…] <result>` when the work finishes

Kill a backgrounded call by deleting its json file. The emitter SIGTERMs the pid (if any) and appends a `[bg <id> killed]` message.

## State

```
SOUL.md                       # the prompt, immutable
agent.py + chat/cron/...      # the harness, included verbatim in system prompt
agents/<self>/
  MEMORY.md                   # long-term memory, edited by the agent
  LIFE.md                     # append-only event log; tail goes into system prompt
  messages.jsonl              # canonical conversation, one JSON message per line
  telegram_token              # required at boot
  telegram_chat               # learned on first inbound message
  tg_poll.offset              # telegram update_id cursor
  cron/<name>.json            # scheduled jobs
  cron/heartbeat.json         # auto-created at boot, 60s tick
  mail_inbox/                 # drop files here
  bg/<id>.json                # in-flight background work
blobs/<hash>                  # content-addressed store (stash, stash_messages)
```

## System prompt

Built fresh every turn:

```
<soul>      SOUL.md (with <self> substituted)
<harness>   agent.py source
<memory>    MEMORY.md (middle-elided if > MEMORY_LIMIT)
<life>      last LIFE_TAIL lines of LIFE.md
```

The agent sees its own harness. Modify `agent.py` and the agent's self-model updates next turn.

## Memory pressure

- `MEMORY.md > MEMORY_LIMIT` (10000) → middle is elided with a warning telling the agent to shrink it.
- `len(messages.jsonl) > MSG_LIMIT` (200) → `STASH_MESSAGES` runs automatically, first half goes to a blob, replaced by a single system message holding `[stash <hash>]`. The agent can `READ_FILE blobs/<hash>` to recover.

## Run

```
pip install -r requirements.txt
echo $TELEGRAM_TOKEN > agents/myagent/telegram_token   # create the dir + drop the token
DEEPSEEK_API_KEY=… python agent.py myagent
```

No `<self>` argument → derived from `sha256(SOUL.md + boot-time)`; useful for ephemeral throwaway agents.

Config (env vars, all optional):

```
MODEL=deepseek-v4-pro            API_BASE=http://localhost:8181/deepseek/v1
BLOB_DIR=blobs                   AGENTS_DIR=agents
MSG_LIMIT=200                    MEMORY_LIMIT=10000
LIFE_TAIL=50                     TOOL_TIMEOUT=30
CRON_TICK=30                     INBOX_TICK=2
INBOX_PREVIEW=1000               TG_MAX=4000
```

Reads `.env` from cwd on startup.

## Principles

1. **The agent is a loop.** One process, one file watch, one LLM call per change.
2. **The bus is the filesystem.** Channels in, channels out, scheduled jobs, background work, memory — all files. No daemon, no queue, no IPC.
3. **Opinionated cuts code.** Telegram is the chat. DeepSeek is the model. One operator, one chat. No abstractions for things that aren't pluralized.
