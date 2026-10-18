"""Dewin MQTT 3.1.1 telemetry; one QoS-1, non-retained envelope per sample."""

import json
import os
import time
import machine
import ubinascii
import network

# umqtt.simple is imported lazily in connect() -- NOT at module load. A stock MicroPython flash
# doesn't ship umqtt, so a module-level import here would raise on import of this module, which
# main.py imports unconditionally -- taking down WiFi and the web server too. Lazy import means a
# missing library only disables MQTT.

try:
    import mqtt as mqtt_config
except ImportError:
    class mqtt_config:
        pass  # Anonymous one-board demo defaults; mqtt.py is optional.


def valid_id(value):
    allowed = "abcdefghijklmnopqrstuvwxyz0123456789_-"
    return (isinstance(value, str) and 1 <= len(value) <= 48
            and value[0] in allowed[:36] and all(c in allowed for c in value))


def finite_number(value, low=-1000000000000, high=1000000000000):
    return not isinstance(value, bool) and isinstance(value, (int, float)) and low <= value <= high


class MQTTManager:
    def __init__(self):
        self.client = None
        self.connected = False
        self.last_publish_time = None
        self.last_connect_time = None
        self.device_id = self._get_device_id()
        # One-board demo fixture, also used by the phone's demo mode. These are
        # configured demo coordinates, not GPS measured by the Pico.
        self.location_id = getattr(mqtt_config, "MQTT_LOCATION_ID", "demo-venue")
        self.latitude = getattr(mqtt_config, "MQTT_LATITUDE", 25.7617)
        self.longitude = getattr(mqtt_config, "MQTT_LONGITUDE", -80.1918)
        if not valid_id(self.location_id):
            raise ValueError("Set MQTT_LOCATION_ID in mqtt.py (lowercase ID, max 48 characters)")
        if not finite_number(self.latitude, -90, 90) or not finite_number(self.longitude, -180, 180):
            raise ValueError("Set MQTT_LATITUDE and MQTT_LONGITUDE to this sensor's actual deployment coordinates")
        self.topic = "env/v1/" + self.device_id + "/telemetry"
        self.boot_id = ubinascii.hexlify(os.urandom(8)).decode()
        self.seq = 0
        self.pending_payload = None
        print("Dewin device:", self.device_id, "topic:", self.topic)
        print("Sensor deployment:", self.location_id, self.latitude, self.longitude)

    def _get_device_id(self):
        override = getattr(mqtt_config, "MQTT_DEVICE_ID", "pico-water-01")
        if override:
            device_id = override
        else:
            try:
                wlan = network.WLAN(network.STA_IF)
                wlan.active(True)
                suffix = ubinascii.hexlify(wlan.config("mac")).decode()[-6:]
            except Exception:
                suffix = ubinascii.hexlify(machine.unique_id()).decode()[-6:]
            device_id = "picotds_" + suffix
        if not valid_id(device_id):
            raise ValueError("MQTT_DEVICE_ID must be a lowercase ID, max 48 characters")
        return device_id

    def connect(self):
        self.last_connect_time = time.time()
        self.disconnect()
        # Import the MQTT library lazily so a missing umqtt only disables MQTT instead of
        # crashing the whole application at import time.
        try:
            from umqtt.simple import MQTTClient
        except ImportError:
            print("MQTT disabled: umqtt not installed (mip.install('umqtt.simple'))")
            return False
        try:
            user = getattr(mqtt_config, "MQTT_USER", "")
            password = getattr(mqtt_config, "MQTT_PASSWORD", "")
            self.client = MQTTClient(
                client_id=self.device_id.encode(),
                server=getattr(mqtt_config, "MQTT_BROKER", "10.104.0.82"),
                port=getattr(mqtt_config, "MQTT_PORT", 1883),
                user=user.encode() if user else None,
                password=password.encode() if user and password else None,
                keepalive=getattr(mqtt_config, "MQTT_KEEPALIVE", 60),
            )
            # No status/LWT, subscriptions, HA discovery or broker scanning: the
            # sensor account is authorized only for env/v1/*/telemetry.
            self.client.connect()
            if getattr(self.client, "sock", None):
                self.client.sock.settimeout(10)
            self.connected = True
            print("MQTT connected:", self.device_id)
            return True
        except Exception as error:
            print("MQTT connect failed:", type(error).__name__)
            self.disconnect()
            return False

    def disconnect(self):
        self.connected = False
        if self.client:
            try:
                self.client.disconnect()
            except Exception:
                try:
                    self.client.sock.close()
                except Exception:
                    pass
            self.client = None

    def is_connected(self):
        return self.connected

    def check_connection(self):
        if self.connected:
            return True
        delay = getattr(mqtt_config, "MQTT_RECONNECT_DELAY", 5)
        if self.last_connect_time is None or time.time() - self.last_connect_time >= delay:
            return self.connect()
        return False

    def should_publish(self):
        interval = max(1, getattr(mqtt_config, "MQTT_PUBLISH_INTERVAL", 5))
        now = time.time()
        if self.last_publish_time is None or now - self.last_publish_time >= interval:
            self.last_publish_time = now
            return True
        return False

    def _timestamp(self):
        # Unsynchronized MicroPython clocks must not be mistaken for UTC. The
        # broker's original reception timestamp supplies event time when null.
        if not getattr(mqtt_config, "MQTT_CLOCK_SYNCED", False):
            return None
        t = time.gmtime()
        if t[0] < 2026:
            return None
        return "%04d-%02d-%02dT%02d:%02d:%02dZ" % t[:6]

    def _packet(self, reading):
        tds = reading.get("tds_ppm")
        if not finite_number(tds, 0):
            raise ValueError("TDS must be a finite nonnegative number")
        readings = [{"sensor_id": "tds-1", "medium": "water", "metric": "tds",
                     "value": tds, "unit": "ppm",
                     "quality": "ok" if getattr(mqtt_config, "MQTT_TDS_CALIBRATED", False) else "uncalibrated"}]
        # An old driver's default 25 C must never become a physical measurement.
        temperature = reading.get("temperature")
        if reading.get("temperature_measured") is True and finite_number(temperature, -55, 125):
            readings.append({"sensor_id": "temperature-1", "medium": "water", "metric": "temperature",
                             "value": temperature, "unit": "°C", "quality": "ok"})
        return {"schema_version": 1, "device_id": self.device_id, "location_id": self.location_id,
                "position": {"latitude": self.latitude, "longitude": self.longitude},
                "boot_id": self.boot_id, "seq": self.seq, "measured_at": self._timestamp(),
                "uptime_ms": time.ticks_ms(), "source": "sensor", "readings": readings}

    def publish_tds_reading(self, reading):
        if not self.connected:
            return False
        try:
            if self.pending_payload is None:
                self.pending_payload = json.dumps(self._packet(reading)).encode()
            # umqtt.simple QoS 1 waits for PUBACK. A lost ACK preserves these
            # exact bytes and boot_id/seq across the next connection.
            self.client.publish(self.topic.encode(), self.pending_payload, qos=1, retain=False)
            print("MQTT PUBACK:", self.device_id, "seq", self.seq)
            self.pending_payload = None
            self.seq += 1
            return True
        except (ValueError, TypeError) as error:
            print("Telemetry validation failed:", type(error).__name__)
            return False
        except Exception as error:
            print("MQTT publish failed; packet retained for retry:", type(error).__name__)
            self.disconnect()
            return False
