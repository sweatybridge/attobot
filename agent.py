#!/usr/bin/env python3
"""Minimal blob-memory agent. See README.md for design."""
import json, os, re, sys, time, hashlib, signal, subprocess, litellm

MODEL = "openai/deepseek-v4-pro"
API_BASE = "https://api.deepseek.com/v1"
BLOB_DIR = "blobs"
BUS_DIR = "bus"
BUS_CHAT_DIR = "bus/chat"
BUS_INBOX_DIR = "bus/email_inbox"
CONTEXT_LIMIT = 160000  # ~40k tokens at 4 chars/token
RESULT_STASH_LIMIT = 2000
TOOL_TIMEOUT = 60
LIFE_TAIL = 50
AGENTS_DIR = "agents"
MEMORY_LIMIT = 10000
HEARTBEAT_INTERVAL = 60
VERBOSE = "--verbose" in sys.argv

REF_RE = re.compile(r'◱hash=(\w+) gist=[^◲]*◲')   # matches blob refs in context
# escaping: ◱◲ = structure (ref delimiters), ◰◳ = escape wrapper (like HTML & ;)
# ◰➀◳=◰  ◰➁◳=◳  ◰➂◳=◱  ◰➃◳=◲
_ESC = {'➀': '◰', '➁': '◳', '➂': '◱', '➃': '◲'}
_RESC = {v: k for k, v in _ESC.items()}

def escape_refs(text):
    """Escape structural chars so they won't be parsed as live refs. Single-pass to avoid cascade."""
    return re.sub(r'[◰◳◱◲]', lambda m: '◰' + _RESC[m.group()] + '◳', text)

def unescape_refs(text):
    """Reverse escape_refs. Single-pass regex to avoid ordering issues."""
    return re.sub(r'◰([➀➁➂➃])◳', lambda m: _ESC[m.group(1)], text)

# native tool calling — tool definitions as JSON schemas
TOOLS = [
    {"type": "function", "function": {"name": "READ_BLOB", "description": "Read a blob by hash or ref. Optional offset/limit for large blobs.",
        "parameters": {"type": "object", "properties": {"hash": {"type": "string"}, "offset": {"type": "integer"}, "limit": {"type": "integer"}}, "required": ["hash"]}}},
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
    {"type": "function", "function": {"name": "COMPACT", "description": "Dump the first half of context to a blob, leaving a ref in its place.",
        "parameters": {"type": "object", "properties": {}, "required": []}}},
    {"type": "function", "function": {"name": "UNCOMPACT", "description": "Rehydrate a compacted blob ref inline in context.",
        "parameters": {"type": "object", "properties": {"hash": {"type": "string"}}, "required": ["hash"]}}},
]

for d in (BLOB_DIR, BUS_CHAT_DIR, BUS_INBOX_DIR, AGENTS_DIR): os.makedirs(d, exist_ok=True)

SELF = None      # agent identity — hash of (SOUL + boot timestamp), set in main()
SELF_DIR = None  # agents/<SELF>/
LIFE_PATH = None # agents/<SELF>/LIFE.md
MEMORY_PATH = None   # agents/<SELF>/MEMORY.md (per-agent working memory)
INBOX_PATH = None    # bus/email_inbox/<SELF>.md
INBOX_DROP_DIR = None  # agents/<SELF>/email_inbox/
tail_offsets = {}  # chat_id -> last byte offset read

def now():
    return time.strftime("%Y%m%dT%H%M%S")

def life(event):
    line = f"[{now()}] {event}"
    with open(LIFE_PATH, "a") as f:
        f.write(line + "\n")
    if VERBOSE:
        print(line, flush=True)

def stash(content, gist="", refs=()):
    """Write content to a blob file, return (hash, ref_string)."""
    refs_line = " ".join(refs)
    body = f"---\nat: {now()}\ngist: {gist}\nrefs: {refs_line}\n---\n{content}"
    h = hashlib.sha256(body.encode()).hexdigest()[:12]
    open(f"{BLOB_DIR}/{h}", "w").write(body)
    safe = escape_refs(gist.replace("\n", " "))[:101]
    return h, f"◱hash={h} gist={safe}◲"

def blob_body(h):
    """Return blob content (everything after the frontmatter)."""
    text = open(f"{BLOB_DIR}/{h}").read()
    return text.split("\n---\n", 1)[1] if "\n---\n" in text else text

def llm(prompt, *, strip_reasoning, tools=None):
    """Call LLM. Returns (content, reasoning, tool_calls). Compaction calls pass tools=None."""
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

def compact(context):
    """Dump the first half of context to a blob, leave a ref in its place."""
    lines = context.splitlines()
    if len(lines) < 2:
        return context
    half = len(lines) // 2
    head = "\n".join(lines[:half])
    rest = "\n".join(lines[half:])
    gist = head[:80].replace("\n", " ").strip()
    _, ref = stash(head, gist=f"forgotten: {gist}")
    life(f"compact: {len(context)}ch -> ref {ref} + {len(rest)}ch tail")
    return f"{ref}\n{rest}"

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
    if name == "READ_BLOB":
        h = args["hash"]
        m = REF_RE.search(h)  # accept full ref string or bare hash
        if m: h = m.group(1)
        return _read_lines(f"{BLOB_DIR}/{h}", args.get("offset", 0), args.get("limit"))
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
    return f"unknown tool: {name}"

def tail_bus():
    """Read new bytes from all subscribed bus streams, strip own lines, return tagged content."""
    blocks = []
    own_prefix = f"[{SELF} "
    subs_dir = f"{SELF_DIR}/subs"
    if not os.path.isdir(subs_dir):
        return ""
    for fname in sorted(os.listdir(subs_dir)):
        if not fname.endswith(".md"):
            continue
        chat_id = fname[:-3]
        path = f"{subs_dir}/{fname}"
        try:
            data = open(path).read()
        except FileNotFoundError:
            continue
        offset = tail_offsets.get(chat_id, 0)
        if len(data) <= offset:
            tail_offsets[chat_id] = len(data)
            continue
        new = data[offset:]
        tail_offsets[chat_id] = len(data)
        lines = [ln for ln in new.splitlines() if ln and not ln.startswith(own_prefix)]
        if lines:
            blocks.append(f"[chat:{chat_id}]\n" + "\n".join(lines))
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
        SELF, self_ref = stash(
            f"soul:\n{soul_text}\nboot: {boot_ts}",
            gist=f"agent identity, booted {boot_ts}",
        )
        resumed = False
    SELF_DIR = f"{AGENTS_DIR}/{SELF}"
    LIFE_PATH = f"{SELF_DIR}/LIFE.md"
    MEMORY_PATH = f"{SELF_DIR}/MEMORY.md"
    INBOX_PATH = f"{BUS_INBOX_DIR}/{SELF}.md"
    INBOX_DROP_DIR = f"{SELF_DIR}/email_inbox"
    os.makedirs(f"{SELF_DIR}/subs", exist_ok=True)
    os.makedirs(INBOX_DROP_DIR, exist_ok=True)
    os.makedirs(f"{INBOX_DROP_DIR}/processed", exist_ok=True)
    os.makedirs(BUS_INBOX_DIR, exist_ok=True)
    if not os.path.exists(INBOX_PATH):
        open(INBOX_PATH, "w").write("")
    inbox_sub = f"{SELF_DIR}/subs/email_inbox.md"
    if not os.path.lexists(inbox_sub):
        os.symlink(os.path.abspath(INBOX_PATH), inbox_sub)
    if not os.path.exists(MEMORY_PATH):
        open(MEMORY_PATH, "w").write("# Memory\n\nLearned preferences, strategies, and notes. Edit with EDIT_FILE.\n")
    soul = open("SOUL.md").read().replace("<self>", SELF)
    harness = open(__file__).read()
    if resumed:
        ctx_path = f"{SELF_DIR}/context.md"
        context = open(ctx_path).read() if os.path.exists(ctx_path) else ""
        subs_dir = f"{SELF_DIR}/subs"
        for fname in os.listdir(subs_dir):
            if fname.endswith(".md"):
                try:
                    tail_offsets[fname[:-3]] = os.path.getsize(f"{subs_dir}/{fname}")
                except OSError:
                    pass
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
        gist_text = resp[:50] + "…" + resp[-50:] if len(resp) > 101 else resp  # 50 + 1 (…) + 50
        _, resp_ref = stash(resp, gist=f"turn {turn} resp: {gist_text}")
        life(f"turn {turn} resp {resp_ref}")
        context += f"\n{resp}\n"
        if not tool_calls:
            if content.strip():
                chat_path = f"{BUS_CHAT_DIR}/{SELF}.md"
                with open(chat_path, "a") as f:
                    f.write(f"[{SELF} {now()}] {content.strip()}\n")
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
            if name == "COMPACT":
                context = compact(context)
                result = f"compacted to {len(context)}ch"
            elif name == "UNCOMPACT":
                h = tc_args["hash"]
                m = REF_RE.search(h)
                if m: h = m.group(1)
                body = blob_body(h)
                found = False
                for cm in REF_RE.finditer(context):
                    if cm.group(1) == h:
                        context = context[:cm.start()] + body + context[cm.end():]
                        found = True
                        break
                result = f"uncompacted {h}" if found else f"ref {h} not in context"
            else:
                result = run_tool(name, tc_args)
        except Exception as e:
            result = f"error: {e}"
        finally:
            signal.alarm(0)
            signal.signal(signal.SIGALRM, prev)
        # all tools get their result into context
        gist_text = result[:50] + "…" + result[-50:] if len(result) > 101 else result  # 50 + 1 (…) + 50
        _, result_ref = stash(result, gist=f"turn {turn} {name}: {gist_text}")
        args_str = json.dumps(tc_args, ensure_ascii=False)
        args_short = args_str[:50] + "…" + args_str[-50:] if len(args_str) > 101 else args_str  # 50 + 1 (…) + 50
        life(f"turn {turn} {name} `{args_short}` result {result_ref}")
        if name == "READ_BLOB" or len(result) <= RESULT_STASH_LIMIT:
            context += f"\n[{name}] {escape_refs(result)}\n"
        else:
            context += f"\n[{name}] {result_ref}\n"
        while len(context) > CONTEXT_LIMIT:
            context = compact(context)
        open(f"{SELF_DIR}/context.md", "w").write(context)

if __name__ == "__main__":
    main()
