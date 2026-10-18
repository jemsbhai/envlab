# Dewin sensor developer handoff

Copy the prompt below into your coding agent. Get the MQTT password privately;
no real credentials are included in this document.

````text
You are implementing sensor firmware for Dewin / envlab. Read AGENTS.md and
docs/sensor-agent-handoff.md in https://github.com/jemsbhai/envlab first.

Connect the sensor nodes to the existing MQTT broker on the same demo LAN:

- Broker: 10.104.0.82
- Port: 1883
- Protocol: MQTT 3.1.1 over TCP
- Username: sensor
- Password: SENSOR_PASSWORD, provided privately by the backend owner
- QoS: 1
- Retain: false
- Initial publication interval: 5 seconds
- Use a unique MQTT client ID and a stable, unique device_id per physical node.

TOPIC MAPPING

| Example node | Publish topic |
| --- | --- |
| Water node pico-water-01 | env/v1/pico-water-01/telemetry |
| Air node pico-air-01 | env/v1/pico-air-01/telemetry |
| Combined node pico-combo-01 | env/v1/pico-combo-01/telemetry |

These are example device names. Assign each physical node its own stable name.
The general pattern is env/v1/<device_id>/telemetry. The topic's device ID must
exactly match the JSON device_id. Use one topic per physical node; place all of
that node's channels in readings. Do not create separate topics per metric.

Example complete packet for pico-combo-01:

```json
{
  "schema_version": 1,
  "device_id": "pico-combo-01",
  "location_id": "demo-venue",
  "position": {"latitude": 25.7617, "longitude": -80.1918},
  "boot_id": "random-id-generated-once-per-boot",
  "seq": 0,
  "measured_at": null,
  "source": "sensor",
  "readings": [
    {
      "sensor_id": "tds-1",
      "medium": "water",
      "metric": "tds",
      "value": 312,
      "unit": "ppm",
      "quality": "uncalibrated"
    },
    {
      "sensor_id": "air-1",
      "medium": "air",
      "metric": "humidity",
      "value": 48,
      "unit": "%",
      "quality": "ok"
    }
  ]
}
```

The coordinates and readings above are illustrative. Replace them with the
node's configured position and actual measurements. A stationary sensor does
not need GPS hardware: configured latitude/longitude are sufficient. Include
position on every packet. Do not use (0,0) as an unknown-location sentinel.

Implement these rules:

1. Use the shared snake_case MQTT envelope. The iOS API's camelCase envelope is
   a separate contract; do not use it for firmware publishing.
2. IDs are 1–48 lowercase letters/digits/underscores/hyphens, starting with a
   letter or digit. Every physical node has a unique device_id.
3. Generate a new random boot_id on reboot. Increment seq for each new packet.
   Retries keep the same device_id, boot_id, seq, timestamp, and exact content.
4. Send measured_at: null until the clock is synchronized. After synchronization,
   send UTC source timestamps such as 2026-10-18T21:00:00Z. The backend records
   original broker receive time separately. Never invent source timestamps.
5. Each reading includes a physical sensor_id, medium (air or water), metric,
   finite numeric value, explicit unit, and quality. Send only measured channels.
   Missing data is omitted, not replaced with zero.
6. Quality is ok, uncalibrated, or invalid. Do not claim calibrated concentration
   or AQI from a raw gas channel. Units must stay consistent per sensor/metric.
7. Use source: sensor only for real hardware data. Use source: simulated for
   mock values and laptop/transport tests.
8. Keep each packet at or below 16 KiB and 1–16 readings. Reconnect with backoff.
   QoS 1 can redeliver; backend dedupe handles identical retry packets. Implement
   a local offline buffer explicitly if required; QoS 1 does not create one.
9. Never retain telemetry. Keep Wi-Fi and MQTT passwords out of Git and logs.
10. Register node IDs, coordinates, and intended public/private ownership with
    the backend owner. Ownership and visibility are controlled server-side;
    do not add owner IDs, user information, or visibility claims to packets.

No NATS SDK, HTTP upload, Postgres insert, or JSONL logger is needed on the node.
NATS is the MQTT broker. The backend maps the MQTT topic
env/v1/<device_id>/telemetry to NATS subject env.v1.<device_id>.telemetry and
stores the raw packet in JetStream stream ENV_RAW. Treat those NATS names as
backend information, not additional sensor publish destinations.

Read these shared files:

- docs/sensor-agent-handoff.md
- backend/docs/pico-contract.md
- backend/water_monitor/telemetry.schema.json
- backend/examples/sensor-telemetry.json
- backend/scripts/publish_sensor_example.py

Verify the transport before wiring up the final sensor code. On a laptop/Pi
with backend/requirements.txt installed and SENSOR_PASSWORD provided privately:

```sh
cd backend
python scripts/publish_sensor_example.py --device-id contract-check-01
```

This sends synthetic data and waits for MQTT PUBACK. PUBACK confirms broker
receipt; ask the backend owner to independently verify JetStream capture and
processor acceptance using the printed boot ID. The coordinates/medium extension
has already passed this physical-Pi acceptance test.

The real Socket.IO spatial gateway is deployed and publicly verified; see
backend/docs/deployment-zerod.md for verified deployment status. Sensor ingestion
is live. The backend owner must enroll actual device IDs and public/private
ownership before a nearby phone receives those readings. Do not claim
end-to-end phone enrichment based only on MQTT PUBACK.

Deliver: working MQTT publishing firmware in your sensors/<node>/ folder, a
brief wiring/configuration README with credential placeholders, and the actual
device IDs, configured coordinates, measured metrics/units, calibration status,
and public/private enrollment requirements for the backend owner.
````
