# envlab collaboration

This repository has concurrent kiosk, sensor, backend, and mobile work. Preserve
other components and their contracts when changing your component.

For the Dewin iOS environmental timeline, start with
[`docs/ios-agent-handoff.md`](docs/ios-agent-handoff.md). Its canonical Socket.IO
contract and payload schemas live under `backend/docs/`. The real Socket.IO
gateway and NEX spatial worker are deployed and publicly verified; check
`backend/docs/deployment-zerod.md` for verified deployment status. A local mock
is also provided. Report real-stack and mock validation separately.

For sensor firmware, start with
[`docs/sensor-agent-handoff.md`](docs/sensor-agent-handoff.md). Its transport is
MQTT 3.1.1 into NATS, with the schema under `backend/water_monitor/`. The earlier
JSONL/Supabase sensor handoff is legacy; do not implement it as the current
sensor-to-app transport. Sensor nodes carry configured latitude/longitude and
typed air/water readings. Keep firmware, app, and server schemas consistent.

The current mobile scope is GPS plus air/water exposure, with shared demo access,
private/public sensor rules, live results, and history. The app uses Socket.IO,
not a NATS SDK. HA and food tracking are earlier prototype work. The existing
kiosk/Supabase pipeline is a separate component; do not rewrite it to integrate
the app without a concrete task to do so.

JetStream streams and KV hold the current backend's durable data. In-memory
indexes rebuild from retained messages; the active spatial worker does not use
the old SQLite/HA path. Device visibility and owner come from the backend's
private registry. Unregistered devices must not appear in app results. Label
all simulated observations and preserve event-time matching on replay.

Current hackathon app connection: Socket.IO auth `{"token":"0"}`, literal
one-character string `"0"`, uses shared identity `demo-ios`. Token-free connections
also work. No login UI or secret handoff is needed. Demo phones share that
identity's history and live results. Optional valid tokens retain separate
identities; explicitly invalid tokens fail. Sensor MQTT on LAN port 1883 accepts
anonymous publish-only telemetry with no username/password. Keep management
credentials private; do not remove internal broker/tunnel credentials.

Never commit credentials, per-user tokens, tunnel credentials/certificates,
runtime databases, face templates, or real location histories. Examples and
mock tokens are synthetic. Share real demo credentials privately.

When changing the mobile API, update its spec, JSON Schema, fixtures, and mock
together, and coordinate breaking changes with the iOS/backend owners. Do not
invent a new event or payload shape solely in the client.
