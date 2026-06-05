"""Cron per agent. Job files: agents/<self>/cron/*.json with {"next", "repeat_s"?, "message"}.

Fires due jobs via APPEND_MESSAGE as role:system.
"""
import json, os, pathlib, threading, time
from tools.append_message import run as append_message

TICK = int(os.environ.get("CRON_TICK", "30"))


def start(self_id):
    cron_dir = pathlib.Path(f"agents/{self_id}/cron")
    cron_dir.mkdir(parents=True, exist_ok=True)

    def loop():
        while True:
            ts = time.time()
            for f in cron_dir.glob("*.json"):
                try: job = json.loads(f.read_text())
                except Exception: continue
                if job.get("next", float("inf")) > ts: continue
                append_message({"role": "system", "content": f"[cron {f.stem}] {job.get('message', '')}"})
                if job.get("repeat_s"):
                    job["next"] = ts + job["repeat_s"]
                    f.write_text(json.dumps(job))
                else:
                    f.unlink()
            time.sleep(TICK)

    threading.Thread(target=loop, daemon=True, name="cron").start()
