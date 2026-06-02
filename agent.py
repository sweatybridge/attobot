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
import bus
import tg
import cron
import inbox_watcher
import bg
import json, sys, time, hashlib, subprocess, pathlib, requests
from ddgs import DDGS

MODEL = "deepseek-v4-pro"
API_BASE = "http://localhost:8181/deepseek/v1"
BLOB_DIR = "blobs"
AGENTS_DIR = "agents"
MSG_LIMIT = 200
LIFE_TAIL = 50
MEMORY_LIMIT = 10000

TOOLS = [
    {"type": "function", "function": {"name": "READ_FILE", "description": "Read a file.",
        "parameters": {"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]}}},
    {"type": "function", "function": {"name": "WRITE_FILE", "description": "Overwrite a file.",
        "parameters": {"type": "object", "properties": {"path": {"type": "string"}, "content": {"type": "string"}}, "required": ["path", "content"]}}},
    {"type": "function", "function": {"name": "EDIT_FILE", "description": "Replace OLD with NEW in a file. OLD must appear exactly once.",
        "parameters": {"type": "object", "properties": {"path": {"type": "string"}, "old": {"type": "string"}, "new": {"type": "string"}}, "required": ["path", "old", "new"]}}},
    {"type": "function", "function": {"name": "BASH", "description": "Run a shell command.",
        "parameters": {"type": "object", "properties": {"cmd": {"type": "string"}}, "required": ["cmd"]}}},
    {"type": "function", "function": {"name": "STASH", "description": "Save text to a blob at blobs/<hash>, return [stash <hash>].",
        "parameters": {"type": "object", "properties": {"content": {"type": "string"}}, "required": ["content"]}}},
    {"type": "function", "function": {"name": "SEARCH", "description": "Search the web via DuckDuckGo. Returns title, URL, and snippet for up to 10 results.",
        "parameters": {"type": "object", "properties": {"query": {"type": "string"}, "n": {"type": "integer"}}, "required": ["query"]}}},
    {"type": "function", "function": {"name": "WEB_FETCH", "description": "Fetch and extract text from a URL.",
        "parameters": {"type": "object", "properties": {"url": {"type": "string"}}, "required": ["url"]}}},
]

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

def stash(content):
    h = hashlib.sha256(content.encode()).hexdigest()[:12]
    open(f"{BLOB_DIR}/{h}", "w").write(content)
    return h

def llm(messages, tools=None):
    body = {"model": MODEL, "messages": messages}
    if tools:
        body["tools"] = tools
    r = requests.post(f"{API_BASE}/chat/completions",
        headers={"Authorization": f"Bearer {os.environ['DEEPSEEK_API_KEY']}"},
        json=body, timeout=120)
    data = r.json()
    if "choices" not in data:
        raise RuntimeError(f"llm {r.status_code}: {data}")
    return data["choices"][0]["message"]

def life_tail():
    return "\n".join(open(LIFE_PATH).read().splitlines()[-LIFE_TAIL:])

def run_tool(name, args):
    if name == "READ_FILE":
        return open(args["path"]).read()
    if name == "WRITE_FILE":
        path = args["path"]
        if path == "SOUL.md":
            return f"error: {path} is immutable"
        open(path, "w").write(args["content"])
        return f"wrote {path} ({len(args['content'])} chars)"
    if name == "EDIT_FILE":
        path, old, new = args["path"], args["old"], args["new"]
        if path == "SOUL.md":
            return f"error: {path} is immutable"
        text = open(path).read()
        if text.count(old) != 1:
            return f"error: OLD must appear exactly once in {path} (found {text.count(old)})"
        open(path, "w").write(text.replace(old, new))
        return f"edited {path}"
    if name == "STASH":
        return f"stashed: [stash {stash(args['content'])}]"
    if name == "SEARCH":
        n = min(args.get("n", 5), 10)
        try:
            results = list(DDGS().text(args["query"], max_results=n))
            out = []
            for i, r in enumerate(results):
                out.append(f"{i+1}. {r['title']}\n   {r['href']}\n   {r['body']}")
            return "\n\n".join(out) or "(no results)"
        except Exception as e:
            return f"search error: {e}"
    if name == "WEB_FETCH":
        try:
            r = requests.get(args["url"], headers={"User-Agent": "Mozilla/5.0"}, timeout=15)
            r.raise_for_status()
            text = r.text
            # crude extract: remove script/style, get body text
            import re
            text = re.sub(r'<script[^>]*>.*?</script>', '', text, flags=re.DOTALL|re.IGNORECASE)
            text = re.sub(r'<style[^>]*>.*?</style>', '', text, flags=re.DOTALL|re.IGNORECASE)
            text = re.sub(r'<[^>]+>', ' ', text)
            text = re.sub(r'\s+', ' ', text).strip()
            return text[:5000]
        except Exception as e:
            return f"fetch error: {e}"
    return f"unknown tool: {name}"

def load_messages():
    return [json.loads(l) for l in open(MESSAGES_PATH) if l.strip()]

def append_msg(m):
    bus.append(MESSAGES_PATH, json.dumps(m) + "\n")

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

def compact(messages):
    half = len(messages) // 2
    head = "\n".join(json.dumps(m) for m in messages[:half])
    h = stash(head)
    new = [{"role": "system", "content": f"<earlier history compacted: [stash {h}]>"}] + messages[half:]
    with open(MESSAGES_PATH, "w") as f:
        for m in new:
            f.write(json.dumps(m) + "\n")
    life(f"compacted -> {h}")
    return new

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
    tg.start(SELF)
    cron.start(SELF)
    inbox_watcher.start(SELF)
    life(f"awake self={SELF}")

    messages = load_messages()
    msg_size = os.path.getsize(MESSAGES_PATH)
    tool_called = False
    while True:
        cur_size = os.path.getsize(MESSAGES_PATH)
        new_arrived = False
        if cur_size > msg_size:
            with open(MESSAGES_PATH, "r") as f:
                f.seek(msg_size)
                new = f.read()
            msg_size = cur_size
            for line in new.splitlines():
                if line.strip():
                    messages.append(json.loads(line))
            new_arrived = True
        if not (new_arrived or tool_called):
            time.sleep(1)
            continue

        msg = llm([{"role": "system", "content": build_system()}] + messages, tools=TOOLS)
        assistant = serialize_assistant(msg)
        append_msg(assistant)
        msg_size = os.path.getsize(MESSAGES_PATH)
        messages.append(assistant)
        life("resp")

        if not assistant.get("tool_calls"):
            tg.send((msg.get("content") or "").strip())
            tool_called = False
            continue

        tool_called = True
        for tc in assistant["tool_calls"]:
            name = tc["function"]["name"]
            tc_args = json.loads(tc["function"]["arguments"])
            try:
                result = bg.run(name, tc_args, tc["id"], run_tool, SELF_DIR, MESSAGES_PATH)
            except Exception as e:
                result = f"error: {e}"
            tool_msg = {"role": "tool", "tool_call_id": tc["id"], "content": result}
            append_msg(tool_msg)
            msg_size = os.path.getsize(MESSAGES_PATH)
            messages.append(tool_msg)
            life(name)

        if len(messages) > MSG_LIMIT:
            messages = compact(messages)
            msg_size = os.path.getsize(MESSAGES_PATH)

if __name__ == "__main__":
    main()
