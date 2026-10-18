# Dewin: start here for sensor agents

Download/copy the complete [sensor developer prompt](sensor-dev-prompt.md).

The repo's earlier JSONL/Supabase contract is legacy kiosk work. For the current
air/water exposure app, sensor nodes publish **MQTT 3.1.1** directly to the Pi.
NATS is the MQTT broker; JetStream persists the raw packets. NEX workers process
them. Sensors do not connect to Socket.IO, Postgres, or a native NATS port.

## Canonical files

- [MQTT endpoint, envelope, timestamps, retries, and units](../backend/docs/pico-contract.md)
- [Machine-readable packet schema](../backend/water_monitor/telemetry.schema.json)
- [Complete synthetic packet](../backend/examples/sensor-telemetry.json)
- [Laptop/Pi publisher check](../backend/scripts/publish_sensor_example.py)
- [App-side contract](../backend/docs/api-v1.md), for context only

## What the sensor owner needs

1. Obtain `SENSOR_PASSWORD` privately from the backend owner. Username is `sensor`.
   Each physical node needs a unique device ID and MQTT client ID.
2. Connect on the event LAN to **`10.104.0.82:1883`**, MQTT **3.1.1**.
3. Publish JSON to **`env/v1/<device_id>/telemetry`**, QoS **1**, retain **false**.
4. Include `position.latitude`/`position.longitude` on every packet. For a fixed
   installation these can be configured coordinates; no GPS module is required.
5. Include `medium: "air"` or `"water"` on every reading, with a stable physical
   sensor ID, metric, numeric value, explicit unit, and quality flag.
6. Use UTC source time if synchronized; otherwise send `measured_at: null`.
   The server records its own original receive time. Never invent a clock.
7. Keep `(device_id, boot_id, seq)` and the exact payload stable while retrying.
   Create a new random `boot_id` on reboot. Start at one sample every five seconds.
8. Register the node's identity, location, and intended owner/public visibility
   with the backend owner. Device-supplied owner/privacy claims are not trusted.

Run the laptop publisher after installing `backend/requirements.txt`; provide
the actual deployed password through the environment or a private backend `.env`:

```sh
cd backend
python scripts/publish_sensor_example.py --device-id contract-check-01
```

This sends one **simulated** packet and waits for the MQTT publish ACK. It does
not turn simulated values into actual sensor readings. The check's credential
is not included in the repo. Generating fresh local passwords with `init_env.py`
does not make those passwords valid on an already running broker.

## Compatibility and deployment boundary

Coordinates and medium extend the existing v1 envelope. Legacy packets remain
valid for ingestion, but new firmware must include these fields for the spatial
API. The backend's schema and acceptance test cover this extension. See the MQTT
contract's deployment status for the physical-Pi verification.

The real Socket.IO spatial gateway is still pending. Publishing successfully
does not mean the phone's final matching/history feature is deployed. MQTT
PUBACK confirms broker receipt; the backend acceptance test separately checks
validation and durable raw storage.

## Copy/paste task for the sensor agent

> Read `AGENTS.md`, `docs/sensor-agent-handoff.md`,
> `backend/docs/pico-contract.md`, the telemetry JSON Schema, and the complete
> synthetic packet. Implement MQTT 3.1.1 publishing at `10.104.0.82:1883` with
> credentials supplied privately, QoS 1, no retain, and topic
> `env/v1/<device_id>/telemetry`. Include configured sensor coordinates on every
> packet and air/water medium, units, and quality for each reading. Preserve
> source time, per-boot identity, and sequence across retries; reconnect with
> backoff. Keep hardware drivers and calibration in your component. Do not use
> the legacy JSONL/Supabase path as the current transport. Test the contract
> publisher first, then replace only its simulated measurements with real
> hardware data and set `source: "sensor"`. Keep all credentials out of Git.
