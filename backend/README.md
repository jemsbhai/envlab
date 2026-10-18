# Dewin environmental backend

Sensors publish air/water measurements over MQTT. Phones submit GPS positions
through a Socket.IO gateway and receive nearby authorized sensor observations,
live and in a persisted timeline. NATS is the broker; JetStream stores the data;
the Python workload running under NEX performs the spatial join.

The real gateway is deployed and verified at `https://dewin-api.cbnsndwch.dev`.
[The deployment notes](docs/deployment-zerod.md) record the completed checks
and their limits. Home Assistant is stopped, with its saved volume
preserved. The current runtime does not write a SQLite exposure archive.

**Demo connections require no credentials.** The app connects with no auth
payload (or `{}`) and uses shared identity `demo-ios`. Anonymous phones share
its history, live results, and private demo sensor access. Optional valid tokens
still select separate identities; an explicitly invalid token is rejected.
Sensors omit MQTT username/password and can publish telemetry only on the LAN.

```text
Pico / simulator -- MQTT 3.1.1 --> ENV_RAW (JetStream)
                                          |
iOS -- Socket.IO --> gateway --> DEWIN_GEO |
                        ^                 v
                        |            NEX spatial worker
                        +---- DEWIN_RESULTS KV + DEWIN_EXPOSURES
```

Start with [the Socket.IO API](docs/api-v1.md), [iOS handoff](../docs/ios-agent-handoff.md),
or [sensor MQTT contract](docs/pico-contract.md). MQTT packet keys are snake_case;
the app API uses camelCase. Simulated readings always carry `source: "simulated"`.

## Run a local real stack

Use 64-bit Debian/Raspberry Pi OS or Docker Desktop with Compose. Generate
configuration on a trusted development computer:

```sh
python3 scripts/init_env.py
docker compose --profile sim up -d --build --wait
docker compose ps
curl -f http://127.0.0.1:8765/healthz
```

The first build compiles a pinned NEX revision. Build on a laptop for a 1 GB Pi;
the current physical backend `zerod` has approximately 4 GB. On a Debian host
where Docker requires root, prefix Docker commands with `sudo -n`.

`init_env.py` preserves existing passwords, creates missing secrets, generates
two personal demo API tokens, writes their SHA-256 hashes into
`.runtime/api-clients.json`, and creates `.runtime/devices.json` only if absent.
Both runtime files and `.env` are ignored by Git. The plaintext app tokens are
`API_DEMO_TOKEN` for `demo-ios` and `API_SECOND_TOKEN` for `demo-other`; these are
optional identity overrides for tests or separate sessions. They are not needed
for the shared demo. The gateway reads hashes, not plaintext token variables.
Initialization preserves an existing client registry; keep optional plaintext
tokens and management credentials private.

The default local API is `http://127.0.0.1:8765`, Socket.IO path `/socket.io/`,
namespace `/`, Engine.IO 4. MQTT listens on port 1883; Core NATS 4222, monitoring
8222, and the API bind to host loopback. Override `MQTT_PORT`, `NATS_PORT`,
`MONITOR_PORT`, or `API_HOST_PORT` in `.env` if occupied. Browser origins use the
gateway's `API_ALLOWED_ORIGINS` setting. Native iOS connects without a login or
token for the shared demo. The Compose service does not publish the API directly to the LAN.

## Device enrollment and demo data

Only registered devices can appear in app results. Edit the private
`.runtime/devices.json` on the backend, for example:

```json
{
  "devices": {
    "pico-water-01": {"visibility": "public"},
    "pico-home-01": {"visibility": "private", "ownerUserId": "demo-ios"}
  }
}
```

Give the backend owner each actual `device_id`, configured position, measured
metrics/units, and intended owner/visibility. Positions come from each telemetry
packet. Ownership comes from this trusted registry; device-supplied ownership
claims are not used. Unknown nodes can be ingested without being exposed to users.
After replacing either bind-mounted registry file, recreate `nex` and `gateway`
so both containers see the new file. Token-registry changes require gateway
recreation; disconnect existing sessions when revoking a credential.

The simulator publishes every five seconds at `25.7617, -80.1918`. Its water
temperature and air humidity are synthetic demonstration values, with humidity
marked uncalibrated. The example registry enrolls `sim-pico-01` and `sim-pico-02`
as public, and `sim-pico-03` as private to `demo-ios`. All anonymous app clients
share `demo-ios` access. A valid optional token for the second demo identity
cannot see that private device. Real hardware needs different IDs and enrollment.

```sh
docker compose stop simulator
docker compose --profile sim up -d simulator
docker compose --profile sim up -d --force-recreate nex gateway
```

Changing simulator cadence uses `SIM_DEVICES` / `SIM_INTERVAL` in `.env`, then
`docker compose --profile sim up -d simulator`.

## Topics and persistence

| Purpose | Transport / name | Producer → consumer |
| --- | --- | --- |
| Sensor telemetry | MQTT `env/v1/<device_id>/telemetry` | Sensor → NATS |
| Raw sensor archive | NATS `env.v1.*.telemetry`, stream `ENV_RAW` | MQTT bridge → worker |
| Phone position archive | NATS `dewin.v1.<userId>.location`, stream `DEWIN_GEO` | Gateway → worker |
| Completed exposure archive | NATS `dewin.v1.<userId>.exposure`, stream `DEWIN_EXPOSURES` | Worker → persistence |
| Request deduplication | JetStream KV `DEWIN_RECEIPTS` | Gateway |
| Immutable exposure/history records | JetStream KV `DEWIN_RESULTS` | Worker → gateway |
| Worker readiness | JetStream KV `DEWIN_HEALTH` | Worker → gateway |
| Phone submission / live result / history | Socket.IO `location:update`, `exposure:update`, `exposure:history` | App ↔ gateway |

Sensors publish only their MQTT topic. Phones use only Socket.IO. Neither needs
native NATS credentials, stream names, or direct JetStream consumer access.

File-backed application streams retain up to 90 days, bounded by size and message
counts. `ENV_RAW` is capped at 256 MiB/50,000 messages, `DEWIN_GEO` at
128 MiB/100,000, and `DEWIN_EXPOSURES` at 256 MiB/100,000. Receipt and result KV
buckets are capped at 128 and 256 MiB respectively, with a 90-day TTL; worker
health is a 1 MiB/60-second bucket. The broker has a 2 GB total file-store budget,
also shared with MQTT protocol state and preserved legacy streams. These caps
do not guarantee 90 days at every sampling rate. Capacity or broker failures
produce a retryable error rather than a successful location ACK.

The worker's `dewin-spatial-v1` durable consumer acknowledges GPS work after the
exposure is persisted. Repeated delivery reuses the stored result. Original
source and receive times survive replay. In-memory sensor/history indexes are
disposable and rebuild from JetStream; the sensor index is bounded to 50,000
distinct packets. Do not scale the spatial worker beyond one instance in this
demo configuration. New sensor data does not rewrite completed exposures.

Named volume `water-monitor_jetstream` preserves broker data across ordinary
container restarts and `down`/`up`. Do not run `down -v`. The old `history` volume
is retained for the earlier prototype and is not used by this gateway.

## Check and operate

```sh
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements.txt
python -m unittest discover -v
python scripts/check_live_api.py --url http://127.0.0.1:8765
```

On Windows use `.venv\Scripts\python`. The live check loads the two API tokens
privately from `.env`, submits synthetic locations, and tests the running real
stack. Use a test environment or demo identities; its test records are durable.
The local mock remains useful for app development without Docker:
`pip install -r requirements-mock.txt`, then `python scripts/mock_api.py`.
Mock data is in memory and is not evidence of JetStream durability.

```sh
docker compose logs --tail 50 gateway nex
docker compose exec nex python -m water_monitor.health
docker compose exec nex nex --disable-upgrade-check --config /tmp/water-nex/config.json workload list
curl -f http://127.0.0.1:8222/healthz
docker stats --no-stream
```

Avoid dumping `.env`, Compose's fully interpolated configuration, or raw GPS
payloads into shared logs. Docker memory limits are configured but the current
Pi kernel lacks memory-controller support, so monitor actual usage.

The existing Debian host and other services remain in place. See
[Pi operations](docs/deployment-zerod.md) for deployment commands and
[Cloudflare routing](docs/cloudflare-tunnel.md) for the public API. Earlier
HA/SQLite and NATS frontend source remains for reference; its old smoke test
is not the acceptance test for the current spatial gateway.
