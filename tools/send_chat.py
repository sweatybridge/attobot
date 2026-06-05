import os, pathlib, requests

TG_MAX = int(os.environ.get("TG_MAX", "4000"))

SCHEMA = {
    "type": "function",
    "function": {
        "name": "SEND_CHAT",
        "description": "Send a text message to the operator via the chat channel.",
        "parameters": {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]},
    },
}


def run(args):
    self_dir = pathlib.Path(os.environ["SELF_DIR"])
    token = (self_dir / "telegram_token").read_text().strip()
    chat_file = self_dir / "telegram_chat"
    if not chat_file.exists():
        return "no chat_id yet"
    chat_id = chat_file.read_text().strip()
    text = args["text"]
    for i in range(0, len(text), TG_MAX):
        requests.post(f"https://api.telegram.org/bot{token}/sendMessage",
                      data={"chat_id": chat_id, "text": text[i:i+TG_MAX]}, timeout=45)
    return "sent"
