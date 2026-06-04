import hashlib, os

SCHEMA = {
    "type": "function",
    "function": {
        "name": "STASH",
        "description": "Save text to a blob at blobs/<hash>, return [stash <hash>].",
        "parameters": {"type": "object", "properties": {"content": {"type": "string"}}, "required": ["content"]},
    },
}


def run(args, on_pid=None):
    content = args["content"]
    h = hashlib.sha256(content.encode()).hexdigest()[:12]
    blob_dir = os.environ.get("BLOB_DIR", "blobs")
    open(f"{blob_dir}/{h}", "w").write(content)
    return f"stashed: [stash {h}]"
