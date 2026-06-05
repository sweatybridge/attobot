SCHEMA = {
    "type": "function",
    "function": {
        "name": "READ_FILE",
        "description": "Read a file.",
        "parameters": {"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]},
    },
}


def run(args):
    return open(args["path"]).read()
