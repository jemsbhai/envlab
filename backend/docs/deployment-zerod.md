# Backend Pi: zerod

The real Socket.IO gateway and NEX spatial worker are deployed on the Pi using
ARM64 image `water-monitor:gateway`. On 18 October 2026, the real integration
check passed through `https://dewin-api.cbnsndwch.dev`, backed by NATS/JetStream.
The origin is healthy and the named tunnel routes the API to localhost 8765.

**Current demo connection mode:** Socket.IO needs no token or login UI; omit
auth or send `{}` to use shared identity `demo-ios`. All anonymous phones share
that identity's live updates, history, and private demo sensor access. Optional
valid tokens select separate identities; an explicitly invalid token is rejected.
MQTT on LAN port 1883 accepts anonymous publish-only sensor telemetry with no
username/password. Internal broker and tunnel management credentials remain.

The earlier token-identity public check verified invalid-token rejection, WebSocket and polling,
persisted location ACKs, identical retries and conflicts, live simulated
air/water matches, public/private isolation, no-match results, scoped paginated
history/cursors, and reconnect recovery. The local real stack additionally
passed 23 unit tests, full-stack restart recovery, and a broker-only restart
while app sockets stayed connected. Full service-restart recovery has not been
run on the physical Pi. Actual Swift app/Xcode validation remains with iOS.

| Item | Value |
| --- | --- |
| SSH | `ssh zerod` |
| Host | `pi-09.local` / `10.104.0.82` |
| User | `hacker9`; passwordless `sudo -n` |
| Hardware / OS | ARM64 Pi, approximately 4 GB RAM; Debian 13 |
| Project on Pi | `/home/hacker9/team-zero-water-monitor` |
| Docker / Compose | 29.9.1 / v5.6.0 |
| Broker | `nats:2.15.1-alpine` |
| Application image | `water-monitor:gateway`, `linux/arm64` |
| MQTT for sensors | `10.104.0.82:1883`, MQTT 3.1.1 |
| Core NATS / monitoring | Pi loopback `4222` / `8222` |
| API origin | Pi loopback `8765` |
| Live public API | `https://dewin-api.cbnsndwch.dev` |
| Portainer CE | `https://10.104.0.82:9443`, 2.45.2 |

Keep Debian and the pre-existing services on ports 80 and 3000. NATS, NEX, the
gateway, Portainer, and cloudflared are sibling containers. Home Assistant is
stopped; its saved `water-homeassistant_ha_config` volume remains. Portainer
inspects the externally managed backend, but on-disk Compose files are authoritative.
The gateway serves canonical API documents from the read-only `./docs:/app/docs`
mount, so documentation updates do not require an application-image rebuild.
The static interactive explainer is served at `/architecture/` from
`docs/architecture/index.html`. NEX and the gateway use the ARM64
`water-monitor:gateway-demo` image, including the idle-fetch timeout fix.
The old `dewin-events.cbnsndwch.dev` NATS ingress was removed at the API cutover;
it is not an app endpoint.

## Private configuration

Generate secrets on the trusted laptop with `backend/scripts/init_env.py`.
Preserve the deployed broker passwords. Copy only required broker secrets and
`API_CURSOR_SECRET` into the Pi project `.env` (mode 0600). The Pi's
`WATER_MONITOR_IMAGE` selects the transferred ARM64 image. The API listens on
host loopback via `API_HOST_PORT=8765` by default.

Copy these ignored files into the Pi project's `.runtime/` directory:

- `api-clients.json`: personal token hashes and server-assigned user IDs.
- `devices.json`: trusted device visibility and optional `ownerUserId`.
- `cloudflare-tunnel.json`: this tunnel's run credential only.
- `cloudflared.yml`: API hostname → `http://127.0.0.1:8765`, then HTTP 404.

Keep `.runtime/` mode 0700. The registry JSON files are mode 0644 so container
UID 10001 can read their bind mounts; only token hashes are present. The tunnel
credential is mode 0600, owned by UID/GID 1000 for its connector container.
Plaintext app tokens and the Cloudflare account certificate stay on the laptop.
Run token provisioning on the laptop. Ordinary initialization preserves an
existing client registry; enrollment, rotation, and revocation require explicit
registry edits. Keep plaintext app tokens on the laptop.

The gateway loads its token-hash file at startup. After changing it, recreate
the gateway and disconnect existing sessions to revoke a token. After replacing
the bind-mounted device registry, recreate `nex` and `gateway`. The registry is
the authority for both live matching and current history authorization. Device
payloads provide positions, not trusted ownership.

The default simulator enrollment has public `sim-pico-01` / `sim-pico-02` and
`sim-pico-03` private to `demo-ios`. Register each real sensor's actual ID and
intended public/private owner before expecting it in the app. Anonymous MQTT
allows publishing only `env/v1/<device_id>/telemetry`, with subscriptions denied.
Existing optional `sensor` credentials continue to work. Device IDs are not
per-device identity verification. Anonymous app users all share `demo-ios`.

## Deploy or update

Build the image on the laptop to avoid compiling Go on the Pi:

```sh
cd backend
docker buildx build --platform linux/arm64 --load -t water-monitor:gateway .
docker save -o water-monitor-arm64.tar water-monitor:gateway
```

Transfer the image archive and current `backend/` sources without `.env`, private
runtime files, virtual environments, or local data; provision the required
private files separately as above. Preserve remote `.env`, `.runtime/`, and
Docker volumes. After `ssh zerod`:

```sh
cd ~/team-zero-water-monitor
sudo -n docker load -i .runtime/water-monitor-arm64.tar
# Set WATER_MONITOR_IMAGE=water-monitor:gateway in the private .env.
sudo -n docker compose -f compose.yaml -f deploy/websocket.compose.yaml exec -T nats nats-server -t -c /etc/nats/nats.conf
sudo -n docker compose -f compose.yaml -f deploy/websocket.compose.yaml restart nats
sudo -n docker compose -f compose.yaml -f deploy/websocket.compose.yaml --profile sim up -d --no-build --wait
curl -f http://127.0.0.1:8765/healthz
```

The NATS restart applies the new file-store budget. Keep the WebSocket overlay
while preserving this deployment's existing localhost mapping; it is not the
app transport. The new worker replaces the active legacy HA/SQLite workload.
NEX deploys the spatial workload automatically at container startup. Readiness
waits for the retained raw-sensor replay and gateway result-index initialization.

Only after local readiness, apply the named tunnel API route according to
[Cloudflare operations](cloudflare-tunnel.md), then verify the public connection.
Neither a successful image build nor `/healthz` alone proves the phone contract.

## Operate

```sh
cd ~/team-zero-water-monitor
sudo -n docker compose -f compose.yaml -f deploy/websocket.compose.yaml --profile sim ps
sudo -n docker compose -f compose.yaml -f deploy/websocket.compose.yaml logs --tail 50 gateway nex
sudo -n docker compose -f compose.yaml -f deploy/websocket.compose.yaml stop simulator
sudo -n docker compose -f compose.yaml -f deploy/websocket.compose.yaml --profile sim up -d --no-build --wait
sudo -n docker compose exec nex python -m water_monitor.health
curl -f http://127.0.0.1:8765/healthz
curl -f http://127.0.0.1:2000/ready
sudo -n docker stats --no-stream
```

Stopping the simulator leaves real sensor ingestion, spatial processing, and
the app API running. Simulator readings are synthetic at `25.7617, -80.1918`;
the app must label their provenance. Use a separate demo/test fix to exercise
these coordinates rather than changing a real phone location record.

`/healthz` returns 200 only when the gateway's NATS/index path and the recent NEX
worker heartbeat are ready, otherwise 503. It contains no user data. Container
logs suppress token and location payload logging. Do not run `docker compose
config` into shared logs because it interpolates secrets.

All core services restart with Docker (`unless-stopped`). JetStream's named
volume preserves app data; never use `down -v`. Preserve the old history and HA
volumes as well. Memory limits in Compose are not enforced by this Pi's kernel;
monitor real usage. The configured JetStream file-store limit remains enforced.

Portainer is a separate management project:

```sh
sudo -n docker compose -f deploy/portainer.compose.yaml ps
```

Use its private `PORTAINER_ADMIN_PASSWORD` with username `admin`. Its local HTTPS
certificate is self-signed. It has no public tunnel route.

## Verify the real API

From the laptop, with private demo tokens in `backend/.env`:

```sh
cd backend
python scripts/check_live_api.py --url https://dewin-api.cbnsndwch.dev
```

The test creates durable synthetic location records for the two demo identities.
It covers authentication, real Socket.IO transport, position ACK/retry/conflict,
live spatial results, private/public isolation, no-match, history pagination and
reconnect recovery. Report actual completed checks separately from the local
memory-only mock. Controlled broker/worker/gateway restart verification should
also prove retained results, original receipt times, automatic reconnection, and
offline work catch-up before calling durability verified.

For loopback debugging without changing firewall rules:

```sh
ssh -N -L 18765:127.0.0.1:8765 zerod
```

Then run the live check with `--url http://127.0.0.1:18765`. Keep the forward open
until it finishes. Recheck HTTP 200 on the existing ports 80 and 3000 after
deployment. Actual Swift app/Xcode validation remains with the iOS owner.
