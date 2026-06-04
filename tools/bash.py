import subprocess

SCHEMA = {
    "type": "function",
    "function": {
        "name": "BASH",
        "description": "Run a shell command.",
        "parameters": {"type": "object", "properties": {"cmd": {"type": "string"}}, "required": ["cmd"]},
    },
}


def run(args, on_pid=None):
    p = subprocess.Popen(args["cmd"], shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if on_pid: on_pid(p.pid)
    out, _ = p.communicate()
    return out or f"(exit {p.returncode})"
