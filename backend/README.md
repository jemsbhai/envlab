# Dewin environmental telemetry

**Current direction:** iOS uses a Socket.IO API for GPS submission and enriched
air/water exposure history. Start with [the API v1 team contract](docs/api-v1.md).
The broker is live; the new Socket.IO gateway is pending implementation. Home
Assistant is stopped with its data preserved. HA and food-result instructions
below describe the earlier prototype, not the current app integration.

Runnable data pipes for the **1 GB Raspberry Pi 4**:

The current live deployment is on **`zerod` (`10.104.0.82`, actually 4 GB RAM)**.
See [its deployment and operating notes](docs/deployment-zerod.md).

```text
Simulated Pico / real Pico W --MQTT 3.1.1--> NATS :1883
                                               |
                                        JetStream ENV_RAW
                                               |
                                     NEX native Python worker
                                       /       |         \
                                  SQLite     MQTT       NATS processed subjects
                                              |               |
                                    Home Assistant     optional WebSocket UI
                                    on the 4 GB Pi
```

The worker validates packets, normalizes temperature units, deduplicates retries,
archives observations, calculates a 60-second arithmetic rolling mean, and
publishes Home Assistant discovery plus current state. Simulated data is marked
as such. These averages are demonstration statistics, not health classifications.

## Start on the Pi

Prerequisites: **64-bit Debian 12/13 or Raspberry Pi OS**, Docker Engine with Compose,
and Python 3 for generating configuration. Keep the existing host OS.
Copy this folder to the 1 GB Pi; retain any existing `.env` and data volumes.

On a fresh Debian 12/13 host, `sh deploy/install-docker-debian.sh` installs Docker
and Compose from Docker's official apt repository. If your user is not in the
Docker group, prefix Docker commands below with `sudo -n`, as on `zerod`.

```sh
python3 scripts/init_env.py
docker compose --profile sim up -d --build --wait
docker compose ps
docker compose logs -f nex simulator
```

The first build compiles a pinned NEX source revision. Go compilation is limited
to one parallel build job, but a laptop build is preferable on a 1 GB board.
To build an ARM64 image on a Docker Desktop laptop and transfer it instead:

```sh
docker buildx build --platform linux/arm64 --load -t water-monitor:pi .
docker save -o water-monitor-arm64.tar water-monitor:pi
```

Copy the tar and this project to the Pi, run `docker load -i water-monitor-arm64.tar`,
and add `WATER_MONITOR_IMAGE=water-monitor:pi` to the Pi's `.env`. Then run
`docker compose --profile sim up -d --wait` **without** `--build`.

The default simulator publishes three devices every five seconds. Set
`SIM_DEVICES` and `SIM_INTERVAL` in `.env`, then run `docker compose --profile sim up -d`
to apply changes. `docker compose stop simulator` leaves the backend running.

`scripts/init_env.py` generates separate random passwords and preserves existing
non-placeholder values. `.env` is ignored by Git and excluded from image builds.

## Connect Home Assistant

On `zerod`, Home Assistant Container runs as a sibling of the broker and processor.
Portainer manages its `water-homeassistant` stack. The install and operating
instructions are in [the deployment notes](docs/deployment-zerod.md).

On the 4 GB Pi's HA instance:

1. Add or reconfigure the **MQTT integration** in Settings → Devices & services.
2. Broker: the **1 GB Pi's LAN IP**, port **1883**.
3. Username: **homeassistant**. Password: **HA_PASSWORD** from the backend `.env`.
4. Select **MQTT 3.1.1**, not the MQTT 5 default. The checked HA 2026.10.2 release
   still has this selection, though the general MQTT docs say MQTT 5 is required.
   If your version offers no 3.1.1 option, direct NATS integration needs a compatible
   HA version or a separate MQTT 5 bridge; this scaffold does not install one.
5. Leave discovery enabled with prefix `homeassistant`.

Look for devices `sim-pico-01`, `sim-pico-02`, and `sim-pico-03`. Each exposes
temperature and its rolling mean. Attributes include source, quality, location,
observation time, and original broker receive time.

For a ready-made demo dashboard, generate JSON (also valid YAML):

```sh
docker compose exec -T nex python -m water_monitor.dashboard > ha-dashboard.json
```

An already generated three-device example is in `deploy/ha-dashboard.json`.

In a new HA dashboard, take control and paste this into the raw configuration
editor. It uses deterministic default entity IDs; adjust them if an existing HA
entity already occupied those IDs or you renamed them.

To prove staleness, stop the simulator. Sensors should become unavailable within
about 30 seconds of their observation time (unless HA was disconnected and could not
observe the original state). Stop the processor to make all its entities
unavailable via the pipeline availability topic. Discovery is retained; sensor
states are not retained. HA's birth message causes fresh current values to be
republished with only their remaining expiry time.

## Contracts and topics

Give the firmware teammate [the Pico contract](docs/pico-contract.md).
The frontend teammate can use [the optional WebSocket contract](docs/frontend-contract.md).
The iOS app's separate durable meal-result channel is documented in
[the iOS results contract](docs/ios-results-contract.md); `ZERO_RESULTS` is deployed.
No sensor model is hardcoded into ingestion.

| Purpose | MQTT topic / NATS subject |
| --- | --- |
| Pico publishes | `env/v1/<device>/telemetry` |
| Raw JetStream capture | `env.v1.*.telemetry` |
| HA entity config | `homeassistant/sensor/<stable-id>/config` |
| HA instantaneous value | `env/ha/<device>/<sensor>/<metric>/state` |
| HA arithmetic rolling mean | `env/ha/<device>/<sensor>/<metric>/mean` |
| Pipeline availability | `env/ha/pipeline/availability` |
| Web frontend live feed | `env.processed.<device>.<sensor>.<metric>` |

## Replay, storage, and resource limits

- File-backed `ENV_RAW`: **24 hours or 512 MiB**, whichever limit is reached first.
  The broker's total JetStream disk budget is 768 MiB, including MQTT state.
- Durable pull consumer: `ha-processor-v1`; explicit acknowledgement after archive
  and live-output handling. A retry after a DB commit does not double-count data.
  Invalid packets go into a bounded SQLite `rejected` table and are acknowledged.
- SQLite archive: up to **90 days or 250,000 events**, whichever is smaller,
  pruned each minute. This demo cap is not a promise of 90 days at every sample
  rate. The `events.raw` column preserves original packets; normalized readings
  and materialized latest values are separate tables. Units cannot silently change.
- Old replayed events enter history and eligible averaging windows but cannot
  replace newer current values or present an expired reading as fresh in HA.
- Named Docker volumes preserve JetStream and SQLite across ordinary `down`/`up`.
  NEX placement is recreated once on each container boot; stream progress and
  deduplication live outside that ephemeral placement. One processor instance is
  intended; do not scale the `nex` service with this shared-volume configuration.
- Runtime memory ceilings: broker 256 MiB, NEX plus worker 384 MiB, simulator
  64 MiB. Use `docker stats --no-stream` to measure actual use on the Pi.
- Authenticated MQTT, HA :8123, and Portainer HTTPS :9443 are exposed to the LAN.
  Core NATS :4222 and monitoring
  :8222 bind to localhost on the host. The optional WebSocket mapping is localhost
  too. The deployed [named Cloudflare tunnel](docs/cloudflare-tunnel.md) exposes
  only the authenticated, read-only WebSocket feed at
  `wss://dewin-events.cbnsndwch.dev`.

## Inspect and test

```sh
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements.txt
python -m unittest discover -v
python scripts/smoke_test.py
```

On Windows use `.venv\Scripts\python` instead of activating the environment.
The smoke test loads local `.env` settings and uses an MQTT 3.1.1 HA stand-in to
check discovery, state, averaging, duplicate/late data, bad packets, retained
config, and HA birth. Run it with the simulator stopped to make consumer-idle
checks deterministic. It removes only its own test discovery configs afterward.

```sh
docker compose stop simulator
python scripts/smoke_test.py --restarts
```

`--restarts` also stops NEX, publishes while the processor is offline, restarts
the broker, and verifies durable catch-up after automatic NEX deployment.
This deliberately interrupts this project's local backend. It does not exercise
HA's actual UI or prove deployment on a physical Pi.

To also verify WebSocket delivery and the viewer's read-only permissions:

```sh
pip install -r requirements-dev.txt
docker compose -f compose.yaml -f deploy/websocket.compose.yaml up -d --wait
python scripts/smoke_test.py --websocket --restarts
```

Useful commands:

```sh
docker compose exec nex python -m water_monitor.health
docker compose exec nex nex --disable-upgrade-check --config /tmp/water-nex/config.json workload list
docker compose exec nex python -c "import sqlite3; c=sqlite3.connect('/data/history.sqlite3'); print(c.execute('select count(*) from events').fetchone())"
curl http://127.0.0.1:8222/healthz
docker compose --profile sim down
```

To rebuild after editing code: `docker compose build nex`, then
`docker compose --profile sim up -d --force-recreate nex simulator`.

## Implementation references

- [NATS MQTT](https://docs.nats.io/learn/mqtt/): topic conversion, MQTT 3.1.1, JetStream requirement.
- [NEX source](https://github.com/synadia-io/nex/tree/12609378dbb5402ef94a1b283704e0441fea4754): pinned native runtime and CLI.
- [HA MQTT discovery](https://www.home-assistant.io/integrations/mqtt/#mqtt-discovery).
- [HA sensor expiry](https://www.home-assistant.io/integrations/sensor.mqtt/#expire_after).
- [HA 2026.10.2 protocol options](https://github.com/home-assistant/core/blob/2026.10.2/homeassistant/components/mqtt/const.py).

Scope: environmental telemetry, processing, Home Assistant, and the read-only
public live feed. Image recognition, per-person exposure matching, and a
historical HTTP API are not implemented here.
