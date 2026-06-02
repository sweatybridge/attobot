"""Telegram bridge. Imported by agent.py and started in-process.

Reads agents/<self>/telegram_token and agents/<self>/telegram_chat.
Spawns two threads: poll (telegram → bus) and tail (bus → telegram).

Layout it creates:
  agents/<self>/tg/pubs/telegram/<self>.log    → bus/telegram/<self>.log
  agents/<self>/tg/subs/chat/<self>.log        → bus/chat/<self>.log
  agents/<self>/tg/subs/chat/<self>.offset     (bus cursor)
  agents/<self>/tg/poll.offset                 (telegram update_id cursor)
"""
import bus
import os, pathlib, requests, threading, time

TG_MAX = int(os.environ.get("TG_MAX", "4000"))


def _api(token, method, **params):
    r = requests.post(f"https://api.telegram.org/bot{token}/{method}", data=params, timeout=45)
    return r.json().get("result")


def _split(text, n):
    return [text[i:i+n] for i in range(0, len(text), n)] or [""]


def start(self_id):
    """Wire telegram bridge for this agent. No-op if telegram_token missing."""
    agents_dir = os.environ.get("AGENTS_DIR", "agents")
    bus_dir = os.environ.get("BUS_DIR", "bus")
    agent = pathlib.Path(agents_dir) / self_id
    token_file = agent / "telegram_token"
    chat_file = agent / "telegram_chat"
    if not (token_file.exists() and chat_file.exists()):
        return
    token = token_file.read_text().strip()
    chat_id = chat_file.read_text().strip()

    tg_dir = agent / "tg"
    tg_pub = tg_dir / "pubs" / "telegram" / f"{self_id}.log"
    tg_sub = tg_dir / "subs" / "chat" / f"{self_id}.log"
    tg_sub_offset = tg_dir / "subs" / "chat" / f"{self_id}.offset"
    poll_offset = tg_dir / "poll.offset"

    for kind, link in [("telegram", tg_pub), ("chat", tg_sub)]:
        bus_path = pathlib.Path(bus_dir) / kind / f"{self_id}.log"
        bus_path.parent.mkdir(parents=True, exist_ok=True)
        bus_path.touch(exist_ok=True)
        link.parent.mkdir(parents=True, exist_ok=True)
        if not link.is_symlink():
            link.symlink_to(bus_path.resolve())

    def now(): return time.strftime("%Y%m%dT%H%M%S")

    def poll_in():
        try: offset = int(poll_offset.read_text())
        except (FileNotFoundError, ValueError): offset = 0
        while True:
            try:
                advanced = False
                for u in _api(token, "getUpdates", offset=offset, timeout=25) or []:
                    offset = u["update_id"] + 1
                    advanced = True
                    text = (u.get("message") or {}).get("text") or ""
                    if not text: continue
                    bus.append(str(tg_pub), f"[ops {now()} tg:{u['update_id']}] {text}\n")
                if advanced:
                    poll_offset.write_text(str(offset))
            except Exception as e:
                print(f"tg poll: {e}"); time.sleep(5)

    def tail_out():
        while True:
            time.sleep(2)
            try:
                data = bus.read_new(str(tg_sub), str(tg_sub_offset))
                if not data: continue
                for line in data.splitlines():
                    if line.strip():
                        for chunk in _split(line, TG_MAX):
                            _api(token, "sendMessage", chat_id=chat_id, text=chunk)
            except Exception as e:
                print(f"tg tail: {e}"); time.sleep(5)

    threading.Thread(target=poll_in, daemon=True, name="tg-poll").start()
    threading.Thread(target=tail_out, daemon=True, name="tg-tail").start()
