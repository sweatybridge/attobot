"""Cron per agent. Imported by agent.py.

Reads agents/<self>/cron/*.json. Fires due jobs to bus/cron/<self>.log.

Job file format:
  {"kind": "every", "every_s": 3600, "message": "..."}
  {"kind": "cron",  "expr": "0 9 * * *", "message": "..."}
  {"kind": "at",    "at_ms": 1717286400000, "message": "..."}
"""
import bus
import json, os, pathlib, threading, time
from croniter import croniter

TICK = int(os.environ.get("CRON_TICK_S", "30"))


def _now(): return time.strftime("%Y%m%dT%H%M%S")


def _compute_next(job, ts):
    kind = job.get("kind")
    if kind == "at":
        at_s = job.get("at_ms", 0) / 1000
        return at_s if at_s > ts else None
    if kind == "every":
        e = job.get("every_s", 0)
        return ts + e if e > 0 else None
    if kind == "cron":
        try: return croniter(job.get("expr", ""), ts).get_next(float)
        except Exception: return None
    return None


def start(self_id):
    agents_dir = os.environ.get("AGENTS_DIR", "agents")
    bus_dir = os.environ.get("BUS_DIR", "bus")
    agent = pathlib.Path(agents_dir) / self_id
    cron_dir = agent / "cron"
    cron_dir.mkdir(parents=True, exist_ok=True)
    bus_cron = pathlib.Path(bus_dir) / "cron" / f"{self_id}.log"
    state = {}  # jobname -> next_run_unix_seconds

    def scan():
        for f in cron_dir.glob("*.json"):
            try: yield f.stem, json.loads(f.read_text())
            except Exception: continue

    def fire(name, job):
        msg = job.get("message", "")
        bus.append(bus_cron, f"[cron {_now()} {name}] {msg}\n")

    def loop():
        while True:
            ts = time.time()
            for name, job in scan():
                if name not in state:
                    state[name] = _compute_next(job, ts)
                if state[name] is not None and ts >= state[name]:
                    fire(name, job)
                    state[name] = _compute_next(job, ts) if job.get("kind") != "at" else None
            time.sleep(TICK)

    threading.Thread(target=loop, daemon=True, name="cron").start()
