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
import json, sys, time, hashlib, signal, subprocess, litellm

MODEL = os.environ.get("MODEL", "openai/deepseek-v4-pro")
API_BASE = os.environ.get("API_BASE", "https://api.deepseek.com/v1")
BLOB_DIR = os.environ.get("BLOB_DIR", "blobs")
BUS_DIR = os.environ.get("BUS_DIR", "bus")
CONTEXT_LIMIT = int(os.environ.get("CONTEXT_LIMIT", str(65536 * 4)))
RESULT_STASH_LIMIT = int(os.environ.get("RESULT_STASH_LIMIT", "2000"))
TOOL_TIMEOUT = int(os.environ.get("TOOL_TIMEOUT", "300"))
LIFE_TAIL = int(os.environ.get("LIFE_TAIL", "50"))
AGENTS_DIR = os.environ.get("AGENTS_DIR", "agents")
MEMORY_LIMIT = int(os.environ.get("MEMORY_LIMIT", "10000"))
HEARTBEAT_INTERVAL = int(os.environ.get("HEARTBEAT_INTERVAL", "60"))
VERBOSE = "--verbose" in sys.argv
KINDS = ["mail", "telegram", "cron"]

TOOLS = [
    {"type": "function", "function": {"name": "READ_FILE", "description": "Read a file. Optional offset/limit (line numbers) for large files.",
        "parameters": {"type": "object", "properties": {"path": {"type": "string"}, "offset": {"type": "integer"}, "limit": {"type": "integer"}}, "required": ["path"]}}},
    {"type": "function", "function": {"name": "WRITE_FILE", "description": "Overwrite a file with new content.",
        "parameters": {"type": "object", "properties": {"path": {"type": "string"}, "content": {"type": "string"}}, "required": ["path", "content"]}}},
    {"type": "function", "function": {"name": "EDIT_FILE", "description": "Replace OLD with NEW in a file. OLD must appear exactly once.",
        "parameters": {"type": "object", "properties": {"path": {"type": "string"}, "old": {"type": "string"}, "new": {"type": "string"}}, "required": ["path", "old", "new"]}}},
    {"type": "function", "function": {"name": "LIST", "description": "List a directory (empty string = cwd).",
        "parameters": {"type": "object", "properties": {"dir": {"type": "string", "default": ""}}, "required": []}}},
    {"type": "function", "function": {"name": "BASH", "description": "Run a shell command (60s timeout).",
        "parameters": {"type": "object", "properties": {"cmd": {"type": "string"}}, "required": ["cmd"]}}},
    {"type": "function", "function": {"name": "STASH", "description": "Save text to a blob at blobs/<hash>, return [stash <hash>]. Recall later with READ_FILE blobs/<hash>.",
        "parameters": {"type": "object", "properties": {"content": {"type": "string"}}, "required": ["content"]}}},
]

for d in (BLOB_DIR, BUS_DIR, AGENTS_DIR): os.makedirs(d, exist_ok=True)

SELF = None
SELF_DIR = None
LIFE_PATH = None
MEMORY_PATH = None

def now():
    return time.strftime("%Y%m%dT%H%M%S")

def life(event):
    line = f"[{now()}] {event}"
    with open(LIFE_PATH, "a") as f:
        f.write(line + "\n")
    if VERBOSE:
        print(line, flush=True)

def stash(content):
    h = hashlib.sha256(content.encode()).hexdigest()[:12]
    open(f"{BLOB_DIR}/{h}", "w").write(content)
    return h, f"[stash {h}]"

def llm(prompt, tools=None):
    kwargs = dict(model=MODEL, api_base=API_BASE, api_key=os.environ["DEEPSEEK_API_KEY"],
                  messages=[{"role": "user", "content": prompt}])
    if tools:
        kwargs["tools"] = tools
    msg = litellm.completion(**kwargs).choices[0].message
    reasoning = getattr(msg, "reasoning_content", None) or ""
    content = msg.content or ""
    tc = msg.tool_calls if hasattr(msg, "tool_calls") else None
    return content, reasoning, tc

def _read_lines(path, offset=0, limit=None):
    content = open(path).read()
    lines = content.splitlines()
    if limit is None: limit = len(lines)
    selected = lines[offset:offset + limit]
    if len(selected) < len(lines):
        selected.append(f"... ({len(lines)} lines total, showing {offset}:{offset + limit})")
    return "\n".join(selected)

def life_tail():
    try:
        lines = open(LIFE_PATH).read().splitlines()
        return "\n".join(lines[-LIFE_TAIL:])
    except FileNotFoundError:
        return ""

def run_tool(name, args):
    if name == "READ_FILE":
        return _read_lines(args["path"], args.get("offset", 0), args.get("limit"))
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
    if name == "LIST":
        return "\n".join(sorted(os.listdir(args.get("dir", "") or ".")))
    if name == "BASH":
        p = subprocess.run(args["cmd"], shell=True, capture_output=True, text=True, timeout=TOOL_TIMEOUT)
        return (p.stdout + p.stderr) or f"(exit {p.returncode}, no output)"
    if name == "STASH":
        _, ref = stash(args["content"])
        return f"stashed: {ref}"
    return f"unknown tool: {name}"

def tail_bus():
    blocks = []
    for kind in KINDS:
        content = bus.read_new(f"{BUS_DIR}/{kind}/{SELF}.log", f"{SELF_DIR}/{kind}.offset")
        if content:
            blocks.append(f"[{kind}]\n{content.rstrip()}")
    return "\n\n".join(blocks)

def main():
    global SELF, SELF_DIR, LIFE_PATH, MEMORY_PATH
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    resume = args[0] if args else None
    if resume:
        if not os.path.isdir(f"{AGENTS_DIR}/{resume}"):
            raise SystemExit(f"agent dir not found: {AGENTS_DIR}/{resume}")
        SELF = resume
        resumed = True
    else:
        SELF, self_ref = stash(f"soul:\n{open('SOUL.md').read()}\nboot: {now()}")
        resumed = False
    SELF_DIR = f"{AGENTS_DIR}/{SELF}"
    LIFE_PATH = f"{SELF_DIR}/LIFE.md"
    MEMORY_PATH = f"{SELF_DIR}/MEMORY.md"
    os.makedirs(SELF_DIR, exist_ok=True)
    if not os.path.exists(MEMORY_PATH):
        open(MEMORY_PATH, "w").write("# Memory\n")
    tg.start(SELF)
    cron.start(SELF)
    inbox_watcher.start(SELF)
    soul = open("SOUL.md").read().replace("<self>", SELF)
    harness = open(__file__).read()
    if resumed:
        ctx_path = f"{SELF_DIR}/context.md"
        context = open(ctx_path).read() if os.path.exists(ctx_path) else ""
        life(f"resumed self={SELF}")
        context += f"\n[resumed at {now()}]\n"
    else:
        context = f"[boot] you are agent {SELF} (identity: {self_ref}).\n"
        life(f"boot self={SELF}")
    last_turn_end = time.time()
    tool_called = False
    while True:
        inbound = tail_bus()
        if inbound:
            context += f"\n{inbound}\n"
            life(f"inbound: {inbound[:50]}…{inbound[-50:]}" if len(inbound) > 101 else f"inbound: {inbound}")
        elif not tool_called:
            if time.time() - last_turn_end >= HEARTBEAT_INTERVAL:
                context += "\n<heartbeat/>\n"
                life("heartbeat")
            else:
                time.sleep(1)
                continue
        memory = open(MEMORY_PATH).read()
        if len(memory) > MEMORY_LIMIT:
            h = MEMORY_LIMIT // 2
            memory = f"{memory[:h]}\n…\n{memory[-h:]}\n[WARNING: MEMORY.md truncated. Shrink it.]"
        prompt = (f"<soul>\n{soul}\n</soul>\n\n"
                  f"<harness>\n{harness}\n</harness>\n\n"
                  f"<memory>\n{memory}\n</memory>\n\n"
                  f"<context>\n{context}\n</context>\n\n<life>\n{life_tail()}\n</life>")
        content, reasoning, tool_calls = llm(prompt, tools=TOOLS)
        resp = ""
        if reasoning: resp += f"<reasoning>\n{reasoning}\n</reasoning>\n"
        if content: resp += content
        _, resp_ref = stash(resp)
        life(f"resp {resp_ref}")
        context += f"\n{resp}\n"
        if not tool_calls:
            if content.strip():
                tg.send(content.strip())
            tool_called = False
            last_turn_end = time.time()
            open(f"{SELF_DIR}/context.md", "w").write(context)
            continue
        tool_called = True
        tc = tool_calls[0]
        name = tc.function.name
        tc_args = json.loads(tc.function.arguments)
        def _timeout_handler(*_): raise TimeoutError("tool timed out")
        try:
            prev = signal.signal(signal.SIGALRM, _timeout_handler)
            signal.alarm(TOOL_TIMEOUT)
            result = run_tool(name, tc_args)
        except Exception as e:
            result = f"error: {e}"
        finally:
            signal.alarm(0)
            signal.signal(signal.SIGALRM, prev)
        _, result_ref = stash(result)
        life(f"{name} result {result_ref}")
        if len(result) <= RESULT_STASH_LIMIT:
            context += f"\n[{name}] {result}\n"
        else:
            context += f"\n[{name}] {result_ref}\n"
        if len(context) > CONTEXT_LIMIT:
            h = CONTEXT_LIMIT // 2
            _, ref = stash(context[:-h])
            context = f"{ref}\n{context[-h:]}"
            life(f"compacted -> {ref}")
        open(f"{SELF_DIR}/context.md", "w").write(context)

if __name__ == "__main__":
    main()
