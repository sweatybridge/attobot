#!/usr/bin/env python3
"""Create agents/<self>/config.json.

CLI-first: pass --token / --chat / --thread for non-interactive use (e.g.
from another agent's BASH call). When running interactively without --chat,
discovers chat_id (and thread_id) by polling Telegram and asking the user
to send a message from the chat they want the bot to serve.

Fails if config.json already exists — delete it to reconfigure.

Usage:
  python setup.py myagent --token 123:abc --chat -1001234567 --thread 42
  python setup.py myagent --token 123:abc   # interactive chat-id discovery
  python setup.py myagent                   # fully interactive
"""
import argparse
import json
import pathlib
import sys

import requests


def assert_bot_settings(token):
    r = requests.get(f"https://api.telegram.org/bot{token}/getMe", timeout=10)
    data = r.json()
    if not data.get("ok"):
        sys.exit(f"getMe failed: {data}")
    bot = data["result"]
    issues = []
    if not bot.get("can_join_groups"):
        issues.append("In @BotFather: /setjoingroups → Enable.")
    if not bot.get("can_read_all_group_messages"):
        issues.append("In @BotFather: /setprivacy → Disable (privacy mode must be OFF).")
    if issues:
        for line in issues:
            print(f"FIX: {line}")
        sys.exit("bot settings need adjustment; rerun after fixing")
    print(f"bot @{bot.get('username')} settings ok")


def discover_chat(token):
    print("Send any message to your bot from the chat/topic you want it to serve (Ctrl-C to cancel)...")
    offset = 0
    while True:
        try:
            r = requests.post(f"https://api.telegram.org/bot{token}/getUpdates",
                              data={"offset": offset, "timeout": 25}, timeout=45)
        except KeyboardInterrupt:
            sys.exit("aborted")
        for u in r.json().get("result") or []:
            msg = u.get("message") or {}
            cid = (msg.get("chat") or {}).get("id")
            if cid:
                tid = msg.get("message_thread_id")
                print(f"detected chat_id={cid}" + (f" thread_id={tid}" if tid is not None else ""))
                return str(cid), str(tid) if tid is not None else None
            offset = u["update_id"] + 1


p = argparse.ArgumentParser()
p.add_argument("self_name")
p.add_argument("--token")
p.add_argument("--chat")
p.add_argument("--thread", help='Telegram thread_id (forum topic).')
p.add_argument("--systemd", action="store_true", help="also emit attobot@.service template + install instructions")
args = p.parse_args()

self_dir = pathlib.Path(f"agents/{args.self_name}")
config_path = self_dir / "config.json"
if config_path.exists():
    sys.exit(f"{config_path} already exists. Delete it to reconfigure.")
self_dir.mkdir(parents=True, exist_ok=True)

cfg = {}
if args.token is not None:
    cfg["telegram_token"] = args.token
if args.chat is not None:
    cfg["telegram_chat_id"] = args.chat
if args.thread:
    cfg["telegram_thread_id"] = args.thread

interactive = sys.stdin.isatty()

if interactive and not cfg.get("telegram_token"):
    cfg["telegram_token"] = input("Telegram bot token (get it from @BotFather): ").strip()
if cfg.get("telegram_token"):
    assert_bot_settings(cfg["telegram_token"])
if interactive and not cfg.get("telegram_chat_id") and cfg.get("telegram_token"):
    cid, tid = discover_chat(cfg["telegram_token"])
    cfg["telegram_chat_id"] = cid
    if tid is not None and "telegram_thread_id" not in cfg:
        cfg["telegram_thread_id"] = tid

for key in ("telegram_token", "telegram_chat_id"):
    if not cfg.get(key):
        sys.exit(f"missing required field: {key}")

config_path.write_text(json.dumps(cfg, indent=2))
print(f"wrote {config_path}")

if args.systemd:
    workdir = str(pathlib.Path.cwd().absolute())
    unit = pathlib.Path("attobot@.service")
    unit.write_text(f"""[Unit]
Description=attobot %i
After=network.target

[Service]
Type=simple
WorkingDirectory={workdir}
ExecStart={sys.executable} agent.py %i
Restart=always
RestartSec=10
NoNewPrivileges=yes
ProtectSystem=strict
ReadWritePaths={workdir}

[Install]
WantedBy=default.target
""")
    print(f"wrote {unit}")
    print(f"\nInstall once (user service, no sudo):")
    print(f"  mkdir -p ~/.config/systemd/user")
    print(f"  cp {unit} ~/.config/systemd/user/")
    print(f"  systemctl --user daemon-reload")
    print(f"  loginctl enable-linger $USER          # so it survives logout")
    print(f"\nThen for each agent:")
    print(f"  systemctl --user enable --now attobot@{args.self_name}")
    print(f"  journalctl --user -u attobot@{args.self_name} -f")

