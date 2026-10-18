"""Exercise Socket.IO API contract, ACKs, history, and isolation on the local mock."""
import argparse
import asyncio
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import uuid

from jsonschema import Draft202012Validator, FormatChecker
import socketio

ROOT = Path(__file__).resolve().parents[1]
SCHEMA = json.loads((ROOT / "docs/api-v1.schema.json").read_text(encoding="utf-8"))


def validate(name, payload):
    Draft202012Validator({"$ref": "#/$defs/" + name, "$defs": SCHEMA["$defs"]},
                         format_checker=FormatChecker()).validate(payload)


async def run(url):
    alice = socketio.AsyncClient(reconnection=False)
    bob = socketio.AsyncClient(reconnection=False)
    bad = socketio.AsyncClient(reconnection=False)
    alice_results, bob_results = [], []

    @alice.on("exposure:update")
    async def alice_result(data):
        validate("Exposure", data); alice_results.append(data)

    @bob.on("exposure:update")
    async def bob_result(data):
        validate("Exposure", data); bob_results.append(data)

    try:
        try:
            await bad.connect(url, auth={"token": "incorrect-demo-token"}, transports=["websocket"])
        except socketio.exceptions.ConnectionError:
            pass
        else:
            raise AssertionError("Invalid auth connected")
        await alice.connect(url, auth={"token": "dev-only-alice-token"}, transports=["websocket"])
        await bob.connect(url, auth={"token": "dev-only-bob-token"}, transports=["polling"])
        now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
        position = {"schemaVersion": 1, "eventId": str(uuid.uuid4()), "measuredAt": now,
                    "latitude": 25.7617, "longitude": -80.1918, "accuracyM": 12.5}
        ack = await alice.call("location:update", position, timeout=5)
        validate("LocationAck", ack); assert ack["ok"] and not ack["duplicate"]
        duplicate = await alice.call("location:update", position, timeout=5)
        assert duplicate["duplicate"] and duplicate["receivedAt"] == ack["receivedAt"]
        conflict = await alice.call("location:update", {**position, "latitude": 26}, timeout=5)
        validate("ErrorAck", conflict); assert conflict["error"]["code"] == "EVENT_ID_CONFLICT"
        invalid = await alice.call("location:update", {**position, "userId": "bob"}, timeout=5)
        assert invalid["error"]["code"] == "INVALID_PAYLOAD"
        await asyncio.sleep(.1)
        assert len(alice_results) == 1 and not bob_results
        assert {x["visibility"] for x in alice_results[0]["sensors"]} == {"public", "private"}
        assert {m["medium"] for x in alice_results[0]["sensors"] for m in x["measurements"]} == {"air", "water"}
        await bob.call("location:update", position, timeout=5)
        await asyncio.sleep(.1)
        assert len(bob_results) == 1 and len(alice_results) == 1
        assert all(x["visibility"] == "public" for x in bob_results[0]["sensors"])
        far = {**position, "eventId": str(uuid.uuid4()), "latitude": 0, "longitude": 0}
        await alice.call("location:update", far, timeout=5)
        await asyncio.sleep(.1)
        assert alice_results[-1]["status"] == "no_match" and not alice_results[-1]["sensors"]
        when = datetime.fromisoformat(now.replace("Z", "+00:00"))
        # Both positions deliberately use the same source timestamp. Query only
        # that microsecond so earlier runs or interactive app use cannot pollute
        # the checker assertions against a long-running shared mock.
        query = {"requestId": str(uuid.uuid4()), "from": when.isoformat(),
                 "to": (when+timedelta(microseconds=1)).isoformat(), "limit": 1, "cursor": None}
        first = await alice.call("exposure:history", query, timeout=5)
        validate("HistoryPage", first); assert first["ok"] and first["nextCursor"] and len(first["items"]) == 1
        second = await alice.call("exposure:history", {**query, "cursor": first["nextCursor"]}, timeout=5)
        validate("HistoryPage", second); assert len(second["items"]) == 1 and second["nextCursor"] is None
        assert first["items"][0]["exposureId"] != second["items"][0]["exposureId"]
        stolen = await bob.call("exposure:history", {**query, "cursor": first["nextCursor"]}, timeout=5)
        assert stolen["error"]["code"] == "INVALID_CURSOR"
        own = await bob.call("exposure:history", {**query, "limit": 100}, timeout=5)
        assert len(own["items"]) == 1
        await alice.disconnect()
        await alice.connect(url, auth={"token": "dev-only-alice-token"}, transports=["websocket"])
        recovered = await alice.call("exposure:history", {**query, "limit": 100}, timeout=5)
        assert len(recovered["items"]) == 2
        print("PASS: auth, WebSocket/polling, schema-valid live events, ACK/dedupe/conflict, no-match,")
        print("      private/public isolation, history pagination, cursor isolation, and reconnect recovery.")
        print("Scope: in-memory local mock, not production/JetStream or an actual iOS build.")
    finally:
        for client in (alice, bob, bad):
            if client.connected:
                await client.disconnect()
            else:
                await client.shutdown()


async def main(args):
    if not args.self_contained:
        await run(args.url)
        return
    from aiohttp import web
    from mock_api import create_app
    runner = web.AppRunner(create_app())
    await runner.setup()
    try:
        site = web.TCPSite(runner, "127.0.0.1", 0)
        await site.start()
        await run(f"http://127.0.0.1:{runner.addresses[0][1]}")
    finally:
        await runner.cleanup()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="http://127.0.0.1:8765")
    parser.add_argument("--self-contained", action="store_true", help="Start an ephemeral loopback mock for this check")
    asyncio.run(main(parser.parse_args()))
