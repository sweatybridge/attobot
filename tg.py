"""Telegram bridge. Imported by agent.py.

Polls telegram. Inbound text → agents/<self>/messages.jsonl as role:user.
Outbound: agent calls tg.send(text) directly.
"""
import fcntl, json, pathlib, requests, threading, time

TG_MAX = 4000

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
    chat_file = pathlib.Path("telegram_chat")
    _chat_id = chat_file.read_text().strip() if chat_file.exists() else None

    messages_path = f"agents/{self_id}/messages.jsonl"
    poll_offset = pathlib.Path(f"agents/{self_id}/tg_poll.offset")

    def poll_in():
        global _chat_id
        try: offset = int(poll_offset.read_text())
        except (FileNotFoundError, ValueError): offset = 0
        while True:
            try:
                advanced = False
                for u in _api("getUpdates", offset=offset, timeout=25) or []:
                    offset = u["update_id"] + 1
                    advanced = True
                    msg = u.get("message") or {}
                    cid = str((msg.get("chat") or {}).get("id") or "")
                    if cid and cid != _chat_id:
                        _chat_id = cid
                        chat_file.write_text(cid)
                    text = msg.get("text") or ""
                    if not text: continue
                    obj = {"role": "user", "content": f"[telegram tg:{u['update_id']}] {text}"}
                    with open(messages_path, "a") as fp:
                        fcntl.flock(fp, fcntl.LOCK_EX)
                        fp.write(json.dumps(obj) + "\n")
                if advanced:
                    poll_offset.write_text(str(offset))
            except Exception as e:
                print(f"tg poll: {e}"); time.sleep(5)

    threading.Thread(target=poll_in, daemon=True, name="tg-poll").start()
