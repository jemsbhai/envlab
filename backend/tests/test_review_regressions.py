"""Regression checks for the mock and retired HA worker review findings."""
import asyncio
from datetime import datetime, timedelta, timezone
from threading import Event
from types import SimpleNamespace
import unittest
from unittest.mock import AsyncMock, Mock, patch
import uuid

from aiohttp import web
import socketio

from scripts import check_mock_api, mock_api
from water_monitor import worker
from water_monitor.settings import Settings


class MockReviewTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        # Short polling heartbeat keeps real transport cleanup fast in tests.
        server_type = socketio.AsyncServer
        with patch.object(mock_api.socketio, "AsyncServer", side_effect=lambda **kwargs:
                          server_type(ping_interval=.25, ping_timeout=1, **kwargs)):
            self.runner = web.AppRunner(mock_api.create_app())
        await self.runner.setup()
        await web.TCPSite(self.runner, "127.0.0.1", 0).start()
        self.url = f"http://127.0.0.1:{self.runner.addresses[0][1]}"
        self.client = socketio.AsyncClient(reconnection=False)
        await self.client.connect(self.url, auth={"token": "dev-only-alice-token"}, transports=["websocket"])

    async def asyncTearDown(self):
        await self.client.disconnect()
        await self.client.shutdown()
        await self.runner.cleanup()

    def position(self, **changes):
        return {"schemaVersion": 1, "eventId": str(uuid.uuid4()),
                "measuredAt": datetime.now(timezone.utc).isoformat(),
                "latitude": 25.7617, "longitude": -80.1918, **changes}

    def query(self, **changes):
        now = datetime.now(timezone.utc)
        return {"requestId": str(uuid.uuid4()), "from": (now-timedelta(days=1)).isoformat(),
                "to": (now+timedelta(minutes=1)).isoformat(), "limit": 1, **changes}

    async def test_malformed_ids_receive_error_acks(self):
        for event, payload in (("location:update", self.position(eventId="not-a-uuid")),
                               ("exposure:history", self.query(requestId="not-a-uuid"))):
            result = await self.client.call(event, payload, timeout=2)
            self.assertFalse(result["ok"])
            self.assertEqual(result["error"]["code"], "INVALID_PAYLOAD")

    async def test_integer_valued_float_limit_paginates_and_fraction_is_rejected(self):
        for _ in range(2):
            self.assertTrue((await self.client.call("location:update", self.position(), timeout=2))["ok"])
        query = self.query(limit=1.0)
        first = await self.client.call("exposure:history", query, timeout=2)
        self.assertTrue(first["ok"])
        self.assertEqual(len(first["items"]), 1)
        self.assertIsNotNone(first["nextCursor"])
        second = await self.client.call("exposure:history", {**query, "cursor": first["nextCursor"]}, timeout=2)
        self.assertEqual(len(second["items"]), 1)
        self.assertIsNone(second["nextCursor"])
        self.assertNotEqual(first["items"][0]["exposureId"], second["items"][0]["exposureId"])
        invalid = await self.client.call("exposure:history", self.query(limit=1.5), timeout=2)
        self.assertEqual(invalid["error"]["code"], "INVALID_PAYLOAD")

    async def test_checker_repeats_with_older_records_in_same_mock(self):
        old = self.position(measuredAt=(datetime.now(timezone.utc)-timedelta(minutes=1)).isoformat())
        self.assertTrue((await self.client.call("location:update", old, timeout=2))["ok"])
        await asyncio.sleep(1.1)
        await check_mock_api.run(self.url)
        await asyncio.sleep(1.1)
        await check_mock_api.run(self.url)


class LegacyRefreshReviewTests(unittest.IsolatedAsyncioTestCase):
    async def test_transient_refresh_failure_retries_without_exiting_worker(self):
        for failing_output in ("availability", "reading"):
            with self.subTest(failing_output=failing_output):
                stop = asyncio.Event()
                client = SimpleNamespace(refresh=Event(), connected=Event(), configs={},
                                         start=AsyncMock(), stop=AsyncMock(), publish=AsyncMock())
                client.refresh.set()
                client.connected.set()
                if failing_output == "availability":
                    client.publish.side_effect = [TimeoutError("simulated outage"), None, None]
                refresh = AsyncMock(side_effect=[TimeoutError("simulated outage"), None]
                                    if failing_output == "reading" else None)

                async def reached_ingestion(**kwargs):
                    stop.set()
                    return []

                subscription = SimpleNamespace(fetch=AsyncMock(side_effect=reached_ingestion))
                js = SimpleNamespace(pull_subscribe=AsyncMock(return_value=subscription))
                nc = SimpleNamespace(jetstream=lambda: js, is_connected=True, close=AsyncMock())
                store, health = Mock(), Mock()
                with patch.object(worker, "connect_nats", AsyncMock(return_value=nc)), \
                        patch.object(worker, "ensure_stream", AsyncMock()), \
                        patch.object(worker, "MqttClient", return_value=client), \
                        patch.object(worker, "Store", return_value=store), \
                        patch.object(worker, "publish_current", refresh), \
                        patch.object(worker, "write_health", health):
                    await asyncio.wait_for(worker.run(Settings(), stop), timeout=6)
                self.assertEqual(subscription.fetch.await_count, 1)
                self.assertFalse(client.refresh.is_set(), "Refresh was never successfully retried")
                self.assertEqual(sum(call.args[1] == "online" for call in client.publish.call_args_list), 2)
                self.assertEqual(refresh.await_count, 2 if failing_output == "reading" else 1)
                self.assertTrue(any(call.kwargs.get("ready") is False for call in health.call_args_list))


if __name__ == "__main__":
    unittest.main()
