#!/usr/bin/env python3
"""File in agents/<self>/email_inbox/ → line in bus/email_inbox/<self>.md."""
import config  # loads .env into os.environ
import bus
import os, pathlib, pwd, time
from inotify_simple import INotify, flags as iflags

AGENTS = pathlib.Path(os.environ.get("AGENTS_DIR", "agents"))
BUS_EMAIL = pathlib.Path(os.environ.get("BUS_DIR", "bus")) / "email"
PREVIEW = int(os.environ.get("INBOX_PREVIEW", "1000"))

def now(): return time.strftime("%Y%m%dT%H%M%S")

def deliver(drop):
    sender = pwd.getpwuid(drop.stat().st_uid).pw_name
    text = drop.read_bytes()[:PREVIEW * 4].decode("utf-8", errors="replace")[:PREVIEW]
    bus.append(BUS_EMAIL / f"{drop.parent.parent.name}.log", f"[{sender} {now()}] {drop}\n{text}\n---\n")

AGENTS.mkdir(parents=True, exist_ok=True)
ino = INotify()
wds = {}

def watch(d):
    inbox = d / "email_inbox"
    inbox.mkdir(parents=True, exist_ok=True)
    wds[ino.add_watch(str(inbox), iflags.CREATE | iflags.MOVED_TO)] = inbox

for d in AGENTS.iterdir():
    if d.is_dir(): watch(d)
wds[ino.add_watch(str(AGENTS), iflags.CREATE)] = AGENTS

while True:
    for ev in ino.read():
        parent = wds.get(ev.wd)
        if parent is None: continue
        t = parent / ev.name
        if parent == AGENTS:
            if t.is_dir(): watch(t)
        elif t.is_file() and not t.name.startswith("."):
            deliver(t)
