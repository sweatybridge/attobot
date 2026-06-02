"""Cron per agent. Job files: agents/<self>/cron/*.json with {"next": <unix>, "repeat_s"?, "message"}."""
import bus
import json, os, pathlib, threading, time

TICK = int(os.environ.get("CRON_TICK_S", "30"))


def start(self_id):
    cron_dir = pathlib.Path(f"agents/{self_id}/cron")
    cron_dir.mkdir(parents=True, exist_ok=True)
    bus_cron = f"bus/cron/{self_id}.log"

    def loop():
        while True:
            ts = time.time()
            for f in cron_dir.glob("*.json"):
                try: job = json.loads(f.read_text())
                except Exception: continue
                if job.get("next", float("inf")) > ts: continue
                bus.append(bus_cron, f"[cron {time.strftime('%Y%m%dT%H%M%S')} {f.stem}] {job.get('message', '')}\n")
                if job.get("repeat_s"):
                    job["next"] = ts + job["repeat_s"]
                    f.write_text(json.dumps(job))
                else:
                    f.unlink()
            time.sleep(TICK)

    threading.Thread(target=loop, daemon=True, name="cron").start()
