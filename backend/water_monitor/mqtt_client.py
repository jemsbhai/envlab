"""Paho's network loop runs in a thread; callers can await publish acknowledgements."""
import asyncio
import json
import threading
import uuid

import paho.mqtt.client as mqtt


class MqttClient:
    def __init__(self, host, port, user, password, prefix="pipeline", on_message=None, availability=False):
        self.host, self.port = host, port
        self.connected = threading.Event()
        self.refresh = threading.Event()
        self.client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2,
                                  client_id=f"{prefix}-{uuid.uuid4().hex[:12]}", protocol=mqtt.MQTTv311)
        self.client.username_pw_set(user, password)
        self.client.reconnect_delay_set(min_delay=1, max_delay=10)
        self.client.max_queued_messages_set(100)
        self.client.max_inflight_messages_set(10)
        if availability:
            self.client.will_set("env/ha/pipeline/availability", "offline", qos=1, retain=True)

        def connect(client, userdata, flags, reason, properties):
            if reason.is_failure:
                return
            if on_message:
                client.subscribe("homeassistant/status", qos=1)
            self.connected.set()
            self.refresh.set()

        def disconnect(client, userdata, flags, reason, properties):
            self.connected.clear()

        self.client.on_connect = connect
        self.client.on_disconnect = disconnect
        if on_message:
            self.client.on_message = on_message

    async def start(self):
        self.client.connect_async(self.host, self.port, keepalive=15)
        self.client.loop_start()
        if not await asyncio.to_thread(self.connected.wait, 15):
            self.client.loop_stop()
            raise RuntimeError("MQTT connection failed; check host, port, and credentials")

    async def publish(self, topic, payload, retain=False):
        if isinstance(payload, dict):
            payload = json.dumps(payload, allow_nan=False, separators=(",", ":"))

        def send():
            result = self.client.publish(topic, payload, qos=1, retain=retain)
            if result.rc != mqtt.MQTT_ERR_SUCCESS:
                raise RuntimeError(f"MQTT publish failed: {mqtt.error_string(result.rc)}")
            result.wait_for_publish(timeout=5)
            if not result.is_published():
                raise TimeoutError("MQTT publish acknowledgement timed out")

        await asyncio.to_thread(send)

    async def stop(self):
        self.client.disconnect()
        await asyncio.to_thread(self.client.loop_stop)
