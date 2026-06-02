#!/usr/bin/env python3
"""Minimal blob-memory agent. See README.md for design."""
import config  # loads .env into os.environ
import bus
import tg
import cron
import inbox_watcher
import json, os, re, sys, time, hashlib, signal, subprocess, litellm

MODEL = os.environ.get("MODEL", "openai/deepseek-v4-pro")
API_BASE = os.environ.get("API_BASE", "https://api.deepseek.com/v1")
BLOB_DIR = os.environ.get("BLOB_DIR", "blobs")
BUS_DIR = os.environ.get("BUS_DIR", "bus")
CONTEXT_LIMIT = int(os.environ.get("CONTEXT_LIMIT", "160000"))
RESULT_STASH_LIMIT = int(os.environ.get("RESULT_STASH_LIMIT", "2000"))
TOOL_TIMEOUT = int(os.environ.get("TOOL_TIMEOUT", "60"))
LIFE_TAIL = int(os.environ.get("LIFE_TAIL", "50"))
AGENTS_DIR = os.environ.get("AGENTS_DIR", "agents")
MEMORY_LIMIT = int(os.environ.get("MEMORY_LIMIT", "10000"))
HEARTBEAT_INTERVAL = int(os.environ.get("HEARTBEAT_INTERVAL", "60"))
VERBOSE = "--verbose" in sys.argv

# native tool calling — tool definitions as JSON schemas
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

SELF = None      # agent identity — hash of (SOUL + boot timestamp), set in main()
SELF_DIR = None  # agents/<SELF>/
LIFE_PATH = None # agents/<SELF>/LIFE.md
MEMORY_PATH = None   # agents/<SELF>/MEMORY.md (per-agent working memory)
INBOX_PATH = None    # bus/email_inbox/<SELF>.md
INBOX_DROP_DIR = None  # agents/<SELF>/email_inbox/

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

def llm(prompt, *, strip_reasoning, tools=None):
    """Call LLM. Returns (content, reasoning, tool_calls)."""
    kwargs = dict(model=MODEL, api_base=API_BASE, api_key=os.environ["DEEPSEEK_API_KEY"],
                  messages=[{"role": "user", "content": prompt}])
    if tools:
        kwargs["tools"] = tools
    msg = litellm.completion(**kwargs).choices[0].message
    reasoning = getattr(msg, "reasoning_content", None) or ""
    content = msg.content or ""
    tc = msg.tool_calls if hasattr(msg, "tool_calls") else None
    if strip_reasoning:
        return content, "", None
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

def last_turn_number():
    try: matches = re.findall(r'turn (\d+)', open(LIFE_PATH).read())
    except FileNotFoundError: return 0
    return max(int(m) for m in matches) if matches else 0

def run_tool(name, args):
    """Execute a tool. args is a dict from parsed JSON."""
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
    """Walk subs/ recursively. For each *.log (symlink to bus stream), read new content
    since this consumer's cursor, strip own lines, return tagged content."""
    import pathlib as _p
    subs_dir = _p.Path(SELF_DIR) / "subs"
    if not subs_dir.is_dir():
        return ""
    blocks = []
    own_prefix = f"[{SELF} "
    for log_path in sorted(subs_dir.rglob("*.log")):
        offset_path = log_path.with_suffix(".offset")
        content = bus.read_new(str(log_path), str(offset_path))
        if not content:
            continue
        lines = [ln for ln in content.splitlines() if ln and not ln.startswith(own_prefix)]
        if lines:
            rel = log_path.relative_to(subs_dir).with_suffix("")
            blocks.append(f"[{rel}]\n" + "\n".join(lines))
    return "\n\n".join(blocks)

def main():
    global SELF, SELF_DIR, LIFE_PATH, MEMORY_PATH, INBOX_PATH, INBOX_DROP_DIR
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    resume = args[0] if args else None
    if resume:
        if not os.path.isdir(f"{AGENTS_DIR}/{resume}"):
            raise SystemExit(f"agent dir not found: {AGENTS_DIR}/{resume}")
        SELF = resume
        resumed = True
    else:
        soul_text = open("SOUL.md").read()
        boot_ts = now()
        SELF, self_ref = stash(f"soul:\n{soul_text}\nboot: {boot_ts}")
        resumed = False
    SELF_DIR = f"{AGENTS_DIR}/{SELF}"
    LIFE_PATH = f"{SELF_DIR}/LIFE.md"
    MEMORY_PATH = f"{SELF_DIR}/MEMORY.md"
    INBOX_DROP_DIR = f"{SELF_DIR}/email_inbox"
    os.makedirs(INBOX_DROP_DIR, exist_ok=True)
    os.makedirs(f"{INBOX_DROP_DIR}/processed", exist_ok=True)
    os.makedirs(f"{SELF_DIR}/cron", exist_ok=True)
    import pathlib as _p
    subs_root = _p.Path(SELF_DIR) / "subs"
    pubs_root = _p.Path(SELF_DIR) / "pubs"
    for kind in ["email", "telegram", "cron"]:
        bus_path = _p.Path(f"{BUS_DIR}/{kind}/{SELF}.log")
        bus_path.parent.mkdir(parents=True, exist_ok=True)
        bus_path.touch(exist_ok=True)
        sub = subs_root / kind / f"{SELF}.log"
        sub.parent.mkdir(parents=True, exist_ok=True)
        if not sub.is_symlink():
            sub.symlink_to(bus_path.resolve())
    for kind in ["chat"]:
        bus_path = _p.Path(f"{BUS_DIR}/{kind}/{SELF}.log")
        bus_path.parent.mkdir(parents=True, exist_ok=True)
        bus_path.touch(exist_ok=True)
        pub = pubs_root / kind / f"{SELF}.log"
        pub.parent.mkdir(parents=True, exist_ok=True)
        if not pub.is_symlink():
            pub.symlink_to(bus_path.resolve())
    if not os.path.exists(MEMORY_PATH):
        open(MEMORY_PATH, "w").write("# Memory\n\nLearned preferences, strategies, and notes. Edit with EDIT_FILE.\n")
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
    turn = last_turn_number()
    last_turn_end = time.time()
    tool_called = False
    while True:
        # check for inbound every iteration
        inbound = tail_bus()
        if inbound:
            context += f"\n{inbound}\n"
            inbound_short = inbound[:50] + "…" + inbound[-50:] if len(inbound) > 101 else inbound  # 50 + 1 (…) + 50
            life(f"inbound: {inbound_short}")
        elif not tool_called:
            # idle — wait for messages or heartbeat
            if time.time() - last_turn_end >= HEARTBEAT_INTERVAL:
                context += "\n<heartbeat/>\n"
                life("heartbeat")
            else:
                time.sleep(1)
                continue
        # every LLM call is a turn
        turn += 1
        memory_raw = open(MEMORY_PATH).read()
        if len(memory_raw) > MEMORY_LIMIT:
            half = MEMORY_LIMIT // 2
            memory = memory_raw[:half] + "\n…\n" + memory_raw[-half:] + "\n[WARNING: MEMORY.md is over the limit and has been truncated. Make it smaller.]"
        else:
            memory = memory_raw
        lt = life_tail()
        prompt = (f"<soul>\n{soul}\n</soul>\n\n"
                  f"<harness>\n{harness}\n</harness>\n\n"
                  f"<memory>\n{memory}\n</memory>\n\n"
                  f"<context>\n{context}\n</context>\n\n<life>\n{lt}\n</life>")
        content, reasoning, tool_calls = llm(prompt, strip_reasoning=False, tools=TOOLS)
        # build resp text for context (reasoning + content, no tool markers)
        resp = ""
        if reasoning: resp += f"<reasoning>\n{reasoning}\n</reasoning>\n"
        if content: resp += content
        _, resp_ref = stash(resp)
        life(f"turn {turn} resp {resp_ref}")
        context += f"\n{resp}\n"
        if not tool_calls:
            if content.strip():
                bus.append(f"{SELF_DIR}/pubs/chat/{SELF}.log", f"[{SELF} {now()}] {content.strip()}\n")
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
        # all tools get their result into context
        _, result_ref = stash(result)
        life(f"turn {turn} {name} result {result_ref}")
        if len(result) <= RESULT_STASH_LIMIT:
            context += f"\n[{name}] {result}\n"
        else:
            context += f"\n[{name}] {result_ref}\n"
        while len(context) > CONTEXT_LIMIT:
            lines = context.splitlines()
            if len(lines) < 2: break
            half = len(lines) // 2
            head, rest = "\n".join(lines[:half]), "\n".join(lines[half:])
            _, ref = stash(head)
            context = f"{ref}\n{rest}"
            life(f"stashed older half -> {ref} (+{len(rest)}ch tail)")
        open(f"{SELF_DIR}/context.md", "w").write(context)

if __name__ == "__main__":
    main()
