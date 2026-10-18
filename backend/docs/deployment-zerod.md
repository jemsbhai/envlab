# Live backend: zerod

**Current scope update:** HA's Portainer stack was stopped on 18 October 2026;
its saved volume is retained. The new iOS integration is
[Socket.IO API v1](api-v1.md), pending gateway deployment. The HA URLs and
verification below document the previous prototype. NATS/JetStream, NEX,
the simulator, Portainer, and the tunnel remain deployed.

Deployed and tested on 2026-10-18 via the user's existing SSH profile.

| Item | Value |
| --- | --- |
| SSH | `ssh zerod` |
| Host | `pi-09.local` / `10.104.0.82` |
| User | `hacker9` |
| Actual hardware | Raspberry Pi, ARM64, approximately 4 GB RAM |
| OS | Debian 13 (trixie), 64-bit |
| Project | `/home/hacker9/team-zero-water-monitor` |
| Docker / Compose | 29.9.1 / v5.6.0 |
| Application image | `water-monitor:spatial-contract`, built for `linux/arm64` |
| Broker image | `nats:2.15.1-alpine`, ARM64 |
| MQTT for Picos and HA | `10.104.0.82:1883`, MQTT 3.1.1 |
| Core NATS | Pi localhost `127.0.0.1:4222` |
| Monitoring | Pi localhost `127.0.0.1:8222` |
| Optional NATS WebSocket | Pi localhost `127.0.0.1:8080` |
| Home Assistant Container | `http://10.104.0.82:8123`, version 2026.10.2 |
| Portainer CE | `https://10.104.0.82:9443`, version 2.45.2 |
| Public read-only feed | `wss://dewin-events.cbnsndwch.dev` |

Debian remains the host OS. HA, Portainer, NATS/NEX, and the tunnel connector
are sibling Docker containers. The pre-existing apps on ports 80 and 3000 are
preserved. HA Container has no Supervisor/add-on store; services are managed in
Docker/Portainer instead. This MQTT-only deployment does not grant HA privileged
access or host Bluetooth-management capabilities.

The same generated credentials are in the local workspace `.env` and the Pi's
project `.env` (mode 0600). They are not included in the image or source ZIP.
Use username `sensor` for Picos, `homeassistant` for HA, and `viewer` for the
processed frontend feed. Each password has a correspondingly named variable.

For the UIs, use:

| UI | Username | Password in private `.env` |
| --- | --- | --- |
| Home Assistant | `teamzero` | `HA_ADMIN_PASSWORD` |
| Portainer | `admin` | `PORTAINER_ADMIN_PASSWORD` |

`HA_PASSWORD` is HA's MQTT broker password, separate from its UI administrator
password. Portainer uses a self-signed HTTPS certificate on the local network.
The Dewin dashboard is at `http://10.104.0.82:8123/team-zero/pipes`.

## Operate

After `ssh zerod`:

```sh
cd ~/team-zero-water-monitor
sudo -n docker compose -f compose.yaml -f deploy/websocket.compose.yaml --profile sim ps
sudo -n docker compose -f compose.yaml -f deploy/websocket.compose.yaml logs -f nex simulator
sudo -n docker compose -f compose.yaml -f deploy/websocket.compose.yaml stop simulator
sudo -n docker compose -f compose.yaml -f deploy/websocket.compose.yaml --profile sim up -d --wait
```

Docker starts at boot. The broker, NEX node, and simulator use `unless-stopped`.
NEX automatically deploys the processor when its container starts. Stopping the
simulator leaves all ingestion and processing services running for real Picos.

## HA and Portainer operation

Portainer owns the `water-homeassistant` stack, so HA's Compose definition is
editable in its stack editor. The backend, management UI, and tunnel were
created with external Compose; Portainer can inspect their containers, logs,
and status, while their Compose files remain authoritative on disk.

HA configuration/history/authentication use the named
`water-homeassistant_ha_config` volume. The base `configuration.yaml` is mounted
read-only from `deploy/homeassistant/`; history retention is seven days.
Portainer's state uses `water-management_portainer_data`. Preserve these volumes.

For a fresh equivalent installation on the Pi, generate `.env` and the private
Portainer bootstrap password file, then start the management container:

```sh
cd ~/team-zero-water-monitor
python3 scripts/init_env.py
sudo -n docker compose -f deploy/portainer.compose.yaml up -d
```

With the same `.env` in the laptop workspace and development requirements installed:

```powershell
.\.venv\Scripts\python scripts/setup_homeassistant.py --ha-url http://10.104.0.82:8123 --portainer-url https://10.104.0.82:9443 --portainer-self-signed
```

This imports the HA stack if missing, completes fresh local onboarding, configures
MQTT 3.1.1 at `127.0.0.1:1883`, imports the dedicated Dewin dashboard, and verifies
the six simulated entities. Existing users and MQTT settings are preserved on
rerun. The script's temporary HA login session is revoked afterward.

For routine operations, use Portainer or:

```sh
sudo -n docker logs --tail 50 water-homeassistant-homeassistant-1
sudo -n docker restart water-homeassistant-homeassistant-1
sudo -n docker compose -f deploy/portainer.compose.yaml ps
sudo -n docker compose -f deploy/portainer.compose.yaml logs --tail 50
```

Tunnel permissions and rollback are in [the Cloudflare notes](cloudflare-tunnel.md).
The separate durable meal-results stream and iOS handoff are in
[the iOS results contract](ios-results-contract.md).

## Verification performed on the physical Pi

- Simulated Pico MQTT ingestion into JetStream.
- HA-compatible discovery/state and correct rolling means.
- Duplicate delivery, late measurements, and malformed packet handling.
- Retained discovery, non-retained live states, and HA birth refresh.
- NATS WebSocket processed feed; viewer publishing/raw subscriptions denied.
- Processor downtime plus a broker restart, followed by durable catch-up.
- Broker restart while the processor runs; publisher and processor reconnect.
- Consumer returns to zero pending/unacknowledged messages.
- Live simulated readings received directly over the LAN at `10.104.0.82:1883`.
- Existing HTTP services on ports 80 and 3000 still return HTTP 200.

Real HA was also connected and verified with all six live simulated entities.
All six became unavailable after stopping the simulator, returned after restarting
it, and returned again after restarting HA with its saved MQTT integration.
The `ZERO_RESULTS` stream captured an offline meal-result test, delivered it
through a filtered durable consumer, and preserved explicit ACK progress on
rebind. Phone credentials and an actual Swift app connection still require
the teammate's SDK/transport details.

Memory controller support is disabled in this Pi's kernel, so Docker reports that
the configured container memory ceilings are not enforced. With broker and NEX
processor running, the host had about 3.2 GiB available. Summed process RSS was
about 122 MiB (this sum includes shared pages). The simulator adds another Python
process. JetStream's own disk retention limits remain configured.
After adding HA, Portainer, and cloudflared, the host had about 2.8 GiB available
and 16 GiB free on the root filesystem. The existing web apps still returned 200.

## Repeat the remote smoke test from the laptop

Stop the Pi's simulator first. In one laptop terminal, forward unused local ports:

```sh
ssh -N -L 11883:127.0.0.1:1883 -L 14222:127.0.0.1:4222 -L 18081:127.0.0.1:8080 zerod
```

In a second PowerShell terminal in the local project:

```powershell
$env:MQTT_PORT='11883'
$env:NATS_PORT='14222'
$env:WS_PORT='18081'
.\.venv\Scripts\python scripts/smoke_test.py --ssh zerod --websocket --restarts
```

`--ssh zerod` directs Compose restart/cleanup operations to the Pi. The local port
overrides direct the test's protocol connections through the SSH tunnel. This
test deliberately restarts only this project's Pi services. Close the forwarding
terminal afterward and restart the simulator if desired.


## Sensor contract extension, 18 October 2026

The running NEX/simulator image is now `water-monitor:spatial-contract`. A
synthetic packet with coordinates and three air/water readings was published
over LAN MQTT with QoS 1, captured in `ENV_RAW`, and accepted by the NEX worker.
The complete original packet, including `position` and `medium`, was preserved.
This verifies ingestion, not the pending spatial Socket.IO gateway. Canonical
source and team handoffs now live under `backend/` in `jemsbhai/envlab`.
