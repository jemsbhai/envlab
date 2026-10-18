import asyncio
import json
import logging
import os
from pathlib import Path
import signal

import nats
from nats.errors import TimeoutError as NatsTimeout
from nats.js.api import AckPolicy, ConsumerConfig, RetentionPolicy, StorageType, StreamConfig
from nats.js.errors import NotFoundError
from jsonschema import ValidationError

from .contract import DURABLE, RAW_SUBJECT, STREAM, now_ts, validate
from .ha import messages
from .mqtt_client import MqttClient
from .settings import Settings
from .storage import Store

LOG = logging.getLogger("water-monitor")


async def ensure_stream(js):
    config = StreamConfig(name=STREAM, subjects=[RAW_SUBJECT], storage=StorageType.FILE,
                          retention=RetentionPolicy.LIMITS, num_replicas=1,
                          max_age=86400, max_bytes=512 * 1024 * 1024, max_msg_size=16384)
    try:
        await js.stream_info(STREAM)
    except NotFoundError:
        await js.add_stream(config=config)


async def connect_nats(settings):
    async def connection_error(error):
        LOG.warning("NATS connection event: %s", type(error).__name__)

    return await nats.connect(settings.nats_url, user=settings.nats_user,
                              password=settings.nats_password, name="water-processor",
                              max_reconnect_attempts=-1, reconnect_time_wait=1, error_cb=connection_error)


async def process(msg, store, client, settings, nc=None):
    received_at = msg.metadata.timestamp.timestamp()
    try:
        event, observed_at = validate(msg.data, msg.subject, received_at)
        store.ingest(event, observed_at, received_at, msg.data)
    except (ValueError, TypeError, ValidationError, json.JSONDecodeError, UnicodeDecodeError) as error:
        store.reject(msg.subject, msg.data, error, received_at)
        LOG.warning("Rejected packet on %s: %s", msg.subject, str(error).splitlines()[0][:180])
        await msg.ack()
        return "rejected"
    # A retry after a DB commit still publishes the materialized latest reading.
    # An old event never replaces a newer value in this table.
    await publish_current(store, client, settings, event["device_id"], nc=nc)
    await msg.ack()
    return "processed"


async def publish_current(store, client, settings, device_id=None, nc=None):
    for row in store.current(device_id):
        mean, count = store.mean(row, settings.window_seconds)
        output = messages(row, mean, count, now_ts(), settings.expire_seconds, settings.window_seconds)
        for topic, payload, retained in output:
            if retained and client.configs.get(topic) == payload:
                continue
            await client.publish(topic, payload, retain=retained)
            if retained:
                client.configs[topic] = payload
        if nc and output:
            state = output[1][1]
            processed = {**state, "schema_version": 1, "device_id": row["device_id"],
                         "sensor_id": row["sensor_id"], "metric": row["metric"], "unit": row["unit"],
                         "rolling_mean": round(mean, 4), "sample_count": count,
                         "window_seconds": settings.window_seconds}
            subject = f"env.processed.{row['device_id']}.{row['sensor_id']}.{row['metric']}"
            await nc.publish(subject, json.dumps(processed, allow_nan=False).encode())
            await nc.flush(timeout=5)


def write_health(path, processed, ready=True):
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_suffix(".tmp")
    temporary.write_text(json.dumps({"ready": ready, "updated_at": now_ts(), "pid": os.getpid(), "processed": processed}), encoding="utf-8")
    temporary.replace(target)


async def run(settings=None, stop=None):
    settings = settings or Settings.from_env()
    stop = stop or asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(sig, stop.set)
        except NotImplementedError:
            pass
    store = Store(settings.database_path)
    nc = None
    client = None
    processed = 0
    prune_at = 0
    try:
        nc = await connect_nats(settings)
        js = nc.jetstream()
        await ensure_stream(js)
        subscription = await js.pull_subscribe(RAW_SUBJECT, durable=DURABLE, stream=STREAM,
            config=ConsumerConfig(durable_name=DURABLE, ack_policy=AckPolicy.EXPLICIT,
                                  ack_wait=60, max_ack_pending=16))

        def ha_message(paho, userdata, message):
            if message.topic == "homeassistant/status" and message.payload == b"online":
                client.refresh.set()

        client = MqttClient(settings.mqtt_host, settings.mqtt_port, settings.mqtt_user,
                            settings.mqtt_password, on_message=ha_message, availability=True)
        client.configs = {}
        await client.start()
        LOG.info("Ready: stream=%s consumer=%s window=%ss", STREAM, DURABLE, settings.window_seconds)
        while not stop.is_set():
            if client.refresh.is_set():
                client.refresh.clear()
                client.configs.clear()
                await client.publish("env/ha/pipeline/availability", "online", retain=True)
                await publish_current(store, client, settings)
            if now_ts() >= prune_at:
                store.prune(now_ts(), settings.history_days)
                prune_at = now_ts() + 60
            write_health(settings.health_path, processed, ready=nc.is_connected and client.connected.is_set())
            try:
                batch = await subscription.fetch(batch=1, timeout=1)
            except NatsTimeout:
                continue
            for msg in batch:
                try:
                    await process(msg, store, client, settings, nc=nc)
                    processed += 1
                except (RuntimeError, TimeoutError, nats.errors.Error) as error:
                    LOG.warning("Output unavailable; leaving event for retry: %s", type(error).__name__)
                    await msg.nak(delay=2)
                    await asyncio.sleep(1)
    finally:
        write_health(settings.health_path, processed, ready=False)
        if client:
            try:
                await client.publish("env/ha/pipeline/availability", "offline", retain=True)
            except (RuntimeError, TimeoutError):
                pass
            await client.stop()
        if nc:
            await nc.close()
        store.close()


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    asyncio.run(run())
