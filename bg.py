"""Generic background tool wrapper.

bg.run(name, args, tool_call_id, tool_fn):
    Runs tool_fn(args) in a thread with TIMEOUT seconds. If it finishes in
    time, returns the result inline. Otherwise registers agents/<self>/bg/<id>.json,
    spawns an emitter thread that appends a system message to messages.jsonl
    when the tool completes, and returns a "[backgrounded …]" placeholder.

    A tool may return a subprocess.Popen-like object (anything with .pid and
    .communicate()); bg records its pid for kill-by-rm and awaits its output.

    To kill a backgrounded call: rm agents/<self>/bg/<id>.json. The emitter
    notices the file is gone, SIGTERMs the pid (if any), and emits a "killed"
    system message.
"""
import hashlib, json, os, pathlib, signal, threading, time
from tools.append_message import run as append_message

TIMEOUT = int(os.environ.get("TOOL_TIMEOUT", "30"))


def run(name, args, tool_call_id, tool_fn):
    self_dir = os.environ["SELF_DIR"]
    bg_id = hashlib.sha256(f"{tool_call_id}{time.time()}".encode()).hexdigest()[:8]
    bg_dir = pathlib.Path(self_dir) / "bg"
    bg_dir.mkdir(parents=True, exist_ok=True)
    holder = {"result": None, "done": False, "pid": None}

    def work():
        try:
            r = tool_fn(args)
            if hasattr(r, "pid") and hasattr(r, "communicate"):
                holder["pid"] = r.pid
                out, _ = r.communicate()
                holder["result"] = out or f"(exit {r.returncode})"
            else:
                holder["result"] = r
        except Exception as e:
            holder["result"] = f"error: {e}"
        finally:
            holder["done"] = True

    t = threading.Thread(target=work, daemon=True)
    t.start()
    t.join(TIMEOUT)
    if holder["done"]:
        return holder["result"]

    json_path = bg_dir / f"{bg_id}.json"
    json_path.write_text(json.dumps({
        "name": name, "tool_call_id": tool_call_id,
        "pid": holder.get("pid"), "started": time.time(),
    }))

    def emit():
        while not holder["done"]:
            if not json_path.exists():
                if holder.get("pid"):
                    try: os.kill(holder["pid"], signal.SIGTERM)
                    except Exception: pass
                append_message({"role": "system", "content": f"[bg {bg_id} killed, tc:{tool_call_id}]"})
                return
            time.sleep(1)
        append_message({"role": "system", "content": f"[bg {bg_id} done, tc:{tool_call_id}] {holder['result']}"})
        try: json_path.unlink()
        except Exception: pass

    threading.Thread(target=emit, daemon=True).start()
    pid_info = f" (pid {holder['pid']})" if holder.get("pid") else ""
    return f"[backgrounded bg/{bg_id}{pid_info} — rm agents/{pathlib.Path(self_dir).name}/bg/{bg_id}.json to kill]"
