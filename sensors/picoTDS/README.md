# Sensor firmware

**Publish MQTT to the backend Pi.** The old requirement to write
`~/envlab/sensors.jsonl` belonged to the kiosk prototype and is not the current
Dewin sensor contract.

Start with [the sensor agent handoff](../docs/sensor-agent-handoff.md) and
[the MQTT v1 contract](../backend/docs/pico-contract.md).

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

PicoTDS is a Raspberry Pi Pico W project for reading TDS (Total Dissolved Solids) measurements. See [PicoTDS README](picotds/README.md) for full documentation.
