#!/usr/bin/env python3
"""dewin_presence: the kiosk as a position source for Dewin.

While a person is checked in at the kiosk (card + face, see tapwatch.py), this process submits Dewin
`location:update` events on their behalf, at the kiosk's configured coordinates, every DEWIN_INTERVAL_S
seconds, using that person's own personal API token. The backend performs the spatial join against nearby
sensors and sends back `exposure:update` records, which are appended to ~/envlab/dewin_exposure.jsonl.
No API extension is involved: the kiosk is an ordinary Socket.IO client acting for the checked-in user,
exactly like the phone app (backend/docs/api-v1.md).

Config, in ~/envlab/.env:
  DEWIN_API_URL=http://127.0.0.1:8765      the gateway, or the local mock (backend/scripts/mock_api.py)
  KIOSK_LAT=25.7617                        WGS84 position of the kiosk
  KIOSK_LON=-80.1918
  KIOSK_ACCURACY_M=5
  DEWIN_INTERVAL_S=5
Tokens, in ~/envlab/dewin_tokens.json (never committed):  {"muntaser": "<personal api token>", ...}
Sessions come from ~/envlab/sessions.json, which tapwatch.py maintains.

Retry rule (from the contract): a submission that times out is retried with the same eventId and the same
payload; the server answers duplicate=true if it already had it. Events wait in a bounded per-user queue.
"""
import json
import os
import sys
import time
import uuid
from collections import deque
from datetime import datetime, timezone
from pathlib import Path

import socketio  # python3-socketio + python3-websocket, or pip "python-socketio[client]"

ROOT = Path.home() / "envlab"
SESSIONS = ROOT / "sessions.json"
TOKENS = ROOT / "dewin_tokens.json"
EXPOSURE_LOG = ROOT / "dewin_exposure.jsonl"
PRESENCE_LOG = ROOT / "dewin_presence.jsonl"


def load_env():
    env = {"DEWIN_API_URL": "http://127.0.0.1:8765", "KIOSK_ACCURACY_M": "5", "DEWIN_INTERVAL_S": "5"}
    p = ROOT / ".env"
    if p.exists():
        for line in p.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env[k.strip()] = v.strip().strip('"').strip("'")
    for k in ("DEWIN_API_URL", "KIOSK_LAT", "KIOSK_LON", "KIOSK_ACCURACY_M", "DEWIN_INTERVAL_S"):
        if os.environ.get(k):
            env[k] = os.environ[k]
    missing = [k for k in ("KIOSK_LAT", "KIOSK_LON") if not env.get(k)]
    if missing:
        sys.exit(f"missing {missing} in {p}: the kiosk needs configured WGS84 coordinates")
    return env


def now_iso():
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def read_json(p, default):
    try:
        return json.loads(p.read_text()) if p.exists() else default
    except json.JSONDecodeError:
        return default  # file mid-write; use the previous state this round


def append_line(p, obj):
    with p.open("a") as f:
        f.write(json.dumps(obj) + "\n")


class UserPresence:
    """One Socket.IO connection and one submission queue for one checked-in person."""

    def __init__(self, pid, token, cfg):
        self.pid, self.token, self.cfg = pid, token, cfg
        self.queue = deque(maxlen=720)        # about an hour of 5 s events while offline
        self.submitted = deque(maxlen=2000)    # eventIds this person's kiosk session submitted
        self.last_created = 0.0
        self.last_connect_attempt = 0.0
        self.sio = socketio.Client(reconnection=True, reconnection_delay=1, reconnection_delay_max=30)
        self.sio.on("exposure:update", self.on_exposure)
        self.sio.on("connect", lambda: print(f"[{pid}] connected to {cfg['DEWIN_API_URL']}"))
        self.sio.on("disconnect", lambda: print(f"[{pid}] disconnected"))

    def connect(self):
        if self.sio.connected or time.time() - self.last_connect_attempt < 5:
            return
        self.last_connect_attempt = time.time()
        try:
            self.sio.connect(self.cfg["DEWIN_API_URL"], auth={"token": self.token},
                             transports=["websocket"], wait_timeout=10)
        except socketio.exceptions.ConnectionError as e:
            print(f"[{self.pid}] connect failed: {e}")

    def close(self):
        try:
            self.sio.disconnect()
        except Exception:
            pass

    def on_exposure(self, data):
        # With the shared demo identity every connected client receives every exposure:update,
        # so keep only the records that answer this person's own location events.
        if data.get("locationEventId") not in self.submitted:
            return
        rec = {"ts": round(time.time(), 3), "person_id": self.pid, **data}
        append_line(EXPOSURE_LOG, rec)
        sensors = data.get("sensors") or []
        head = ""
        if sensors:
            s = sensors[0]
            m = (s.get("measurements") or [{}])[0]
            head = f"; nearest {s.get('deviceId')} {s.get('distanceM')} m, {m.get('medium')} {m.get('metric')} {m.get('value')} {m.get('unit')}"
        print(f"[{self.pid}] exposure:update {data.get('status')} ({len(sensors)} sensor(s)){head}")

    def tick(self):
        """Create a new location event on schedule, then flush whatever is queued."""
        cfg = self.cfg
        interval = float(cfg["DEWIN_INTERVAL_S"])
        if time.time() - self.last_created >= interval:
            self.last_created = time.time()
            event_id = str(uuid.uuid4())
            self.submitted.append(event_id)
            self.queue.append({
                "schemaVersion": 1,
                "eventId": event_id,
                "measuredAt": now_iso(),
                "latitude": float(cfg["KIOSK_LAT"]),
                "longitude": float(cfg["KIOSK_LON"]),
                "accuracyM": float(cfg["KIOSK_ACCURACY_M"]),
            })
        self.connect()
        if not self.sio.connected:
            return
        while self.queue:
            ev = self.queue[0]
            try:
                ack = self.sio.call("location:update", ev, timeout=10)
            except (socketio.exceptions.TimeoutError, socketio.exceptions.BadNamespaceError) as e:
                print(f"[{self.pid}] no ack ({type(e).__name__}); {len(self.queue)} queued, will retry same eventId")
                return
            if not isinstance(ack, dict):
                print(f"[{self.pid}] unexpected ack {ack!r}")
                return
            if ack.get("ok"):
                self.queue.popleft()
                append_line(PRESENCE_LOG, {"ts": round(time.time(), 3), "person_id": self.pid, "event": ev, "ack": ack})
                if ack.get("duplicate"):
                    print(f"[{self.pid}] {ev['eventId'][:8]} accepted earlier (duplicate)")
                continue
            err = ack.get("error") or {}
            code = err.get("code")
            if code == "RATE_LIMITED":
                time.sleep(0.6)
                continue
            if err.get("retryable"):
                print(f"[{self.pid}] {code}: {err.get('message')}; retrying later")
                return
            self.queue.popleft()  # permanent rejection: drop this event, keep going
            append_line(PRESENCE_LOG, {"ts": round(time.time(), 3), "person_id": self.pid, "event": ev, "ack": ack})
            print(f"[{self.pid}] {code}: {err.get('message')} (event dropped)")
            if len(self.queue) > 1:
                time.sleep(0.6)  # respect the two-per-second limit when draining a backlog


def main():
    cfg = load_env()
    print(f"dewin_presence -> {cfg['DEWIN_API_URL']} at ({cfg['KIOSK_LAT']}, {cfg['KIOSK_LON']}), "
          f"every {cfg['DEWIN_INTERVAL_S']} s; sessions from {SESSIONS}")
    active = {}
    warned = set()
    try:
        while True:
            sessions = read_json(SESSIONS, {})
            tokens = read_json(TOKENS, {})
            for pid in list(active):
                if pid not in sessions:
                    print(f"[{pid}] checked out; stopping presence")
                    active.pop(pid).close()
            for pid in sessions:
                if pid in active:
                    continue
                token = tokens.get(pid)
                if not token:
                    if pid not in warned:
                        print(f"[{pid}] checked in but has no token in {TOKENS}; not submitting")
                        warned.add(pid)
                    continue
                print(f"[{pid}] checked in; starting presence")
                active[pid] = UserPresence(pid, token, cfg)
            for up in active.values():
                up.tick()
            time.sleep(1.0)
    except KeyboardInterrupt:
        pass
    finally:
        for up in active.values():
            up.close()


if __name__ == "__main__":
    main()
