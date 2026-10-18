"""Start the NEX node and deploy one worker automatically after each container boot.

JetStream consumers and the SQLite archive persist independently of NEX placement.
The container has a single node, so a fresh placement does not duplicate workloads.
"""
import asyncio
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time
from urllib.parse import quote, urlsplit, urlunsplit

from .settings import Settings
from .worker import connect_nats, ensure_stream


async def bootstrap_stream(settings):
    nc = await connect_nats(settings)
    try:
        await ensure_stream(nc.jetstream())
    finally:
        await nc.close()


def main():
    settings = Settings.from_env()
    asyncio.run(bootstrap_stream(settings))
    # NEX passes this server URL to its native nexlet. Keeping auth in the URL
    # also authenticates that child (the development minter supplies no user).
    parsed = urlsplit(settings.nats_url)
    host = parsed.hostname or "nats"
    if ":" in host:
        host = f"[{host}]"
    netloc = f"{quote(settings.nats_user, safe='')}:{quote(settings.nats_password, safe='')}@{host}:{parsed.port or 4222}"
    server = urlunsplit((parsed.scheme, netloc, parsed.path, parsed.query, parsed.fragment))
    runtime = Path("/tmp/water-nex")
    runtime.mkdir(mode=0o700, exist_ok=True)
    config = runtime / "config.json"
    config.write_text(json.dumps({"nats": {"servers": [server]}}))
    config.chmod(0o600)
    workload = json.loads(Path("/app/deploy/processor.Nexfile.json").read_text())
    allowed = ("NATS_URL", "NATS_USER", "NATS_PASSWORD", "MQTT_HOST", "MQTT_PORT", "MQTT_USER", "MQTT_PASSWORD",
               "DATABASE_PATH", "HEALTH_PATH", "SENSOR_EXPIRE_SECONDS", "WINDOW_SECONDS", "HISTORY_DAYS")
    workload["start_request"]["environment"] = {key: os.environ[key] for key in allowed if key in os.environ}
    workload["start_request"]["environment"].update(PYTHONUNBUFFERED="1", PYTHONDONTWRITEBYTECODE="1")
    nexfile = runtime / "processor.json"
    nexfile.write_text(json.dumps(workload))
    nexfile.chmod(0o600)
    command = ["nex", "--disable-upgrade-check", "--config", str(config)]
    # Upstream logs its server URL at INFO level, including URL credentials.
    # Redact before forwarding any node or workload output to container logs.
    node = subprocess.Popen(command + ["node", "up", "--node-name", "water-pi", "--show-workload-logs"],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)

    def forward_logs():
        for line in node.stdout:
            line = line.replace(server, settings.nats_url)
            for secret in (settings.nats_password, settings.mqtt_password):
                if secret:
                    line = line.replace(secret, "[redacted]").replace(quote(secret, safe=""), "[redacted]")
            sys.stdout.write(line)
            sys.stdout.flush()

    log_thread = threading.Thread(target=forward_logs, daemon=True)
    log_thread.start()
    stopping = False

    def stop(signum, frame):
        nonlocal stopping
        stopping = True
        if node.poll() is None:
            node.terminate()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        deadline = time.monotonic() + 60
        while node.poll() is None and not stopping and time.monotonic() < deadline:
            result = subprocess.run(command + ["workload", "start", "-f", str(nexfile)],
                                    capture_output=True, text=True, timeout=15)
            if result.returncode == 0:
                print("NEX deployed water-processor; worker output follows in node logs.", flush=True)
                return node.wait()
            time.sleep(2)
        if not stopping:
            raise RuntimeError("NEX did not deploy the processor within 60 seconds; inspect node logs")
        return 0
    finally:
        if node.poll() is None:
            node.terminate()
            try:
                node.wait(timeout=12)
            except subprocess.TimeoutExpired:
                node.kill()
                node.wait()


if __name__ == "__main__":
    raise SystemExit(main())
