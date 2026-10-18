"""Publish one synthetic GPS + air/water packet through the actual MQTT path."""
import argparse
import json
import os
from pathlib import Path
import sys
import threading
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import paho.mqtt.client as mqtt
from water_monitor.contract import iso, now_ts, validate

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="10.104.0.82")
    parser.add_argument("--port", type=int, default=1883)
    parser.add_argument("--device-id", default="contract-check-01")
    args = parser.parse_args()
    env = {}
    if (ROOT / ".env").exists():
        env = dict(line.split("=", 1) for line in (ROOT / ".env").read_text().splitlines()
                   if line and not line.startswith("#") and "=" in line)
    password = os.environ.get("SENSOR_PASSWORD", env.get("SENSOR_PASSWORD", ""))
    if not password or password == "replace-with-random-password":
        raise SystemExit("Provide the deployed SENSOR_PASSWORD privately through the environment or backend/.env")
    event = json.loads((ROOT / "examples/sensor-telemetry.json").read_text(encoding="utf-8"))
    event.update(device_id=args.device_id, boot_id=uuid.uuid4().hex, seq=0, measured_at=iso(now_ts()))
    topic = f"env/v1/{args.device_id}/telemetry"
    payload = json.dumps(event, ensure_ascii=False, allow_nan=False).encode()
    validate(payload, topic.replace("/", "."), now_ts())
    connected = threading.Event()
    accepted = []

    def on_connect(client, userdata, flags, reason, properties):
        accepted.append(not reason.is_failure)
        connected.set()

    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2,
                         client_id="contract-check-"+uuid.uuid4().hex[:12], protocol=mqtt.MQTTv311)
    client.username_pw_set("sensor", password)
    client.on_connect = on_connect
    try:
        client.connect(args.host, args.port, keepalive=20)
        client.loop_start()
        if not connected.wait(10) or not accepted[0]:
            raise RuntimeError("MQTT connection/authentication failed")
        message = client.publish(topic, payload, qos=1, retain=False)
        message.wait_for_publish(timeout=10)
        if not message.is_published():
            raise RuntimeError("No MQTT PUBACK received")
        print(f"MQTT PUBACK: {topic}, source=simulated, GPS + {len(event['readings'])} readings")
        print("boot_id=" + event["boot_id"])
        print("Backend validation/storage must be checked separately from the publish ACK.")
    finally:
        client.disconnect()
        client.loop_stop()


if __name__ == "__main__":
    main()
