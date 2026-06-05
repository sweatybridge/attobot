import fcntl, hashlib, json, os

SCHEMA = {
    "type": "function",
    "function": {
        "name": "STASH_MESSAGES",
        "description": "Stash the first half of messages.jsonl to a blob and leave a [stash <hash>] placeholder in its place.",
        "parameters": {"type": "object", "properties": {}},
    },
}


def run(args):
    self_dir = os.environ["SELF_DIR"]
    blob_dir = os.environ.get("BLOB_DIR", "blobs")
    messages_path = f"{self_dir}/messages.jsonl"
    with open(messages_path, "r+") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        all_msgs = [json.loads(l) for l in f.read().splitlines() if l.strip()]
        cut = len(all_msgs) // 2
        while cut < len(all_msgs) and all_msgs[cut].get("role") == "tool":
            cut += 1
        if cut >= len(all_msgs):
            return "nothing safe to stash"
        head = "\n".join(json.dumps(m) for m in all_msgs[:cut])
        h = hashlib.sha256(head.encode()).hexdigest()[:12]
        open(f"{blob_dir}/{h}", "w").write(head)
        new = [{"role": "system", "content": f"<earlier history stashed: [stash {h}]>"}] + all_msgs[cut:]
        f.seek(0)
        f.truncate()
        for m in new:
            f.write(json.dumps(m) + "\n")
    return f"stashed {cut} messages to [stash {h}]"
