import fcntl, json, os

SCHEMA = {
    "type": "function",
    "function": {
        "name": "APPEND_MESSAGE",
        "description": "Append a message to the conversation log.",
        "parameters": {"type": "object", "properties": {
            "role": {"type": "string"},
            "content": {"type": "string"},
        }, "required": ["role", "content"]},
    },
}


def run(args):
    messages_path = f"{os.environ['SELF_DIR']}/messages.jsonl"
    with open(messages_path, "a") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        f.write(json.dumps({"role": args["role"], "content": args["content"]}) + "\n")
    return "appended"
