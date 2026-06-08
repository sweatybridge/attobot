"""Stash a range of lines from a messages.jsonl file into a blob, replacing them with a placeholder.

Useful for surgical context-pruning — e.g. drop a long noisy stretch of tool output
in the middle of your history while keeping the framing turns on either side.

If `path` is omitted, operates on your own conversation log.
"""
import fcntl
import json

from agent import AGENTS_DIR, SELF, stash

NAME = "STASH_MESSAGES"
DESCRIPTION = "Stash a contiguous range of lines from a messages.jsonl file into a blob, leaving a placeholder in their place. Defaults to your own conversation log. Lines are 1-indexed, end is inclusive."
PARAMETERS = {
    "type": "object",
    "properties": {
        "path": {"type": "string"},
        "start": {"type": "integer"},
        "end": {"type": "integer"},
    },
    "required": ["start", "end"],
}


def run(args):
    path = args.get("path") or f"{AGENTS_DIR}/{SELF}/messages.jsonl"
    start = int(args["start"])
    end = int(args["end"])
    with open(path, "r+") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        lines = f.read().splitlines()
        n = len(lines)
        if start < 1 or end > n or start > end:
            return f"error: invalid range start={start} end={end} (file has {n} lines)"
        head = "\n".join(lines[start - 1:end])
        marker = stash(head)
        placeholder = json.dumps({
            "role": "system",
            "content": f"<lines {start}-{end} stashed: {marker}>",
        })
        new_lines = lines[:start - 1] + [placeholder] + lines[end:]
        f.seek(0)
        f.truncate()
        for line in new_lines:
            f.write(line + "\n")
    return f"stashed lines {start}-{end} to {marker}"
