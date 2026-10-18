"""Create the iOS meal-results stream without changing environmental processing.

Run locally against NATS using NATS_URL/NATS_USER/NATS_PASSWORD, or use --ssh
zerod to execute with the existing private pipeline identity inside the Pi's
NEX container. No credentials are placed in command-line arguments.
"""
import argparse
import asyncio
import json
import os
from pathlib import Path
import shlex
import subprocess
import uuid


async def configure(check=False):
    import nats
    from nats.js.api import AckPolicy, ConsumerConfig, RetentionPolicy, StorageType, StreamConfig
    from nats.js.errors import NotFoundError

    nc = await nats.connect(os.environ.get("NATS_URL", "nats://127.0.0.1:4222"),
                            user=os.environ.get("NATS_USER", "pipeline"),
                            password=os.environ["NATS_PASSWORD"])
    js = nc.jetstream()
    try:
        try:
            info = await js.stream_info("ZERO_RESULTS")
        except NotFoundError:
            info = await js.add_stream(config=StreamConfig(
                name="ZERO_RESULTS", subjects=["zero.v1.*.meals.*.result"],
                storage=StorageType.FILE, retention=RetentionPolicy.LIMITS,
                max_age=30 * 86400, max_bytes=128 * 1024 * 1024,
                max_msgs=100_000, max_msg_size=16_384, num_replicas=1,
            ))
            print("Created ZERO_RESULTS (file storage; 30 days / 128 MiB / 100,000 messages).", flush=True)
        else:
            if info.config.subjects != ["zero.v1.*.meals.*.result"]:
                raise RuntimeError("Existing ZERO_RESULTS subjects differ; preserving existing stream")
            print("Existing ZERO_RESULTS preserved.", flush=True)
        if check:
            await offline_check(nc, js, ConsumerConfig, AckPolicy)
        print("ZERO_RESULTS ready for the meal-analysis producer.", flush=True)
    finally:
        await nc.close()


async def offline_check(nc, js, ConsumerConfig, AckPolicy):
    from nats.js.errors import NotFoundError

    client = "pipecheck-" + uuid.uuid4().hex[:10]
    meal = "meal-" + uuid.uuid4().hex
    durable = "zero-app-" + client
    subject = f"zero.v1.{client}.meals.{meal}.result"
    config = ConsumerConfig(durable_name=durable, ack_policy=AckPolicy.EXPLICIT,
                            filter_subject=f"zero.v1.{client}.meals.*.result",
                            ack_wait=60, max_ack_pending=10)
    sequence = None
    try:
        await js.add_consumer("ZERO_RESULTS", config=config)
        # Core NATS publication, with no active pull subscriber: the stream captures it.
        payload = {"mealId": meal, "status": "failed", "error": "Transport smoke test; no meal analyzed",
                   "processedAt": "2026-10-18T12:31:09-04:00"}
        await nc.publish(subject, json.dumps(payload).encode()); await nc.flush()
        # Obtain the captured sequence for cleanup without changing app behavior.
        msg = await js.get_last_msg("ZERO_RESULTS", subject)
        sequence = msg.seq
        sub = await js.pull_subscribe_bind(stream="ZERO_RESULTS", durable=durable)
        messages = await sub.fetch(10, timeout=1)
        assert len(messages) == 1 and json.loads(messages[0].data) == payload
        await messages[0].ack_sync()
        await sub.unsubscribe()
        # Bind again, as a reconnecting phone would, and check durable ACK progress.
        reconnected = await js.pull_subscribe_bind(stream="ZERO_RESULTS", durable=durable)
        progress = await js.consumer_info("ZERO_RESULTS", durable)
        assert progress.num_pending == 0 and progress.num_ack_pending == 0
        await reconnected.unsubscribe()
        print("Verified offline Core NATS capture, filtered durable pull, explicit ACK, and reconnect progress.", flush=True)
    finally:
        try:
            await js.delete_consumer("ZERO_RESULTS", durable)
        except NotFoundError:
            pass
        if sequence is not None:
            await js.delete_msg("ZERO_RESULTS", sequence)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ssh")
    parser.add_argument("--remote-dir", default="/home/hacker9/team-zero-water-monitor")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    if args.ssh:
        command = (f"cd {shlex.quote(args.remote_dir)} && sudo -n docker compose "
                   "exec -T nex python -" + (" --check" if args.check else ""))
        subprocess.run(["ssh", "-o", "BatchMode=yes", args.ssh, command],
                       input=Path(__file__).read_bytes(), check=True)
    else:
        asyncio.run(configure(args.check))


if __name__ == "__main__":
    main()
