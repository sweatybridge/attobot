"""Generic background tool wrapper.

bg.run(name, args, tool_call_id, tool_fn, self_dir, messages_path):
    Runs tool_fn(args, on_pid=...) in a thread with TIMEOUT seconds. If it
    finishes in time, returns the result inline. Otherwise registers
    agents/<self>/bg/<id>.json, spawns an emitter thread that appends a
    system message to messages.jsonl when the tool completes, and returns
    a "[backgrounded …]" placeholder.

    Tools that spawn subprocesses (e.g. BASH) call on_pid(pid) so we can
    SIGTERM them on kill.

    To kill a backgrounded call: rm agents/<self>/bg/<id>.json. The emitter
    notices the file is gone, SIGTERMs the pid (if any), and emits a "killed"
    system message.
"""
import fcntl, hashlib, json, os, pathlib, signal, threading, time

TIMEOUT = int(os.environ.get("TOOL_TIMEOUT", "10"))


def run(name, args, tool_call_id, tool_fn, self_dir, messages_path):
    bg_id = hashlib.sha256(f"{tool_call_id}{time.time()}".encode()).hexdigest()[:8]
    bg_dir = pathlib.Path(self_dir) / "bg"
    bg_dir.mkdir(parents=True, exist_ok=True)
    holder = {"result": None, "done": False, "pid": None}

    def work():
        try:
            holder["result"] = tool_fn(args, on_pid=lambda pid: holder.update(pid=pid))
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

    def append_line(line):
        with open(messages_path, "a") as fp:
            fcntl.flock(fp, fcntl.LOCK_EX)
            fp.write(line + "\n")

    def emit():
        while not holder["done"]:
            if not json_path.exists():
                if holder.get("pid"):
                    try: os.kill(holder["pid"], signal.SIGTERM)
                    except Exception: pass
                append_line(json.dumps({
                    "role": "system",
                    "content": f"[bg {bg_id} killed, tc:{tool_call_id}]"
                }))
                return
            time.sleep(1)
        append_line(json.dumps({
            "role": "system",
            "content": f"[bg {bg_id} done, tc:{tool_call_id}] {holder['result']}"
        }))
        try: json_path.unlink()
        except Exception: pass

    threading.Thread(target=emit, daemon=True).start()
    pid_info = f" (pid {holder['pid']})" if holder.get("pid") else ""
    return f"[backgrounded bg/{bg_id}{pid_info} — rm agents/{pathlib.Path(self_dir).name}/bg/{bg_id}.json to kill]"
