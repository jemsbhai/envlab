# PicoTDS → Dewin MQTT setup

The publisher sends actual TDS readings to the running NATS MQTT broker. Home
Assistant, broker discovery, status topics and Last Will messages are disabled.

| Setting | Value |
| --- | --- |
| Broker | `10.104.0.82:1883`, on the event LAN |
| Username | `sensor` |
| Password | Get `SENSOR_PASSWORD` privately from Serge |
| Topic | `env/v1/<device_id>/telemetry` |
| MQTT | 3.1.1, QoS 1, retain false, every five seconds |
| NATS mapping | `env.v1.<device_id>.telemetry` → stream `ENV_RAW` |

Copy `config/mqtt.py.example` to `config/mqtt.py` **only if the private file does
not already exist**. For an existing private file, retain its secrets and add
the new settings from the example. Set:

```python
MQTT_BROKER = "10.104.0.82"
MQTT_PORT = 1883
MQTT_USER = "sensor"
MQTT_PASSWORD = "GET_PRIVATELY_FROM_SERGE"  # Replace locally; never commit.
MQTT_DEVICE_ID = "pico-water-01"  # Public one-board demo; change for a second board.
MQTT_LOCATION_ID = "demo-venue"
MQTT_LATITUDE = 25.7617   # DEMO FIXTURE, shared with phone demo mode.
MQTT_LONGITUDE = -80.1918 # Use actual coordinates for real phone GPS.
MQTT_TDS_CALIBRATED = False
MQTT_CLOCK_SYNCED = False
```

`pico-water-01` is the simplest public demo identity. Its readings are real, but
the configured coordinates are an explicit demo fixture shared with phone demo
mode; they are not Pico-measured GPS. Legacy configs missing these new fields
also use this one-board fixture. Change identity for any second board; for real
phone GPS, configure actual deployment coordinates. The firmware refuses an
invalid coordinate or placeholder password. `MQTT_DEVICE_ID=None` instead
derives `picotds_<last six lowercase Wi-Fi MAC hex digits>`.
IDs use lowercase letters/digits/`_`/`-`, start with a letter/digit, and have at
most 48 characters. Boot logs print identity, topic and configured coordinates.

Give Serge the exact device ID, location ID, coordinates, and whether the sensor
is public or private. Private devices also require the owner's backend user ID.
The backend must enroll the device; unregistered sensors are not exposed to the
phone. Do not put ownership or visibility in MQTT payloads.

The single packet has the canonical v1 envelope and `readings[]`:

```json
{
  "schema_version": 1,
  "device_id": "picotds_a1b2c3",
  "location_id": "demo-venue",
  "position": {"latitude": 25.7617, "longitude": -80.1918},
  "boot_id": "b7ac25e19f04d832",
  "seq": 0,
  "measured_at": null,
  "uptime_ms": 1000,
  "source": "sensor",
  "readings": [
    {"sensor_id": "tds-1", "medium": "water", "metric": "tds", "value": 150.5,
     "unit": "ppm", "quality": "uncalibrated"}
  ]
}
```

Coordinates above are the demo fixture; the value is illustrative. `tds` comes from the real ADC driver;
it remains `uncalibrated` unless the sensor owner confirms calibration and sets
`MQTT_TDS_CALIBRATED=True`. No air measurements or health scores are invented.
Temperature appears only after a successful physical temperature-sensor read.
Missing temperature is `None` locally and omitted from MQTT readings; 25°C may
be used internally as a compensation reference, never as a fabricated reading.

Leave `MQTT_CLOCK_SYNCED=False` unless UTC has actually been synchronized; null
`measured_at` tells the backend to use original broker reception time. A random
boot ID is generated per startup. Failed publication retains the identical bytes
and sequence for retry; a new sequence follows PUBACK. Broker/Wi-Fi failures
reconnect without discarding the manager.

Upload using [Quick start](QUICKSTART.md). For acceptance:

1. Observe `MQTT connected` and `MQTT PUBACK` in the serial console. A failure
   never reports PUBACK success; no password is logged.
2. Ask Serge to confirm the device's packet in `ENV_RAW` and enroll it.
3. Send a fresh phone fix within 100 meters of the configured sensor, after its
   latest packet and within 300 seconds. An authorized user should receive an
   `exposure:update` containing this device, `source: "sensor"`, `metric: "tds"`
   and its value, then recover it using `exposure:history`.
4. Interrupt/reconnect Wi-Fi or the broker and verify telemetry resumes.

The authoritative schema is
[`backend/water_monitor/telemetry.schema.json`](../../../backend/water_monitor/telemetry.schema.json).
Shared handoff: [sensor agent handoff](../../../docs/sensor-agent-handoff.md).
