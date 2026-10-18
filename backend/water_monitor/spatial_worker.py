"""NEX-native spatial worker: stored MQTT + stored GPS -> immutable stored exposures."""
import asyncio
import json
import logging
import os
import signal

from nats.errors import TimeoutError as NatsTimeout
from nats.errors import Error as NatsError
from nats.js.api import AckPolicy, ConsumerConfig, DeliverPolicy
from nats.js.errors import NotFoundError
from jsonschema import ValidationError

from .api_protocol import validate as validate_api
from .contract import validate, now_ts
from .dewin_bus import connect, encode, ensure_resources, kv_get, GEO_STREAM, RESULT_STREAM
from .spatial import SensorIndex, registry
from .worker import write_health
from .noaa import NoaaAir, enrich_exposure

LOG = logging.getLogger("dewin-spatial")


def raw_watermark(state, applied):
    # Empty/expired streams retain their historical last sequence. There is no
    # packet left to consume, so waiting for that sequence would never finish.
    return max(applied, state.last_seq) if state.messages == 0 else applied


async def sensor_subscription(js, applied):
    return await js.pull_subscribe("env.v1.*.telemetry", stream="ENV_RAW", config=ConsumerConfig(
        ack_policy=AckPolicy.EXPLICIT, deliver_policy=DeliverPolicy.BY_START_SEQUENCE,
        opt_start_seq=applied+1, max_ack_pending=512, inactive_threshold=60))


async def run():
    nc = await connect("dewin-spatial-nex")
    js = nc.jetstream()
    buckets = await ensure_resources(js)
    index, ready = SensorIndex(), asyncio.Event()
    noaa = NoaaAir()
    applied = 0
    health_path = os.getenv("HEALTH_PATH", "/tmp/dewin-worker-health.json")
    stop = asyncio.Event()
    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            asyncio.get_running_loop().add_signal_handler(sig, stop.set)
        except NotImplementedError:
            pass
    sensors = await sensor_subscription(js, applied)

    async def sensor_loop():
        nonlocal applied, sensors
        while not stop.is_set():
            try:
                batch = await sensors.fetch(256, timeout=1)
            except (NatsTimeout, TimeoutError):
                batch = []
            except NatsError:
                await asyncio.sleep(1)
                batch = []
            for msg in batch:
                try:
                    event, observed = validate(msg.data, msg.subject, msg.metadata.timestamp.timestamp())
                    index.add(event, observed, msg.metadata.timestamp.timestamp(), msg.metadata.sequence.stream)
                except (ValueError, TypeError, UnicodeDecodeError, ValidationError):
                    LOG.warning("Rejected sensor packet: schema/identity validation")
                applied = max(applied, msg.metadata.sequence.stream)
                try:
                    await msg.ack()
                except NatsError:
                    # The cache already contains this packet. A lost ACK may
                    # redeliver it; SensorIndex deduplicates the event identity.
                    pass
            try:
                info = await sensors.consumer_info()
                state = (await js.stream_info("ENV_RAW")).state
                index.retain_from(state.first_seq if state.messages else state.last_seq+1)
                applied = raw_watermark(state, applied)
            except NotFoundError:
                # Ephemeral consumers may disappear during a server restart or
                # prolonged disconnect. Continue from the in-memory watermark;
                # a process restart rebuilds the whole retained history instead.
                try:
                    replacement = await sensor_subscription(js, applied)
                    await sensors.unsubscribe()
                    sensors = replacement
                except NatsError:
                    await asyncio.sleep(1)
                continue
            except NatsError:
                await asyncio.sleep(1)
                continue
            if info.num_pending == 0:
                ready.set()

    task = asyncio.create_task(sensor_loop())
    geos = None
    count = 0
    try:
        while not ready.is_set():
            if stop.is_set():
                return
            if task.done():
                await task
            write_health(health_path, count, ready=False)
            try:
                await buckets["DEWIN_HEALTH"].put("spatial", encode({"ready": False, "updatedAt": now_ts()}))
            except NatsError:
                pass
            await asyncio.sleep(1)
        geos = await js.pull_subscribe("dewin.v1.*.location", durable="dewin-spatial-v1", stream=GEO_STREAM,
            config=ConsumerConfig(durable_name="dewin-spatial-v1", ack_policy=AckPolicy.EXPLICIT,
                                  ack_wait=60, max_ack_pending=16))
        LOG.info("Spatial worker ready; sensor history rebuilt from JetStream")
        while not stop.is_set():
            if task.done():
                await task
            write_health(health_path, count, ready=nc.is_connected)
            try:
                await buckets["DEWIN_HEALTH"].put("spatial", encode({"ready": nc.is_connected, "updatedAt": now_ts(), "processed": count}))
            except NatsError:
                await asyncio.sleep(1)
                continue
            try:
                messages = await geos.fetch(1, timeout=1)
            except (NatsTimeout, TimeoutError):
                continue
            except NatsError:
                await asyncio.sleep(1)
                continue
            for msg in messages:
                try:
                    envelope = json.loads(msg.data)
                    validate_api("LocationUpdate", envelope["location"])
                    if msg.subject != f"dewin.v1.{envelope['userId']}.location":
                        raise ValueError("User/subject mismatch")
                except (ValueError, KeyError, TypeError, ValidationError):
                    LOG.error("Rejected internal location envelope")
                    await msg.ack()
                    continue
                key = envelope["userId"]+"."+envelope["location"]["eventId"]
                try:
                    existing, revision = await kv_get(buckets["DEWIN_RESULTS"], key)
                    if existing is None:
                        state = (await js.stream_info("ENV_RAW")).state
                        index.retain_from(state.first_seq if state.messages else state.last_seq+1)
                        target = state.last_seq
                        applied = raw_watermark(state, applied)
                        deadline = asyncio.get_running_loop().time()+10
                        while applied < target and asyncio.get_running_loop().time() < deadline:
                            if task.done():
                                await task
                            await asyncio.sleep(.02)
                        if applied < target:
                            raise RuntimeError("Sensor cache is catching up")
                        value = index.match(envelope, registry())
                        await enrich_exposure(value, noaa)
                        existing = {"userId": envelope["userId"], "exposure": value, "published": False}
                        revision = await buckets["DEWIN_RESULTS"].create(key, encode(existing))
                    if not existing["published"]:
                        await js.publish(f"dewin.v1.{envelope['userId']}.exposure", encode(existing["exposure"]),
                                         headers={"Nats-Msg-Id": "exposure/"+key})
                        existing["published"] = True
                        await buckets["DEWIN_RESULTS"].update(key, encode(existing), last=revision)
                    await msg.ack()
                    count += 1
                except Exception as exc:
                    LOG.warning("Exposure persistence unavailable; retrying: %s", type(exc).__name__)
                    try:
                        await msg.nak(delay=2)
                    except NatsError:
                        # Explicit ACK policy redelivers even if NAK was lost.
                        pass
                    await asyncio.sleep(.2)
    finally:
        await noaa.close()
        write_health(health_path, count, ready=False)
        task.cancel()
        await asyncio.gather(task, return_exceptions=True)
        try:
            await js.delete_consumer("ENV_RAW", sensors._consumer)
        except Exception:
            pass
        await nc.close()


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    asyncio.run(run())
