"""Mail inbox watcher per agent. Imported by agent.py.

Watches agents/<self>/mail_inbox/ via inotify. On file drop:
  - Append to bus/mail/<self>.log
  - Notify operator via tg.send
"""
import bus
import tg
import os, pathlib, pwd, threading, time
from inotify_simple import INotify, flags as iflags

PREVIEW = int(os.environ.get("INBOX_PREVIEW", "1000"))


def _now(): return time.strftime("%Y%m%dT%H%M%S")


def start(self_id):
    agents_dir = os.environ.get("AGENTS_DIR", "agents")
    bus_dir = os.environ.get("BUS_DIR", "bus")
    agent = pathlib.Path(agents_dir) / self_id
    inbox = agent / "mail_inbox"
    inbox.mkdir(parents=True, exist_ok=True)
    (inbox / "processed").mkdir(exist_ok=True)
    bus_mail = pathlib.Path(bus_dir) / "mail" / f"{self_id}.log"

    def deliver(drop):
        try: sender = pwd.getpwuid(drop.stat().st_uid).pw_name
        except (KeyError, OSError): sender = "?"
        try: text = drop.read_bytes()[:PREVIEW * 4].decode("utf-8", errors="replace")[:PREVIEW]
        except OSError as e: text = f"[read failed: {e}]"
        bus.append(bus_mail, f"[{sender} {_now()}] {drop}\n{text}\n---\n")
        tg.send(f"📬 mail from {sender}\n{text}")

    def watch():
        ino = INotify()
        ino.add_watch(str(inbox), iflags.CREATE | iflags.MOVED_TO)
        while True:
            for ev in ino.read():
                t = inbox / ev.name
                if t.is_file() and not t.name.startswith("."):
                    deliver(t)

    threading.Thread(target=watch, daemon=True, name="inbox-watch").start()
