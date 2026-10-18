"""A laptop/Pi publisher using the same MQTT 3.1.1 contract as Pico firmware."""
import argparse
import asyncio
import math
import os
import signal
import uuid

from .contract import iso, now_ts
from .mqtt_client import MqttClient


def packet(device_id, boot_id, seq, timestamp=None):
    return {
        "schema_version": 1, "device_id": device_id, "location_id": "demo-school",
        "position": {"latitude": 25.7617, "longitude": -80.1918},
        "boot_id": boot_id, "seq": seq, "measured_at": iso(now_ts() if timestamp is None else timestamp),
        "source": "simulated",
        "readings": [{"sensor_id": "water-1", "medium": "water", "metric": "temperature", "unit": "°C",
                      "value": round(22 + 2 * math.sin(seq / 6), 2), "quality": "ok"},
                     {"sensor_id": "air-1", "medium": "air", "metric": "humidity", "unit": "%",
                      "value": round(48 + 3 * math.sin(seq / 9), 2), "quality": "uncalibrated"}],
    }


async def run(args):
    stop = asyncio.Event()
    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            asyncio.get_running_loop().add_signal_handler(sig, stop.set)
        except NotImplementedError:
            pass
    client = MqttClient(os.getenv("MQTT_HOST", "127.0.0.1"), int(os.getenv("MQTT_PORT", "1883")),
                        os.getenv("MQTT_USER", "sensor"), os.getenv("MQTT_PASSWORD", ""), prefix="sim-pico")
    await client.start()
    boot_id = uuid.uuid4().hex
    seq = 0
    try:
        while not stop.is_set() and (args.count == 0 or seq < args.count):
            for index in range(args.devices):
                device_id = f"sim-pico-{index+1:02}"
                event = packet(device_id, boot_id, seq)
                await client.publish(f"env/v1/{device_id}/telemetry", event)
            print(f"Published sequence {seq} for {args.devices} simulated Picos", flush=True)
            seq += 1
            if args.count and seq >= args.count:
                break
            try:
                await asyncio.wait_for(stop.wait(), timeout=args.interval)
            except TimeoutError:
                pass
    finally:
        await client.stop()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--devices", type=int, default=int(os.getenv("SIM_DEVICES", "3")))
    parser.add_argument("--interval", type=float, default=float(os.getenv("SIM_INTERVAL", "5")))
    parser.add_argument("--count", type=int, default=0, help="Packets per device; zero runs until stopped")
    args = parser.parse_args()
    if args.devices < 1 or args.interval <= 0 or args.count < 0:
        parser.error("devices and interval must be positive; count must be nonnegative")
    asyncio.run(run(args))
