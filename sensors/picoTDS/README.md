# Sensor firmware

**Publish MQTT to the backend Pi.** The old requirement to write
`~/envlab/sensors.jsonl` belonged to the kiosk prototype and is not the current
Dewin sensor contract.

Start with [the sensor agent handoff](../../docs/sensor-agent-handoff.md) and
[the MQTT v1 contract](../../backend/docs/pico-contract.md).

- Broker: `10.104.0.82:1883`, MQTT 3.1.1, authenticated TCP on the event LAN.
- Topic: `env/v1/<device_id>/telemetry`, QoS 1, retain false.
- Include coordinates per packet, source timestamp (or null), stable device ID,
  per-boot ID, sequence number, and typed air/water readings with explicit units.
- Get MQTT credentials privately. Neither MQTT passwords nor Wi-Fi secrets
  belong in the repo. No NATS SDK is needed on the sensor.

Keep one folder per node, such as `pico_water/` or `uno_r4_air/`. Driver choices
remain with the firmware owner. Use the shared JSON fixture and publisher smoke
test to check the transport before attaching real sensors.

## PicoTDS

PicoTDS reads total dissolved solids with a Raspberry Pi Pico W. Hardware setup
is in [Wiring](docs/WIRING.md) and [Calibration](docs/CALIBRATION.md). The publisher
now follows the Dewin contract. Start with [Quick start](docs/QUICKSTART.md) to
configure private credentials and actual sensor coordinates, pull/upload the
firmware and give Serge its printed device ID for enrollment. The detailed
[MQTT setup](docs/MQTT_SETUP.md) includes topic mapping and app acceptance checks.
