"""Generic background tool wrapper.

bg.run(name, args, tool_call_id, run_tool_fn, self_dir, messages_path):
    Runs the tool in a thread with TIMEOUT seconds. If it finishes in time,
    returns the result inline. Otherwise registers agents/<self>/bg/<id>.json,
    spawns an emitter thread that appends a system message to messages.jsonl
    when the tool eventually completes, and returns a "[backgrounded …]"
    placeholder.

    BASH is special-cased: spawned via Popen so we know the subprocess pid
    (recorded in the bg json). Other tools run their normal sync path.

    To kill a backgrounded call: rm agents/<self>/bg/<id>.json. The emitter
    notices the file is gone, SIGTERMs the pid (if any), and emits a "killed"
    system message.
"""
import bus
import hashlib, json, os, pathlib, signal, subprocess, threading, time

TIMEOUT = 10


def run(name, args, tool_call_id, run_tool_fn, self_dir, messages_path):
    bg_id = hashlib.sha256(f"{tool_call_id}{time.time()}".encode()).hexdigest()[:8]
    bg_dir = pathlib.Path(self_dir) / "bg"
    bg_dir.mkdir(parents=True, exist_ok=True)
    holder = {"result": None, "done": False, "pid": None}

    def work():
        try:
            if name == "BASH":
                stdout_path = bg_dir / f"{bg_id}.stdout"
                f = open(stdout_path, "w")
                p = subprocess.Popen(args["cmd"], shell=True, stdout=f, stderr=subprocess.STDOUT, text=True)
                f.close()
                holder["pid"] = p.pid
                p.wait()
                try: holder["result"] = open(stdout_path).read() or f"(exit {p.returncode}, no output)"
                except Exception: holder["result"] = f"(exit {p.returncode})"
                try: stdout_path.unlink()
                except Exception: pass
            else:
                holder["result"] = run_tool_fn(name, args)
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
                bus.append(messages_path, json.dumps({
                    "role": "system",
                    "content": f"[bg {bg_id} killed, tc:{tool_call_id}]"
                }) + "\n")
                return
            time.sleep(1)
        bus.append(messages_path, json.dumps({
            "role": "system",
            "content": f"[bg {bg_id} done, tc:{tool_call_id}] {holder['result']}"
        }) + "\n")
        try: json_path.unlink()
        except Exception: pass

    threading.Thread(target=emit, daemon=True).start()
    pid_info = f" (pid {holder['pid']})" if holder.get("pid") else ""
    return f"[backgrounded bg/{bg_id}{pid_info} — rm agents/{pathlib.Path(self_dir).name}/bg/{bg_id}.json to kill]"
