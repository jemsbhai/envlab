# envlab collaboration

This repository has concurrent kiosk, sensor, backend, and mobile work. Preserve
other components and their contracts when changing your component.

For the Dewin iOS environmental timeline, start with
[`docs/ios-agent-handoff.md`](docs/ios-agent-handoff.md). Its canonical Socket.IO
contract and payload schemas live under `backend/docs/`. The NATS MQTT backend
is deployed; the new real Socket.IO gateway is pending. A local mock is provided
for client integration. Do not describe the mock as the deployed gateway.

For sensor firmware, start with
[`docs/sensor-agent-handoff.md`](docs/sensor-agent-handoff.md). Its transport is
MQTT 3.1.1 into NATS, with the schema under `backend/water_monitor/`. The earlier
JSONL/Supabase sensor handoff is legacy; do not implement it as the current
sensor-to-app transport. Sensor nodes carry configured latitude/longitude and
typed air/water readings. Keep firmware, app, and server schemas consistent.

The current mobile scope is GPS plus air/water exposure, with authentication,
private/public sensor rules, live results, and history. The app uses Socket.IO,
not a NATS SDK. HA and food tracking are earlier prototype work. The existing
kiosk/Supabase pipeline is a separate component; do not rewrite it to integrate
the app without a concrete task to do so.

Never commit credentials, per-user tokens, tunnel credentials/certificates,
runtime databases, face templates, or real location histories. Examples and
mock tokens are synthetic. Share real demo credentials privately.

When changing the mobile API, update its spec, JSON Schema, fixtures, and mock
together, and coordinate breaking changes with the iOS/backend owners. Do not
invent a new event or payload shape solely in the client.
