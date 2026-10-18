from copy import deepcopy
from types import SimpleNamespace
import unittest

from water_monitor.api_protocol import Cursors
from water_monitor.contract import iso, validate
from water_monitor.dewin_bus import encode
from water_monitor.simulator import packet
from water_monitor.spatial import SensorIndex, authorized_result
from water_monitor.spatial_worker import raw_watermark


class SpatialTests(unittest.TestCase):
    def setUp(self):
        self.index = SensorIndex()
        self.t = 1800000000
        self.devices = {"sim-pico-01": {"visibility": "public"},
                        "sim-pico-02": {"visibility": "private", "ownerUserId": "alice"}}
        self.location = {"userId": "alice", "receivedAt": iso(self.t+.1), "location": {
            "schemaVersion": 1, "eventId": "d4d01f91-5619-4693-97c5-ff9025daa1d4",
            "measuredAt": iso(self.t), "latitude": 25.7617, "longitude": -80.1918}}

    def add(self, device, at, seq, value=20, quality="ok"):
        event = packet(device, "boot", seq, at)
        event["readings"][0].update(value=value, quality=quality)
        event, observed = validate(encode(event), f"env.v1.{device}.telemetry", at+.1)
        self.index.add(event, observed, at+.1, seq+1)
        return event

    def test_event_time_future_readings_never_attach_and_mean_deduplicates(self):
        event = self.add("sim-pico-01", self.t-20, 0, 10)
        self.index.add(event, self.t-20, self.t-19.9, 99)
        self.add("sim-pico-01", self.t-10, 1, 20)
        self.add("sim-pico-01", self.t+1, 2, 100)
        result = self.index.match(self.location, self.devices)
        value = result["sensors"][0]["measurements"][0]
        self.assertEqual(value["value"], 20)
        self.assertEqual(value["rollingMean"], 15)
        self.assertEqual(value["sampleCount"], 2)

    def test_public_private_and_unregistered_devices(self):
        for i, device in enumerate(["sim-pico-01", "sim-pico-02", "sim-pico-99"]):
            self.add(device, self.t-5, i)
        own = self.index.match(self.location, self.devices)
        self.assertEqual({s["deviceId"] for s in own["sensors"]}, {"sim-pico-01", "sim-pico-02"})
        other = self.index.match({**self.location, "userId": "bob"}, self.devices)
        self.assertEqual([s["deviceId"] for s in other["sensors"]], ["sim-pico-01"])
        self.assertNotEqual(own["exposureId"], other["exposureId"])

    def test_stale_and_far_locations_are_no_match(self):
        self.add("sim-pico-01", self.t-301, 0)
        self.assertEqual(self.index.match(self.location, self.devices)["status"], "no_match")
        self.add("sim-pico-01", self.t-3, 1)
        far = deepcopy(self.location)
        far["location"].update(latitude=0, longitude=0)
        self.assertEqual(self.index.match(far, self.devices)["sensors"], [])

    def test_invalid_reading_not_included_and_current_authorization_applies_to_history(self):
        self.add("sim-pico-02", self.t-3, 0, quality="invalid")
        result = self.index.match(self.location, self.devices)
        self.assertEqual(len(result["sensors"][0]["measurements"]), 1)
        self.assertEqual(result["sensors"][0]["measurements"][0]["medium"], "air")
        self.devices["sim-pico-02"]["ownerUserId"] = "bob"
        self.assertEqual(authorized_result(result, "alice", self.devices)["sensors"], [])

    def test_cursor_is_user_and_query_scoped(self):
        cursor = Cursors("x"*48)
        query = ["alice", "from", "to", 100]
        token = cursor.encode({"query": query, "expires": 9999999999, "snapshot": 4, "last": None})
        self.assertEqual(cursor.decode(token, query)["snapshot"], 4)
        with self.assertRaises(ValueError):
            cursor.decode(token, ["bob", "from", "to", 100])
        with self.assertRaises(ValueError):
            cursor.decode(token[:-1]+("a" if token[-1]!="a" else "b"), query)

    def test_retention_tracks_raw_sequence_instead_of_device_time(self):
        self.add("sim-pico-01", self.t-5, 0)
        self.add("sim-pico-02", self.t-10, 1)
        self.index.retain_from(2)
        self.assertEqual(set(self.index.points), {"sim-pico-02"})
        self.assertEqual(len(self.index.identities), 1)
        self.index.retain_from(3)
        self.assertEqual(self.index.match(self.location, self.devices)["status"], "no_match")
        self.assertEqual(dict(self.index.points), {})

    def test_expired_raw_stream_can_cross_historical_sequence_gap(self):
        self.assertEqual(raw_watermark(SimpleNamespace(messages=0, last_seq=40), 0), 40)
        self.assertEqual(raw_watermark(SimpleNamespace(messages=1, last_seq=41), 40), 40)

    def test_history_uses_current_visibility_for_authorized_owner(self):
        self.add("sim-pico-01", self.t-3, 0)
        result = self.index.match(self.location, self.devices)
        self.devices["sim-pico-01"] = {"visibility": "private", "ownerUserId": "alice"}
        private = authorized_result(result, "alice", self.devices)
        self.assertEqual(private["sensors"][0]["visibility"], "private")
        self.assertEqual(result["sensors"][0]["visibility"], "public")
        self.assertEqual(authorized_result(result, "bob", self.devices)["sensors"], [])


if __name__ == "__main__":
    unittest.main()
