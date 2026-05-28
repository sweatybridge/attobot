#!/usr/bin/env python3
"""CLI chat tool for talking to a running agent."""
import hashlib, os, sys, time

AGENTS_DIR = "agents"
BUS_CHAT_DIR = "bus/chat"
SENDER = os.environ.get("SENDER") or hashlib.sha256(b"anon").hexdigest()[:12]


def now():
    return time.strftime("%Y%m%dT%H%M%S")


def pick_agent():
    """List agents and let user pick."""
    agents = [d for d in os.listdir(AGENTS_DIR)
              if os.path.isfile(f"{AGENTS_DIR}/{d}/LIFE.md")]
    if not agents:
        print("no agents found")
        sys.exit(1)
    agents.sort(key=lambda d: os.path.getmtime(f"{AGENTS_DIR}/{d}/LIFE.md"), reverse=True)
    if len(agents) == 1:
        return agents[0]
    print("agents:")
    for i, a in enumerate(agents):
        mtime = time.strftime("%Y-%m-%d %H:%M", time.localtime(os.path.getmtime(f"{AGENTS_DIR}/{a}/LIFE.md")))
        print(f"  {i + 1}) {a}  (last active: {mtime})")
    while True:
        try:
            choice = input("pick [1]: ").strip()
        except (EOFError, KeyboardInterrupt):
            sys.exit(0)
        if not choice:
            return agents[0]
        if choice.isdigit() and 1 <= int(choice) <= len(agents):
            return agents[int(choice) - 1]


def main():
    chat_id = sys.argv[1] if len(sys.argv) > 1 else "dev"
    agent = pick_agent()
    chat_path = f"{BUS_CHAT_DIR}/{chat_id}.md"
    sub_path = f"{AGENTS_DIR}/{agent}/subs/{chat_id}.md"

    os.makedirs(BUS_CHAT_DIR, exist_ok=True)
    if not os.path.exists(chat_path):
        open(chat_path, "w").close()

    # auto-subscribe agent
    if not os.path.exists(sub_path):
        os.symlink(os.path.abspath(chat_path), sub_path)
        print(f"subscribed agent {agent} to {chat_id}")

    # print existing history
    existing = open(chat_path).read()
    if existing.strip():
        print(existing.strip())
        print()

    print(f"chatting in #{chat_id} with agent {agent}")
    print("ctrl+c to exit\n")

    offset = len(open(chat_path).read())

    while True:
        try:
            msg = input(f"{SENDER}> ")
        except (EOFError, KeyboardInterrupt):
            print()
            break
        if not msg.strip():
            continue
        with open(chat_path, "a") as f:
            f.write(f"[{SENDER} {now()}] {msg}\n")
        offset = len(open(chat_path).read())
        # wait for agent reply
        while True:
            data = open(chat_path).read()
            if len(data) > offset:
                new = data[offset:]
                offset = len(data)
                for line in new.splitlines():
                    if line:
                        print(line)
                break
            time.sleep(0.5)


if __name__ == "__main__":
    main()
