#!/usr/bin/env python3
"""Minimal agent."""
import os
try:
    for line in open(".env"):
        line = line.strip()
        if line and not line.startswith("#"):
            k, _, v = line.partition("=")
            os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))
except FileNotFoundError:
    pass
import base64, fcntl, hashlib, importlib.util, json, mimetypes, pathlib, pwd, re, requests, shutil, signal, subprocess, sys, threading, time
sys.modules.setdefault("agent", sys.modules[__name__])

MODEL = os.environ.get("MODEL", "kimi-k2.5")
API_BASE = os.environ.get("API_BASE", "https://api.moonshot.ai/v1")
TEMPERATURE = float(os.environ.get("TEMPERATURE", "1.0"))
BLOB_DIR = os.environ.get("BLOB_DIR", "blobs")
AGENTS_DIR = os.environ.get("AGENTS_DIR", "agents")
CONTEXT_TOKENS = int(os.environ.get("CONTEXT_TOKENS", "100000"))
LIFE_TAIL = int(os.environ.get("LIFE_TAIL", "50"))
MEMORY_LIMIT = int(os.environ.get("MEMORY_LIMIT", "10000"))
TOOL_TIMEOUT = int(os.environ.get("TOOL_TIMEOUT", "30"))
CRON_TICK = int(os.environ.get("CRON_TICK", "30"))
INBOX_TICK = int(os.environ.get("INBOX_TICK", "2"))
INBOX_PREVIEW = int(os.environ.get("INBOX_PREVIEW", "1000"))
CHAT_MSG_MAX = int(os.environ.get("CHAT_MSG_MAX", "4000"))
TOOL_OUTPUT_LIMIT = int(os.environ.get("TOOL_OUTPUT_LIMIT", "5000"))
MULTIMODAL_SUPPORT = os.environ.get("MULTIMODAL_SUPPORT", "true").lower() in ("1", "true", "yes", "on")
PROVIDER = os.environ.get("PROVIDER", "").strip()
OPT = [t.strip() for t in os.environ.get("OPT", "").split(",") if t.strip()]
if not MULTIMODAL_SUPPORT and "tools/ocr_image" not in OPT:
    OPT.append("tools/ocr_image")
if PROVIDER and f"providers/{PROVIDER}" not in OPT:
    OPT.append(f"providers/{PROVIDER}")

for d in (BLOB_DIR, AGENTS_DIR): os.makedirs(d, exist_ok=True)

SELF = None

def life(event):
    with open(f"{AGENTS_DIR}/{SELF}/LIFE.md", "a") as f:
        f.write(f"[{time.strftime('%Y%m%dT%H%M%S')}] {event}\n")

def load_messages():
    return [json.loads(l) for l in open(f"{AGENTS_DIR}/{SELF}/messages.jsonl") if l.strip()]

def append_msg(m):
    with open(f"{AGENTS_DIR}/{SELF}/messages.jsonl", "a") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        f.write(json.dumps(m) + "\n")

def _default_chat(messages, tools):
    body = {"model": MODEL, "messages": messages, "temperature": TEMPERATURE}
    if tools:
        body["tools"] = tools
    r = requests.post(f"{API_BASE}/chat/completions",
        headers={"Authorization": f"Bearer {os.environ['API_KEY']}"},
        json=body, timeout=120)
    data = r.json()
    if "choices" not in data:
        raise RuntimeError(f"{r.status_code}: {data}")
    return data["choices"][0]["message"]

_chat_fn = _default_chat

def llm(messages, tools=None):
    delay = 1
    while True:
        try:
            return _chat_fn(messages, tools)
        except Exception as e:
            life(f"llm retry in {delay}s: {e}")
            time.sleep(delay)
            delay = min(delay * 2, 900)

# ---------- tools ----------

def append_message(args):
    append_msg({"role": args["role"], "content": args["content"]})
    return "appended"

def send_chat(args):
    agent_dir = pathlib.Path(f"{AGENTS_DIR}/{SELF}")
    token = (agent_dir / "telegram_token").read_text().strip()
    chat_file = agent_dir / "telegram_chat"
    if not chat_file.exists():
        return "no chat_id yet"
    chat_id = chat_file.read_text().strip()
    text = args["text"]
    for i in range(0, len(text), CHAT_MSG_MAX):
        requests.post(f"https://api.telegram.org/bot{token}/sendMessage",
                      data={"chat_id": chat_id, "text": text[i:i+CHAT_MSG_MAX]}, timeout=45)
    return "sent"

def stash(content):
    h = hashlib.sha256(content.encode()).hexdigest()[:12]
    open(f"{BLOB_DIR}/{h}", "w").write(content)
    return f"[stash {h}]"

def clip(s):
    if not isinstance(s, str) or len(s) <= TOOL_OUTPUT_LIMIT:
        return s
    h = TOOL_OUTPUT_LIMIT // 2
    return f"{s[:h]}\n... {len(s) - 2*h} chars truncated, {stash(s)} ...\n{s[-h:]}"

IMAGE_EXTS = {".png", ".jpg", ".jpeg", ".gif", ".webp"}

def read_file(args):
    path = args["path"]
    if pathlib.Path(path).suffix.lower() in IMAGE_EXTS and MULTIMODAL_SUPPORT:
        mime = mimetypes.guess_type(path)[0] or "application/octet-stream"
        b64 = base64.b64encode(open(path, "rb").read()).decode()
        return [{"type": "image_url", "image_url": {"url": f"data:{mime};base64,{b64}"}}]
    return "\n".join(f"{i+1}\t{line}" for i, line in enumerate(open(path).read().splitlines()))

def write_file(args):
    path = args["path"]
    if path == "SOUL.md":
        return f"error: {path} is immutable"
    open(path, "w").write(args["content"])
    return f"wrote {path} ({len(args['content'])} chars)"

def edit_file(args):
    path, old, new = args["path"], args["old"], args["new"]
    if path == "SOUL.md":
        return f"error: {path} is immutable"
    text = open(path).read()
    count = text.count(old)
    if args.get("replace_all"):
        if count == 0:
            return f"error: OLD not found in {path}"
        open(path, "w").write(text.replace(old, new))
        return f"edited {path} ({count} replacements)"
    if count != 1:
        return f"error: OLD must appear exactly once in {path} (found {count}; pass replace_all to replace every occurrence)"
    open(path, "w").write(text.replace(old, new))
    return f"edited {path}"

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
    try:
        r = requests.get(args["url"], headers={"User-Agent": "Mozilla/5.0"}, timeout=15)
        r.raise_for_status()
        text = r.text
        text = re.sub(r'<script[^>]*>.*?</script>', '', text, flags=re.DOTALL|re.IGNORECASE)
        text = re.sub(r'<style[^>]*>.*?</style>', '', text, flags=re.DOTALL|re.IGNORECASE)
        text = re.sub(r'<[^>]+>', ' ', text)
        return re.sub(r'\s+', ' ', text).strip()
    except Exception as e:
        return f"fetch error: {e}"

def stash_messages(args):
    messages_path = f"{AGENTS_DIR}/{SELF}/messages.jsonl"
    with open(messages_path, "r+") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        all_msgs = [json.loads(l) for l in f.read().splitlines() if l.strip()]
        n = len(all_msgs)
        start = n // 4
        end = (3 * n) // 4
        # advance past tool messages so we don't orphan an assistant's tool_calls
        while start < n and all_msgs[start].get("role") == "tool":
            start += 1
        while end < n and all_msgs[end].get("role") == "tool":
            end += 1
        if start >= end:
            return "nothing safe to stash"
        middle = all_msgs[start:end]
        marker = stash("\n".join(json.dumps(m) for m in middle))
        new = all_msgs[:start] + [{"role": "system", "content": f"<middle history stashed: {marker}>"}] + all_msgs[end:]
        f.seek(0)
        f.truncate()
        for m in new:
            f.write(json.dumps(m) + "\n")
    return f"stashed middle {end-start} messages to {marker}"

TOOLS = [
    ("APPEND_MESSAGE", append_message, "Append a message to the log.",
        {"type": "object", "properties": {"role": {"type": "string"}, "content": {"type": "string"}}, "required": ["role", "content"]}),
    ("SEND_CHAT", send_chat, "Send a text message to the chat.",
        {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]}),
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
]
TOOL_FNS = {n: f for n, f, _, _ in TOOLS}
TOOL_SCHEMAS = [{"type": "function", "function": {"name": n, "description": d, "parameters": p}} for n, _, d, p in TOOLS]

def load_agent_tools():
    tools_dir = pathlib.Path(f"{AGENTS_DIR}/{SELF}/tools")
    for path in sorted(tools_dir.glob("*.py")):
        spec = importlib.util.spec_from_file_location(path.stem, path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        TOOL_FNS[mod.NAME] = mod.run
        TOOL_SCHEMAS.append({"type": "function", "function": {
            "name": mod.NAME, "description": mod.DESCRIPTION, "parameters": mod.PARAMETERS}})

def _load_provider():
    global _chat_fn
    path = pathlib.Path(f"{AGENTS_DIR}/{SELF}/providers/{PROVIDER}.py")
    spec = importlib.util.spec_from_file_location(f"provider_{PROVIDER}", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    _chat_fn = mod.chat

# ---------- background tool wrapper ----------

def bg_run(name, args, tool_call_id, tool_fn):
    bg_id = hashlib.sha256(f"{tool_call_id}{time.time()}".encode()).hexdigest()[:8]
    bg_dir = pathlib.Path(f"{AGENTS_DIR}/{SELF}/bg")
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
    t.join(TOOL_TIMEOUT)
    if holder["done"]:
        return holder["result"]

    json_path = bg_dir / f"{bg_id}.json"
    json_path.write_text(json.dumps({
        "name": name, "tool_call_id": tool_call_id,
        "pid": holder.get("pid"), "started": time.time(),
    }))

    def emit():
        while not holder["done"]:
            if not json_path.exists():
                if holder.get("pid"):
                    try: os.kill(holder["pid"], signal.SIGTERM)
                    except Exception: pass
                append_msg({"role": "system", "content": f"[bg {bg_id} killed, tc:{tool_call_id}]"})
                return
            time.sleep(1)
        append_msg({"role": "system", "content": f"[bg {bg_id} done, tc:{tool_call_id}] {holder['result']}"})
        try: json_path.unlink()
        except Exception: pass

    threading.Thread(target=emit, daemon=True).start()
    pid_info = f" (pid {holder['pid']})" if holder.get("pid") else ""
    return f"[backgrounded bg/{bg_id}{pid_info} — rm agents/{SELF}/bg/{bg_id}.json to kill]"

# ---------- channels ----------

def start_chat():
    agent_dir = pathlib.Path(f"{AGENTS_DIR}/{SELF}")
    token = (agent_dir / "telegram_token").read_text().strip()
    chat_file = agent_dir / "telegram_chat"
    poll_offset = agent_dir / "tg_poll.offset"

    def poll_in():
        try: offset = int(poll_offset.read_text())
        except (FileNotFoundError, ValueError): offset = 0
        cached_chat_id = chat_file.read_text().strip() if chat_file.exists() else None
        while True:
            try:
                advanced = False
                r = requests.post(f"https://api.telegram.org/bot{token}/getUpdates",
                                  data={"offset": offset, "timeout": 25}, timeout=45)
                for u in r.json().get("result") or []:
                    offset = u["update_id"] + 1
                    advanced = True
                    msg = u.get("message") or {}
                    cid = str((msg.get("chat") or {}).get("id") or "")
                    if cid and cid != cached_chat_id:
                        cached_chat_id = cid
                        chat_file.write_text(cid)
                    text = msg.get("text") or ""
                    if not text: continue
                    append_msg({"role": "user", "content": f"[telegram {u['update_id']}] {text}"})
                if advanced:
                    poll_offset.write_text(str(offset))
            except Exception as e:
                append_msg({"role": "system", "content": f"[chat error] {e}"})
                time.sleep(5)

    threading.Thread(target=poll_in, daemon=True, name="chat-poll").start()

def start_cron():
    cron_dir = pathlib.Path(f"{AGENTS_DIR}/{SELF}/cron")
    cron_dir.mkdir(parents=True, exist_ok=True)

    def loop():
        while True:
            try:
                ts = time.time()
                for f in cron_dir.glob("*.json"):
                    try: job = json.loads(f.read_text())
                    except Exception: continue
                    if job.get("next", float("inf")) > ts: continue
                    append_msg({"role": "system", "content": f"[cron {f.stem}] {job.get('message', '')}"})
                    if job.get("repeat_s"):
                        job["next"] = ts + job["repeat_s"]
                        f.write_text(json.dumps(job))
                    else:
                        f.unlink()
            except Exception as e:
                append_msg({"role": "system", "content": f"[cron error] {e}"})
            time.sleep(CRON_TICK)

    threading.Thread(target=loop, daemon=True, name="cron").start()

def start_inbox():
    inbox = pathlib.Path(f"{AGENTS_DIR}/{SELF}/mail_inbox")
    inbox.mkdir(parents=True, exist_ok=True)

    def deliver(drop):
        sender = pwd.getpwuid(drop.stat().st_uid).pw_name
        text = drop.read_bytes()[:INBOX_PREVIEW * 4].decode("utf-8", errors="replace")[:INBOX_PREVIEW]
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
                append_msg({"role": "system", "content": f"[inbox error] {e}"})
            time.sleep(INBOX_TICK)

    threading.Thread(target=watch, daemon=True, name="inbox-poll").start()

# ---------- main loop ----------

def build_system():
    soul = open(f"{AGENTS_DIR}/{SELF}/SOUL.md").read().replace("<self>", SELF)
    harness = open(__file__).read()
    memory = open(f"{AGENTS_DIR}/{SELF}/MEMORY.md").read()
    if len(memory) > MEMORY_LIMIT:
        h = MEMORY_LIMIT // 2
        memory = f"{memory[:h]}\n…\n{memory[-h:]}\n[WARNING: MEMORY.md truncated. Shrink it.]"
    tail = open(f"{AGENTS_DIR}/{SELF}/LIFE.md").readlines()
    return (f"<soul>\n{soul}\n</soul>\n\n"
            f"<harness>\n{harness}\n</harness>\n\n"
            f"<memory>\n{memory}\n</memory>\n\n"
            f"<life>\n[{max(0, len(tail)-LIFE_TAIL)} earlier]\n{''.join(tail[-LIFE_TAIL:])}</life>")

def serialize_assistant(msg):
    out = {"role": "assistant", "content": msg.get("content") or ""}
    if msg.get("reasoning_content"):
        out["reasoning_content"] = msg["reasoning_content"]
    if msg.get("tool_calls"):
        out["tool_calls"] = msg["tool_calls"]
    return out

def main():
    global SELF
    soul_template = sys.argv[2] if len(sys.argv) > 2 else "SOUL.md"
    soul_text = open(soul_template).read()
    SELF = sys.argv[1] if len(sys.argv) > 1 else hashlib.sha256(soul_text.encode()).hexdigest()[:12]
    self_dir = f"{AGENTS_DIR}/{SELF}"
    os.makedirs(self_dir, exist_ok=True)
    if not pathlib.Path(f"{self_dir}/SOUL.md").exists():
        shutil.copy(soul_template, f"{self_dir}/SOUL.md")
    for entry in OPT:
        src = pathlib.Path(f"opt/{entry}.py")
        dst = pathlib.Path(f"{self_dir}/{entry}.py")
        if src.exists() and not dst.exists():
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(src, dst)
    load_agent_tools()
    if PROVIDER:
        _load_provider()
    pathlib.Path(f"{self_dir}/MEMORY.md").touch(exist_ok=True)
    pathlib.Path(f"{self_dir}/messages.jsonl").touch(exist_ok=True)
    life("start")
    heartbeat = pathlib.Path(f"{self_dir}/cron/heartbeat.json")
    heartbeat.parent.mkdir(parents=True, exist_ok=True)
    if not heartbeat.exists():
        heartbeat.write_text(json.dumps({"next": time.time() + 60, "repeat_s": 60, "message": "tick"}))
    start_chat()
    start_cron()
    start_inbox()
    append_msg({"role": "system", "content": f"[boot] MULTIMODAL_SUPPORT={MULTIMODAL_SUPPORT} PROVIDER={PROVIDER or 'openai_compat'}"})
    life(f"awake self={SELF}")

    def file_hash():
        return hashlib.sha256(open(f"{self_dir}/messages.jsonl", "rb").read()).hexdigest()

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
        total_chars = len(system) + sum(len(json.dumps(m)) for m in messages)
        if total_chars > CONTEXT_TOKENS * 4 * 0.8:
            life(f"stash_messages: {stash_messages({})}")
            messages = load_messages()
            last_hash = file_hash()
            system = build_system()

        msg = llm([{"role": "system", "content": system}] + messages, tools=TOOL_SCHEMAS)
        assistant = serialize_assistant(msg)
        append_msg(assistant)
        last_hash = file_hash()
        life("resp")

        if not assistant.get("tool_calls"):
            send_chat({"text": (msg.get("content") or "").strip()})
            tool_called = False
            continue

        tool_called = True
        for tc in assistant["tool_calls"]:
            name = tc["function"]["name"]
            try:
                tc_args = json.loads(tc["function"]["arguments"])
                result = bg_run(name, tc_args, tc["id"], TOOL_FNS[name])
            except Exception as e:
                result = f"error: {e}"
            tool_msg = {"role": "tool", "tool_call_id": tc["id"], "content": result}
            append_msg(tool_msg)
            last_hash = file_hash()
            life(name)

if __name__ == "__main__":
    main()
