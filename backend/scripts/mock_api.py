"""Local-only Socket.IO API v1 mock. Synthetic data, memory storage, no NATS.

This is for iOS integration while the real gateway is being implemented.
"""
import argparse
import asyncio
import base64
from collections import defaultdict, deque
from copy import deepcopy
from datetime import datetime, timezone
import hashlib
import hmac
import json
import math
from pathlib import Path
import secrets
import time
import uuid

from aiohttp import web
from jsonschema import Draft202012Validator, ValidationError
import socketio

ROOT = Path(__file__).resolve().parents[1]
SCHEMA = json.loads((ROOT / "docs/api-v1.schema.json").read_text(encoding="utf-8"))
FIXTURES = json.loads((ROOT / "docs/api-v1.examples.json").read_text(encoding="utf-8"))
TOKENS = {"dev-only-alice-token": "alice", "dev-only-bob-token": "bob"}


def timestamp(value=None):
    return datetime.fromtimestamp(time.time() if value is None else value, timezone.utc).isoformat().replace("+00:00", "Z")


def parse_date(value):
    result = datetime.fromisoformat(value.replace("Z", "+00:00").replace("z", "+00:00"))
    if result.utcoffset() is None:
        raise ValueError("Timezone required")
    return result.timestamp()


def validate(name, data):
    # JSON itself has no NaN/infinity; some language encoders accept them.
    if len(json.dumps(data, allow_nan=False).encode()) > 16384:
        raise ValueError("Request exceeds 16 KiB")
    Draft202012Validator({"$ref": "#/$defs/" + name, "$defs": SCHEMA["$defs"]}).validate(data)


def failure(code, message, data=None, retryable=False):
    result = {"ok": False, "error": {"code": code, "message": message, "retryable": retryable}}
    if isinstance(data, dict):
        for key in ("eventId", "requestId"):
            try:
                result[key] = str(uuid.UUID(data[key]))
            except (KeyError, ValueError, TypeError, AttributeError):
                pass
    return result


def distance_m(latitude, longitude, other):
    a, b = math.radians(latitude), math.radians(other["latitude"])
    delta = math.radians(other["longitude"] - longitude)
    h = math.sin((b-a)/2)**2 + math.cos(a)*math.cos(b)*math.sin(delta/2)**2
    return 6371008.8 * 2 * math.asin(min(1, math.sqrt(h)))


def create_app():
    sio = socketio.AsyncServer(async_mode="aiohttp", logger=False, engineio_logger=False,
                              cors_allowed_origins=None, max_http_buffer_size=16384)
    app = web.Application()
    sio.attach(app)
    records = defaultdict(dict)
    submissions = defaultdict(deque)
    cursor_secret = secrets.token_bytes(32)
    sequence = 0

    def cursor_encode(value):
        payload = base64.urlsafe_b64encode(json.dumps(value, separators=(",", ":")).encode()).rstrip(b"=")
        signature = hmac.new(cursor_secret, payload, hashlib.sha256).hexdigest()
        return payload.decode() + "." + signature

    def cursor_decode(value):
        payload, signature = value.rsplit(".", 1)
        expected = hmac.new(cursor_secret, payload.encode(), hashlib.sha256).hexdigest()
        if not hmac.compare_digest(expected, signature):
            raise ValueError("Invalid cursor")
        return json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))

    @sio.event
    async def connect(sid, environ, auth):
        try:
            validate("ConnectionAuth", auth)
            user = TOKENS.get(auth["token"])
        except (ValidationError, ValueError, TypeError):
            user = None
        if user is None:
            raise socketio.exceptions.ConnectionRefusedError("UNAUTHORIZED")
        await sio.save_session(sid, {"user": user})
        await sio.enter_room(sid, user)

    @sio.on("location:update")
    async def location(sid, data):
        nonlocal sequence
        user = (await sio.get_session(sid))["user"]
        try:
            validate("LocationUpdate", data)
            observed = parse_date(data["measuredAt"])
            if not time.time()-90*86400 <= observed <= time.time()+60:
                raise ValueError("Timestamp outside allowed horizon")
        except (ValidationError, ValueError, TypeError, OverflowError):
            return failure("INVALID_PAYLOAD", "Invalid location fields or timestamp", data)
        event_id = str(uuid.UUID(data["eventId"]))
        canonical = json.dumps({**data, "eventId": event_id}, sort_keys=True, allow_nan=False)
        previous = records[user].get(event_id)
        if previous:
            if previous["input"] != canonical:
                return failure("EVENT_ID_CONFLICT", "Event ID was already used for different data", data)
            return {**previous["ack"], "duplicate": True}
        recent = submissions[user]
        while recent and recent[0] <= time.monotonic()-1:
            recent.popleft()
        if len(recent) >= 2:
            return failure("RATE_LIMITED", "Wait before submitting another location", data, retryable=True)
        recent.append(time.monotonic())
        received = timestamp()
        exposure = deepcopy(FIXTURES["Exposure"])
        exposure.update(exposureId=str(uuid.uuid5(uuid.NAMESPACE_URL, "mock/"+user+"/"+event_id)),
                        locationEventId=event_id, measuredAt=timestamp(observed),
                        receivedAt=received, processedAt=timestamp(),
                        position={"latitude": data["latitude"], "longitude": data["longitude"],
                                  "accuracyM": data.get("accuracyM")})
        public = exposure["sensors"][0]
        distance = distance_m(data["latitude"], data["longitude"], public["position"])
        if distance > exposure["matchRadiusM"]:
            exposure.update(status="no_match", sensors=[])
        else:
            public.update(distanceM=round(distance, 2), measuredAt=timestamp(observed-3),
                          receivedAt=timestamp(observed-2.9), observedAt=timestamp(observed-3))
            if user == "alice":
                private = deepcopy(public)
                private.update(deviceId="mock-alice-home", locationId="mock-home", visibility="private")
                exposure["sensors"].append(private)
        ack = {"ok": True, "eventId": event_id, "receivedAt": received, "duplicate": False}
        sequence += 1
        records[user][event_id] = {"input": canonical, "ack": ack, "exposure": exposure, "sequence": sequence}
        if len(records[user]) > 5000:
            del records[user][next(iter(records[user]))]
        await sio.emit("exposure:update", exposure, room=user)
        return ack

    @sio.on("exposure:history")
    async def history(sid, data):
        user = (await sio.get_session(sid))["user"]
        try:
            validate("HistoryQuery", data)
            start, end = parse_date(data["from"]), parse_date(data["to"])
            if not 0 < end-start <= 31*86400:
                raise ValueError("Invalid history range")
        except (ValidationError, ValueError, TypeError, OverflowError):
            return failure("INVALID_PAYLOAD", "Invalid history fields or range", data)
        limit = data.get("limit", 100)
        query = [user, data["from"], data["to"], limit]
        snapshot, last, expires = sequence, None, time.time()+900
        if data.get("cursor"):
            try:
                cursor = cursor_decode(data["cursor"])
                if cursor["query"] != query or cursor["expires"] < time.time():
                    raise ValueError("Cursor does not match this query")
                snapshot, last, expires = cursor["snapshot"], cursor["last"], cursor["expires"]
            except (ValueError, KeyError, TypeError, json.JSONDecodeError):
                return failure("INVALID_CURSOR", "Restart the query without a cursor", data)
        selected = []
        for value in records[user].values():
            exposure = value["exposure"]
            key = [parse_date(exposure["measuredAt"]), exposure["exposureId"]]
            if value["sequence"] <= snapshot and start <= key[0] < end and (last is None or key > last):
                selected.append((key, exposure))
        selected.sort(key=lambda x: x[0])
        page = selected[:limit]
        cursor = None
        if len(selected) > limit:
            cursor = cursor_encode({"query": query, "snapshot": snapshot, "last": page[-1][0], "expires": expires})
        return {"ok": True, "requestId": data["requestId"], "items": [v for _, v in page], "nextCursor": cursor}

    async def health(request):
        return web.json_response({"ok": True, "mode": "mock", "persistent": False, "schemaVersion": 1})

    app.router.add_get("/healthz", health)
    return app


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()
    print("Dewin MOCK: synthetic data, in-memory history, NOT the deployed gateway.", flush=True)
    web.run_app(create_app(), host=args.host, port=args.port, access_log=None)
