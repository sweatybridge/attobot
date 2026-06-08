# attobot

A persistent agent in a single `agent.py`.

One agent = one `agents/<self>/` directory + one process running `agent.py <self>`.
The process is a loop that re-runs the LLM every time `messages.jsonl` changes.

## The loop

```
hash messages.jsonl
  if unchanged: sleep
  build system prompt + sum chars
  if over budget: stash_messages
  llm(<soul> + <harness> + <memory> + <life-tail>, messages, tools)
  append assistant reply
  if tool_calls: run each via bg_run, append results
  else: SEND_CHAT(content)
```

That's `agent.py`. Channels, tools, and the backgrounding wrapper all live inline in the same file.

## Channels in

Three daemon threads append to `messages.jsonl`:

- **telegram** — `start_chat()` long-polls `getUpdates`. Inbound text → `{role:user, content:"[telegram <id>] …"}`. Discovers `chat_id` on first message, persists to `agents/<self>/telegram_chat`.
- **cron** — `start_cron()` scans `agents/<self>/cron/*.json` every 30s. Job format: `{"next": <ts>, "repeat_s": <s?>, "message": "…"}`. Due jobs append `{role:system, content:"[cron <name>] …"}`. Repeating jobs reschedule; one-shots delete.
- **mail** — `start_inbox()` polls `agents/<self>/mail_inbox/`. New files append `{role:system, content:"[mail from <unix-user>] <name>\n<preview>"}` and notify the operator via chat.

## Channel out

`SEND_CHAT` writes back to telegram. There is no other output channel. Reply with no `tool_calls` → content goes to chat automatically.

## Tools

Declared in the `TOOLS` list in `agent.py`: `(NAME, fn, description, parameters)` per entry.

| name | what |
|---|---|
| `APPEND_MESSAGE` | inject a message into `messages.jsonl` (also used by channels) |
| `SEND_CHAT` | post to telegram |
| `READ_FILE` | file → line-numbered text; images → multimodal content blocks (when `MULTIMODAL_SUPPORT=true`) |
| `WRITE_FILE` / `EDIT_FILE` | filesystem writes (SOUL.md is immutable); `EDIT_FILE` has optional `replace_all` |
| `BASH` | run a shell command (returns Popen → `bg_run` can background it) |
| `SEARCH` / `WEB_FETCH` | DuckDuckGo + plain HTML scrape |
| `STASH` | content-addressed save to `blobs/<hash>`, returns `[stash <hash>]` |

A tool returning a `subprocess.Popen` (or anything with `.pid` + `.communicate`) gets handled by `bg_run`.

Tool results longer than `TOOL_OUTPUT_LIMIT` (5000 chars) are auto-clipped to `<head>\n... N chars truncated, [stash <hash>] ...\n<tail>`. The agent recovers the full content with `READ_FILE blobs/<hash>`.

## Backgrounding

`bg_run` runs the tool in a thread with `TOOL_TIMEOUT` (30s). Finishes in time → inline (post-clip) result. Otherwise:

- registers `agents/<self>/bg/<id>.json` (with pid if known)
- returns `[backgrounded bg/<id> — rm … to kill]` to the assistant immediately
- spawns an emitter thread that appends `[bg <id> done, tc:…] <result>` when the work finishes

Kill a backgrounded call by deleting its json file. The emitter SIGTERMs the pid (if any) and appends a `[bg <id> killed]` message.

## State

```
SOUL.md                       # the prompt template (copied to each agent at first boot)
agent.py                      # the harness, included verbatim in the system prompt
opt/
  tools/<name>.py             # optional capability tools (see Optional add-ons)
  providers/<name>.py         # alternative LLM providers
agents/<self>/
  SOUL.md                     # this agent's soul (copy of the template)
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
  tools/<name>.py             # opt-in tools (copied from opt/tools/ at first boot)
  providers/<name>.py         # opt-in provider (copied from opt/providers/ at first boot)
blobs/<hash>                  # content-addressed store, shared across agents
```

## System prompt

Built fresh every turn:

```
<soul>      agents/<self>/SOUL.md (with <self> substituted)
<harness>   agent.py source
<memory>    MEMORY.md (middle-elided if > MEMORY_LIMIT)
<life>      last LIFE_TAIL lines of LIFE.md, prefixed with [N earlier lines]
```

The agent sees its own harness. Modify `agent.py` and the agent's self-model updates next turn.

## Memory pressure

- `MEMORY.md > MEMORY_LIMIT` (10000) → middle is elided with a warning telling the agent to shrink it.
- System prompt + serialized messages, divided by 4 chars/token, > `CONTEXT_TOKENS * 0.8` → `stash_messages` runs automatically; the first half of `messages.jsonl` goes to a blob, replaced by a single system message holding `[stash <hash>]`. The agent can `READ_FILE blobs/<hash>` to recover.

The 4-chars-per-token heuristic over-counts base64 image content — safe direction.

## Optional add-ons

Anything under `opt/` is opt-in via the `OPT` env var (comma-separated paths relative to `opt/`, no `.py` suffix):

```
OPT=tools/ocr_image,tools/stash_messages,providers/anthropic
```

Each entry copies `opt/<path>.py` → `agents/<self>/<path>.py` at first boot. From then on, the agent owns its copy.

**Tools** in `agents/<self>/tools/` auto-register at startup. Built-in:
- `ocr_image` — RapidOCR + spatial ASCII layout, for text-only LLMs. Auto-included when `MULTIMODAL_SUPPORT=false`. Requires `rapidocr-onnxruntime` + `opencv-python`.
- `stash_messages` — surgical version with explicit `path` / `start` / `end` parameters; complements the harness's internal auto-stash.

**Providers** swap `_chat_fn`. Set `PROVIDER=anthropic` (auto-includes `providers/anthropic`) to use it. Built-in:
- `anthropic` — native `/v1/messages` translation. Set `ANTHROPIC_API_KEY` and `MODEL=claude-...`.

## Run

```
pip install -r requirements.txt
echo $TELEGRAM_TOKEN > agents/myagent/telegram_token   # create the dir + drop the token
API_KEY=… python agent.py myagent
```

Default: `kimi-k2.6` via `https://api.moonshot.ai/v1`. Override `MODEL` / `API_BASE` to point at any OpenAI-compatible endpoint, or set `PROVIDER=anthropic` to switch the request shape.

`python agent.py <self> [soul_path]` — second arg overrides the SOUL template (defaults to `./SOUL.md`). No `<self>` argument → derived from `sha256(soul_text)`; useful for ephemeral agents.

Config (env vars, all optional):

```
MODEL=kimi-k2.6              API_BASE=https://api.moonshot.ai/v1
TEMPERATURE=0.6              REASONING_EFFORT=medium
CONTEXT_TOKENS=100000
MEMORY_LIMIT=10000           LIFE_TAIL=50
TOOL_TIMEOUT=30              TOOL_OUTPUT_LIMIT=5000
CRON_TICK=30                 INBOX_TICK=2
INBOX_PREVIEW=1000           CHAT_MSG_MAX=4000
BLOB_DIR=blobs               AGENTS_DIR=agents
MULTIMODAL_SUPPORT=true      PROVIDER=
OPT=
```

Reads `.env` from cwd on startup.

## Principles

1. **The agent is a loop.** One process, one file watch, one LLM call per change.
2. **The bus is the filesystem.** Channels in, channels out, scheduled jobs, background work, memory — all files. No daemon, no queue, no IPC.
3. **Opinionated cuts code.** Telegram is the chat. One operator, one chat. Default is Kimi K2.6 via Moonshot, but anything OpenAI-shape works out of the box and other shapes live in `opt/providers/`. No abstractions for things that aren't pluralized.
