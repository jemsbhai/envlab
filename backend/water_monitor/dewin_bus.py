"""Persistent resources for the real API. All durable application data is in JetStream."""
import json
import logging
import os

import nats
from nats.js.api import KeyValueConfig, RetentionPolicy, StorageType, StreamConfig
from nats.js.errors import APIError, BucketNotFoundError, NotFoundError

LOG = logging.getLogger("dewin")
HORIZON = 90 * 86400
GEO_STREAM = "DEWIN_GEO"
RESULT_STREAM = "DEWIN_EXPOSURES"


def encode(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False).encode()


async def connect(name):
    async def error_cb(error):
        LOG.warning("NATS event: %s", type(error).__name__)
    return await nats.connect(os.getenv("NATS_URL", "nats://127.0.0.1:4222"),
                              user=os.getenv("NATS_USER", "pipeline"), password=os.environ["NATS_PASSWORD"],
                              name=name, max_reconnect_attempts=-1, reconnect_time_wait=1, error_cb=error_cb)


async def ensure_resources(js):
    for name, subjects, megabytes, max_size, max_msgs in (
        ("ENV_RAW", ["env.v1.*.telemetry"], 256, 16384, 50000),
        (GEO_STREAM, ["dewin.v1.*.location"], 128, 20000, 100000),
        (RESULT_STREAM, ["dewin.v1.*.exposure"], 256, 64000, 100000),
    ):
        try:
            info = await js.stream_info(name)
        except NotFoundError:
            try:
                info = await js.add_stream(config=StreamConfig(name=name, subjects=subjects, storage=StorageType.FILE,
                    retention=RetentionPolicy.LIMITS, num_replicas=1, max_age=HORIZON,
                    max_bytes=megabytes*1024*1024, max_msg_size=max_size, max_msgs=max_msgs))
            except APIError:
                # Gateway and NEX bootstrap can start concurrently.
                info = await js.stream_info(name)
        if info.config.subjects != subjects or info.config.storage != StorageType.FILE:
            raise RuntimeError("Unexpected subjects or storage for " + name)
        config = info.config
        if (config.max_age, config.max_bytes, config.max_msgs, config.max_msg_size) != (HORIZON, megabytes*1024*1024, max_msgs, max_size):
            config.max_age, config.max_bytes = HORIZON, megabytes*1024*1024
            config.max_msgs, config.max_msg_size = max_msgs, max_size
            await js.update_stream(config=config)
    buckets = {}
    for bucket, size, ttl in (("DEWIN_RECEIPTS", 128, HORIZON), ("DEWIN_RESULTS", 256, HORIZON), ("DEWIN_HEALTH", 1, 60)):
        try:
            buckets[bucket] = await js.key_value(bucket)
        except (BucketNotFoundError, NotFoundError):
            try:
                buckets[bucket] = await js.create_key_value(config=KeyValueConfig(
                    bucket=bucket, storage=StorageType.FILE, history=1, ttl=ttl,
                    max_bytes=size*1024*1024, max_value_size=64000, replicas=1))
            except Exception:
                # Another starting service may have created the same bucket.
                buckets[bucket] = await js.key_value(bucket)
    return buckets


async def kv_get(bucket, key):
    from nats.js.errors import KeyNotFoundError, KeyDeletedError
    try:
        entry = await bucket.get(key)
        return json.loads(entry.value), entry.revision
    except (KeyNotFoundError, KeyDeletedError):
        return None, None
