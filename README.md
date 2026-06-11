# attobot

A persistent agent in a single `agent.py`.

One agent = one working directory (in production, one unix user's `$HOME`) + one process running `agent.py`. All agent state lives in `./agent/`.
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

- **telegram** — `start_chat()` long-polls `getUpdates`. Inbound text → `{role:user, content:"[telegram <id>] …"}`. Only the `chat_id`/`thread_id` locked in `config.json` is accepted. Optional: no `telegram_token` in config → no chat channel, `SEND_CHAT` returns "no chat configured"; the agent wakes on triggers/mail only.
- **triggers** — `start_triggers()` scans `agent/triggers/*.json` every 30s; due ones append `{role:system, content:"[trigger <name>] …"}`. Three kinds: a **cron** — `{"next": <ts>, "repeat_s": <s?>, "message": "…"}` — fires on the clock (repeating ones reschedule, one-shots delete); a **watch** — `{"watch": "<path>", "repeat_s": <cooldown?>, "message": "…"}` — fires when the file's content changes; a **cmd** — `{"cmd": "<shell>", "repeat_s": <s?>}` — runs the command and fires with its stdout (clipped), no output = no fire. Combined with `watch`, the cmd runs when the file grows and gets only the new bytes on stdin, starting from install — `[trigger`/`[subconscious]` lines are filtered and its own fires absorbed, so heuristics structurally can't self-loop or ping-pong. A repeating trigger with `"backoff": <cap_s>` is idle-aware: every turn defers its `next`; an idle (no-tool-call) turn doubles the interval toward the cap, an active turn resets it to `repeat_s`. The heartbeat is just a shipped backoff cron.
- **mail** — `start_inbox()` polls `agent/mail_inbox/`. New files append `{role:system, content:"[mail from <unix-user>] <name>\n<preview>"}` and notify the operator via chat.

## Channel out

`SEND_CHAT` writes back to telegram. There is no other output channel. Reply with no `tool_calls` → content goes to chat automatically.

## Tools

Declared in the `TOOLS` list in `agent.py`: `(NAME, fn, description, parameters)` per entry.

| name | what |
|---|---|
| `APPEND_MESSAGE` | inject a message into an agent's `messages.jsonl` (default own; `dir` targets a sibling agent, which wakes on it; also surfaced to the target's chat if it has one) |
| `SEND_CHAT` | post to telegram |
| `READ_FILE` | file → line-numbered text; images → multimodal content blocks (when `MULTIMODAL_SUPPORT=true`) |
| `WRITE_FILE` / `EDIT_FILE` | filesystem writes; `EDIT_FILE` has optional `replace_all` |
| `BASH` | run a shell command (returns Popen → `bg_run` can background it) |
| `SEARCH` / `WEB_FETCH` | DuckDuckGo + plain HTML scrape |
| `STASH` | content-addressed save to `agent/blobs/<hash>`, returns `[stash <hash>]` |

A tool returning a `subprocess.Popen` (or anything with `.pid` + `.communicate`) gets handled by `bg_run`.

Tool results longer than `tool_output_limit` (5000 chars) are auto-clipped to `<head>\n... N chars truncated, [stash <hash>] ...\n<tail>`. The agent recovers the full content with `READ_FILE agent/blobs/<hash>`.

## Backgrounding

`bg_run` runs the tool in a thread with `tool_timeout` (30s). Finishes in time → inline (post-clip) result. Otherwise:

- registers `agent/bg/<id>.json` (with pid if known)
- returns `[backgrounded bg/<id> (pid …)]` to the assistant immediately
- spawns an emitter thread that appends `[bg <id> done, tc:…] <result>` when the work finishes (and removes the json)

Kill a backgrounded subprocess by killing its pid (recorded in the json and the placeholder); the emitter then reports `[bg <id> done] (exit -15)`.

## State

```
SOUL.md                       # the prompt template (copied into agent/ by setup.py)
agent.py                      # the harness, included verbatim in the system prompt
opt/
  tools/<name>.py             # optional capability tools (see Optional add-ons)
  providers/<name>.py         # alternative LLM providers
  subconscious/               # reviewer agent skeleton (soul + seeded trigger), copied out beside agent/
agent/
  SOUL.md                     # this agent's soul (copy of the template)
  MEMORY.md                   # memory index: one pointer line per memory
  memory/<name>.md            # memory bodies, read on demand via the index
  LIFE.md                     # append-only event log; tail goes into system prompt
  messages.jsonl              # canonical conversation, one JSON message per line
  config.json                 # telegram token/chat, api key, overrides
  tg_poll.offset              # telegram update_id cursor
  triggers/<name>.json        # crons (clock) and watches (file change)
  triggers/heartbeat.json     # auto-created at boot, 225s tick (backs off when idle)
  mail_inbox/                 # drop files here
  bg/<id>.json                # in-flight background work
  tools/<name>.py             # opt-in tools (copied from opt/tools/ at first boot)
  providers/<name>.py         # opt-in provider (copied from opt/providers/ at first boot)
  blobs/<hash>                # content-addressed store
```

## System prompt

Built fresh every turn:

```
<soul>      agent/SOUL.md
<harness>   agent.py source
<memory>    MEMORY.md (middle-elided if > MEMORY_LIMIT)
<life>      last life_tail lines of LIFE.md, prefixed with [N bytes earlier]
```

The agent sees its own harness. Modify `agent.py` and the agent's self-model updates next turn.

## Memory pressure

- Memory is two-tier: `MEMORY.md` is an always-in-context index (one pointer line per memory), bodies live in `agent/memory/` and are read on demand. `MEMORY.md > MEMORY_LIMIT` (10000) → middle is elided with a warning telling the agent to move detail into `agent/memory/` files.
- System prompt + serialized messages, divided by 4 chars/token, > `context_tokens * 0.8` → `stash_messages` runs automatically; the middle half of `messages.jsonl` goes to a blob, replaced by a single system message holding `[stash <hash>]` plus an LLM summary. The agent can `READ_FILE agent/blobs/<hash>` to recover.

The 4-chars-per-token heuristic over-counts base64 image content — safe direction.

## Optional add-ons

Anything under `opt/` is opt-in via the `opt` field in `config.json` (a list of paths relative to `opt/`, no `.py` suffix):

```json
"opt": ["tools/ocr_image", "providers/anthropic"]
```

Each entry copies `opt/<path>.py` → `agent/<path>.py` at first boot. From then on, the agent owns its copy.

**Tools** in `agent/tools/` auto-register at startup. Built-in:
- `ocr_image` — RapidOCR + spatial ASCII layout, for text-only LLMs. Auto-included when `multimodal_support=false`. Requires `rapidocr-onnxruntime` + `opencv-python`.

**Providers** swap `_chat_fn`. Set `provider: "anthropic"` (auto-includes `providers/anthropic`) to use it. Built-in:
- `anthropic` — native `/v1/messages` translation. Reads `api_key` and `model` from `config.json` like the default provider.

## Subconscious

A second attobot that reviews the first. Same harness, different soul (`opt/subconscious/` — an agent-dir skeleton: soul + a pre-seeded watch job), no chat. It runs in the same unix user as the primary — it needs direct read/write into `agent/` — unlike peer agents, which get a user each.

```bash
python setup.py --subconscious ...   # copies opt/subconscious/ out beside agent/, reuses the api_key
python agent.py agent subconscious   # one command, one process per dir
```

For an existing install: `cp -r opt/subconscious . && echo '{"api_key": "sk-..."}' > subconscious/config.json`.

It wakes when the primary's stream changes (a pre-seeded watch trigger on `agent/messages.jsonl`, 600s cooldown) or on its own heartbeat, reads `agent/messages.jsonl` / `agent/LIFE.md` since its last review marker, and acts two ways: `APPEND_MESSAGE` — a `[subconscious] …` system message injected into the primary's stream (the tool serializes, so the stream can't be corrupted) and surfaced to the operator's chat — for nudges and proposed lessons (the primary folds accepted lessons into `MEMORY.md` itself, in its own words); and for mistakes that keep recurring, `subc-*` cmd triggers installed in `agent/triggers/` — compiled heuristics that grep the stream and inject a warning with no LLM in the loop. Every heuristic fire is greppable by name, so the subconscious reviews its own heuristics' precision and retires bad ones. It writes nothing else of the primary's.

## Run

```
pip install -r requirements.txt
python setup.py                            # prompts for token, auto-discovers chat_id, prompts for api_key
python agent.py
```

`setup.py` accepts CLI args for non-interactive use (e.g. an HR-style agent spawning new agents):

```
python setup.py --token 123:abc --chat -1001234567 --api-key sk-... [--thread 42] [--systemd]
```

Required config (`agent/config.json`) is created by `setup.py`. It validates `GET /getMe` and refuses to proceed if the bot's privacy mode is on or `can_join_groups` is off.

## Deploy

One agent per unix user: give the agent its own user, clone this repo into their `$HOME`, run `setup.py` and `agent.py` from there. The agent owns its copy of the harness; editing it affects no other agent.

On macOS or for quick testing, just run `python agent.py` (use `tmux` to keep it alive across logout).

On Linux, run `setup.py --systemd` as the dedicated user to emit a systemd unit + install instructions:

```bash
python setup.py --systemd
# wrote agent/config.json
# wrote attobot.service
#
# Install (user service, no sudo):
#   mkdir -p ~/.config/systemd/user
#   cp attobot.service ~/.config/systemd/user/
#   systemctl --user daemon-reload
#   loginctl enable-linger $USER          # so it survives logout
#   systemctl --user enable --now attobot
#   journalctl --user -u attobot -f
```

Default: `kimi-k2.6` via `https://api.moonshot.ai/v1`. Override `model` / `api_base` in `config.json` to point at any OpenAI-compatible endpoint, or set `provider: "anthropic"` to switch the request shape.

`python agent.py [agent_dir ...]` — the arg is the agent state folder (default `./agent`); same optional arg on `setup.py`. It must hold `config.json` and `SOUL.md` (`setup.py` creates both). Extra dirs each get their own process (`python agent.py agent subconscious` runs the pair; ctrl-C kills both).

`agent/config.json` fields (only `api_key` is required — omit `telegram_token` for a chat-less agent; the rest fall back to sensible defaults baked into `agent.py`):

```jsonc
{
  "telegram_token": "...",         // optional — omit for no chat channel
  "telegram_chat_id": "...",       // required if telegram_token is set
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

Tunables with defaults in `CFG` (rarely worth changing, override in `config.json`): `life_tail`, `memory_limit`, `tool_timeout`, `trigger_tick`, `inbox_tick`, `inbox_preview`, `chat_msg_max`, `tool_output_limit`. `AGENT_DIR` / `BLOB_DIR` are in-source constants.

## Principles

1. **The agent is a loop.** One process, one file watch, one LLM call per change.
2. **The bus is the filesystem.** Channels in, channels out, scheduled jobs, background work, memory — all files. No daemon, no queue, no IPC.
3. **Opinionated cuts code.** Telegram is the chat. One operator, one chat. Default is Kimi K2.6 via Moonshot, but anything OpenAI-shape works out of the box and other shapes live in `opt/providers/`. No abstractions for things that aren't pluralized.
