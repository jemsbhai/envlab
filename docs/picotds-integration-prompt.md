# PicoTDS → Dewin integration prompt

Copy the prompt below to the developer/agent working on `sensors/picoTDS`.
Obtain the real MQTT password privately from Serge; never commit it.

````text
Adapt the existing sensors/picoTDS firmware to Dewin’s running MQTT pipeline.
Preserve the sensor driver, calibration work and other teammates’ changes.
Read docs/sensor-agent-handoff.md and backend/docs/pico-contract.md first;
backend/water_monitor/telemetry.schema.json is the canonical MQTT schema.

Connection and topic
- MQTT 3.1.1 on the demo LAN: 10.104.0.82:1883.
- Username: sensor. Password: obtain SENSOR_PASSWORD privately from Serge.
- Disable broker discovery; use the configured broker directly.
- Stable device_id: the existing lowercase picotds_<MAC suffix> is valid.
  Use a unique MQTT client ID for each physical board.
- Publish ONE JSON packet to env/v1/<device_id>/telemetry every five seconds.
- QoS 1, retain false. Success means the publish received its MQTT PUBACK.
- NATS maps that topic to env.v1.<device_id>.telemetry and persists ENV_RAW;
  firmware does not connect to NATS directly.

Remove the old transport behavior
- Stop publishing picotds/{tds,voltage,temperature,reading,status}.
- Disable HA discovery and all homeassistant/* publications.
- Remove the status Last Will and the online/offline status publishes, including
  those in connect() and disconnect(). Merely changing the base topic does not
  fix these: the sensor account may publish only env/v1/*/telemetry.
- Make publish_tds_reading() publish the envelope below and propagate failure.
  Do not return success after failed publishes.
- Keep the MQTT manager available after an initial connection failure so the
  existing reconnect loop can retry. main.py currently sets self.mqtt=None on
  failed initialization, preventing subsequent reconnection.

Envelope example (illustrative coordinates and values; configure actual ones)
```json
{
  "schema_version": 1,
  "device_id": "picotds_a1b2c3",
  "location_id": "demo-venue",
  "position": {"latitude": 25.7617, "longitude": -80.1918},
  "boot_id": "b7ac25e19f04d832",
  "seq": 0,
  "measured_at": null,
  "source": "sensor",
  "readings": [
    {
      "sensor_id": "tds-1",
      "medium": "water",
      "metric": "tds",
      "value": 150.5,
      "unit": "ppm",
      "quality": "uncalibrated"
    }
  ]
}
```

Implementation rules
- Configure latitude/longitude for the physical sensor’s deployment location.
  Do not silently use the illustrative coordinates above.
- Map the actual reading['tds_ppm'] to the tds measurement; do not invent air,
  water-safety scores, or additional sensor readings. Mark uncalibrated until
  calibration is confirmed; use ok only when justified by the sensor owner.
- Current read_temperature() returns 25.0 when no temperature sensor exists or
  a read fails. Never publish that fallback as measured water temperature.
  Omit temperature unless there is a successful physical temperature reading;
  then use medium water, metric temperature, unit °C.
- Generate a fresh random lowercase hex boot_id once per board boot. Increment
  seq per new packet. Retries reuse the same complete packet, boot_id and seq;
  do not change a packet’s values while reusing its identity.
- Use measured_at=null until the board has a trustworthy UTC clock. A valid
  timestamp must be an ISO 8601 string with timezone, such as ...Z. Never put
  ticks_ms or seconds since boot in measured_at. uptime_ms is optional.
- Keep values finite JSON numbers. IDs use lowercase letters/digits/_/- and
  are at most 48 characters. Put all actual channels in readings[] in one packet.
- Store the private MQTT password in the local ignored config, not examples,
  source control, logs, screenshots or the handoff message.

Backend enrollment and acceptance
1. Give Serge the exact device_id, location_id, configured coordinates and
   desired visibility. For a private sensor, also provide the owner’s backend
   user ID. Ownership/visibility are server registry settings, not MQTT fields.
   Unregistered sensors are deliberately not exposed to the app.
2. Connect the board on the same LAN and obtain PUBACK for the canonical topic.
   Confirm the packet appears in ENV_RAW; PUBACK alone does not prove schema
   validation or device enrollment succeeded.
3. With the device enrolled, submit a fresh phone location within 100 meters of
   its configured coordinates and after the sensor measurement, no more than
   300 seconds later. The authorized phone must receive exposure:update with
   this deviceId, source sensor, medium water, metric tds and the actual value.
   Also confirm the exposure can be recovered through exposure:history.
4. Verify reconnection after Wi-Fi/broker interruption and no false success
   indication when publication fails. Preserve packet identity on retries.

Deliver the focused firmware/config changes, the exact board identity and
coordinates for enrollment, and observed test results. Coordinate in the shared
repo; do not modify backend or iOS contracts independently.
````
