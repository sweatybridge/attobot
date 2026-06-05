SCHEMA = {
    "type": "function",
    "function": {
        "name": "WRITE_FILE",
        "description": "Overwrite a file.",
        "parameters": {"type": "object", "properties": {"path": {"type": "string"}, "content": {"type": "string"}}, "required": ["path", "content"]},
    },
}


def run(args):
    path = args["path"]
    if path == "SOUL.md":
        return f"error: {path} is immutable"
    open(path, "w").write(args["content"])
    return f"wrote {path} ({len(args['content'])} chars)"
