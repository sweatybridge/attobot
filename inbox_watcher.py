"""Mail inbox watcher per agent. Imported by agent.py.

Polls agents/<self>/mail_inbox/ for new files. Drops → messages.jsonl as role:system + tg.send.
"""
import tg
import fcntl, json, pathlib, pwd, threading, time

PREVIEW = 1000
TICK = 2


def start(self_id):
    inbox = pathlib.Path(f"agents/{self_id}/mail_inbox")
    inbox.mkdir(parents=True, exist_ok=True)
    messages_path = f"agents/{self_id}/messages.jsonl"

    def deliver(drop):
        sender = pwd.getpwuid(drop.stat().st_uid).pw_name
        text = drop.read_bytes()[:PREVIEW * 4].decode("utf-8", errors="replace")[:PREVIEW]
        obj = {"role": "system", "content": f"[mail from {sender}] {drop.name}\n{text}"}
        with open(messages_path, "a") as fp:
            fcntl.flock(fp, fcntl.LOCK_EX)
            fp.write(json.dumps(obj) + "\n")
        tg.send(f"📬 mail from {sender}\n{text}")

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
