"""Telegram bridge. Imported by agent.py.

Reads telegram_token and telegram_chat from CWD.
Inbound: long-polls Telegram, writes to bus/telegram/<self>.log.
Outbound: agent calls tg.send(text) directly.
"""
import bus
import os, pathlib, requests, threading, time

TG_MAX = int(os.environ.get("TG_MAX", "4000"))

_token = None
_chat_id = None


def _api(method, **params):
    r = requests.post(f"https://api.telegram.org/bot{_token}/{method}", data=params, timeout=45)
    return r.json().get("result")


def send(text):
    for i in range(0, len(text), TG_MAX):
        _api("sendMessage", chat_id=_chat_id, text=text[i:i+TG_MAX])


def start(self_id):
    global _token, _chat_id
    _token = pathlib.Path("telegram_token").read_text().strip()
    _chat_id = pathlib.Path("telegram_chat").read_text().strip()
    bus_telegram = f"bus/telegram/{self_id}.log"
    poll_offset = pathlib.Path(f"agents/{self_id}/tg_poll.offset")

    def poll_in():
        try: offset = int(poll_offset.read_text())
        except (FileNotFoundError, ValueError): offset = 0
        while True:
            try:
                advanced = False
                for u in _api("getUpdates", offset=offset, timeout=25) or []:
                    offset = u["update_id"] + 1
                    advanced = True
                    text = (u.get("message") or {}).get("text") or ""
                    if not text: continue
                    bus.append(bus_telegram, f"[ops {time.strftime('%Y%m%dT%H%M%S')} tg:{u['update_id']}] {text}\n")
                if advanced:
                    poll_offset.write_text(str(offset))
            except Exception as e:
                print(f"tg poll: {e}"); time.sleep(5)

    threading.Thread(target=poll_in, daemon=True, name="tg-poll").start()
