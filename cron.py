#!/usr/bin/env python3
"""Cron: walks agents/*/cron/*.json, fires due jobs to bus/cron/<self>.log.

Job file format (any name, must be .json):
  {"kind": "every", "every_s": 3600, "message": "..."}
  {"kind": "cron",  "expr": "0 9 * * *", "message": "..."}
  {"kind": "at",    "at_ms": 1717286400000, "message": "..."}

State is in-memory only; on restart, schedules recompute from now.
"""
import config  # loads .env into os.environ
import bus
import json, os, pathlib, time
from croniter import croniter

AGENTS = pathlib.Path(os.environ.get("AGENTS_DIR", "agents"))
BUS = pathlib.Path(os.environ.get("BUS_DIR", "bus"))
TICK = int(os.environ.get("CRON_TICK_S", "30"))

state = {}  # (agent, jobname) -> next_run_unix_seconds

def now(): return time.strftime("%Y%m%dT%H%M%S")

def compute_next(job, ts):
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

def scan():
    for agent_dir in AGENTS.iterdir():
        if not agent_dir.is_dir(): continue
        cron_dir = agent_dir / "cron"
        if not cron_dir.is_dir(): continue
        for f in cron_dir.glob("*.json"):
            try: yield agent_dir.name, f.stem, json.loads(f.read_text())
            except Exception: continue

def fire(agent, name, job):
    msg = job.get("message", "")
    bus.append(BUS / "cron" / f"{agent}.log", f"[cron {now()} {name}] {msg}\n")

while True:
    ts = time.time()
    for agent, name, job in scan():
        key = (agent, name)
        if key not in state:
            state[key] = compute_next(job, ts)
        if state[key] is not None and ts >= state[key]:
            fire(agent, name, job)
            state[key] = compute_next(job, ts) if job.get("kind") != "at" else None
    time.sleep(TICK)
