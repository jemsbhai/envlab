# Dewin public feed

The named Cloudflare Tunnel `dewin-zerod` runs on the backend Pi and exposes:

```text
wss://dewin-events.cbnsndwch.dev
            -> cloudflared on zerod
            -> http://127.0.0.1:8080
            -> NATS WebSocket, viewer login only
```

Subscribe to `env.processed.>` with username `viewer` and `VIEWER_PASSWORD`
from `.env`. Use a NATS WebSocket client; this endpoint speaks NATS, rather than
plain JSON frames. It does not serve a webpage. HA, Portainer, MQTT publishing,
Core NATS, and NATS monitoring have no public tunnel routes.

## Credentials and account management

- Cloudflare account: `cbnsndwch`; zone: `cbnsndwch.dev`.
- Tunnel ID: `517a8da6-71eb-448a-b847-a46e376a52b7`.
- Account certificate stays on this laptop at
  `.runtime/cloudflare-profile/.cloudflared/cert.pem`.
  The existing `~/.cloudflared` login is preserved.
- Only `.runtime/cloudflare-tunnel.json`, which can run this one tunnel, is
  copied to the Pi. It is mode 0600, owned by UID/GID 1000, matching the
  unprivileged connector container's user. Its parent directory is mode 0700.
- No Cloudflare account certificate, OAuth refresh token, or account API token
  is copied to the Pi. Private runtime files are ignored by Git and Docker builds.

Cloudflare documents the distinction between
[account certificates and tunnel credentials](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/local-management/tunnel-permissions/).

The generated `.runtime/cloudflared.yml` contains the tunnel ID, credential mount
path, the single hostname-to-localhost route, and a final HTTP 404 catch-all.
The connector uses `cloudflare/cloudflared:2026.10.1`, has no published ports,
and restarts with Docker. Metrics bind only to Pi localhost port 2000.

## Operate on the Pi

```sh
cd ~/team-zero-water-monitor
sudo -n docker compose -f deploy/cloudflared.compose.yaml ps
sudo -n docker compose -f deploy/cloudflared.compose.yaml logs --tail 50
curl -f http://127.0.0.1:2000/ready
sudo -n docker compose -f deploy/cloudflared.compose.yaml stop
sudo -n docker compose -f deploy/cloudflared.compose.yaml up -d
```

The source Compose file expects the two private runtime files already present.
It deliberately cannot create a tunnel or change DNS from the Pi.

## Manage or revoke from this laptop

In PowerShell from the project folder:

```powershell
$dewinCert = '.runtime/cloudflare-profile/.cloudflared/cert.pem'
$dewinTunnel = '517a8da6-71eb-448a-b847-a46e376a52b7'
cloudflared tunnel --origincert $dewinCert info $dewinTunnel
```

DNS was created without overwriting an existing record. Its proxied CNAME is
`dewin-events.cbnsndwch.dev` ->
`517a8da6-71eb-448a-b847-a46e376a52b7.cfargotunnel.com`.
To retire it, stop the connector, remove this exact DNS record from the
`cbnsndwch.dev` zone, then delete this exact tunnel from the laptop. Deleting
the tunnel revokes its run credential. Leave unrelated tunnels and DNS records alone.

## Browser origins and access

`deploy/nats.conf` explicitly allows `https://dewin.cbnsndwch.dev`, localhost
ports 3000/5173, and the existing Pi web apps on ports 80/3000. Add the teammate's
actual frontend origin if it differs. NATS requires the full scheme, hostname,
and port. Validate the configuration and **restart** NATS after changing the
WebSocket block; this block cannot be changed with a HUP reload:

```sh
sudo -n docker compose exec -T nats nats-server -t -c /etc/nats/nats.conf
sudo -n docker compose -f compose.yaml -f deploy/websocket.compose.yaml restart nats
```

Origin checks apply to browsers. All clients must still authenticate. Viewer
credentials allow WebSocket connections and processed subscriptions only;
publishing and raw/history/system subscriptions are denied. Sensor and HA logins
allow MQTT only; pipeline credentials allow local Core NATS/MQTT, with no
WebSocket connection types. No anonymous or Cloudflare Access bypass login exists.

Verified through the public hostname: trusted TLS, all three simulated devices,
viewer publish/raw subscription denial, privileged NATS WebSocket login denial,
and allowed/rejected browser Origin handshakes.
