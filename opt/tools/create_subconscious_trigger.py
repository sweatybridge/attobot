"""Create a trigger file for an agent's harness to run. Pure passthrough to the trigger format.
The trigger name is always forced to a `subconscious-` prefix, so every trigger the subconscious
creates is identifiable in code (the primary surfaces `subconscious-*` triggers to Telegram)."""
import json
import pathlib

NAME = "CREATE_SUBCONSCIOUS_TRIGGER"
DESCRIPTION = (
    "Write a trigger to an agent's triggers/ dir. `spec` is the trigger object, written verbatim, "
    'in the format the harness already runs: {"message": <system text fired into the stream>, '
    '"next": <epoch seconds; 0 = next tick>, "repeat_s": <seconds; omit for one-off>, '
    '"watch": <file path>, "cmd": <shell>}. A trigger fires `[trigger <name>] <message>` into the '
    "target's stream and wakes it. One-off: set next (0 = soon) and omit repeat_s/watch — it fires "
    "once and deletes itself. dir is 'agent' (the primary) or 'subconscious' (yourself). The name is "
    "automatically prefixed with `subconscious-`; you do not add it."
)
PARAMETERS = {
    "type": "object",
    "properties": {
        "name": {"type": "string", "description": "trigger filename, no extension (subconscious- prefix added automatically)"},
        "dir": {"type": "string", "enum": ["agent", "subconscious"]},
        "spec": {"type": "object", "description": 'the trigger object, e.g. {"message": "STASH_MESSAGE: 200 540", "next": 0}'},
    },
    "required": ["name", "spec"],
}

def run(args):
    import agent
    name = args["name"]
    if "/" in name or ".." in name:
        return "error: name must not contain '/' or '..'"
    if not name.startswith("subconscious-"):
        name = "subconscious-" + name
    d = args.get("dir", "agent")
    if d not in ("agent", "subconscious"):
        return "error: dir must be 'agent' or 'subconscious'"
    tdir = pathlib.Path(agent.AGENT_DIR).resolve().parent / d / "triggers"
    tdir.mkdir(parents=True, exist_ok=True)
    (tdir / f"{name}.json").write_text(json.dumps(args["spec"]))
    return f"created {d}/triggers/{name}.json"
