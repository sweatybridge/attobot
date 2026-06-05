"""Telegram inbound poller. Imported by agent.py.

Polls telegram. Inbound text → APPEND_MESSAGE as role:user. Discovers chat_id
on first message and persists to agents/<self>/telegram_chat for SEND_CHAT.
"""
import pathlib, requests, threading, time
from tools.append_message import run as append_message


def start(self_id):
    agent_dir = pathlib.Path(f"agents/{self_id}")
    token = (agent_dir / "telegram_token").read_text().strip()
    chat_file = agent_dir / "telegram_chat"
    poll_offset = agent_dir / "tg_poll.offset"

    def poll_in():
        try: offset = int(poll_offset.read_text())
        except (FileNotFoundError, ValueError): offset = 0
        cached_chat_id = chat_file.read_text().strip() if chat_file.exists() else None
        while True:
            try:
                advanced = False
                r = requests.post(f"https://api.telegram.org/bot{token}/getUpdates",
                                  data={"offset": offset, "timeout": 25}, timeout=45)
                for u in r.json().get("result") or []:
                    offset = u["update_id"] + 1
                    advanced = True
                    msg = u.get("message") or {}
                    cid = str((msg.get("chat") or {}).get("id") or "")
                    if cid and cid != cached_chat_id:
                        cached_chat_id = cid
                        chat_file.write_text(cid)
                    text = msg.get("text") or ""
                    if not text: continue
                    append_message({"role": "user", "content": f"[telegram {u['update_id']}] {text}"})
                if advanced:
                    poll_offset.write_text(str(offset))
            except Exception as e:
                print(f"chat poll: {e}"); time.sleep(5)

    threading.Thread(target=poll_in, daemon=True, name="chat-poll").start()
