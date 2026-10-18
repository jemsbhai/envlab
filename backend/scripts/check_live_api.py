"""Check the real Dewin Socket.IO API, including JetStream-backed recovery.

Writes a few synthetic demo-user positions; it does not delete retained data.
Credentials come from backend/.env or existing environment variables. Never
prints credentials. Services restart only with the explicit --restarts flag.
"""
import argparse
import asyncio
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import re
import shlex
import sys
import time
import uuid

import aiohttp
from jsonschema import Draft202012Validator, FormatChecker
import socketio

ROOT = Path(__file__).resolve().parents[1]
SCHEMA = json.loads((ROOT / "docs/api-v1.schema.json").read_text(encoding="utf-8"))


def load_env(path):
    for line in path.read_text(encoding="utf-8").splitlines():
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            os.environ.setdefault(key.strip(), value.strip().strip("\"'"))


def validate(name, payload):
    Draft202012Validator({"$ref": "#/$defs/" + name, "$defs": SCHEMA["$defs"]},
                         format_checker=FormatChecker()).validate(payload)


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def timestamp(value=None):
    return (value or datetime.now(timezone.utc)).isoformat().replace("+00:00", "Z")


def position(**changes):
    return {"schemaVersion": 1, "eventId": str(uuid.uuid4()), "measuredAt": timestamp(),
            "latitude": 25.7617, "longitude": -80.1918, "accuracyM": 12.5, **changes}


class DemoClient:
    def __init__(self, url, token, transport):
        self.url, self.token, self.transport = url, token, transport
        self.socket = socketio.AsyncClient(reconnection=False, logger=False, engineio_logger=False)
        self.results = []
        self.changed = asyncio.Event()
        self.socket.on("exposure:update", self.on_result)

    async def on_result(self, data):
        self.results.append(data)
        self.changed.set()

    async def connect(self):
        await self.socket.connect(self.url, auth={"token": self.token},
                                  transports=[self.transport], wait_timeout=15)
        require(self.socket.transport() == self.transport, "Requested transport was not used")

    async def close(self):
        if self.socket.connected:
            await self.socket.disconnect()
        await self.socket.shutdown()

    async def call(self, event, payload):
        return await self.socket.call(event, payload, timeout=20)

    async def exposure(self, event_id, timeout=30):
        deadline = time.monotonic() + timeout
        while True:
            for result in self.results:
                if result.get("locationEventId") == event_id:
                    validate("Exposure", result)
                    return result
            self.changed.clear()
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise AssertionError("No live exposure received for accepted position")
            await asyncio.wait_for(self.changed.wait(), remaining)


async def health(url, timeout=90):
    deadline = time.monotonic() + timeout
    async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=10)) as session:
        while time.monotonic() < deadline:
            try:
                async with session.get(url.rstrip("/") + "/healthz") as response:
                    data = await response.json()
                    if response.status == 200 and data.get("ok") and data.get("mode") == "live":
                        require(data.get("nats") and data.get("processor"), "Live dependencies are unhealthy")
                        return
            except (aiohttp.ClientError, TimeoutError, ValueError):
                pass
            await asyncio.sleep(1)
    raise AssertionError("Real gateway and NEX processor did not become healthy")


async def rejected_auth(url, auth):
    client = socketio.AsyncClient(reconnection=False, logger=False, engineio_logger=False)
    try:
        try:
            await client.connect(url, auth=auth, transports=["websocket"], wait_timeout=15)
        except socketio.exceptions.ConnectionError:
            return
        raise AssertionError("Unauthorized Socket.IO connection was accepted")
    finally:
        if client.connected:
            await client.disconnect()
        await client.shutdown()


def require_error(result, code):
    validate("ErrorAck", result)
    require(not result["ok"] and result["error"]["code"] == code, "Expected " + code + " rejection")


def check_sensors(record, private):
    require(record["status"] == "matched", "Nearby simulated sensor data did not match")
    sensors = {entry["deviceId"]: entry for entry in record["sensors"]}
    require({"sim-pico-01", "sim-pico-02"} <= sensors.keys(), "Public simulated sensors missing")
    require(("sim-pico-03" in sensors) == private, "Private sensor authorization failed")
    for device in ("sim-pico-01", "sim-pico-02") + (("sim-pico-03",) if private else ()):
        sensor = sensors[device]
        require(sensor["visibility"] == ("private" if device == "sim-pico-03" else "public"),
                "Device registry visibility was not respected")
        require(sensor["source"] == "simulated", "Simulator provenance missing")
        require({"air", "water"} <= {m["medium"] for m in sensor["measurements"]},
                "Both air and water measurements were not joined")
        require(sensor["distanceM"] <= record["matchRadiusM"], "Out-of-range sensor was attached")
        observed = datetime.fromisoformat(sensor["observedAt"].replace("Z", "+00:00"))
        measured = datetime.fromisoformat(record["measuredAt"].replace("Z", "+00:00"))
        require(observed <= measured, "Future measurement attached to past position")


async def pages(client, query):
    items, cursor, seen = [], None, set()
    for _ in range(1000):
        page = await client.call("exposure:history", {**query, "cursor": cursor})
        validate("HistoryPage", page)
        require(page["ok"] and page["requestId"] == query["requestId"], "History ACK did not match request")
        require(len(page["items"]) <= query["limit"], "History ignored page limit")
        items.extend(page["items"])
        cursor = page["nextCursor"]
        if cursor is None:
            require(len({item["exposureId"] for item in items}) == len(items), "History duplicated an exposure")
            ordered = [(datetime.fromisoformat(item["measuredAt"].replace("Z", "+00:00")), item["exposureId"]) for item in items]
            require(ordered == sorted(ordered), "History ordering is unstable")
            return items
        require(cursor not in seen, "History cursor did not advance")
        seen.add(cursor)
    raise AssertionError("History pagination did not finish")


async def docker(args, operation, compose=True):
    command = ["docker"]
    if compose:
        command += ["compose"]
        if args.compose_project:
            command += ["--project-name", args.compose_project]
        command += ["-f", "compose.yaml", "-f", "deploy/websocket.compose.yaml"]
    command += operation
    if args.ssh:
        remote = "cd " + shlex.quote(args.remote_dir) + " && sudo -n " + shlex.join(command)
        command = ["ssh", "-o", "BatchMode=yes", args.ssh, remote]
    process = await asyncio.create_subprocess_exec(*command, cwd=ROOT,
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    stdout, stderr = await asyncio.wait_for(process.communicate(), 120)
    # Compose output is deliberately not printed: private configuration can occur
    # in diagnostics. A nonzero exit code is sufficient to identify this failure.
    require(process.returncode == 0, "Explicit Docker operation failed")
    return stdout.decode().strip()


async def process_identity(args):
    identifiers = (await docker(args, ["ps", "-q", "nex", "gateway"])).splitlines()
    require(len(identifiers) == 2, "Expected two running NEX/gateway containers")
    states = await docker(args, ["inspect", "--format", "{{.Id}} {{.State.Pid}} {{.State.StartedAt}} {{.RestartCount}}",
                                *identifiers], compose=False)
    return sorted(states.splitlines())


async def restart_services(args):
    services = ["nats"] if args.broker_only_restart else ["nats", "nex", "gateway"]
    await docker(args, ["restart", *services])


async def run(args):
    load_env(args.env_file)
    token, other_token = os.environ["API_DEMO_TOKEN"], os.environ["API_SECOND_TOKEN"]
    require(token != other_token and len(token) >= 16 and len(other_token) >= 16,
            "Two distinct private demo tokens are required")
    await health(args.url, args.ready_timeout)
    await rejected_auth(args.url, {"token": "invalid-live-api-token"})
    await rejected_auth(args.url, None)
    print("PASS real gateway health and anonymous/invalid-token rejection")
    alice = DemoClient(args.url, token, "websocket")
    bob = DemoClient(args.url, other_token, "polling")
    started = datetime.now(timezone.utc) - timedelta(seconds=2)
    baseline = None
    expected = set()
    try:
        await alice.connect()
        await bob.connect()
        print("PASS authenticated WebSocket and HTTP long-polling connections")
        # Wait for the simulator's first packet without treating its warm-up
        # no_match as a false failure; every accepted position is still persisted.
        deadline = time.monotonic() + args.ready_timeout
        while True:
            candidate = position()
            ack = await alice.call("location:update", candidate)
            validate("LocationAck", ack)
            require(ack["ok"] and not ack["duplicate"], "Fresh location was not accepted")
            record = await alice.exposure(candidate["eventId"])
            expected.add(candidate["eventId"])
            if {"sim-pico-01", "sim-pico-02", "sim-pico-03"} <= {s["deviceId"] for s in record["sensors"]}:
                baseline, original_ack = candidate, ack
                break
            require(time.monotonic() < deadline, "Simulator never produced all public/private fixtures")
            await asyncio.sleep(2)
        check_sensors(record, private=True)
        require(not bob.results, "Another user received a location's live result")
        duplicate = await alice.call("location:update", baseline)
        validate("LocationAck", duplicate)
        require(duplicate["duplicate"] and duplicate["receivedAt"] == original_ack["receivedAt"],
                "Identical retry did not preserve acceptance time")
        require_error(await alice.call("location:update", {**baseline, "latitude": 26}), "EVENT_ID_CONFLICT")
        require_error(await alice.call("location:update", {**baseline, "userId": "demo-other"}), "INVALID_PAYLOAD")
        require_error(await alice.call("location:update", {**baseline, "measuredAt": "bad-timestamp"}), "INVALID_PAYLOAD")
        await asyncio.sleep(.7)
        require(sum(x["locationEventId"] == baseline["eventId"] for x in alice.results) == 1,
                "Duplicate submission emitted another exposure")
        print("PASS persisted location ACK, immutable duplicate, conflict, and closed request validation")
        bob_ack = await bob.call("location:update", baseline)
        validate("LocationAck", bob_ack)
        require(not bob_ack["duplicate"], "Event identity was not scoped to authenticated user")
        bob_record = await bob.exposure(baseline["eventId"])
        check_sensors(bob_record, private=False)
        require(bob_record["exposureId"] != record["exposureId"], "Exposure identity leaked across users")
        await asyncio.sleep(.2)
        require(sum(x["locationEventId"] == baseline["eventId"] for x in alice.results) == 1,
                "Other user's result was emitted to owner socket")
        print("PASS public/private spatial matching, air/water values, and live user isolation")
        await asyncio.sleep(.7)
        far = position(latitude=0, longitude=0)
        far_ack = await alice.call("location:update", far)
        validate("LocationAck", far_ack)
        expected.add(far["eventId"])
        far_record = await alice.exposure(far["eventId"])
        require(far_record["status"] == "no_match" and far_record["sensors"] == [], "Far-away position matched")
        print("PASS persisted no_match for a position outside sensor radius")
        query = {"requestId": str(uuid.uuid4()), "from": timestamp(started),
                 "to": timestamp(datetime.now(timezone.utc) + timedelta(minutes=5)), "limit": 1}
        first = await alice.call("exposure:history", query)
        validate("HistoryPage", first)
        require(first["nextCursor"] is not None, "Two exposures did not paginate")
        cursor = first["nextCursor"]
        require_error(await bob.call("exposure:history", {**query, "cursor": cursor}), "INVALID_CURSOR")
        require_error(await alice.call("exposure:history", {**query, "limit": 2, "cursor": cursor}), "INVALID_CURSOR")
        require_error(await alice.call("exposure:history", {**query, "cursor": cursor + "tampered"}), "INVALID_CURSOR")
        owner_history = await pages(alice, query)
        require(expected <= {x["locationEventId"] for x in owner_history}, "Accepted positions missing from history")
        other_history = await pages(bob, {**query, "limit": 100})
        require(bob_record["exposureId"] in {x["exposureId"] for x in other_history}, "Other user's own history missing")
        require(record["exposureId"] not in {x["exposureId"] for x in other_history}, "History crossed user boundary")
        require(all(s["deviceId"] != "sim-pico-03" for x in other_history for s in x["sensors"]),
                "Private sensor leaked into another user's history")
        print("PASS scoped history, stable pagination, and stolen/changed/tampered cursor rejection")
        await alice.close()
        await alice.connect()
        recovered = await pages(alice, {**query, "limit": 100})
        require(expected <= {x["locationEventId"] for x in recovered}, "Reconnect lost retained results")
        retry = await alice.call("location:update", baseline)
        require(retry["duplicate"] and retry["receivedAt"] == original_ack["receivedAt"], "Reconnect lost receipt identity")
        print("PASS reconnect history recovery and persistent deduplication")
        if args.restarts:
            if not args.broker_only_restart:
                await alice.close()
                await bob.close()
            before = await process_identity(args) if args.broker_only_restart else None
            await restart_services(args)
            await health(args.url, args.ready_timeout)
            if before is not None:
                require(await process_identity(args) == before, "Broker-only restart changed NEX/gateway process identity")
                require(alice.socket.connected and bob.socket.connected, "Broker-only restart dropped app sockets")
            else:
                await alice.connect()
            restarted = await pages(alice, {**query, "limit": 100})
            require(expected <= {x["locationEventId"] for x in restarted}, "Restart lost retained exposure history")
            retry = await alice.call("location:update", baseline)
            require(retry["duplicate"] and retry["receivedAt"] == original_ack["receivedAt"], "Restart lost original receipt")
            after_restart = position()
            ack = await alice.call("location:update", after_restart)
            validate("LocationAck", ack)
            check_sensors(await alice.exposure(after_restart["eventId"]), private=True)
            label = "broker-only restart with unchanged NEX/gateway processes" if args.broker_only_restart else "NATS/NEX/gateway restart"
            print("PASS explicit " + label + ": retained history, receipt identity, and new live enrichment")
        print("PASS real Socket.IO gateway checks; synthetic test records remain subject to normal retention")
    finally:
        await alice.close()
        await bob.close()


if __name__ == "__main__":
    sys.stdout.reconfigure(line_buffering=True)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="http://127.0.0.1:8765")
    parser.add_argument("--env-file", type=Path, default=ROOT / ".env")
    parser.add_argument("--ready-timeout", type=float, default=90)
    parser.add_argument("--restarts", action="store_true", help="Explicitly restart NATS, NEX, and gateway to check durability")
    parser.add_argument("--broker-only-restart", action="store_true", help="With --restarts, restart only NATS and prove NEX/gateway processes stayed up")
    parser.add_argument("--ssh", help="SSH profile for explicitly requested restart checks")
    parser.add_argument("--remote-dir", default="/home/hacker9/team-zero-water-monitor")
    parser.add_argument("--compose-project", help="Local Compose project to restart (required for local --restarts)")
    args = parser.parse_args()
    if args.restarts and not (args.ssh or args.compose_project):
        parser.error("--restarts requires --ssh or --compose-project")
    if args.broker_only_restart and not args.restarts:
        parser.error("--broker-only-restart requires --restarts")
    if not args.restarts and (args.ssh or args.compose_project):
        parser.error("--ssh and --compose-project require explicit --restarts")
    if args.compose_project and not re.fullmatch(r"[a-z0-9][a-z0-9_-]*", args.compose_project):
        parser.error("Invalid Compose project name")
    try:
        asyncio.run(run(args))
    except Exception as exc:
        # Avoid dumping library exceptions/payloads that could include auth data.
        message = str(exc) if isinstance(exc, AssertionError) else type(exc).__name__
        print("FAIL " + message, file=sys.stderr)
        sys.exit(1)
