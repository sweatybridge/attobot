"""Mail inbox watcher per agent. Imported by agent.py.

Watches agents/<self>/mail_inbox/ via inotify. Drops → bus/mail/<self>.log + tg.send.
"""
import bus
import tg
import os, pathlib, pwd, threading, time
from inotify_simple import INotify, flags as iflags

PREVIEW = int(os.environ.get("INBOX_PREVIEW", "1000"))


def start(self_id):
    inbox = pathlib.Path(f"agents/{self_id}/mail_inbox")
    inbox.mkdir(parents=True, exist_ok=True)
    bus_mail = f"bus/mail/{self_id}.log"

    def deliver(drop):
        sender = pwd.getpwuid(drop.stat().st_uid).pw_name
        text = drop.read_bytes()[:PREVIEW * 4].decode("utf-8", errors="replace")[:PREVIEW]
        bus.append(bus_mail, f"[{sender} {time.strftime('%Y%m%dT%H%M%S')}] {drop}\n{text}\n---\n")
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
