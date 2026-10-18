# Dewin sensor MQTT contract v1

**Current sensor transport: MQTT into NATS.** The earlier JSONL/Supabase contract
in the kiosk prototype is not the current path. This contract is hardware- and
language-independent: Pico, Arduino, and laptop simulators use the same packet.

## Connection

| Setting | Value |
| --- | --- |
| Broker on event LAN | **10.104.0.82** (`zerod`, existing Debian backend Pi) |
| Port / protocol | **1883 / MQTT 3.1.1 over TCP** |
| Username | `sensor` |
| Password | `SENSOR_PASSWORD`, supplied privately by the backend owner |
| MQTT client ID | Unique per physical node/connection |
| Publish topic | **`env/v1/<device_id>/telemetry`** |
| QoS / retain | **1 / false** |
| Initial cadence | One packet every five seconds |

Sensors use a standard MQTT client. Do not connect sensors to Core NATS :4222,
the old WebSocket feed, Socket.IO, Postgres, or the kiosk JSONL logger. NATS
converts the MQTT topic to `env.v1.<device_id>.telemetry`; JetStream captures it
in `ENV_RAW`. Workers process the stored packet after broker receipt.

Get the deployed password privately; `.env.example` has placeholders. A freshly
generated password on a new laptop will not authenticate to the existing broker.
Do not put Wi-Fi or MQTT passwords into Git. The demo credential is MQTT-only
and can publish telemetry, not subscribe to users' data. Per-device credentials
are the next hardening step before enrolling private production devices.

## Complete packet

All sensor keys use **snake_case**. The iOS API independently uses camelCase.
Replace these illustrative coordinates and readings with the installed node's
configuration and hardware data. This example is marked **simulated**:

```json
{
  "schema_version": 1,
  "device_id": "pico-water-01",
  "location_id": "demo-venue",
  "position": {"latitude": 25.7617, "longitude": -80.1918},
  "boot_id": "replace-with-random-id-per-boot",
  "seq": 42,
  "measured_at": null,
  "source": "simulated",
  "readings": [
    {"sensor_id": "tds-1", "medium": "water", "metric": "tds", "value": 312, "unit": "ppm", "quality": "uncalibrated"},
    {"sensor_id": "water-temp-1", "medium": "water", "metric": "temperature", "value": 22.4, "unit": "°C", "quality": "ok"},
    {"sensor_id": "air-1", "medium": "air", "metric": "humidity", "value": 48, "unit": "%", "quality": "ok"}
  ]
}
```

JSON fixture: [sensor-telemetry.json](../examples/sensor-telemetry.json).
Machine-readable schema: [telemetry.schema.json](../water_monitor/telemetry.schema.json).

## Field and retry rules

- `device_id` is stable and unique, and must exactly match the topic's device ID.
  IDs are 1–48 lowercase letters/digits/underscores/hyphens, starting alphanumeric.
  Assign separate IDs to real hardware and simulators.
- `location_id` identifies the installation; it is not a user ID.
- `position` is WGS84 decimal degrees: latitude -90…90, longitude -180…180.
  Include it on every new packet. Fixed installations can use configured
  coordinates and do not need a GPS module. Never use `(0,0)` as an unknown sentinel.
- `boot_id` changes to a new random ID on reboot. `seq` increases for each new
  measured packet. `(device_id, boot_id, seq)` is the idempotency identity.
  Retries preserve the same identity **and exact content**; do not regenerate a
  timestamp or values while retrying an old packet.
- `measured_at` is the source measurement time as RFC 3339 with a timezone,
  e.g. `2026-10-18T19:00:00Z`. If the clock is not synchronized, send **null**.
  Optional `uptime_ms` is diagnostic. The backend separately records original
  broker receive time; null source times use it as observation time. Old buffered
  samples with no source clock cannot reconstruct their original wall time.
- `source` is `sensor` for physical readings or `simulated` for test data.
- Each packet contains 1–16 readings. `sensor_id` identifies the physical sensor;
  each `(sensor_id, metric)` pair appears at most once per packet.
- Every new reading includes `medium: "air"` or `"water"`, a stable `metric`, a
  finite numeric `value`, explicit `unit`, and preferably `quality`.
  Quality is `ok` (default), `uncalibrated`, or `invalid`.
  Invalid readings are archived but do not replace valid current values.
- Units stay consistent per device/sensor/metric. Temperature in `C`, `°C`,
  `F`, or `°F` is normalized to `°C`. Missing/unsupported readings are omitted,
  not filled with zero. A raw gas channel remains raw; do not invent calibrated
  concentration or air-quality indices.
- Packets are at most 16 KiB, values are between -1e12 and 1e12, and source
  timestamps over 60 seconds ahead of broker reception are rejected.
- Reconnect with backoff. QoS 1 may redeliver; backend dedupe handles identical
  retry packets. QoS 1 is not a local offline sensor buffer: implement buffering
  explicitly if required. Do not retain telemetry on MQTT.

Suggested metric/unit pairs: water `tds`/`ppm`, `temperature`/`°C`, `ph`/empty unit,
`turbidity`/`NTU`, `conductivity`/`µS/cm`; air `temperature`/`°C`, `humidity`/`%`,
`co2`/`ppm`, `pm2_5`/`µg/m³`. Report only channels actually measured by the device.

## Ownership and privacy

Register the node ID, location, and intended owner/public visibility with the
backend owner. Ownership and privacy are trusted server registry fields, not
claims in MQTT packets. Do not add `owner_user_id`, user histories, names, face
metadata, or `visibility` to telemetry. New unregistered nodes must not appear
in the future app's matching results until registered. The real Socket.IO
spatial gateway is not deployed yet.

## Verify transport before hardware integration

On a laptop/Pi with `backend/requirements.txt` installed and the deployed
`SENSOR_PASSWORD` set privately in the environment (or backend `.env`):

```sh
cd backend
python scripts/publish_sensor_example.py --device-id contract-check-01
```

This validates the fixture locally, publishes one synthetic GPS + air/water
packet, and waits for MQTT PUBACK. PUBACK confirms broker receipt, not completion
of backend validation or spatial matching. The backend owner can independently
check `ENV_RAW` and processor acceptance using the printed boot ID.

**Deployment status:** verified on the physical Pi on 18 October 2026: MQTT
QoS 1 publish, JetStream durable capture, and NEX acceptance of coordinates plus
air/water readings. The running image is `water-monitor:spatial-contract`.
Legacy v1 packets remain accepted for backward compatibility;
new firmware must include coordinates and medium for the upcoming spatial API.
The actual sensor drivers, calibration, and offline queue remain firmware work.
