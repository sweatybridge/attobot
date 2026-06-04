"""Cron per agent. Job files: agents/<self>/cron/*.json with {"next", "repeat_s"?, "message"}.

Fires due jobs into agents/<self>/messages.jsonl as role:system.
"""
import fcntl, json, os, pathlib, threading, time

TICK = int(os.environ.get("CRON_TICK", "30"))


def start(self_id):
    cron_dir = pathlib.Path(f"agents/{self_id}/cron")
    cron_dir.mkdir(parents=True, exist_ok=True)
    messages_path = f"agents/{self_id}/messages.jsonl"

    def loop():
        while True:
            ts = time.time()
            for f in cron_dir.glob("*.json"):
                try: job = json.loads(f.read_text())
                except Exception: continue
                if job.get("next", float("inf")) > ts: continue
                obj = {"role": "system", "content": f"[cron {f.stem}] {job.get('message', '')}"}
                with open(messages_path, "a") as fp:
                    fcntl.flock(fp, fcntl.LOCK_EX)
                    fp.write(json.dumps(obj) + "\n")
                if job.get("repeat_s"):
                    job["next"] = ts + job["repeat_s"]
                    f.write_text(json.dumps(job))
                else:
                    f.unlink()
            time.sleep(TICK)

    threading.Thread(target=loop, daemon=True, name="cron").start()
