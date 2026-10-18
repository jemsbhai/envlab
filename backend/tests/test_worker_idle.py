"""Idle fetches must not consume NEX's finite worker restart allowance."""
import asyncio
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest
from unittest.mock import AsyncMock, patch

from nats.errors import TimeoutError as NatsTimeout
from water_monitor import spatial_worker


class WorkerIdleTests(unittest.IsolatedAsyncioTestCase):
    async def test_sensor_and_location_idle_timeouts_keep_processing_alive(self):
        real_sleep = asyncio.sleep
        for timeout in (TimeoutError, NatsTimeout):
            with self.subTest(timeout=timeout.__module__), TemporaryDirectory() as directory:
                callbacks, calls = [], {"sensor": 0, "location": 0}

                async def pause(seconds):
                    await real_sleep(.001)

                async def sensor_fetch(*args, **kwargs):
                    calls["sensor"] += 1
                    await real_sleep(.001)
                    if calls["sensor"] == 1:
                        raise timeout()
                    return []

                async def geo_fetch(*args, **kwargs):
                    calls["location"] += 1
                    if calls["location"] == 1:
                        raise timeout()
                    callbacks[0]()  # Stop after both idle paths recovered.
                    return []

                sensors = SimpleNamespace(fetch=sensor_fetch, _consumer="idle-test",
                    consumer_info=AsyncMock(return_value=SimpleNamespace(num_pending=0)))
                geos = SimpleNamespace(fetch=geo_fetch)
                js = SimpleNamespace(
                    pull_subscribe=AsyncMock(side_effect=[sensors, geos]),
                    stream_info=AsyncMock(return_value=SimpleNamespace(
                        state=SimpleNamespace(messages=0, first_seq=0, last_seq=0))),
                    delete_consumer=AsyncMock())
                nc = SimpleNamespace(is_connected=True, jetstream=lambda: js, close=AsyncMock())
                buckets = {"DEWIN_HEALTH": SimpleNamespace(put=AsyncMock())}
                loop = asyncio.get_running_loop()
                with patch.object(spatial_worker, "connect", AsyncMock(return_value=nc)), \
                     patch.object(spatial_worker, "ensure_resources", AsyncMock(return_value=buckets)), \
                     patch.object(loop, "add_signal_handler", side_effect=lambda sig, cb: callbacks.append(cb)), \
                     patch.object(spatial_worker.asyncio, "sleep", pause), \
                     patch.dict("os.environ", {"HEALTH_PATH": str(Path(directory)/"health.json")}):
                    await asyncio.wait_for(spatial_worker.run(), timeout=3)
                self.assertGreaterEqual(calls["sensor"], 2)
                self.assertEqual(calls["location"], 2)
                nc.close.assert_awaited_once()
