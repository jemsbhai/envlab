"""Test a running Compose stack with an MQTT 3.1.1 Home Assistant stand-in.

Use --restarts to also stop the processor, publish while it is offline, restart
the broker, and confirm NEX redeployment catches up from the persisted stream.
This verifies the MQTT contract, not Home Assistant's actual UI or installation.
"""
import argparse
import asyncio
import copy
import json
import os
import shlex
from pathlib import Path
import subprocess
import sys
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

import paho.mqtt.client as mqtt
import nats
from water_monitor.contract import DURABLE, STREAM, now_ts
from water_monitor.mqtt_client import MqttClient
from water_monitor.simulator import packet
from water_monitor.worker import connect_nats
from water_monitor.settings import Settings

COMPOSE_FILES = ["-f", "compose.yaml"]
REMOTE_HOST = None
REMOTE_DIR = "team-zero-water-monitor"

def load_env():
    for line in (ROOT / ".env").read_text().splitlines():
        if line and not line.lstrip().startswith("#"):
            key, value = line.split("=", 1)
            os.environ.setdefault(key, value)


def compose(*args):
    command = ["docker", "compose", *COMPOSE_FILES, *args]
    if REMOTE_HOST:
        directory = shlex.quote(REMOTE_DIR) if REMOTE_DIR.startswith("/") else '"$HOME"/' + shlex.quote(REMOTE_DIR)
        remote_command = "cd " + directory + " && sudo -n " + shlex.join(command)
        command = ["ssh", "-o", "BatchMode=yes", REMOTE_HOST, remote_command]
    subprocess.run(command, cwd=ROOT, check=True,
                   stdout=subprocess.DEVNULL, timeout=60)


class Observer:
    def __init__(self, device_id):
        self.items = []
        self.lock = threading.Lock()
        self.subscribed = threading.Event()
        self.client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2,
                                  client_id="ha-test-" + uuid.uuid4().hex[:10], protocol=mqtt.MQTTv311)
        self.client.username_pw_set("homeassistant", os.environ["HA_PASSWORD"])

        def on_connect(client, userdata, flags, reason, properties):
            if not reason.is_failure:
                client.subscribe([(f"env/ha/{device_id}/#", 1), ("homeassistant/sensor/+/config", 1)])

        def on_message(client, userdata, message):
            with self.lock:
                self.items.append((message.topic, bytes(message.payload), message.retain))

        self.client.on_connect = on_connect
        self.client.on_message = on_message
        self.client.on_subscribe = lambda *args: self.subscribed.set()
        self.client.connect("127.0.0.1", int(os.getenv("MQTT_PORT", "1883")), keepalive=15)
        self.client.loop_start()

    async def wait_for(self, predicate, timeout=20):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            with self.lock:
                for item in reversed(self.items):
                    if predicate(item):
                        return item
            await asyncio.sleep(.1)
        raise AssertionError("Timed out waiting for MQTT output")

    def close(self):
        self.client.disconnect()
        self.client.loop_stop()


async def run(restarts, websocket=False):
    load_env()
    if websocket:
        COMPOSE_FILES.extend(["-f", "deploy/websocket.compose.yaml"])
    device = "test-pico-" + uuid.uuid4().hex[:8]
    observer = Observer(device)
    sensor = MqttClient("127.0.0.1", int(os.getenv("MQTT_PORT", "1883")), "sensor", os.environ["SENSOR_PASSWORD"], "test-pico")
    nc = None
    ws = None
    try:
        assert await asyncio.to_thread(observer.subscribed.wait, 10), "HA test subscription failed"
        await sensor.start()
        settings = Settings(nats_password=os.environ["PIPELINE_PASSWORD"],
                            nats_url=f"nats://127.0.0.1:{os.getenv('NATS_PORT', '4222')}")
        nc = await connect_nats(settings)
        js = nc.jetstream()
        await js.stream_info(STREAM)
        ws_errors = []
        if websocket:
            async def on_ws_error(error):
                ws_errors.append(error)

            ws = await nats.connect(f"ws://127.0.0.1:{os.getenv('WS_PORT', '8080')}",
                                    user="viewer", password=os.environ["VIEWER_PASSWORD"],
                                    error_cb=on_ws_error, max_reconnect_attempts=0)
            ws_subscription = await ws.subscribe(f"env.processed.{device}.>")
            await ws.flush()
        boot = uuid.uuid4().hex
        first = packet(device, boot, 0)
        first["readings"][0]["value"] = 10
        second = packet(device, boot, 1)
        second["readings"][0]["value"] = 20
        topic = f"env/v1/{device}/telemetry"
        state_topic = f"env/ha/{device}/water-1/temperature/state"
        mean_topic = f"env/ha/{device}/water-1/temperature/mean"
        await sensor.publish(topic, first)
        await sensor.publish(topic, second)
        await observer.wait_for(lambda item: item[0] == state_topic and json.loads(item[1])["value"] == 20)
        await observer.wait_for(lambda item: item[0] == mean_topic and json.loads(item[1])["value"] == 15)
        config = await observer.wait_for(lambda item: item[0].startswith("homeassistant/sensor/")
                                         and device.encode() in item[1] and json.loads(item[1])["state_topic"] == state_topic)
        assert json.loads(config[1])["expire_after"] > 0
        print("PASS MQTT ingestion, HA discovery/state, rolling mean")
        if ws:
            update = json.loads((await ws_subscription.next_msg(timeout=10)).data)
            assert update["device_id"] == device and update["source"] == "simulated"
            await ws.publish("env.v1.forbidden.telemetry", b"{}")
            await ws.subscribe("env.v1.*.telemetry")
            await ws.flush()
            await asyncio.sleep(.2)
            assert len(ws_errors) >= 2, "Viewer unexpectedly has write or raw telemetry permissions"
            await ws.close()
            ws = None
            print("PASS read-only WebSocket feed; raw subscriptions and publishing denied")
        await sensor.publish(topic, second)
        late = packet(device, boot, 2, now_ts() - 120)
        late["readings"][0]["value"] = 99
        await sensor.publish(topic, late)
        await sensor.publish(topic, "{malformed-json")
        await asyncio.sleep(2)
        with observer.lock:
            states = [json.loads(payload)["value"] for name, payload, _ in observer.items if name == state_topic]
            averages = [json.loads(payload) for name, payload, _ in observer.items if name == mean_topic]
        assert states[-1] == 20 and 99 not in states, states
        assert averages[-1]["value"] == 15 and averages[-1]["sample_count"] == 2
        print("PASS duplicate delivery, out-of-order data, malformed packet isolation")

        # A late subscriber must get retained discovery, but no retained live state.
        later = Observer(device)
        try:
            assert await asyncio.to_thread(later.subscribed.wait, 10)
            await later.wait_for(lambda item: item[0] == config[0] and item[2])
            await asyncio.sleep(.5)
            with later.lock:
                assert not any(name == state_topic for name, _, _ in later.items)
            result = later.client.publish("homeassistant/status", "online", qos=1)
            await asyncio.to_thread(result.wait_for_publish, 5)
            await later.wait_for(lambda item: item[0] == state_topic)
        finally:
            later.close()
        print("PASS retained discovery, non-retained states, HA birth refresh")

        if restarts:
            await asyncio.to_thread(compose, "stop", "nex")
            pending = packet(device, boot, 3)
            pending["readings"][0]["value"] = 30
            await sensor.publish(topic, pending)
            await asyncio.to_thread(compose, "restart", "nats")
            await asyncio.to_thread(compose, "up", "-d", "--wait", "nex")
            await observer.wait_for(lambda item: item[0] == state_topic and json.loads(item[1])["value"] == 30, timeout=30)
            print("PASS broker persistence, NEX redeployment, durable consumer catch-up")
            await asyncio.to_thread(compose, "restart", "nats")
            assert await asyncio.to_thread(sensor.connected.wait, 15), "Publisher did not reconnect"
            reconnect_packet = packet(device, boot, 4)
            reconnect_packet["readings"][0]["value"] = 40
            await sensor.publish(topic, reconnect_packet)
            await observer.wait_for(lambda item: item[0] == state_topic and json.loads(item[1])["value"] == 40, timeout=30)
            print("PASS broker restart with processor running; publisher and worker reconnect")
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            info = await js.consumer_info(STREAM, DURABLE)
            if info.num_ack_pending == 0 and info.num_pending == 0:
                break
            await asyncio.sleep(.2)
        else:
            raise AssertionError("Consumer did not acknowledge all test packets")
        print("PASS consumer has no unacknowledged or pending packets")
    finally:
        # Remove only discovery configs created for this isolated test device.
        cleanup_code = "import sqlite3,sys; c=sqlite3.connect('/data/history.sqlite3'); c.execute('DELETE FROM latest WHERE device_id=?',(sys.argv[1],)); c.commit()"
        await asyncio.to_thread(compose, "exec", "-T", "nex", "python", "-c", cleanup_code, device)
        if sensor.connected.is_set():
            cleanup = MqttClient("127.0.0.1", int(os.getenv("MQTT_PORT", "1883")), "pipeline", os.environ["PIPELINE_PASSWORD"], "test-cleanup")
            await cleanup.start()
            try:
                with observer.lock:
                    configs = {name for name, payload, _ in observer.items
                               if name.startswith("homeassistant/sensor/") and device.encode() in payload}
                for name in configs:
                    await cleanup.publish(name, "", retain=True)
            finally:
                await cleanup.stop()
        await sensor.stop()
        observer.close()
        if nc:
            await nc.close()
        if ws:
            await ws.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--restarts", action="store_true")
    parser.add_argument("--websocket", action="store_true", help="Test the optional localhost WebSocket mapping (requires aiohttp)")
    parser.add_argument("--ssh", help="Run Compose operations on this SSH profile; use forwarded local ports for MQTT/NATS/WebSocket")
    parser.add_argument("--remote-dir", default="team-zero-water-monitor", help="Remote project path, relative to the SSH user's home unless absolute")
    args = parser.parse_args()
    REMOTE_HOST = args.ssh
    REMOTE_DIR = args.remote_dir
    asyncio.run(run(args.restarts, args.websocket))
