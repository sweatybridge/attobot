SCHEMA = {
    "type": "function",
    "function": {
        "name": "EDIT_FILE",
        "description": "Replace OLD with NEW in a file. OLD must appear exactly once.",
        "parameters": {"type": "object", "properties": {"path": {"type": "string"}, "old": {"type": "string"}, "new": {"type": "string"}}, "required": ["path", "old", "new"]},
    },
}


def run(args):
    path, old, new = args["path"], args["old"], args["new"]
    if path == "SOUL.md":
        return f"error: {path} is immutable"
    text = open(path).read()
    if text.count(old) != 1:
        return f"error: OLD must appear exactly once in {path} (found {text.count(old)})"
    open(path, "w").write(text.replace(old, new))
    return f"edited {path}"
