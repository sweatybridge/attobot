#!/usr/bin/env python3
"""Minimal blob-memory agent. See README.md for design."""
import os
try:
    for line in open(".env"):
        line = line.strip()
        if line and not line.startswith("#"):
            k, _, v = line.partition("=")
            os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))
except FileNotFoundError:
    pass
import chat
import cron
import inbox_watcher
import bg
import fcntl, hashlib, importlib, json, pathlib, pkgutil, requests, sys, time

MODEL = os.environ.get("MODEL", "deepseek-v4-pro")
API_BASE = os.environ.get("API_BASE", "http://localhost:8181/deepseek/v1")
BLOB_DIR = os.environ.get("BLOB_DIR", "blobs")
AGENTS_DIR = os.environ.get("AGENTS_DIR", "agents")
MSG_LIMIT = int(os.environ.get("MSG_LIMIT", "200"))
LIFE_TAIL = int(os.environ.get("LIFE_TAIL", "50"))
MEMORY_LIMIT = int(os.environ.get("MEMORY_LIMIT", "10000"))

TOOL_RUN = {}
SCHEMAS = []
for mod_info in pkgutil.iter_modules(["tools"]):
    mod = importlib.import_module(f"tools.{mod_info.name}")
    if not hasattr(mod, "SCHEMA") or not callable(getattr(mod, "run", None)):
        raise RuntimeError(f"tools/{mod_info.name}.py must export SCHEMA and run(args)")
    TOOL_RUN[mod.SCHEMA["function"]["name"]] = mod.run
    SCHEMAS.append(mod.SCHEMA)

for d in (BLOB_DIR, AGENTS_DIR): os.makedirs(d, exist_ok=True)

SELF = None
SELF_DIR = None
LIFE_PATH = None
MEMORY_PATH = None
MESSAGES_PATH = None


def now():
    return time.strftime("%Y%m%dT%H%M%S")

def life(event):
    with open(LIFE_PATH, "a") as f:
        f.write(f"[{now()}] {event}\n")

def llm(messages, tools=None):
    body = {"model": MODEL, "messages": messages}
    if tools:
        body["tools"] = tools
    delay = 1
    while True:
        try:
            r = requests.post(f"{API_BASE}/chat/completions",
                headers={"Authorization": f"Bearer {os.environ['DEEPSEEK_API_KEY']}"},
                json=body, timeout=120)
            data = r.json()
            if "choices" in data:
                return data["choices"][0]["message"]
            err = f"{r.status_code}: {data}"
        except Exception as e:
            err = str(e)
        life(f"llm retry in {delay}s: {err}")
        time.sleep(delay)
        delay = min(delay * 2, 60)

def life_tail():
    return "\n".join(open(LIFE_PATH).read().splitlines()[-LIFE_TAIL:])

def load_messages():
    return [json.loads(l) for l in open(MESSAGES_PATH) if l.strip()]

def append_msg(m):
    with open(MESSAGES_PATH, "a") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        f.write(json.dumps(m) + "\n")

def build_system():
    soul = open("SOUL.md").read().replace("<self>", SELF)
    harness = open(__file__).read()
    memory = open(MEMORY_PATH).read()
    if len(memory) > MEMORY_LIMIT:
        h = MEMORY_LIMIT // 2
        memory = f"{memory[:h]}\n…\n{memory[-h:]}\n[WARNING: MEMORY.md truncated. Shrink it.]"
    return (f"<soul>\n{soul}\n</soul>\n\n"
            f"<harness>\n{harness}\n</harness>\n\n"
            f"<memory>\n{memory}\n</memory>\n\n"
            f"<life>\n{life_tail()}\n</life>")

def serialize_assistant(msg):
    out = {"role": "assistant", "content": msg.get("content") or ""}
    if msg.get("reasoning_content"):
        out["reasoning_content"] = msg["reasoning_content"]
    if msg.get("tool_calls"):
        out["tool_calls"] = msg["tool_calls"]
    return out

def main():
    global SELF, SELF_DIR, LIFE_PATH, MEMORY_PATH, MESSAGES_PATH
    soul_text = open("SOUL.md").read()
    SELF = sys.argv[1] if len(sys.argv) > 1 else hashlib.sha256(f"soul:\n{soul_text}\nboot: {now()}".encode()).hexdigest()[:12]
    SELF_DIR = f"{AGENTS_DIR}/{SELF}"
    LIFE_PATH = f"{SELF_DIR}/LIFE.md"
    MEMORY_PATH = f"{SELF_DIR}/MEMORY.md"
    MESSAGES_PATH = f"{SELF_DIR}/messages.jsonl"
    os.makedirs(SELF_DIR, exist_ok=True)
    pathlib.Path(MEMORY_PATH).touch(exist_ok=True)
    pathlib.Path(MESSAGES_PATH).touch(exist_ok=True)
    heartbeat = pathlib.Path(f"{SELF_DIR}/cron/heartbeat.json")
    heartbeat.parent.mkdir(parents=True, exist_ok=True)
    if not heartbeat.exists():
        heartbeat.write_text(json.dumps({"next": time.time() + 60, "repeat_s": 60, "message": "tick"}))
    os.environ["SELF_DIR"] = SELF_DIR
    chat.start(SELF)
    cron.start(SELF)
    inbox_watcher.start(SELF)
    life(f"awake self={SELF}")

    def file_hash():
        return hashlib.sha256(open(MESSAGES_PATH, "rb").read()).hexdigest()

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

        if len(messages) > MSG_LIMIT:
            life(f"stash_messages: {TOOL_RUN['STASH_MESSAGES']({})}")
            messages = load_messages()
            last_hash = file_hash()

        msg = llm([{"role": "system", "content": build_system()}] + messages, tools=SCHEMAS)
        assistant = serialize_assistant(msg)
        append_msg(assistant)
        last_hash = file_hash()
        life("resp")

        if not assistant.get("tool_calls"):
            TOOL_RUN["SEND_CHAT"]({"text": (msg.get("content") or "").strip()})
            tool_called = False
            continue

        tool_called = True
        for tc in assistant["tool_calls"]:
            name = tc["function"]["name"]
            try:
                tc_args = json.loads(tc["function"]["arguments"])
                result = bg.run(name, tc_args, tc["id"], TOOL_RUN[name])
            except Exception as e:
                result = f"error: {e}"
            tool_msg = {"role": "tool", "tool_call_id": tc["id"], "content": result}
            append_msg(tool_msg)
            last_hash = file_hash()
            life(name)

if __name__ == "__main__":
    main()
