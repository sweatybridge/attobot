#!/usr/bin/env python3
"""telegram bridge for one agent.

Config: agents/<self>/telegram_token and agents/<self>/telegram_chat (one line each).
Inbound:  telegram → append to bus/chat/<self>.md as `[ops <ts>] <text>`
Outbound: tail bus/chat/<self>.md, send any `[<self> ...]` line via sendMessage.
"""
import config  # loads .env into os.environ
import bus
import os, pathlib, requests, sys, threading, time

AGENTS_DIR = os.environ.get("AGENTS_DIR", "agents")
BUS_DIR = os.environ.get("BUS_DIR", "bus")
TG_MAX = int(os.environ.get("TG_MAX", "4000"))

SELF = sys.argv[1]
AGENT = pathlib.Path(AGENTS_DIR) / SELF
TOKEN = (AGENT / "telegram_token").read_text().strip()
CHAT  = (AGENT / "telegram_chat").read_text().strip()

# tg declares its bus participation: publishes to bus/telegram, subscribes to bus/chat.
TG_DIR = AGENT / "bridges" / "tg"
TG_PUB = TG_DIR / "pubs" / "telegram" / f"{SELF}.log"   # writes telegram inbound here (→ bus/telegram)
TG_SUB = TG_DIR / "subs" / "chat" / f"{SELF}.log"       # reads agent chat here (→ bus/chat)
TG_SUB_OFFSET = TG_DIR / "subs" / "chat" / f"{SELF}.offset"

for kind, link, side in [("telegram", TG_PUB, "pubs"), ("chat", TG_SUB, "subs")]:
    bus_path = pathlib.Path(BUS_DIR) / kind / f"{SELF}.log"
    bus_path.parent.mkdir(parents=True, exist_ok=True)
    bus_path.touch(exist_ok=True)
    link.parent.mkdir(parents=True, exist_ok=True)
    if not link.is_symlink():
        link.symlink_to(bus_path.resolve())

def now(): return time.strftime("%Y%m%dT%H%M%S")

def api(method, **params):
    r = requests.post(f"https://api.telegram.org/bot{TOKEN}/{method}", data=params, timeout=45)
    return r.json().get("result")

def split(text, n):
    return [text[i:i+n] for i in range(0, len(text), n)] or [""]

def poll_in():
    offset = 0
    while True:
        try:
            for u in api("getUpdates", offset=offset, timeout=25) or []:
                offset = u["update_id"] + 1
                text = (u.get("message") or {}).get("text") or ""
                if not text: continue
                bus.append(str(TG_PUB), f"[ops {now()}] {text}\n")
        except Exception as e:
            print(f"poll: {e}"); time.sleep(5)

def tail_out():
    while True:
        time.sleep(2)
        try:
            data = bus.read_new(str(TG_SUB), str(TG_SUB_OFFSET))
            if not data: continue
            for line in data.splitlines():
                if line.strip():
                    for chunk in split(line, TG_MAX):
                        api("sendMessage", chat_id=CHAT, text=chunk)
        except Exception as e:
            print(f"tail: {e}"); time.sleep(5)

threading.Thread(target=poll_in, daemon=True).start()
tail_out()
