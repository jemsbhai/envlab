# Dewin named Cloudflare Tunnel

The API cutover uses the existing `dewin-zerod` tunnel, managed in Cloudflare
account `cbnsndwch`, zone `cbnsndwch.dev`:

```text
https://dewin-api.cbnsndwch.dev
          -> cloudflared on zerod
          -> http://127.0.0.1:8765
          -> Socket.IO gateway /socket.io/ + API health/docs
```

The API is deployed and passed real public end-to-end integration checks on
18 October 2026; see [validation details](deployment-zerod.md). The route carries Socket.IO 4 /
Engine.IO 4, including WebSocket transport and polling. The current demo needs
no secret: send auth `{"token":"0"}` (literal string `"0"`) to share identity
`demo-ios`. Token-free connections also work. Optional valid
tokens still select separate identities. It does not expose native NATS or MQTT.
The old `dewin-events.cbnsndwch.dev` NATS-over-WebSocket ingress rule was removed
at the cutover; the hostname receives the 404 catch-all.

Home Assistant, Portainer, MQTT, Core NATS, and NATS monitoring have no public
tunnel routes. Anonymous app connections intentionally share the demo identity
and its history/live data. `/`, `/healthz`, and the three canonical contract documents are
public service metadata, without per-user data or credentials.

## Credential boundary

- Tunnel UUID: `517a8da6-71eb-448a-b847-a46e376a52b7`.
- Account certificate stays on the laptop in the original private workspace:
  `.runtime/cloudflare-profile/.cloudflared/cert.pem`.
- Keep the existing unrelated `~/.cloudflared` login unchanged.
- Copy only `.runtime/cloudflare-tunnel.json` to the Pi. It can run this one
  tunnel, but it cannot administer the account or DNS. File mode is 0600, owned
  by UID/GID 1000; its parent `.runtime/` is mode 0700.
- Do not copy account certificates, API tokens, or OAuth refresh tokens to the
  Pi, repository, container image, or app.

The distinction is documented by
[Cloudflare's tunnel permissions](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/local-management/tunnel-permissions/).
The connector image is `cloudflare/cloudflared:2026.10.1`, runs as UID/GID 1000
with host networking, publishes no ports, and binds metrics to localhost 2000.

## Route and operate

The Pi's ignored `.runtime/cloudflared.yml` should contain only the API ingress
and a final catch-all:

```yaml
tunnel: 517a8da6-71eb-448a-b847-a46e376a52b7
credentials-file: /run/secrets/tunnel_credentials
metrics: 127.0.0.1:2000
ingress:
  - hostname: dewin-api.cbnsndwch.dev
    service: http://127.0.0.1:8765
  - service: http_status:404
```

First verify origin `/healthz` on the Pi. From the laptop, check that no unrelated
record already occupies the exact API hostname, then create its DNS route using
the existing tunnel UUID and this account's private certificate:

```powershell
$dewinCert = '.runtime/cloudflare-profile/.cloudflared/cert.pem'
$dewinTunnel = '517a8da6-71eb-448a-b847-a46e376a52b7'
cloudflared tunnel --origincert $dewinCert route dns $dewinTunnel dewin-api.cbnsndwch.dev
cloudflared tunnel --origincert $dewinCert info $dewinTunnel
```

Run these in the original private workspace containing the certificate, not a
fresh repo checkout. Do not use `--overwrite-dns` against an unknown record.
The route's proxied CNAME points at
`517a8da6-71eb-448a-b847-a46e376a52b7.cfargotunnel.com`.

On the Pi:

```sh
cd ~/team-zero-water-monitor
sudo -n docker compose -f deploy/cloudflared.compose.yaml up -d --force-recreate
sudo -n docker compose -f deploy/cloudflared.compose.yaml ps
curl -f http://127.0.0.1:2000/ready
sudo -n docker compose -f deploy/cloudflared.compose.yaml logs --tail 50
```

Then verify trusted TLS, public `/healthz`, and the real Socket.IO integration
check. A Cloudflare HTTP 200 alone does not establish authenticated API operation.
Test that the old public NATS hostname no longer provides a NATS connection.

Browser origin restrictions belong to `API_ALLOWED_ORIGINS` in the gateway.
Native iOS uses demo token string `"0"`; token-free access also works. The old NATS WebSocket origin
allowlist in `deploy/nats.conf` does not control this Socket.IO route.

## Revoke or retire

To stop external API access, stop this connector project:

```sh
sudo -n docker compose -f deploy/cloudflared.compose.yaml stop
```

To retire the tunnel permanently, remove only its exact Dewin DNS records from
`cbnsndwch.dev`, then delete this tunnel from the authorized laptop. Deletion
revokes its run credential. Leave unrelated DNS records, tunnels, and account
logins alone. A per-user app-token revocation is separate: remove that user's
token hash, recreate the gateway, and disconnect their existing sessions.
