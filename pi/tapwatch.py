#!/usr/bin/env python3
"""tapwatch: card tap on the Nano 33 IoT (USB serial) -> face verification -> check-in / check-out events.

Run from ~/envlab (it imports facekit.py from the same directory):
  python3 tapwatch.py                   listen: known card + matching face = check-in; next tap by that person = check-out
  python3 tapwatch.py --bind muntaser   bind the next tapped card to an enrolled person, then exit
  python3 tapwatch.py --list            show card bindings and open sessions

Files (all under ~/envlab):
  cards.json       {"04A1B2C3": "muntaser", ...}                card UID -> enrolled person id
  sessions.json    {"muntaser": {"uid": "...", "start": ts}}    currently open sessions
  events.jsonl     one JSON object per line: hello, tamper, bind, unknown_card, checkin, checkout, face_reject
  nano_imu.jsonl   the node's 1 Hz IMU telemetry, for the sensor log
Exposure accounting later joins each checkin/checkout pair with the sensor log by timestamp.
"""
import argparse
import glob
import json
import sys
import time

import serial  # apt: python3-serial

import facekit as fk

CARDS = fk.ROOT / "cards.json"
SESSIONS = fk.ROOT / "sessions.json"
EVENTS = fk.ROOT / "events.jsonl"
IMU_LOG = fk.ROOT / "nano_imu.jsonl"


def find_port():
    for pat in ("/dev/ttyACM*", "/dev/ttyUSB*"):
        ports = sorted(glob.glob(pat))
        if ports:
            return ports[0]
    sys.exit("no /dev/ttyACM* device found; is the Nano plugged into the Pi's USB?")


def read_json(p, default):
    return json.loads(p.read_text()) if p.exists() else default


def write_json(p, obj):
    p.write_text(json.dumps(obj, indent=2))


def append_line(p, obj):
    with p.open("a") as f:
        f.write(json.dumps(obj) + "\n")


def log_event(ev):
    ev = {"ts": round(time.time(), 3), "iso": time.strftime("%Y-%m-%dT%H:%M:%S"), **ev}
    append_line(EVENTS, ev)
    return ev


def verify_live(cam, det, rec, pid, seconds):
    ref, _ = fk.load_template(pid)
    best, n, seen, t0 = -1.0, 0, 0, time.time()
    while time.time() - t0 < seconds:
        img = cam.frame()
        faces = fk.detect(det, img)
        n += 1
        f = fk.largest(faces)
        if f is None:
            continue
        seen += 1
        s = fk.cosine(ref, fk.embed(rec, img, f))
        best = max(best, s)
        if s >= fk.COS_THRESH:
            break
    return best, n, seen


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--bind", metavar="ID", help="bind the next tapped card to this enrolled person, then exit")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--seconds", type=float, default=5.0, help="face verification window per tap")
    args = ap.parse_args()

    cards = read_json(CARDS, {})
    sessions = read_json(SESSIONS, {})
    if args.list:
        print("cards:", json.dumps(cards, indent=2))
        print("open sessions:", json.dumps(sessions, indent=2))
        return
    if args.bind:
        fk.load_template(args.bind)  # exits with a clear message if that id is not enrolled

    port = args.port or find_port()
    ser = serial.Serial(port, args.baud, timeout=1)
    print(f"serial: {port} @ {args.baud}")
    ser.write(b'{"cmd":"ping"}\n')
    ser.write(b'{"cmd":"rebase"}\n')  # the reader is in its final position when this starts: re-take the IMU baseline

    det = rec = cam = None
    if not args.bind:
        det, rec = fk.load_models()
        cam = fk.Camera()
        print("models loaded, camera running")
    print("tap a card" + (f" to bind it to '{args.bind}'" if args.bind else ""))

    try:
        while True:
            raw = ser.readline().decode("utf-8", "replace").strip()
            if not raw:
                continue
            try:
                msg = json.loads(raw)
            except json.JSONDecodeError:
                print(f"[serial] {raw}")
                continue
            t = msg.get("type")

            if t == "hello":
                v = str(msg.get("rc522_version", "?"))
                warn = "   <-- RC522 not answering: check wiring" if v.upper() in ("0X0", "0X00", "0XFF") else ""
                print(f"node {msg.get('node')}: rc522 version {v}, imu {msg.get('imu')}{warn}")
                log_event({"type": "hello", **msg})

            elif t == "imu":
                append_line(IMU_LOG, {"ts": round(time.time(), 3), **msg})

            elif t == "tamper":
                print(f"!! node moved (deviation {msg.get('dev_g')} g)")
                log_event({"type": "tamper", **msg})

            elif t == "card":
                uid = msg["uid"]
                if args.bind:
                    cards[uid] = args.bind
                    write_json(CARDS, cards)
                    log_event({"type": "bind", "uid": uid, "id": args.bind, "picc": msg.get("picc")})
                    print(f"bound card {uid} ({msg.get('picc')}) -> {args.bind}")
                    return
                pid = cards.get(uid)
                if pid is None:
                    print(f"card {uid}: unknown. Bind it with: python3 tapwatch.py --bind <id>")
                    log_event({"type": "unknown_card", "uid": uid, "picc": msg.get("picc")})
                    continue
                if pid in sessions:
                    start = sessions.pop(pid)
                    write_json(SESSIONS, sessions)
                    dur = time.time() - start["start"]
                    log_event({"type": "checkout", "uid": uid, "id": pid, "start": start["start"],
                               "duration_s": round(dur, 1)})
                    print(f"card {uid}: {pid} checked OUT after {dur / 60:.1f} min")
                    continue
                print(f"card {uid}: {pid}, look at the camera...")
                best, n, seen = verify_live(cam, det, rec, pid, args.seconds)
                ok = best >= fk.COS_THRESH
                if ok:
                    sessions[pid] = {"uid": uid, "start": round(time.time(), 3)}
                    write_json(SESSIONS, sessions)
                    log_event({"type": "checkin", "uid": uid, "id": pid, "score": round(best, 4),
                               "frames": n, "with_face": seen})
                    print(f"  MATCH {best:.3f}: {pid} checked IN")
                else:
                    log_event({"type": "face_reject", "uid": uid, "id": pid, "score": round(best, 4),
                               "frames": n, "with_face": seen})
                    print(f"  NO MATCH {best:.3f} (face seen in {seen}/{n} frames): card holder is not {pid}")

            elif t in ("ack", "error"):
                print(f"[node] {raw}")
    except KeyboardInterrupt:
        pass
    finally:
        if cam:
            cam.close()
        ser.close()


if __name__ == "__main__":
    main()
