#!/usr/bin/env python3
"""Filesystem email-inbox bridge.

Watches `agents/*/email_inbox/` for new files. When a top-level file
appears in `agents/<self>/email_inbox/<filename>`, appends a line to
`bus/email_inbox/<self>.md` and moves the source file to
`agents/<self>/email_inbox/processed/`.

If the file looks RFC822-shaped (has `From:`/`Subject:` headers),
the bus line is formatted with those headers. Otherwise the body is
treated as plain content with sender parsed from the filename.

Newly-created agents (mkdir under agents/) are watched automatically.
"""
import os
import pathlib
import shutil
import sys
import time

from inotify_simple import INotify, flags as iflags

AGENTS_DIR = pathlib.Path(os.environ.get("AGENTS_DIR", "agents"))
BUS_INBOX_DIR = pathlib.Path(os.environ.get("BUS_INBOX_DIR", "bus/email_inbox"))
INBOX_SUBDIR = "email_inbox"
PREVIEW_CHARS = 4000


def now():
    return time.strftime("%Y%m%dT%H%M%S")


def known_agents():
    if not AGENTS_DIR.is_dir():
        return []
    return [d.name for d in AGENTS_DIR.iterdir() if d.is_dir()]


def parse_sender_from_filename(filename: str, agents: list[str]) -> str:
    """Longest known-agent name that filename starts with, followed by '-'."""
    candidates = sorted(
        (n for n in agents if filename.startswith(n + "-")),
        key=len, reverse=True,
    )
    if candidates:
        return candidates[0]
    if "-" in filename:
        return filename.split("-", 1)[0]
    return filename


def parse_email(text: str) -> tuple[dict[str, str], str]:
    """Extract RFC822-ish headers if present. Returns (headers, body).
    Headers empty if file isn't email-shaped."""
    if "\n\n" not in text:
        return {}, text
    head, _, body = text.partition("\n\n")
    headers: dict[str, str] = {}
    for line in head.splitlines():
        if ":" in line and not line.startswith(" "):
            k, _, v = line.partition(":")
            headers[k.strip().lower()] = v.strip()
    if "from" not in headers and "subject" not in headers:
        return {}, text
    return headers, body


def is_top_level_drop(p: pathlib.Path) -> bool:
    if not p.is_file():
        return False
    if p.name.startswith(".") or p.name.endswith(".tmp"):
        return False
    if p.parent.name == "processed":
        return False
    return True


def file_text(path: pathlib.Path) -> str:
    """First PREVIEW_CHARS as utf-8, or a path marker if binary."""
    try:
        with path.open("rb") as f:
            head = f.read(PREVIEW_CHARS * 4)
    except OSError as e:
        return f"[read failed: {e}]"
    if b"\x00" in head:
        return f"[binary file at {path}]"
    try:
        return head.decode("utf-8", errors="strict")[:PREVIEW_CHARS]
    except UnicodeDecodeError:
        return f"[non-utf8 file at {path}]"


def deliver(drop: pathlib.Path):
    """drop = agents/<recipient>/email_inbox/<filename>"""
    recipient = drop.parent.parent.name
    inbox_md = BUS_INBOX_DIR / f"{recipient}.md"
    text = file_text(drop)
    headers, body = parse_email(text)
    body = body.rstrip("\n")
    if headers:
        sender = headers.get("from") or parse_sender_from_filename(drop.name, known_agents())
        ts = headers.get("date") or now()
        subject = headers.get("subject", "")
        head_line = f"[{sender} {ts}]"
        if subject:
            head_line += f" Subject: {subject}"
        if "\n" in body:
            line = f"{head_line}\n```\n{body}\n```\n"
        else:
            line = f"{head_line} {body}\n"
    else:
        sender = parse_sender_from_filename(drop.name, known_agents())
        if "\n" in body:
            body = "```\n" + body + "\n```"
        line = f"[{sender} {now()}] {body}\n"
    BUS_INBOX_DIR.mkdir(parents=True, exist_ok=True)
    with inbox_md.open("a") as f:
        f.write(line)
    processed = drop.parent / "processed"
    processed.mkdir(exist_ok=True)
    try:
        shutil.move(str(drop), str(processed / drop.name))
    except OSError as e:
        print(f"move failed for {drop}: {e}", file=sys.stderr)


def run():
    AGENTS_DIR.mkdir(parents=True, exist_ok=True)
    ino = INotify()
    inbox_mask = iflags.CREATE | iflags.MOVED_TO
    wds: dict[int, pathlib.Path] = {}

    def watch_agent(agent_dir: pathlib.Path):
        inbox = agent_dir / INBOX_SUBDIR
        inbox.mkdir(parents=True, exist_ok=True)
        try:
            wd = ino.add_watch(str(inbox), inbox_mask)
            wds[wd] = inbox
            print(f"watching {inbox}")
        except OSError as e:
            print(f"add_watch {inbox}: {e}", file=sys.stderr)

    for d in AGENTS_DIR.iterdir():
        if d.is_dir():
            watch_agent(d)

    # Watch AGENTS_DIR itself so new agents get watched on creation.
    root_wd = ino.add_watch(str(AGENTS_DIR), iflags.CREATE)
    wds[root_wd] = AGENTS_DIR

    while True:
        for ev in ino.read(timeout=None):
            parent = wds.get(ev.wd)
            if parent is None:
                continue
            target = parent / ev.name
            if parent == AGENTS_DIR:
                if target.is_dir():
                    watch_agent(target)
                continue
            if is_top_level_drop(target):
                deliver(target)


def main():
    try:
        run()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
