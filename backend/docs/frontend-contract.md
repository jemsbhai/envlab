# Dewin frontend feed

**Legacy development feed:** the current iOS integration uses
[Socket.IO API v1](api-v1.md). Its real gateway is deployed and publicly verified; see
[the deployment notes](deployment-zerod.md) for verified status. This document
records the earlier NATS socket, retired at the API cutover. Its instructions
below are historical; do not use them as the current app API or re-enable a
public unscoped sensor feed for private devices.

The previous public endpoint was **`wss://dewin-events.cbnsndwch.dev`**.
Username: `viewer`. Password: `VIEWER_PASSWORD` from the private backend `.env`.
Subscribe to `env.processed.>`. See [tunnel operations](cloudflare-tunnel.md).

Home Assistant consumes MQTT discovery and state. A separate web frontend can
consume the same processed readings using the **NATS protocol over WebSocket**.
This is not a plain JSON WebSocket endpoint: use an official NATS client.

Enable the optional host listener:

```sh
docker compose -f compose.yaml -f deploy/websocket.compose.yaml up -d --wait
```

The listener binds to `127.0.0.1:8080` on the backend Pi by default; `WS_PORT` in
`.env` overrides the host port if it is occupied. Keep using both `-f`
arguments on subsequent commands, or the next `up` removes that host mapping.
For a teammate's laptop during LAN development, forward it over SSH:

```sh
ssh -L 8080:127.0.0.1:8080 <pi-user>@<pi-ip>
```

Connect to `ws://localhost:8080`, username `viewer`, password `VIEWER_PASSWORD`
from the backend `.env`. This user can subscribe only to `env.processed.>` and
cannot publish. Never place pipeline credentials in a frontend.

| Subject | Subscription |
| --- | --- |
| All live processed readings | `env.processed.>` |
| One device | `env.processed.pico-01.>` |
| One metric | `env.processed.pico-01.water-1.temperature` |

The frontend receives JSON bytes such as:

```json
{
  "schema_version": 1,
  "device_id": "pico-01",
  "sensor_id": "water-1",
  "metric": "temperature",
  "unit": "°C",
  "value": 22.4,
  "rolling_mean": 22.1,
  "sample_count": 12,
  "window_seconds": 60,
  "source": "sensor",
  "location_id": "demo-school",
  "quality": "ok",
  "measured_at": "2026-10-18T18:30:00Z",
  "received_at": "2026-10-18T18:30:00.100Z"
}
```

This is a live Core NATS feed. It has no retained initial snapshot and can have
repeated updates during retries. A subscriber waits for the next sample (normally
five seconds); it should mark values stale using `measured_at`. Original events
are separately durable in JetStream and SQLite. Historical queries and per-person
exposure joins are future API work, not part of this socket.

For browser integration, use the current [NATS JavaScript client](https://github.com/nats-io/nats.js)
and its WebSocket transport. NATS subject subscriptions are the named channels
mentioned in the team notes.

The named Cloudflare tunnel terminates TLS and forwards only to this localhost
WebSocket listener. The browser origin allowlist in `deploy/nats.conf` includes
`https://dewin.cbnsndwch.dev`, localhost ports 3000/5173, and existing Pi web apps.
Add the frontend's actual origin if different, then validate and restart NATS.
Image recognition is outside this pipe.
