#!/usr/bin/env python3
"""Minimal agent."""
import base64, fcntl, hashlib, importlib.util, json, mimetypes, os, pathlib, pwd, requests, shutil, subprocess, sys, threading, time
sys.modules.setdefault("agent", sys.modules[__name__])

AGENT_DIR = sys.argv[1] if len(sys.argv) > 1 else "agent"
BLOB_DIR = f"{AGENT_DIR}/blobs"

CFG = { # defaults
    "model": "kimi-k2.6",
    "api_base": "https://api.moonshot.ai/v1",
    "temperature": 1.0,
    "reasoning_effort": "medium",
    "context_tokens": 100000,
    "multimodal_support": True,
    "provider": "",
    "opt": [],
    "life_tail": 50,
    "memory_limit": 10000,
    "tool_timeout": 30,
    "trigger_tick": 30,
    "inbox_tick": 2,
    "inbox_preview": 1000,
    "chat_msg_max": 4000,
    "tool_output_limit": 5000,
}

os.makedirs(BLOB_DIR, exist_ok=True)
os.makedirs(f"{AGENT_DIR}/memory", exist_ok=True)

def life(event, agent_dir=AGENT_DIR):
    with open(f"{agent_dir}/LIFE.md", "a") as f:
        f.write(f"[{time.strftime('%Y%m%dT%H%M%S')}] {event}\n")

def _preview(s, n=100):
    if not isinstance(s, str):
        s = repr(s)
    if len(s) <= n:
        return s
    h = n // 2
    return f"{s[:h]}…{s[-h:]}"

def _parse_msg(line):
    """The only way a line becomes a message: a json dict, or None — anything else isn't a message."""
    try: m = json.loads(line)
    except Exception: return None
    return m if isinstance(m, dict) else None

def load_messages():
    """The stream is a sequence of json values; the messages are the dicts with a role.
    Scanning value-by-value makes torn writes (fused or truncated lines) a non-event."""
    s, dec, out, i = open(f"{AGENT_DIR}/messages.jsonl").read(), json.JSONDecoder(), [], 0
    while i < len(s):
        if s[i].isspace():
            i += 1
            continue
        try:
            obj, i = dec.raw_decode(s, i)
            if isinstance(obj, dict) and "role" in obj:
                out.append(obj)
        except json.JSONDecodeError:
            i += 1  # garbage byte — skip; whatever parses next is recovered
    return out

_append_lock = threading.RLock()

def _msg_summary(m):
    role = m.get("role", "?")
    if role == "assistant" and m.get("tool_calls"):
        calls = ", ".join(
            f"{tc['function']['name']}({tc['function'].get('arguments', '')})"
            for tc in m["tool_calls"]
        )
        content = m.get("content") or ""
        return _preview(f"assistant {calls}" + (f" {content}" if content else ""))
    if role == "tool":
        return f"tool {m.get('tool_call_id', '?')}: {_preview(m.get('content', ''))}"
    return f"{role}: {_preview(m.get('content', ''))}"

def append_msg(m, agent_dir=AGENT_DIR):
    with _append_lock:
        with open(f"{agent_dir}/messages.jsonl", "a") as f:
            fcntl.flock(f, fcntl.LOCK_EX)
            f.write(json.dumps(m) + "\n")
    life(_msg_summary(m), agent_dir)

def _default_chat(messages, tools):
    body = {
        "model": CFG["model"],
        "messages": messages,
        "temperature": CFG["temperature"],
    }
    if CFG["reasoning_effort"]:
        body["reasoning_effort"] = CFG["reasoning_effort"]
    if tools:
        body["tools"] = tools
    r = requests.post(f"{CFG['api_base']}/chat/completions",
        headers={"Authorization": f"Bearer {CFG['api_key']}"},
        json=body, timeout=120)
    data = r.json()
    if "choices" not in data:
        if 400 <= r.status_code < 500 and r.status_code != 429:
            sys.exit(f"fatal llm error {r.status_code}: {data}")  # bad key/model/request — retrying won't help
        raise RuntimeError(f"{r.status_code}: {data}")
    return data["choices"][0]["message"]

_chat_fn = _default_chat

def llm(messages, tools=None):
    delay = 1
    while True:
        try:
            return _chat_fn(messages, tools)
        except Exception as e:
            append_msg({"role": "system", "content": f"[llm retry in {delay}s] {e}"})
            time.sleep(delay)
            delay = min(delay * 2, 900)

# ---------- tools ----------

_TG_MEDIA = {ext: (f"send{kind}", kind.lower())
             for kind, exts in {"Photo": "jpg jpeg png gif webp", "Video": "mp4 mov webm",
                                "Voice": "ogg", "Audio": "mp3 m4a wav"}.items() for ext in exts.split()}

def _tg_send(endpoint, payload, files=None, cfg=None):
    """Post to an agent's chat via the telegram API; returns an error string or None. Failures land in LIFE."""
    cfg = cfg or CFG
    payload = {"chat_id": cfg["telegram_chat_id"], **payload}
    if cfg.get("telegram_thread_id"):
        payload["message_thread_id"] = cfg["telegram_thread_id"]
    r = requests.post(f"https://api.telegram.org/bot{cfg['telegram_token']}/{endpoint}",
                      data=payload, files=files, timeout=60)
    data = r.json()
    if not data.get("ok"):
        life(f"[send_chat error] {data}")
        return f"telegram error: {data.get('description', data)}"
    return None

def send_chat(args):
    if not CFG.get("telegram_token"):
        return "no chat configured"
    text = args.get("text", "")
    if path := args.get("path"):
        ext = pathlib.Path(path).suffix.lower().lstrip(".")
        endpoint, field = _TG_MEDIA.get(ext, ("sendDocument", "document"))
        with open(path, "rb") as f:
            err = _tg_send(endpoint, {"caption": text[:1024]}, files={field: f})
        result = err or f"sent {field} {path}"
    else:
        errors = [err for i in range(0, len(text), CFG["chat_msg_max"])
                  if (err := _tg_send("sendMessage", {"text": text[i:i+CFG['chat_msg_max']]}))]
        result = errors[0] if errors else "sent"
    while _pending_reactions:
        _react(_pending_reactions.pop(), "")
    return result

def stash(content):
    h = hashlib.sha256(content.encode()).hexdigest()[:12]
    open(f"{BLOB_DIR}/{h}", "w").write(content)
    return f"[stash {h}]"

def clip(s):
    if not isinstance(s, str) or len(s) <= CFG["tool_output_limit"]:
        return s
    h = CFG["tool_output_limit"] // 2
    return f"{s[:h]}\n... {len(s) - 2*h} chars truncated, {stash(s)} ...\n{s[-h:]}"

IMAGE_EXTS = {".png", ".jpg", ".jpeg", ".gif", ".webp"}

def read_file(args):
    path = args["path"]
    if pathlib.Path(path).suffix.lower() in IMAGE_EXTS and CFG["multimodal_support"]:
        mime = mimetypes.guess_type(path)[0] or "application/octet-stream"
        b64 = base64.b64encode(open(path, "rb").read()).decode()
        return [{"type": "image_url", "image_url": {"url": f"data:{mime};base64,{b64}"}}]
    return "\n".join(f"{i+1}\t{line}" for i, line in enumerate(open(path).read().splitlines()))

def write_file(args):
    path = args["path"]
    open(path, "w").write(args["content"])
    return f"wrote {path} ({len(args['content'])} chars)"

def edit_file(args):
    path, old, new = args["path"], args["old"], args["new"]
    text = open(path).read()
    count = text.count(old)
    if not args.get("replace_all") and count != 1:
        return f"error: OLD must appear exactly once in {path} (found {count}; pass replace_all to replace every occurrence)"
    if count == 0:
        return f"error: OLD not found in {path}"
    open(path, "w").write(text.replace(old, new))
    return f"edited {path}" + (f" ({count} replacements)" if args.get("replace_all") else "")

def bash(args):
    return subprocess.Popen(args["cmd"], shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)

def search(args):
    from ddgs import DDGS
    n = min(args.get("n", 5), 10)
    try:
        results = list(DDGS().text(args["query"], max_results=n))
        return "\n\n".join(f"{i+1}. {r['title']}\n   {r['href']}\n   {r['body']}" for i, r in enumerate(results)) or "(no results)"
    except Exception as e:
        return f"search error: {e}"

def web_fetch(args):
    from markdownify import markdownify
    url = args["url"]
    if url.startswith("http://"):
        url = "https://" + url[7:]
    try:
        r = requests.get(url, headers={"User-Agent": "Mozilla/5.0"}, timeout=15)
        r.raise_for_status()
        return markdownify(r.text, heading_style="ATX", strip=["script", "style"]).strip()
    except Exception as e:
        return f"fetch error: {e}"

def stash_messages(args):
    path = args.get("path") or f"{AGENT_DIR}/messages.jsonl"

    with open(path) as f:
        fcntl.flock(f, fcntl.LOCK_SH)
        lines = f.read().splitlines()
    n = len(lines)

    if "start" in args and "end" in args:
        s, e = int(args["start"]) - 1, int(args["end"])
        if s < 0 or e > n or s >= e:
            return f"error: invalid range start={args['start']} end={args['end']} (file has {n} lines)"
    else:
        s, e = n // 4, (3 * n) // 4

    while s < n and (_parse_msg(lines[s]) or {}).get("role") not in ("user", "system"):
        s += 1
    while e < n and (_parse_msg(lines[e]) or {}).get("role") not in ("user", "system"):
        e += 1
    if s >= e:
        return "nothing safe to stash"
    start, end = s + 1, e

    target = "\n".join(lines[s:e])
    try:
        response = _chat_fn(
            [{"role": "user", "content": "Summarize this conversation segment in 2-4 sentences. Be terse, factual.\n\n" + target}],
            None,
        )
        summary = (response.get("content") or "").strip()
    except Exception as exc:
        summary = f"(summary failed: {exc})"
    marker = stash(target)
    placeholder = json.dumps({"role": "system", "content": f"<lines {start}-{end} stashed: {marker}>\nsummary: {summary}"})

    with open(path, "r+") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        content = f.read()
        if target not in content:
            return "error: target range no longer in file (file was modified)"
        new_content = content.replace(target, placeholder, 1)
        f.seek(0)
        f.truncate()
        f.write(new_content)
    return f"stashed lines {start}-{end} ({end-start+1} → 1). summary: {_preview(summary)}"

def append_message(args):
    d = args.get("dir") or AGENT_DIR
    append_msg({"role": args.get("role", "system"), "content": args["content"]}, d)
    if d != AGENT_DIR:  # foreign injection also surfaces to the target's chat
        try:
            tcfg = json.loads(open(f"{d}/config.json").read())
            if tcfg.get("telegram_token"):
                _tg_send("sendMessage", {"text": args["content"][:4000]}, cfg=tcfg)
        except Exception:
            pass
    return f"appended to {d}/messages.jsonl"

TOOLS = [
    ("APPEND_MESSAGE", append_message, "Inject a message into an agent's messages.jsonl (default: your own). The owning agent wakes on it. `dir` targets a sibling agent dir — the message also surfaces to that agent's chat if it has one. `role` defaults to system.",
        {"type": "object", "properties": {"content": {"type": "string"}, "role": {"type": "string"}, "dir": {"type": "string"}}, "required": ["content"]}),
    ("SEND_CHAT", send_chat, "Send a message to the chat. With just `text`, sends a normal text message. With `path`, sends that file as an attachment (photo for images, voice for .ogg, video for .mp4, audio for .mp3/.m4a/.wav, document otherwise); `text` becomes the caption (capped at 1024 chars by telegram).",
        {"type": "object", "properties": {"text": {"type": "string"}, "path": {"type": "string"}}, "required": ["text"]}),
    ("READ_FILE", read_file, "Read a file.",
        {"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]}),
    ("WRITE_FILE", write_file, "Overwrite a file.",
        {"type": "object", "properties": {"path": {"type": "string"}, "content": {"type": "string"}}, "required": ["path", "content"]}),
    ("EDIT_FILE", edit_file, "Replace OLD with NEW in a file. Default: OLD must appear exactly once. Pass replace_all=true to replace every occurrence.",
        {"type": "object", "properties": {"path": {"type": "string"}, "old": {"type": "string"}, "new": {"type": "string"}, "replace_all": {"type": "boolean"}}, "required": ["path", "old", "new"]}),
    ("BASH", bash, "Run a shell command.",
        {"type": "object", "properties": {"cmd": {"type": "string"}}, "required": ["cmd"]}),
    ("SEARCH", search, "Search the web via DuckDuckGo. Returns title, URL, and snippet for up to 10 results.",
        {"type": "object", "properties": {"query": {"type": "string"}, "n": {"type": "integer"}}, "required": ["query"]}),
    ("WEB_FETCH", web_fetch, "Fetch and extract text from a URL.",
        {"type": "object", "properties": {"url": {"type": "string"}}, "required": ["url"]}),
    ("STASH", lambda args: stash(args["content"]), "Save text to a blob, return [stash <hash>].",
        {"type": "object", "properties": {"content": {"type": "string"}}, "required": ["content"]}),
    ("STASH_MESSAGES", stash_messages, "Collapse a line range of a messages.jsonl (default: your own, middle half) into one [stash <hash>] line with an LLM summary. 1-indexed, end inclusive, snapped to turn boundaries. Line numbers shift afterwards — re-read, or stash bottom-up.",
        {"type": "object", "properties": {"path": {"type": "string"}, "start": {"type": "integer"}, "end": {"type": "integer"}}}),
]
TOOL_FNS = {n: f for n, f, _, _ in TOOLS}
TOOL_SCHEMAS = [{"type": "function", "function": {"name": n, "description": d, "parameters": p}} for n, _, d, p in TOOLS]

def _load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod

def load_agent_tools():
    for path in sorted(pathlib.Path(f"{AGENT_DIR}/tools").glob("*.py")):
        mod = _load_module(path.stem, path)
        TOOL_FNS[mod.NAME] = mod.run
        TOOL_SCHEMAS.append({"type": "function", "function": {
            "name": mod.NAME, "description": mod.DESCRIPTION, "parameters": mod.PARAMETERS}})

def _load_provider():
    global _chat_fn
    _chat_fn = _load_module(f"provider_{CFG['provider']}", f"{AGENT_DIR}/providers/{CFG['provider']}.py").chat

# ---------- background tool wrapper ----------

def bg_run(name, args, tool_call_id, tool_fn):
    bg_id = hashlib.sha256(f"{tool_call_id}{time.time()}".encode()).hexdigest()[:8]
    bg_dir = pathlib.Path(f"{AGENT_DIR}/bg")
    bg_dir.mkdir(parents=True, exist_ok=True)
    holder = {"result": None, "done": False, "pid": None}

    def work():
        try:
            r = tool_fn(args)
            if hasattr(r, "pid") and hasattr(r, "communicate"):
                holder["pid"] = r.pid
                out, _ = r.communicate()
                holder["result"] = clip(out or f"(exit {r.returncode})")
            else:
                holder["result"] = clip(r)
        except Exception as e:
            holder["result"] = f"error: {e}"
        finally:
            holder["done"] = True

    t = threading.Thread(target=work, daemon=True)
    t.start()
    t.join(CFG["tool_timeout"])
    if holder["done"]:
        return holder["result"]

    json_path = bg_dir / f"{bg_id}.json"
    json_path.write_text(json.dumps({
        "name": name, "tool_call_id": tool_call_id,
        "pid": holder.get("pid"), "started": time.time(),
    }))

    def emit():
        t.join()
        append_msg({"role": "system", "content": f"[bg {bg_id} done, tc:{tool_call_id}] {holder['result']}"})
        try: json_path.unlink()
        except Exception: pass

    threading.Thread(target=emit, daemon=True).start()
    pid_info = f" (pid {holder['pid']})" if holder.get("pid") else ""
    return f"[backgrounded bg/{bg_id}{pid_info} — see {AGENT_DIR}/bg/{bg_id}.json; kill the pid to stop it]"

# ---------- channels ----------

def start_chat():
    token = CFG["telegram_token"]
    locked_cid = CFG["telegram_chat_id"]
    locked_tid = CFG.get("telegram_thread_id")
    poll_offset = pathlib.Path(f"{AGENT_DIR}/tg_poll.offset")

    def poll_in():
        try: offset = int(poll_offset.read_text())
        except (FileNotFoundError, ValueError): offset = 0
        while True:
            try:
                r = requests.post(f"https://api.telegram.org/bot{token}/getUpdates",
                                  data={"offset": offset, "timeout": 25}, timeout=45)
                updates = r.json().get("result") or []
                for u in updates:
                    offset = u["update_id"] + 1
                    msg = u.get("message") or {}
                    msg_cid = str((msg.get("chat") or {}).get("id") or "")
                    tid_raw = msg.get("message_thread_id")
                    msg_tid = str(tid_raw) if tid_raw is not None else None
                    if msg_cid != locked_cid or msg_tid != locked_tid:
                        continue  # not our chat/topic — drop silently (no bus, no LIFE)
                    if msg.get("photo"):
                        file_id = max(msg["photo"], key=lambda p: p.get("file_size", 0))["file_id"]
                    else:
                        file_id = next((msg[k]["file_id"] for k in ("document", "voice", "video", "audio") if msg.get(k)), None)
                    body = msg.get("text") or ""
                    if file_id:
                        meta = requests.get(f"https://api.telegram.org/bot{token}/getFile",
                                            params={"file_id": file_id}, timeout=30).json()
                        rel = meta["result"]["file_path"]
                        blob = requests.get(f"https://api.telegram.org/file/bot{token}/{rel}", timeout=60).content
                        inbound = pathlib.Path(f"{AGENT_DIR}/inbound")
                        inbound.mkdir(parents=True, exist_ok=True)
                        save = inbound / f"{u['update_id']}_{rel.rsplit('/', 1)[-1]}"
                        save.write_bytes(blob)
                        caption = msg.get("caption") or ""
                        body = f"(file: {save})" + (f" {caption}" if caption else "")
                    if not body:
                        continue
                    append_msg({"role": "user", "content": f"[telegram {u['update_id']}] {body}"})
                    if mid := msg.get("message_id"):
                        _pending_reactions.append(mid)
                        _react(mid, "👀")
                if updates:
                    poll_offset.write_text(str(offset))
            except Exception as e:
                life(f"[chat error] {e}")  # transient channel hiccup — log only, don't wake
                time.sleep(5)

    threading.Thread(target=poll_in, daemon=True, name="chat-poll").start()

def _is_machinery(line):
    """A genuine harness system message (trigger fire / subconscious note) — not e.g. an operator quoting one."""
    m = _parse_msg(line) or {}
    return m.get("role") == "system" and str(m.get("content", "")).startswith(("[trigger ", "[subconscious]"))

def start_triggers():
    """Only this thread writes trigger files. Its sole contract with the turn loop is the
    stream itself: fires are appended to it, and the agent's replies read back from it are
    the verdicts (hold while unanswered, back off on [IDLE])."""
    trig_dir = pathlib.Path(f"{AGENT_DIR}/triggers")
    trig_dir.mkdir(parents=True, exist_ok=True)
    heartbeat = trig_dir / "heartbeat.json"
    if not heartbeat.exists():
        heartbeat.write_text(json.dumps({"next": time.time() + 225, "repeat_s": 225, "backoff": 3600, "message": "tick"}))
    stream = f"{AGENT_DIR}/messages.jsonl"
    pending, cursor = set(), 0  # unanswered fires + how far we've read our own stream

    def adjust(fired, active):
        # the reply is the verdict: defer every backoff trigger; reset the ones that woke
        # this turn if it did work, double them toward the cap if it was [IDLE]
        for f in trig_dir.glob("*.json"):
            try:
                job = json.loads(f.read_text())
                if not job.get("backoff"): continue
                cur = job.get("cur_s", job["repeat_s"])
                if f.stem in fired:
                    cur = job["repeat_s"] if active else min(cur * 2, job["backoff"])
                    job["cur_s"] = cur
                job["next"] = time.time() + cur
                f.write_text(json.dumps(job))
            except Exception: continue

    def consume(verdict=True):
        # advance over new stream lines: track unanswered fires, verdict each assistant turn
        nonlocal cursor
        try: size = os.path.getsize(stream)
        except OSError: return
        if size < cursor:  # stash rewrote the stream: rebuild the view, don't replay verdicts
            cursor, verdict = 0, False
            pending.clear()
        if size == cursor: return
        with open(stream, "rb") as sf:
            sf.seek(cursor)
            raw = sf.read(size - cursor)
        whole = raw.rfind(b"\n") + 1  # a partially-written tail line waits for the next tick
        cursor += whole
        for line in raw[:whole].decode("utf-8", errors="replace").splitlines():
            if not (m := _parse_msg(line)):
                continue
            c = m.get("content")
            if m.get("role") == "assistant":
                if verdict:
                    idle = not m.get("tool_calls") and (not c or str(c).strip().startswith("[IDLE]"))
                    adjust(pending, active=not idle)
                pending.clear()
            elif m.get("role") == "system" and isinstance(c, str) and c.startswith("[trigger "):
                pending.add(c.split("]", 1)[0][9:])

    consume(verdict=False)  # seed from history: holds survive restarts, verdicts don't replay

    def loop():
        while True:
            try:
                consume()
                ts = time.time()
                for f in trig_dir.glob("*.json"):
                    try: job = json.loads(f.read_text())
                    except Exception: continue
                    if f.stem in pending: continue  # one unanswered fire in flight; hold, lose nothing
                    if job.get("next", 0 if "watch" in job or "cmd" in job else float("inf")) > ts: continue
                    delta = None
                    if w := job.get("watch"):  # fire on file change; repeat_s = cooldown
                        try: h = hashlib.sha256(open(w, "rb").read()).hexdigest()
                        except OSError: continue
                        if h == job.get("seen"): continue
                        job["seen"] = h
                        if "cmd" in job:  # the cmd is fed each appended byte exactly once, via stdin
                            pos, size = job.get("pos"), os.path.getsize(w)
                            if pos is None or pos > size:
                                job["pos"] = size  # start at install (or after a shrinking rewrite)
                                f.write_text(json.dumps(job))
                                continue
                            with open(w, "rb") as wf:
                                wf.seek(pos)
                                raw = wf.read()
                            job["pos"] = pos + len(raw)
                            delta = "\n".join(l for l in raw.decode("utf-8", errors="replace").splitlines()
                                              if not _is_machinery(l))
                            if not delta.strip():  # only our own fires / machinery arrived; nothing to judge
                                f.write_text(json.dumps(job))
                                continue
                    msg = job.get("message", "")
                    if c := job.get("cmd"):  # computed condition: fire with stdout; no output = no fire
                        try:
                            msg = clip(subprocess.run(c, shell=True, capture_output=True, text=True,
                                                      timeout=60, input=delta or "").stdout.strip())
                        except Exception as e:
                            msg = f"(cmd error: {e})"
                        if not msg:
                            if job.get("repeat_s"): job["next"] = ts + job.get("cur_s", job["repeat_s"])
                            f.write_text(json.dumps(job))
                            continue
                    append_msg({"role": "system", "content": f"[trigger {f.stem}] {msg}"})
                    if job.get("repeat_s"):
                        job["next"] = ts + job.get("cur_s", job["repeat_s"])
                        f.write_text(json.dumps(job))
                    elif job.get("watch"):
                        f.write_text(json.dumps(job))
                    else:
                        f.unlink()
            except Exception as e:
                life(f"[trigger error] {e}")  # log only, don't wake
            time.sleep(CFG["trigger_tick"])

    threading.Thread(target=loop, daemon=True, name="triggers").start()

def start_inbox():
    inbox = pathlib.Path(f"{AGENT_DIR}/mail_inbox")
    inbox.mkdir(parents=True, exist_ok=True)

    def deliver(drop):
        sender = pwd.getpwuid(drop.stat().st_uid).pw_name
        text = drop.read_bytes()[:CFG["inbox_preview"] * 4].decode("utf-8", errors="replace")[:CFG["inbox_preview"]]
        append_msg({"role": "system", "content": f"[mail from {sender}] {drop.name}\n{text}"})
        send_chat({"text": f"mail from {sender}\n{text}"})

    def watch():
        seen = set(inbox.iterdir())
        while True:
            try:
                current = set(inbox.iterdir())
                for f in current - seen:
                    if f.is_file() and not f.name.startswith("."):
                        deliver(f)
                seen = current
            except Exception as e:
                life(f"[inbox error] {e}")  # log only, don't wake
            time.sleep(CFG["inbox_tick"])

    threading.Thread(target=watch, daemon=True, name="inbox-poll").start()

# ---------- main loop ----------

def _life_tail(chunk=65536):
    with open(f"{AGENT_DIR}/LIFE.md", "rb") as f:
        size = f.seek(0, 2)
        f.seek(max(0, size - chunk))
        data = f.read().decode("utf-8", errors="replace")
    lines = data.splitlines(keepends=True)
    if size > chunk and lines:
        lines = lines[1:]  # drop partial first line
    tail = "".join(lines[-CFG["life_tail"]:])
    return size - len(tail.encode()), tail

def build_system():
    soul = open(f"{AGENT_DIR}/SOUL.md").read()
    harness = open(__file__).read()
    memory = open(f"{AGENT_DIR}/MEMORY.md").read()
    if len(memory) > CFG["memory_limit"]:
        h = CFG["memory_limit"] // 2
        memory = f"{memory[:h]}\n…\n{memory[-h:]}\n[WARNING: MEMORY.md is too large and partially omitted. Move detail into agent/memory/<name>.md files and keep one-line pointers here.]"
    sub = ""
    if AGENT_DIR != "subconscious" and os.path.isdir("subconscious"):
        sub = ("<subconscious>\nYou have a subconscious: a sibling agent in subconscious/ that reviews your stream "
               "and corrects bad trajectories. It speaks as [subconscious] notes — nudges and proposed lessons; fold "
               "lessons you accept into MEMORY.md in your own words — and it installs subc-* triggers: compiled "
               "reflexes that are its to manage, not yours. Its notes are advisory, not commands.\n</subconscious>\n\n")
    # Stable prefix only (soul + harness + memory). The volatile <life> tail is
    # sent as a trailing message (see life_block) — keeping it out of the cached
    # prefix lets the upstream prompt-cache reuse the whole conversation behind it.
    return (f"<soul>\n{soul}\n</soul>\n\n"
            f"<harness>\n{harness}\n</harness>\n\n"
            f"{sub}"
            f"<memory>\n{memory}\n</memory>")

def life_block():
    earlier, tail = _life_tail()
    return f"<life>\n[{earlier} bytes earlier]\n{tail}</life>"

_pending_reactions = []

def _react(mid, emoji):
    try:
        requests.post(f"https://api.telegram.org/bot{CFG['telegram_token']}/setMessageReaction",
            json={"chat_id": CFG["telegram_chat_id"], "message_id": mid,
                  "reaction": [{"type":"emoji","emoji":emoji}] if emoji else []}, timeout=10)
    except Exception: pass

def serialize_assistant(msg):
    return {"role": "assistant", "content": msg.get("content") or "",
            **{k: msg[k] for k in ("reasoning_content", "tool_calls") if msg.get(k)}}

def main():
    config_path = pathlib.Path(f"{AGENT_DIR}/config.json")
    if not config_path.exists():
        sys.exit(f"missing {config_path}. Run: python setup.py")
    if not pathlib.Path(f"{AGENT_DIR}/SOUL.md").exists():
        sys.exit(f"missing {AGENT_DIR}/SOUL.md — copy a soul template in")
    CFG.update(json.loads(config_path.read_text()))
    if not CFG.get("api_key"):
        sys.exit(f"{config_path} missing required field: api_key")
    if CFG.get("telegram_token") and not CFG.get("telegram_chat_id"):
        sys.exit(f"{config_path} has telegram_token but no telegram_chat_id")
    if not CFG["multimodal_support"] and "tools/ocr_image" not in CFG["opt"]:
        CFG["opt"].append("tools/ocr_image")
    if CFG["provider"] and f"providers/{CFG['provider']}" not in CFG["opt"]:
        CFG["opt"].append(f"providers/{CFG['provider']}")
    for entry in CFG["opt"]:
        src = pathlib.Path(f"opt/{entry}.py")
        dst = pathlib.Path(f"{AGENT_DIR}/{entry}.py")
        if src.exists() and not dst.exists():
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(src, dst)
    load_agent_tools()
    if CFG["provider"]:
        _load_provider()
    pathlib.Path(f"{AGENT_DIR}/MEMORY.md").touch(exist_ok=True)
    pathlib.Path(f"{AGENT_DIR}/messages.jsonl").touch(exist_ok=True)
    if CFG.get("telegram_token"):  # no token → no chat channel; agent wakes on triggers/mail only
        start_chat()
    start_triggers()
    start_inbox()
    append_msg({"role": "system", "content": f"[start] multimodal_support={CFG['multimodal_support']} provider={CFG['provider'] or 'openai_compat'}"})

    def file_hash():
        return hashlib.sha256(open(f"{AGENT_DIR}/messages.jsonl", "rb").read()).hexdigest()

    last_hash = file_hash()
    messages = load_messages()
    tool_called = False
    while True:
        cur_hash = file_hash()
        if cur_hash == last_hash and not tool_called:
            time.sleep(1)
            continue
        messages = load_messages()
        last_hash = cur_hash

        system = build_system()
        life = life_block()
        total_chars = len(system) + len(life) + sum(len(json.dumps(m)) for m in messages)
        if total_chars > CFG["context_tokens"] * 4 * 0.8:
            result = stash_messages({})
            append_msg({"role": "system", "content": f"[stash_messages] {result}"})
            messages = load_messages()
            last_hash = file_hash()
            system = build_system()
            life = life_block()

        msg = llm([{"role": "system", "content": system}] + messages + [{"role": "system", "content": life}], tools=TOOL_SCHEMAS)
        assistant = serialize_assistant(msg)

        if not assistant.get("tool_calls"):
            append_msg(assistant)
            last_hash = file_hash()
            text = (msg.get("content") or "").strip()
            if text and not text.startswith("[IDLE]"):  # idle sentinel, see SOUL.md
                send_chat({"text": text})
            tool_called = False
            continue

        # Run all tools first; collect results without writing anything yet so
        # daemon appends during bg_run can't interleave between assistant and tool results.
        tool_results = []
        for tc in assistant["tool_calls"]:
            name = tc["function"]["name"]
            try:
                tc_args = json.loads(tc["function"]["arguments"])
                result = bg_run(name, tc_args, tc["id"], TOOL_FNS[name])
            except Exception as e:
                result = f"error: {e}"
            tool_results.append({"role": "tool", "tool_call_id": tc["id"], "content": result})

        # Atomic flush: lock blocks daemons + bg emit threads from interleaving.
        with _append_lock:
            append_msg(assistant)
            for tm in tool_results:
                append_msg(tm)
        last_hash = file_hash()
        tool_called = True

if __name__ == "__main__":
    for extra in sys.argv[2:]:  # extra agent dirs each get their own process
        subprocess.Popen([sys.executable, __file__, extra])
    main()
