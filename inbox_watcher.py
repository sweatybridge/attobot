"""Email inbox watcher per agent. Imported by agent.py.

Watches agents/<self>/email_inbox/ via inotify. On file drop:
  - Append to bus/email/<self>.log (agent's email stream)
  - If telegram is configured, also notify the operator's chat
"""
import bus
import os, pathlib, pwd, requests, threading, time
from inotify_simple import INotify, flags as iflags

PREVIEW = int(os.environ.get("INBOX_PREVIEW", "1000"))


def _now(): return time.strftime("%Y%m%dT%H%M%S")


def start(self_id):
    agents_dir = os.environ.get("AGENTS_DIR", "agents")
    bus_dir = os.environ.get("BUS_DIR", "bus")
    agent = pathlib.Path(agents_dir) / self_id
    inbox = agent / "email_inbox"
    inbox.mkdir(parents=True, exist_ok=True)
    (inbox / "processed").mkdir(exist_ok=True)
    bus_email = pathlib.Path(bus_dir) / "email" / f"{self_id}.log"

    token_file = agent / "telegram_token"
    chat_file = agent / "telegram_chat"
    tg_token = token_file.read_text().strip() if token_file.exists() else None
    tg_chat = chat_file.read_text().strip() if chat_file.exists() else None

    def notify_tg(text):
        if not (tg_token and tg_chat): return
        try:
            requests.post(f"https://api.telegram.org/bot{tg_token}/sendMessage",
                          data={"chat_id": tg_chat, "text": text}, timeout=10)
        except Exception as e:
            print(f"inbox tg notify: {e}")

    def deliver(drop):
        try: sender = pwd.getpwuid(drop.stat().st_uid).pw_name
        except (KeyError, OSError): sender = "?"
        try: text = drop.read_bytes()[:PREVIEW * 4].decode("utf-8", errors="replace")[:PREVIEW]
        except OSError as e: text = f"[read failed: {e}]"
        bus.append(bus_email, f"[{sender} {_now()}] {drop}\n{text}\n---\n")
        notify_tg(f"📬 mail from {sender}\n{text}")

    def watch():
        ino = INotify()
        ino.add_watch(str(inbox), iflags.CREATE | iflags.MOVED_TO)
        while True:
            for ev in ino.read():
                t = inbox / ev.name
                if t.is_file() and not t.name.startswith("."):
                    deliver(t)

    threading.Thread(target=watch, daemon=True, name="inbox-watch").start()
