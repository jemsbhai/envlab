import copy
from datetime import datetime, timezone
import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from water_monitor.contract import validate
from water_monitor.ha import messages
from water_monitor.settings import Settings
from water_monitor.simulator import packet
from water_monitor.storage import Store
from water_monitor.worker import process


class PipelineTests(unittest.TestCase):
    def setUp(self):
        self.directory = TemporaryDirectory()
        self.store = Store(str(Path(self.directory.name) / "history.sqlite3"))
        self.time = 1_800_000_000.0
        self.event = packet("pico-01", "boot-01", 0, self.time)

    def tearDown(self):
        self.store.close()
        self.directory.cleanup()

    def ingest(self, event, received=None):
        raw = json.dumps(event).encode()
        received = self.time if received is None else received
        normalized, observed = validate(raw, "env.v1.pico-01.telemetry", received)
        return self.store.ingest(normalized, observed, received, raw)

    def test_duplicate_delivery_does_not_bias_rolling_mean(self):
        self.event["readings"][0]["value"] = 10
        self.assertTrue(self.ingest(self.event))
        self.assertFalse(self.ingest(self.event))
        second = copy.deepcopy(self.event)
        second["seq"] = 1
        second["readings"][0]["value"] = 20
        self.ingest(second, self.time + 1)
        self.assertEqual(self.store.mean(self.store.current()[0], 60), (15, 2))

    def test_sensor_position_and_medium_are_preserved_in_raw_archive(self):
        self.event["position"] = {"latitude": 25.7617, "longitude": -80.1918}
        self.event["readings"][0]["medium"] = "water"
        self.ingest(self.event)
        saved = json.loads(self.store.db.execute("SELECT raw FROM events").fetchone()[0])
        self.assertEqual(saved["position"], self.event["position"])
        self.assertEqual(saved["readings"][0]["medium"], "water")

    def test_invalid_sensor_coordinates_and_medium_are_rejected(self):
        from jsonschema import ValidationError
        for position in ({"latitude": 91, "longitude": 0}, {"latitude": 0, "longitude": -181}):
            self.event["position"] = position
            with self.assertRaises(ValidationError):
                self.ingest(self.event)
        self.event["position"] = {"latitude": 0, "longitude": 0}
        self.event["readings"][0]["medium"] = "soil"
        with self.assertRaises(ValidationError):
            self.ingest(self.event)

    def test_old_event_is_archived_without_replacing_live_value(self):
        self.ingest(self.event)
        older = packet("pico-01", "boot-01", 1, self.time - 120)
        older["readings"][0]["value"] = 99
        self.ingest(older, self.time + 1)
        self.assertEqual(self.store.current()[0]["value"], self.event["readings"][0]["value"])
        self.assertEqual(self.store.mean(self.store.current()[0], 60)[1], 1)
        self.assertEqual(self.store.db.execute("SELECT COUNT(*) FROM events").fetchone()[0], 2)

    def test_unsynchronized_clock_uses_original_broker_time(self):
        self.event["measured_at"] = None
        self.ingest(self.event)
        row = self.store.current()[0]
        self.assertEqual(row["observed_at"], self.time)
        self.assertEqual(messages(row, 22, 1, self.time + 31), [])

    def test_replay_expiration_uses_remaining_freshness(self):
        self.ingest(self.event)
        output = messages(self.store.current()[0], 22, 1, self.time + 25, expiry=30)
        self.assertEqual(output[0][1]["expire_after"], 5)
        self.assertTrue(output[0][2])
        self.assertFalse(output[1][2])
        self.assertEqual(output[1][1]["source"], "simulated")
        self.assertRegex(output[0][1]["default_entity_id"], r"^sensor\.[a-z0-9_]+$")

    def test_temperature_normalization(self):
        self.event["readings"][0].update(value=77, unit="°F")
        self.ingest(self.event)
        self.assertEqual(self.store.current()[0]["unit"], "°C")
        self.assertAlmostEqual(self.store.current()[0]["value"], 25)

    def test_identity_conflict_rolls_back(self):
        self.ingest(self.event)
        self.event["readings"][0]["value"] = 100
        with self.assertRaisesRegex(ValueError, "identity reused"):
            self.ingest(self.event)
        self.assertEqual(self.store.db.execute("SELECT COUNT(*) FROM events").fetchone()[0], 1)

    def test_invalid_quality_is_archived_without_publishing(self):
        for reading in self.event["readings"]:
            reading["quality"] = "invalid"
        self.ingest(self.event)
        self.assertEqual(self.store.current(), [])
        self.assertEqual(self.store.db.execute("SELECT COUNT(*) FROM readings").fetchone()[0], len(self.event["readings"]))

    def test_unit_change_rolls_back_whole_packet(self):
        self.ingest(self.event)
        changed = copy.deepcopy(self.event)
        changed["seq"] = 1
        changed["readings"][0]["unit"] = "kelvin"
        with self.assertRaisesRegex(ValueError, "unit changed"):
            self.ingest(changed)
        self.assertEqual(self.store.db.execute("SELECT COUNT(*) FROM events").fetchone()[0], 1)

    def test_bad_topics_clocks_and_nonfinite_numbers_are_rejected(self):
        with self.assertRaisesRegex(ValueError, "does not match"):
            validate(json.dumps(self.event).encode(), "env.v1.someone-else.telemetry", self.time)
        future = packet("pico-01", "boot-01", 1, self.time + 120)
        with self.assertRaisesRegex(ValueError, "clock"):
            validate(json.dumps(future).encode(), "env.v1.pico-01.telemetry", self.time)
        self.event["readings"][0]["value"] = float("nan")
        with self.assertRaises(ValueError):
            validate(json.dumps(self.event).encode(), "env.v1.pico-01.telemetry", self.time)

    def test_archive_survives_reopen(self):
        self.ingest(self.event)
        self.store.close()
        self.store = Store(str(Path(self.directory.name) / "history.sqlite3"))
        self.assertFalse(self.ingest(self.event))
        self.assertEqual(len(self.store.current()), len(self.event["readings"]))

    def test_archive_has_bounded_event_count(self):
        for seq in range(3):
            event = packet("pico-01", "boot-01", seq, self.time + seq)
            self.ingest(event, self.time + seq)
        self.store.prune(self.time + 3, 90, max_events=2)
        self.assertEqual(self.store.db.execute("SELECT COUNT(*) FROM events").fetchone()[0], 2)
        self.assertEqual(self.store.db.execute("SELECT COUNT(*) FROM readings").fetchone()[0], 2 * len(self.event["readings"]))


class ProcessTests(unittest.IsolatedAsyncioTestCase):
    async def test_extreme_numeric_packet_is_quarantined_and_acknowledged(self):
        event = packet("pico-01", "boot-01", 0)
        event["readings"][0]["value"] = 1e308

        class Message:
            data = json.dumps(event).encode()
            subject = "env.v1.pico-01.telemetry"
            metadata = type("Metadata", (), {"timestamp": datetime.now(timezone.utc)})()
            acked = False

            async def ack(self):
                self.acked = True

        with TemporaryDirectory() as directory:
            store = Store(str(Path(directory) / "history.sqlite3"))
            try:
                msg = Message()
                self.assertEqual(await process(msg, store, None, Settings()), "rejected")
                self.assertTrue(msg.acked)
                self.assertEqual(store.db.execute("SELECT COUNT(*) FROM rejected").fetchone()[0], 1)
            finally:
                store.close()

    async def test_failed_output_leaves_event_unacked_and_retry_is_idempotent(self):
        class FakeMessage:
            data = json.dumps(packet("pico-01", "boot-01", 0)).encode()
            subject = "env.v1.pico-01.telemetry"
            acked = False
            metadata = type("Metadata", (), {"timestamp": datetime.now(timezone.utc)})()

            async def ack(self):
                self.acked = True

        class FakeClient:
            configs = {}
            failing = True
            published = []

            async def publish(self, topic, payload, retain=False):
                if self.failing:
                    raise TimeoutError("test outage")
                self.published.append((topic, payload, retain))

        with TemporaryDirectory() as directory:
            store = Store(str(Path(directory) / "history.sqlite3"))
            try:
                msg, client = FakeMessage(), FakeClient()
                with self.assertRaises(TimeoutError):
                    await process(msg, store, client, Settings())
                self.assertFalse(msg.acked)
                client.failing = False
                await process(msg, store, client, Settings())
                self.assertTrue(msg.acked)
                self.assertEqual(store.db.execute("SELECT COUNT(*) FROM events").fetchone()[0], 1)
                self.assertTrue(any(topic.endswith("/state") for topic, _, _ in client.published))
            finally:
                store.close()


if __name__ == "__main__":
    unittest.main()
