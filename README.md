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

Anything under `opt/` is opt-in via the `opt` field in `config.json` (a list of paths relative to `opt/`, no `.py` suffix):

```json
"opt": ["tools/ocr_image", "providers/anthropic"]
```

Each entry copies `opt/<path>.py` → `agents/<self>/<path>.py` at first boot. From then on, the agent owns its copy.

**Tools** in `agents/<self>/tools/` auto-register at startup. Built-in:
- `ocr_image` — RapidOCR + spatial ASCII layout, for text-only LLMs. Auto-included when `multimodal_support=false`. Requires `rapidocr-onnxruntime` + `opencv-python`.

**Providers** swap `_chat_fn`. Set `provider: "anthropic"` (auto-includes `providers/anthropic`) to use it. Built-in:
- `anthropic` — native `/v1/messages` translation. Reads `api_key` and `model` from `config.json` like the default provider.

## Run

```
pip install -r requirements.txt
python setup.py myagent                            # prompts for token, auto-discovers chat_id, prompts for api_key
python agent.py myagent
```

`setup.py` accepts CLI args for non-interactive use (e.g. an HR-style agent spawning new agents):

```
python setup.py newhire --token 123:abc --chat -1001234567 --api-key sk-... [--thread 42] [--systemd]
```

Required config (`agents/<self>/config.json`) is created by `setup.py`. It validates `GET /getMe` and refuses to proceed if the bot's privacy mode is on or `can_join_groups` is off.

## Deploy

On macOS or for quick testing, just run `python agent.py myagent` (use `tmux` to keep it alive across logout).

On Linux, run `setup.py --systemd` to emit a systemd template unit + install instructions:

```bash
python setup.py myagent --systemd
# wrote agents/myagent/config.json
# wrote attobot@.service
#
# Install once (user service, no sudo):
#   mkdir -p ~/.config/systemd/user
#   cp attobot@.service ~/.config/systemd/user/
#   systemctl --user daemon-reload
#   loginctl enable-linger $USER          # so it survives logout
#
# Then for each agent:
#   systemctl --user enable --now attobot@myagent
#   journalctl --user -u attobot@myagent -f
```

Same template handles N agents — `attobot@newhire`, etc. Per the project's "new unix user per agent" convention, run `setup.py --systemd` as the dedicated user so user-mode systemd lives in their `$HOME`.

Default: `kimi-k2.6` via `https://api.moonshot.ai/v1`. Override `model` / `api_base` in `config.json` to point at any OpenAI-compatible endpoint, or set `provider: "anthropic"` to switch the request shape.

`python agent.py <self> [soul_path]` — second arg overrides the SOUL template (defaults to `./SOUL.md`). No `<self>` argument → derived from `sha256(soul_text)`; useful for ephemeral agents.

`agents/<self>/config.json` fields (only `telegram_token`, `telegram_chat_id`, `api_key` are required — the rest fall back to sensible defaults baked into `agent.py`):

```jsonc
{
  "telegram_token": "...",         // required
  "telegram_chat_id": "...",       // required
  "telegram_thread_id": "...",     // optional, forum supergroup topic
  "api_key": "...",                // required, LLM provider key
  "model": "kimi-k2.6",
  "api_base": "https://api.moonshot.ai/v1",
  "temperature": 1.0,
  "reasoning_effort": "medium",
  "context_tokens": 100000,
  "multimodal_support": true,
  "provider": "",                  // "" = openai-compat default; "anthropic" loads opt/providers/anthropic
  "opt": []                        // additional opt/ entries to copy in
}
```

Constants tuned in-source (rarely worth changing): `LIFE_TAIL`, `MEMORY_LIMIT`, `TOOL_TIMEOUT`, `CRON_TICK`, `INBOX_TICK`, `INBOX_PREVIEW`, `CHAT_MSG_MAX`, `TOOL_OUTPUT_LIMIT`, `AGENTS_DIR`, `BLOB_DIR`.

## Principles

1. **The agent is a loop.** One process, one file watch, one LLM call per change.
2. **The bus is the filesystem.** Channels in, channels out, scheduled jobs, background work, memory — all files. No daemon, no queue, no IPC.
3. **Opinionated cuts code.** Telegram is the chat. One operator, one chat. Default is Kimi K2.6 via Moonshot, but anything OpenAI-shape works out of the box and other shapes live in `opt/providers/`. No abstractions for things that aren't pluralized.
