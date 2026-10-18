#!/usr/bin/env python3
"""kiosk_display: the kiosk's screen. Serves a full-screen page and a JSON state feed built from the
kiosk's own files, plus an "ambient" Dewin client that keeps the venue's live readings on screen.

  python3 kiosk_display.py [--port 8080] [--no-ambient]
  chromium --kiosk http://localhost:8080

State feed (GET /api/state) is assembled every request from:
  ~/envlab/events.jsonl          tap, checkin, face_reject, unknown_card, checkout, tamper, rc522_reinit
  ~/envlab/sessions.json         who is checked in now, since when
  ~/envlab/dewin_exposure.jsonl  exposure:update records per person (written by dewin_presence.py)
  ~/envlab/nano_imu.jsonl        reader liveness
and from the ambient client: the latest exposure:update for the kiosk's own position (token "0",
shared demo identity), which is what the idle screen shows as "live at this venue".

Screens are decided here, not in the page: idle, verifying, welcome, checked_in, rejected, unknown,
checked_out. The page polls once a second and renders.
"""
import argparse
import json
import os
import sys
import threading
import time
import uuid
from collections import defaultdict, deque
from datetime import datetime, timezone
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

HERE = Path(__file__).resolve().parent
ROOT = Path.home() / "envlab"
EVENTS = ROOT / "events.jsonl"
SESSIONS = ROOT / "sessions.json"
EXPOSURE = ROOT / "dewin_exposure.jsonl"
IMU = ROOT / "nano_imu.jsonl"

VERIFY_WINDOW_S = 12     # how long a tap keeps the "look at the camera" screen without a verdict
WELCOME_S = 10           # welcome splash after a successful check-in
REJECT_S = 8
UNKNOWN_S = 8
CHECKOUT_S = 30          # visit summary after check-out


# ---------------------------------------------------------------- files

def load_env():
    env = {"DEWIN_API_URL": "https://dewin-api.cbnsndwch.dev", "KIOSK_ACCURACY_M": "5",
           "DEWIN_INTERVAL_S": "5", "KIOSK_NAME": "Dewin kiosk", "VENUE_NAME": "Demo venue"}
    p = ROOT / ".env"
    if p.exists():
        for line in p.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env[k.strip()] = v.strip().strip('"').strip("'")
    for k, v in os.environ.items():
        if k in env or k.startswith(("KIOSK_", "DEWIN_", "VENUE_")):
            env[k] = v
    return env


def read_json(p, default):
    try:
        return json.loads(p.read_text()) if p.exists() else default
    except (json.JSONDecodeError, OSError):
        return default


def tail_records(p, max_bytes):
    """Parse the last max_bytes of a jsonl file into dicts (oldest first), skipping partial/bad lines."""
    if not p.exists():
        return []
    try:
        size = p.stat().st_size
        with p.open("rb") as f:
            f.seek(max(0, size - max_bytes))
            data = f.read()
    except OSError:
        return []
    lines = data.split(b"\n")
    if size > max_bytes:
        lines = lines[1:]  # first line is probably cut
    out = []
    for raw in lines:
        raw = raw.strip()
        if not raw:
            continue
        try:
            out.append(json.loads(raw))
        except json.JSONDecodeError:
            continue
    return out


# ---------------------------------------------------------------- exposure maths

def label(medium, metric):
    names = {"tds": "TDS", "temperature": "temperature", "humidity": "humidity", "co2": "CO2",
             "pm2_5": "PM2.5", "ph": "pH", "turbidity": "turbidity", "conductivity": "conductivity"}
    base = names.get(metric, metric.replace("_", " "))
    if medium in ("air", "water") and metric not in ("ph", "tds"):
        return f"{medium} {base}"
    if metric == "tds":
        return "water TDS"
    return base


def flatten(record):
    """exposure:update -> list of measurement rows."""
    rows = []
    for s in record.get("sensors") or []:
        for m in s.get("measurements") or []:
            if not isinstance(m.get("value"), (int, float)):
                continue
            rows.append({
                "key": f"{m.get('medium')}/{m.get('metric')}",
                "hkey": f"{s.get('deviceId')}/{m.get('sensorId')}/{m.get('medium')}/{m.get('metric')}",
                "label": label(m.get("medium"), m.get("metric", "")),
                "medium": m.get("medium"), "metric": m.get("metric"),
                "value": m["value"], "unit": m.get("unit", ""), "quality": m.get("quality", "ok"),
                "rollingMean": m.get("rollingMean"), "sampleCount": m.get("sampleCount"),
                "deviceId": s.get("deviceId"), "sensorId": m.get("sensorId"),
                "locationId": s.get("locationId"), "distanceM": s.get("distanceM"),
                "source": s.get("source", "sensor"), "visibility": s.get("visibility"),
            })
    return rows


def aggregate(records):
    """Per medium/metric: samples, mean, min, max, last over a list of exposure records."""
    acc = {}
    for r in records:
        for row in flatten(r):
            a = acc.setdefault(row["key"], {"key": row["key"], "label": row["label"], "medium": row["medium"],
                                             "metric": row["metric"], "unit": row["unit"], "n": 0, "sum": 0.0,
                                             "min": None, "max": None, "last": None, "simulated": False})
            v = row["value"]
            a["n"] += 1
            a["sum"] += v
            a["min"] = v if a["min"] is None else min(a["min"], v)
            a["max"] = v if a["max"] is None else max(a["max"], v)
            a["last"] = v
            a["simulated"] = a["simulated"] or row["source"] == "simulated"
    out = []
    for a in acc.values():
        a["mean"] = a["sum"] / a["n"] if a["n"] else None
        del a["sum"]
        out.append(a)
    out.sort(key=lambda a: (a["medium"] or "", a["metric"] or ""))
    return out


# ---------------------------------------------------------------- ambient venue readings

class Ambient:
    """Keeps the venue's live readings by acting as a demo client at the kiosk position."""

    def __init__(self, cfg):
        self.cfg = cfg
        self.latest = None
        self.latest_ts = 0.0
        self.connected = False
        self.history = defaultdict(lambda: deque(maxlen=90))
        self.lock = threading.Lock()
        self.submitted = deque(maxlen=500)
        self.enabled = bool(cfg.get("KIOSK_LAT")) and bool(cfg.get("KIOSK_LON"))
        self.sio = None

    def start(self):
        if not self.enabled:
            print("ambient: KIOSK_LAT/KIOSK_LON not set; venue readings disabled")
            return
        try:
            import socketio
        except ImportError:
            print("ambient: python3-socketio not installed; venue readings disabled")
            return
        self.socketio = socketio
        threading.Thread(target=self._run, daemon=True).start()

    def _on_exposure(self, data):
        if data.get("locationEventId") not in self.submitted:
            return
        with self.lock:
            self.latest = data
            self.latest_ts = time.time()
            for row in flatten(data):
                self.history[row["hkey"]].append([round(time.time()), row["value"]])

    def _run(self):
        sio = self.socketio.Client(reconnection=True, reconnection_delay=2, reconnection_delay_max=30)
        self.sio = sio
        sio.on("exposure:update", self._on_exposure)
        sio.on("connect", lambda: setattr(self, "connected", True))
        sio.on("disconnect", lambda: setattr(self, "connected", False))
        interval = float(self.cfg["DEWIN_INTERVAL_S"])
        last_try = 0.0
        while True:
            if not sio.connected:
                if time.time() - last_try >= 5:
                    last_try = time.time()
                    try:
                        sio.connect(self.cfg["DEWIN_API_URL"], auth={"token": self.cfg.get("AMBIENT_TOKEN", "0")},
                                    transports=["websocket"], wait_timeout=10)
                    except Exception as e:  # noqa: BLE001
                        print(f"ambient: connect failed: {e}")
                time.sleep(1)
                continue
            ev_id = str(uuid.uuid4())
            self.submitted.append(ev_id)
            ev = {"schemaVersion": 1, "eventId": ev_id,
                  "measuredAt": datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z"),
                  "latitude": float(self.cfg["KIOSK_LAT"]), "longitude": float(self.cfg["KIOSK_LON"]),
                  "accuracyM": float(self.cfg["KIOSK_ACCURACY_M"])}
            try:
                sio.call("location:update", ev, timeout=10)
            except Exception as e:  # noqa: BLE001
                print(f"ambient: submit failed: {e}")
            time.sleep(interval)

    def snapshot(self):
        with self.lock:
            rows = flatten(self.latest) if self.latest else []
            hist = {k: list(v) for k, v in self.history.items()}
            return {"connected": self.connected, "age_s": round(time.time() - self.latest_ts, 1) if self.latest else None,
                    "readings": rows, "history": hist, "status": (self.latest or {}).get("status")}


# ---------------------------------------------------------------- state assembly

def build_state(cfg, ambient):
    now = time.time()
    events = tail_records(EVENTS, 300_000)
    sessions = read_json(SESSIONS, {})
    exposures = tail_records(EXPOSURE, 3_000_000)
    imu = tail_records(IMU, 4_000)

    significant = [e for e in events if e.get("type") in ("tap", "checkin", "face_reject", "unknown_card", "checkout")]
    last = significant[-1] if significant else None
    age = now - last["ts"] if last else None

    screen, focus, summary = "idle", None, None
    if last and last["type"] == "tap" and age < VERIFY_WINDOW_S:
        screen, focus = "verifying", last.get("id")
    elif last and last["type"] == "checkin" and age < WELCOME_S and last.get("id") in sessions:
        screen, focus = "welcome", last.get("id")
    elif last and last["type"] == "face_reject" and age < REJECT_S:
        screen, focus = "rejected", last.get("id")
    elif last and last["type"] == "unknown_card" and age < UNKNOWN_S:
        screen = "unknown"
    elif last and last["type"] == "checkout" and age < CHECKOUT_S:
        screen, focus = "checked_out", last.get("id")
        start, end = float(last.get("start") or 0), float(last["ts"])
        recs = [r for r in exposures if r.get("person_id") == focus and start <= r.get("ts", 0) <= end + 2]
        summary = {"person": focus, "start": start, "end": end, "duration_s": last.get("duration_s"),
                   "records": len(recs), "exposure": aggregate(recs)}
    elif sessions:
        screen = "checked_in"

    people = []
    for pid, s in sorted(sessions.items(), key=lambda kv: kv[1].get("start", 0), reverse=True):
        start = float(s.get("start", now))
        recs = [r for r in exposures if r.get("person_id") == pid and r.get("ts", 0) >= start]
        latest = recs[-1] if recs else None
        people.append({"id": pid, "start": start, "elapsed_s": round(now - start),
                       "records": len(recs), "exposure": aggregate(recs),
                       "latest": flatten(latest) if latest else [],
                       "latest_age_s": round(now - latest["ts"], 1) if latest else None})
    if screen in ("welcome", "checked_in") and focus is None and people:
        focus = people[0]["id"]

    last_score = None
    for e in reversed(events):
        if e.get("type") == "checkin" and e.get("id") == focus:
            last_score = e.get("score")
            break

    reader_age = (now - imu[-1]["ts"]) if imu and "ts" in imu[-1] else None
    alerts = [e for e in events if e.get("type") in ("tamper", "rc522_reinit") and now - e.get("ts", 0) < 30]
    ticker = [{"ts": e.get("ts"), "type": e.get("type"), "id": e.get("id"), "score": e.get("score"),
               "duration_s": e.get("duration_s")} for e in events[-8:]]

    return {
        "now": now, "screen": screen, "focus": focus, "focus_score": last_score, "summary": summary,
        "people": people, "venue": ambient.snapshot(), "ticker": ticker, "alerts": alerts,
        "reader_online": reader_age is not None and reader_age < 6,
        "kiosk_name": cfg.get("KIOSK_NAME"), "venue_name": cfg.get("VENUE_NAME"),
        "position": {"lat": cfg.get("KIOSK_LAT"), "lon": cfg.get("KIOSK_LON")},
    }


# ---------------------------------------------------------------- http

def make_handler(cfg, ambient):
    class Handler(SimpleHTTPRequestHandler):
        def __init__(self, *a, **kw):
            super().__init__(*a, directory=str(HERE), **kw)

        def log_message(self, fmt, *args):  # keep the console for real information
            pass

        def do_GET(self):
            path = urlparse(self.path).path
            if path == "/api/state":
                try:
                    body = json.dumps(build_state(cfg, ambient)).encode()
                except Exception as e:  # noqa: BLE001
                    body = json.dumps({"screen": "idle", "error": str(e), "people": [], "venue": {"readings": []}}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Cache-Control", "no-store")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            if path == "/":
                self.path = "/index.html"
            return super().do_GET()
    return Handler


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--no-ambient", action="store_true", help="do not pull live venue readings from Dewin")
    args = ap.parse_args()
    cfg = load_env()
    ambient = Ambient(cfg)
    if not args.no_ambient:
        ambient.start()
    srv = ThreadingHTTPServer(("0.0.0.0", args.port), make_handler(cfg, ambient))
    print(f"kiosk display on http://localhost:{args.port}  (files from {ROOT}, page from {HERE})")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
