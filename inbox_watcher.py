"""Mail inbox watcher per agent. Imported by agent.py.

Polls agents/<self>/mail_inbox/ for new files. Drops → APPEND_MESSAGE + SEND_CHAT.
"""
import os, pathlib, pwd, threading, time
from tools.append_message import run as append_message
from tools.send_chat import run as send_chat

PREVIEW = int(os.environ.get("INBOX_PREVIEW", "1000"))
TICK = int(os.environ.get("INBOX_TICK", "2"))


def start(self_id):
    inbox = pathlib.Path(f"agents/{self_id}/mail_inbox")
    inbox.mkdir(parents=True, exist_ok=True)

    def deliver(drop):
        sender = pwd.getpwuid(drop.stat().st_uid).pw_name
        text = drop.read_bytes()[:PREVIEW * 4].decode("utf-8", errors="replace")[:PREVIEW]
        append_message({"role": "system", "content": f"[mail from {sender}] {drop.name}\n{text}"})
        send_chat({"text": f"📬 mail from {sender}\n{text}"})

    def watch():
        seen = set(inbox.iterdir())
        while True:
            current = set(inbox.iterdir())
            for f in current - seen:
                if f.is_file() and not f.name.startswith("."):
                    deliver(f)
            seen = current
            time.sleep(TICK)

    threading.Thread(target=watch, daemon=True, name="inbox-poll").start()
