"""Host smoke checks with explicit synthetic MicroPython/hardware stubs."""
import binascii
import importlib.util
import json
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from jsonschema import Draft202012Validator

ROOT = Path(__file__).resolve().parents[1]
SCHEMA = json.loads((ROOT.parents[1] / "backend/water_monitor/telemetry.schema.json").read_text(encoding="utf-8"))


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / "src" / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FakeClient:
    fail_connect = False
    fail_publish = False
    attempts = []

    def __init__(self, **settings):
        self.settings = settings
        self.sock = SimpleNamespace(settimeout=lambda seconds: None, close=lambda: None)

    def connect(self):
        if self.fail_connect:
            raise OSError("synthetic connection failure")

    def disconnect(self):
        pass

    def publish(self, topic, payload, **options):
        self.attempts.append((topic, payload, options))
        if self.fail_publish:
            raise OSError("synthetic lost PUBACK")


class MQTTContractTests(unittest.TestCase):
    def setUp(self):
        FakeClient.fail_connect = FakeClient.fail_publish = False
        FakeClient.attempts = []
        self.clock = 100
        self.config = SimpleNamespace()
        wlan = SimpleNamespace(active=lambda value: None, config=lambda key: bytes.fromhex("aabbccddeeff"))
        adc = SimpleNamespace(read_u16=lambda: 1000)
        self.modules = {
            "mqtt": self.config,
            "network": SimpleNamespace(STA_IF=0, WLAN=lambda mode: wlan),
            "machine": SimpleNamespace(unique_id=lambda: b"synthetic-id", ADC=lambda pin: adc),
            "ubinascii": binascii,
            "umqtt": SimpleNamespace(),
            "umqtt.simple": SimpleNamespace(MQTTClient=FakeClient),
            "time": SimpleNamespace(time=lambda: self.clock, ticks_ms=lambda: self.clock * 1000,
                                    sleep=lambda seconds: None, sleep_ms=lambda milliseconds: None),
        }
        self.module_patch = patch.dict(sys.modules, self.modules)
        self.module_patch.start()
        self.addCleanup(self.module_patch.stop)
        self.mqtt = load("firmware_mqtt", "mqtt_client.py")

    def reading(self):
        return {"tds_ppm": 123.4, "temperature": 25.0, "voltage": .75, "raw_adc": 1000}

    def test_default_demo_topic_envelope_matches_backend_schema(self):
        manager = self.mqtt.MQTTManager()
        self.assertTrue(manager.connect())
        self.assertTrue(manager.publish_tds_reading(self.reading()))
        topic, payload, options = FakeClient.attempts[-1]
        self.assertEqual(topic, b"env/v1/pico-water-01/telemetry")
        self.assertEqual(options, {"qos": 1, "retain": False})
        packet = json.loads(payload)
        Draft202012Validator(SCHEMA).validate(packet)
        self.assertEqual(packet["position"], {"latitude": 25.7617, "longitude": -80.1918})
        self.assertEqual(packet["source"], "sensor")
        self.assertIsNone(packet["measured_at"])
        self.assertEqual(packet["readings"], [{"sensor_id": "tds-1", "medium": "water", "metric": "tds",
                                              "value": 123.4, "unit": "ppm", "quality": "uncalibrated"}])
        self.assertEqual(manager.client.settings["server"], "10.104.0.82")
        self.assertIsNone(manager.client.settings["user"])
        self.assertIsNone(manager.client.settings["password"])
        self.assertEqual(len(FakeClient.attempts), 1)  # No status, HA or LWT publication.

    def test_optional_existing_credentials_remain_supported(self):
        self.config.MQTT_USER = "sensor"
        self.config.MQTT_PASSWORD = "synthetic-test-password"
        manager = self.mqtt.MQTTManager()
        self.assertTrue(manager.connect())
        self.assertEqual(manager.client.settings["user"], b"sensor")
        self.assertEqual(manager.client.settings["password"], b"synthetic-test-password")

    def test_missing_mqtt_config_uses_anonymous_demo_defaults(self):
        with patch.dict(sys.modules, {"mqtt": None}):
            module = load("firmware_mqtt_defaults", "mqtt_client.py")
        manager = module.MQTTManager()
        self.assertEqual(manager.device_id, "pico-water-01")
        self.assertTrue(manager.connect())
        self.assertIsNone(manager.client.settings["user"])
        self.assertIsNone(manager.client.settings["password"])

    def test_lost_puback_reuses_identical_packet_after_reconnect(self):
        manager = self.mqtt.MQTTManager()
        manager.connect()
        FakeClient.fail_publish = True
        self.assertFalse(manager.publish_tds_reading(self.reading()))
        original = FakeClient.attempts[-1][1]
        self.assertEqual(manager.seq, 0)
        self.clock += 6
        FakeClient.fail_publish = False
        self.assertTrue(manager.check_connection())
        self.assertTrue(manager.publish_tds_reading({"tds_ppm": 999}))
        self.assertEqual(FakeClient.attempts[-1][1], original)
        self.assertEqual(manager.seq, 1)
        self.assertTrue(manager.publish_tds_reading({"tds_ppm": 200}))
        self.assertEqual(json.loads(FakeClient.attempts[-1][1])["seq"], 1)

    def test_device_override_mac_identity_and_unique_boot(self):
        self.config.MQTT_DEVICE_ID = None
        first, second = self.mqtt.MQTTManager(), self.mqtt.MQTTManager()
        self.assertEqual(first.device_id, "picotds_ddeeff")
        self.assertEqual(first.device_id, second.device_id)
        self.assertNotEqual(first.boot_id, second.boot_id)
        self.config.MQTT_DEVICE_ID = "second-water-board"
        self.assertEqual(self.mqtt.MQTTManager().device_id, "second-water-board")

    def test_invalid_config_and_nonfinite_reading_cannot_publish(self):
        self.config.MQTT_LATITUDE = None
        with self.assertRaises(ValueError):
            self.mqtt.MQTTManager()
        self.config.MQTT_LATITUDE = 25.7617
        manager = self.mqtt.MQTTManager()
        manager.connect()
        self.assertFalse(manager.publish_tds_reading({"tds_ppm": float("nan")}))
        self.assertFalse(manager.publish_tds_reading({"tds_ppm": float("inf")}))
        self.assertEqual(FakeClient.attempts, [])

    def test_temperature_requires_successful_physical_read(self):
        manager = self.mqtt.MQTTManager()
        plain = manager._packet(self.reading())
        self.assertEqual(len(plain["readings"]), 1)
        measured = manager._packet({**self.reading(), "temperature_measured": True})
        self.assertEqual(measured["readings"][1]["metric"], "temperature")
        self.assertEqual(measured["readings"][1]["value"], 25.0)

    def test_driver_missing_temperature_is_unknown_not_25(self):
        driver = load("firmware_driver", "tds_sensor.py").TDSSensor()
        reading = driver.read_tds()
        self.assertIsNone(reading["temperature"])
        self.assertFalse(reading["temperature_measured"])
        self.assertGreaterEqual(reading["tds_ppm"], 0)
        driver.temp_sensor = SimpleNamespace(scan=lambda: [b"sensor"], convert_temp=lambda: None,
                                             read_temp=lambda device: 23.5)
        self.assertEqual(driver.read_temperature(), 23.5)
        self.assertTrue(driver.temperature_measured)
        driver.temp_sensor.read_temp = lambda device: -127
        self.assertIsNone(driver.read_temperature())
        self.assertFalse(driver.temperature_measured)

    def test_main_keeps_manager_and_recovers_initial_broker_failure(self):
        FakeClient.fail_connect = True
        wifi = SimpleNamespace(connect=lambda: True, is_connected=lambda: True,
                               check_connection=lambda: None)
        sensor = SimpleNamespace(read_tds=self.reading)
        with patch.dict(sys.modules, {
            "wifi_connect": SimpleNamespace(WiFiManager=lambda: wifi),
            "tds_sensor": SimpleNamespace(TDSSensor=lambda: sensor),
            "mqtt_client": self.mqtt,
            "web_server": SimpleNamespace(WebServer=lambda: None),
            "web": SimpleNamespace(WEB_SERVER_ENABLED=False),
        }):
            app = load("firmware_main", "main.py").PicoTDS()
            self.assertTrue(app.initialize())
            self.assertIsNotNone(app.mqtt)
            self.assertFalse(app.mqtt.connected)
            FakeClient.fail_connect = False
            self.clock += 6
            app.read_and_display()
            self.assertTrue(app.mqtt.connected)
            self.assertEqual(len(FakeClient.attempts), 1)


if __name__ == "__main__":
    unittest.main()
