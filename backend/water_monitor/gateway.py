"""Live Socket.IO gateway backed entirely by NATS/JetStream streams and KV."""
import asyncio
from collections import defaultdict, deque
import hashlib
import hmac
import json
import logging
import os
from pathlib import Path
import re
import time
import uuid

from aiohttp import web
from jsonschema import ValidationError
import socketio

from .api_protocol import Cursors, error, parse_date, validate
from .contract import iso, now_ts
from .dewin_bus import connect, encode, ensure_resources, kv_get, HORIZON, GEO_STREAM
from .spatial import authorized_result, registry

LOG = logging.getLogger("dewin-api")


class Gateway:
    def __init__(self):
        origins = os.getenv("API_ALLOWED_ORIGINS") or "https://dewin-api.cbnsndwch.dev,https://dewin.cbnsndwch.dev,http://localhost:3000,http://localhost:5173"
        self.sio = socketio.AsyncServer(async_mode="aiohttp", cors_allowed_origins=origins.split(","),
                                       max_http_buffer_size=65536, logger=False, engineio_logger=False)
        self.app = web.Application()
        self.sio.attach(self.app)
        self.clients = json.loads(Path(os.getenv("API_CLIENTS_PATH", "/run/dewin/clients.json")).read_text())["clients"]
        for client in self.clients:
            if not re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,47}", client["userId"]) or not re.fullmatch(r"[0-9a-f]{64}", client["tokenSha256"]):
                raise ValueError("Invalid private API client configuration")
        self.cursors = Cursors(os.environ["API_CURSOR_SECRET"])
        self.index = {}
        self.ready = asyncio.Event()
        self.applied_revision = 0
        self.locks = defaultdict(asyncio.Lock)
        self.recent = defaultdict(deque)
        self.nc = self.js = self.buckets = self.watcher = self.task = None
        self.sio.on("connect", self.authenticate)
        self.sio.on("location:update", self.location)
        self.sio.on("exposure:history", self.history)
        self.app.router.add_get("/healthz", self.health)
        self.app.router.add_get("/", self.info)
        self.app.router.add_get("/architecture", self.architecture)
        self.app.router.add_get("/architecture/", self.architecture)
        self.app.router.add_get("/docs/{filename}", self.docs)
        self.app.on_startup.append(self.start)
        self.app.on_cleanup.append(self.close)

    async def start(self, app):
        self.nc = await connect("dewin-socketio-api")
        self.js = self.nc.jetstream()
        self.buckets = await ensure_resources(self.js)
        self.task = asyncio.create_task(self.watch_results())

    async def close(self, app):
        if self.watcher:
            await self.watcher.stop()
        if self.task:
            self.task.cancel()
            await asyncio.gather(self.task, return_exceptions=True)
        if self.nc:
            await self.nc.close()

    async def watch_results(self):
        while True:
            try:
                # A reconnect may require a fresh ordered consumer. Rebuild the
                # disposable index from retained KV, without replaying it live.
                self.ready.clear()
                self.index.clear()
                self.applied_revision = 0
                self.watcher = await self.buckets["DEWIN_RESULTS"].watchall()
                async for entry in self.watcher:
                    if entry is None:
                        state = (await self.js.stream_info("KV_DEWIN_RESULTS")).state
                        if state.messages == 0:
                            self.applied_revision = max(self.applied_revision, state.last_seq)
                        self.ready.set()
                        continue
                    self.applied_revision = max(self.applied_revision, entry.revision)
                    if entry.operation in {"DEL", "PURGE"}:
                        self.index.pop(entry.key, None)
                        continue
                    value = json.loads(entry.value)
                    if not value.get("published"):
                        continue
                    exposure = value["exposure"]
                    previous = self.index.get(entry.key)
                    self.index[entry.key] = {"user": value["userId"], "at": parse_date(exposure["measuredAt"]),
                        "id": exposure["exposureId"], "revision": entry.revision,
                        "expires": entry.created.timestamp()+HORIZON}
                    if self.ready.is_set() and previous is None:
                        filtered = authorized_result(exposure, value["userId"], registry())
                        await self.sio.emit("exposure:update", filtered, room="user:"+value["userId"])
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                self.ready.clear()
                LOG.warning("Rebuilding result index after %s", type(exc).__name__)
            finally:
                self.ready.clear()
                if self.watcher:
                    try:
                        await self.watcher.stop()
                    except Exception:
                        pass
            await asyncio.sleep(1)

    async def synchronize(self):
        if not self.ready.is_set() or not self.nc.is_connected or self.task.done():
            raise RuntimeError("Index unavailable")
        target = (await self.js.stream_info("KV_DEWIN_RESULTS")).state.last_seq
        deadline = time.monotonic()+5
        while self.applied_revision < target:
            if time.monotonic() >= deadline or self.task.done():
                raise RuntimeError("Index catch-up timeout")
            await asyncio.sleep(.01)
        return self.applied_revision

    async def authenticate(self, sid, environ, auth):
        try:
            validate("ConnectionAuth", auth)
            found = "demo-ios"
            if isinstance(auth, dict) and "token" in auth:
                hashed = hashlib.sha256(auth["token"].encode()).hexdigest()
                found = None
                for client in self.clients:
                    if hmac.compare_digest(hashed, client["tokenSha256"]):
                        found = client["userId"]
            if found is None:
                raise ValueError("Unauthorized")
        except (ValueError, TypeError, ValidationError, KeyError):
            raise socketio.exceptions.ConnectionRefusedError("UNAUTHORIZED")
        if not self.ready.is_set() or not self.nc.is_connected:
            raise socketio.exceptions.ConnectionRefusedError("UNAVAILABLE")
        await self.sio.save_session(sid, {"user": found})
        await self.sio.enter_room(sid, "user:"+found)

    async def location(self, sid, data):
        user = (await self.sio.get_session(sid))["user"]
        try:
            validate("LocationUpdate", data)
            observed = parse_date(data["measuredAt"])
            if not now_ts()-HORIZON <= observed <= now_ts()+60:
                raise ValueError("Timestamp outside horizon")
            data = {**data, "eventId": str(uuid.UUID(data["eventId"]))}
        except (ValueError, TypeError, OverflowError, ValidationError):
            return error("INVALID_PAYLOAD", "Invalid location fields or timestamp", data)
        key = user+"."+data["eventId"]
        digest = hashlib.sha256(encode(data)).hexdigest()
        async with self.locks[user]:
            try:
                previous, revision = await kv_get(self.buckets["DEWIN_RECEIPTS"], key)
                duplicate = previous is not None
                if previous:
                    if previous["digest"] != digest:
                        return error("EVENT_ID_CONFLICT", "Event ID was already used for different data", data)
                    if previous["published"]:
                        return {"ok": True, "eventId": data["eventId"], "receivedAt": previous["receivedAt"], "duplicate": True}
                else:
                    recent = self.recent[user]
                    while recent and recent[0] <= time.monotonic()-1:
                        recent.popleft()
                    if len(recent) >= 2:
                        return error("RATE_LIMITED", "Wait before another location submission", data, True)
                    recent.append(time.monotonic())
                    previous = {"digest": digest, "receivedAt": iso(now_ts()), "published": False}
                    revision = await self.buckets["DEWIN_RECEIPTS"].create(key, encode(previous))
                envelope = {"userId": user, "location": data, "receivedAt": previous["receivedAt"]}
                await self.js.publish(f"dewin.v1.{user}.location", encode(envelope), headers={"Nats-Msg-Id": "location/"+key})
                previous["published"] = True
                await self.buckets["DEWIN_RECEIPTS"].update(key, encode(previous), last=revision)
                return {"ok": True, "eventId": data["eventId"], "receivedAt": previous["receivedAt"], "duplicate": duplicate}
            except Exception as exc:
                LOG.warning("Position persistence unavailable: %s", type(exc).__name__)
                return error("UNAVAILABLE", "Position was not confirmed; retry the same event", data, True)

    async def history(self, sid, data):
        user = (await self.sio.get_session(sid))["user"]
        try:
            validate("HistoryQuery", data)
            start, end = parse_date(data["from"]), parse_date(data["to"])
            if not 0 < end-start <= 31*86400:
                raise ValueError("Invalid range")
        except (ValueError, TypeError, OverflowError, ValidationError):
            return error("INVALID_PAYLOAD", "Invalid history fields or range", data)
        limit = data.get("limit", 100)
        query = [user, data["from"], data["to"], limit]
        try:
            snapshot = await self.synchronize()
            last, expires = None, now_ts()+900
            if data.get("cursor"):
                try:
                    cursor = self.cursors.decode(data["cursor"], query)
                    snapshot, last, expires = cursor["snapshot"], cursor["last"], cursor["expires"]
                except (ValueError, TypeError, KeyError):
                    return error("INVALID_CURSOR", "Restart the query without a cursor", data)
            selected = []
            for key, meta in list(self.index.items()):
                order = [meta["at"], meta["id"]]
                if (meta["user"] == user and meta["revision"] <= snapshot and meta["expires"] > now_ts()
                        and start <= meta["at"] < end and (last is None or order > last)):
                    selected.append((order, key))
            selected.sort(key=lambda item: item[0])
            items, consumed, final_order = [], 0, last
            devices = registry()
            for order, key in selected:
                value, _ = await kv_get(self.buckets["DEWIN_RESULTS"], key)
                consumed += 1
                final_order = order
                if value and value.get("published") and value["userId"] == user:
                    items.append(authorized_result(value["exposure"], user, devices))
                if len(items) >= limit:
                    break
            cursor = None
            if consumed < len(selected):
                cursor = self.cursors.encode({"query": query, "snapshot": snapshot, "last": final_order, "expires": expires})
            return {"ok": True, "requestId": data["requestId"], "items": items, "nextCursor": cursor}
        except Exception as exc:
            LOG.warning("History unavailable: %s", type(exc).__name__)
            return error("UNAVAILABLE", "History is temporarily unavailable", data, True)

    async def health(self, request):
        processor = False
        try:
            value, _ = await kv_get(self.buckets["DEWIN_HEALTH"], "spatial")
            processor = bool(value and value["ready"] and now_ts()-value["updatedAt"] < 15)
        except Exception:
            pass
        live = bool(self.nc and self.nc.is_connected and self.ready.is_set() and self.task and not self.task.done())
        return web.json_response({"ok": live and processor, "mode": "live", "schemaVersion": 1,
                                  "nats": live, "processor": processor}, status=200 if live and processor else 503)

    async def info(self, request):
        return web.json_response({"service": "Dewin environmental API", "mode": "live", "schemaVersion": 1,
            "socketioPath": "/socket.io/", "namespace": "/", "authentication": "No token required; shared demo-ios identity",
            "events": ["location:update", "exposure:update", "exposure:history"], "health": "/healthz",
            "contract": "/docs/api-v1.md", "architecture": "/architecture/"})

    async def architecture(self, request):
        return web.FileResponse(Path("/app/docs/architecture/index.html"),
                                headers={"Cache-Control": "no-cache"})

    async def docs(self, request):
        filename = request.match_info["filename"]
        if filename not in {"api-v1.md", "api-v1.schema.json", "api-v1.examples.json"}:
            raise web.HTTPNotFound()
        return web.FileResponse(Path("/app/docs")/filename)


def main():
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    gateway = Gateway()
    web.run_app(gateway.app, host="0.0.0.0", port=int(os.getenv("API_PORT", "8765")), access_log=None)


if __name__ == "__main__":
    main()
