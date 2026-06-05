import subprocess

SCHEMA = {
    "type": "function",
    "function": {
        "name": "BASH",
        "description": "Run a shell command.",
        "parameters": {"type": "object", "properties": {"cmd": {"type": "string"}}, "required": ["cmd"]},
    },
}


def run(args):
    return subprocess.Popen(args["cmd"], shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
