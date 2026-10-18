#!/usr/bin/env python3
"""cloudsync: push ~/envlab/*.jsonl lines to the envlab Supabase project (Postgres over REST).

Sources (all under ~/envlab) and where they go:
  events.jsonl    -> events    (checkin, checkout, tamper, bind, unknown_card, face_reject, hello)
  nano_imu.jsonl  -> readings  (channel reader_motion_g: the reader's deviation from its rest position)
  sensors.jsonl   -> readings  (the teammate's sensor log; FORMAT below)

FORMAT for sensors.jsonl, one JSON object per line, either narrow:
  {"ts": 1760810000.5, "node": "pico-greenhouse", "channel": "tds_ppm", "value": 312, "unit": "ppm"}
or wide (every numeric key other than ts becomes its own channel):
  {"ts": "2026-10-18T15:40:00", "node": "uno-r4", "tds_ppm": 312, "water_temp_c": 22.4, "air_temp_c": 24.1,
   "humidity_pct": 48, "units": {"tds_ppm": "ppm", "water_temp_c": "C"}}
ts may be epoch seconds or ISO-8601 (naive ISO is taken as this Pi's local time).

Config: ~/envlab/.env with SUPABASE_URL and SUPABASE_KEY (NODE_ID optional, default: hostname).
The jsonl files are the offline buffer: a network outage drops nothing, offsets live in .cloudsync_state.json,
and every row carries client_id = sha1(file + line) so a retry can never create a duplicate.
Rows the server rejects outright (bad data) are written to cloudsync_rejects.jsonl and skipped, so one bad
line cannot block the pipeline.

Usage:  python3 cloudsync.py          run forever (every 2 s)
        python3 cloudsync.py --once   one pass, then exit
"""
import hashlib
import json
import os
import socket
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path.home() / "envlab"
STATE = ROOT / ".cloudsync_state.json"
REJECTS = ROOT / "cloudsync_rejects.jsonl"
SOURCES = {"events.jsonl": "events", "nano_imu.jsonl": "readings", "sensors.jsonl": "readings"}
BATCH = 200
PERIOD_S = 2.0


def load_env():
    env = {}
    p = ROOT / ".env"
    if p.exists():
        for line in p.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env[k.strip()] = v.strip().strip('"').strip("'")
    for k in ("SUPABASE_URL", "SUPABASE_KEY", "NODE_ID"):
        if os.environ.get(k):
            env[k] = os.environ[k]
    missing = [k for k in ("SUPABASE_URL", "SUPABASE_KEY") if not env.get(k)]
    if missing:
        sys.exit(f"missing {missing}: put them in {p} or the environment")
    env["SUPABASE_URL"] = env["SUPABASE_URL"].rstrip("/")
    env.setdefault("NODE_ID", socket.gethostname())
    return env


def iso(ts):
    if isinstance(ts, bool):
        raise ValueError("ts is a bool")
    if isinstance(ts, (int, float)):
        return datetime.fromtimestamp(ts, timezone.utc).isoformat()
    if isinstance(ts, str):
        s = ts.strip()
        try:
            return datetime.fromtimestamp(float(s), timezone.utc).isoformat()
        except ValueError:
            pass
        d = datetime.fromisoformat(s.replace("Z", "+00:00"))
        if d.tzinfo is None:
            d = d.astimezone()  # naive ISO -> this Pi's local time zone
        return d.isoformat()
    raise ValueError(f"bad ts {ts!r}")


def cid(name, line):
    return hashlib.sha1(f"{name}\n{line}".encode()).hexdigest()


def rows_events(line, obj, node_id):
    reserved = {"ts", "iso", "type", "id", "uid", "node"}
    return [{
        "ts": iso(obj["ts"]),
        "node": obj.get("node") or node_id,
        "type": str(obj["type"]),
        "person_id": obj.get("id"),
        "card_uid": obj.get("uid"),
        "payload": {k: v for k, v in obj.items() if k not in reserved},
        "client_id": cid("events.jsonl", line),
    }]


def rows_imu(line, obj, node_id):
    if "dev_g" not in obj:
        return []
    return [{
        "ts": iso(obj["ts"]),
        "node": obj.get("node") or "nano33iot-1",
        "channel": "reader_motion_g",
        "value": float(obj["dev_g"]),
        "unit": "g",
        "meta": {"moved": bool(obj.get("moved"))},
        "client_id": cid("nano_imu.jsonl", line),
    }]


def rows_sensors(line, obj, node_id):
    ts = iso(obj["ts"])
    node = obj.get("node") or node_id
    base = cid("sensors.jsonl", line)
    meta = obj.get("meta") or {}
    if "channel" in obj and "value" in obj:
        return [{"ts": ts, "node": node, "channel": str(obj["channel"]), "value": float(obj["value"]),
                 "unit": obj.get("unit"), "meta": meta, "client_id": base}]
    units = obj.get("units") or {}
    rows = []
    for k, v in obj.items():
        if k in ("ts", "node", "units", "meta") or isinstance(v, bool) or not isinstance(v, (int, float)):
            continue
        rows.append({"ts": ts, "node": node, "channel": k, "value": float(v), "unit": units.get(k),
                     "meta": meta, "client_id": f"{base}:{k}"})
    return rows


MAPPERS = {"events.jsonl": rows_events, "nano_imu.jsonl": rows_imu, "sensors.jsonl": rows_sensors}


def post(env, table, rows):
    url = f"{env['SUPABASE_URL']}/rest/v1/{table}?on_conflict=client_id"
    req = urllib.request.Request(url, data=json.dumps(rows).encode(), method="POST", headers={
        "apikey": env["SUPABASE_KEY"],
        "Authorization": f"Bearer {env['SUPABASE_KEY']}",
        "Content-Type": "application/json",
        "Prefer": "resolution=ignore-duplicates,return=minimal",
    })
    with urllib.request.urlopen(req, timeout=15) as r:
        return r.status


class Unavailable(Exception):
    """Network down or server refusing us (auth, rate limit, 5xx): keep the offset and retry later."""


def post_resilient(env, table, rows):
    """Post a batch; on a data error, isolate the bad rows into the rejects file instead of blocking."""
    try:
        post(env, table, rows)
        return len(rows), 0
    except urllib.error.HTTPError as e:
        body = e.read().decode(errors="replace")[:300]
        if e.code in (401, 403, 429) or e.code >= 500:
            raise Unavailable(f"http {e.code}: {body}")
        if len(rows) == 1:
            with REJECTS.open("a") as f:
                f.write(json.dumps({"table": table, "status": e.code, "error": body, "row": rows[0]}) + "\n")
            return 0, 1
        mid = len(rows) // 2
        a_ok, a_bad = post_resilient(env, table, rows[:mid])
        b_ok, b_bad = post_resilient(env, table, rows[mid:])
        return a_ok + b_ok, a_bad + b_bad
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        raise Unavailable(str(e))


def read_new(path, offset):
    """Return (complete lines, new offset); never consumes a partial trailing line still being written."""
    with path.open("rb") as f:
        f.seek(offset)
        data = f.read()
    if not data:
        return [], offset
    end = data.rfind(b"\n")
    if end < 0:
        return [], offset
    chunk = data[:end + 1]
    return chunk.decode("utf-8", "replace").split("\n")[:-1], offset + len(chunk)


def sync_once(env, state):
    pushed = rejected = 0
    for name, table in SOURCES.items():
        path = ROOT / name
        if not path.exists():
            continue
        off = state.get(name, 0)
        if off > path.stat().st_size:
            off = 0  # file was truncated or replaced; start over (duplicates are ignored server-side)
        lines, new_off = read_new(path, off)
        if not lines:
            continue
        rows = []
        for line in lines:
            line = line.strip()
            if not line:
                continue
            try:
                rows.extend(MAPPERS[name](line, json.loads(line), env["NODE_ID"]))
            except Exception as e:
                with REJECTS.open("a") as f:
                    f.write(json.dumps({"file": name, "error": str(e), "line": line}) + "\n")
                rejected += 1
        for i in range(0, len(rows), BATCH):
            ok, bad = post_resilient(env, table, rows[i:i + BATCH])  # raises Unavailable -> offset not advanced
            pushed += ok
            rejected += bad
        state[name] = new_off
        STATE.write_text(json.dumps(state))
    return pushed, rejected


def main():
    env = load_env()
    state = json.loads(STATE.read_text()) if STATE.exists() else {}
    once = "--once" in sys.argv
    print(f"cloudsync -> {env['SUPABASE_URL']} as node {env['NODE_ID']}; sources: {', '.join(SOURCES)}")
    delay = PERIOD_S
    while True:
        try:
            pushed, rejected = sync_once(env, state)
            if pushed or rejected:
                print(f"{time.strftime('%H:%M:%S')} pushed {pushed} rows" + (f", rejected {rejected}" if rejected else ""))
            delay = PERIOD_S
        except Unavailable as e:
            delay = min(delay * 2, 60)
            print(f"{time.strftime('%H:%M:%S')} unavailable ({e}); retry in {delay:.0f}s")
        if once:
            break
        time.sleep(delay)


if __name__ == "__main__":
    main()
