# Dewin: start here for iOS agents

## Scope and current status

Build a map/timeline that submits phone GPS positions and receives nearby air
and water measurements, live and historically. The app does not speak NATS.
Food analysis, glasses, face recognition, and Home Assistant are outside this
mobile MVP.

The NATS/MQTT backend is deployed. **The real Socket.IO gateway and
`https://dewin-api.cbnsndwch.dev` are not deployed yet.** Use the local mock and
fixtures now; the same Socket.IO contract is the target for the real gateway.
Never send Socket.IO frames to the legacy NATS WebSocket endpoint.

## Canonical files

| File | Purpose |
| --- | --- |
| [`backend/docs/api-v1.md`](../backend/docs/api-v1.md) | Events, fields, ACKs, authentication, matching/privacy, history, errors |
| [`backend/docs/api-v1.schema.json`](../backend/docs/api-v1.schema.json) | JSON Schema 2020-12 payload definitions |
| [`backend/docs/api-v1.examples.json`](../backend/docs/api-v1.examples.json) | Synthetic JSON fixtures for UI/decoding tests |
| [`backend/examples/DewinSocket.swift`](../backend/examples/DewinSocket.swift) | Official Swift Socket.IO client starter; configurable URL |
| [`backend/scripts/mock_api.py`](../backend/scripts/mock_api.py) | Local Socket.IO integration mock |
| [`backend/scripts/check_mock_api.py`](../backend/scripts/check_mock_api.py) | Executable contract/transport check |
| [`backend/docs/pico-contract.md`](../backend/docs/pico-contract.md) | MQTT firmware handoff; not the app's API |

The Swift starter has not been compiled in the team's Xcode project. Keep its
manager alive, register listeners before connecting, and confirm compatibility
with the project's installed `socket.io-client-swift` version.

## Run the mock

Python 3.11+ on the development computer:

```sh
cd backend
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements-mock.txt
python scripts/mock_api.py
```

On Windows use `.venv\Scripts\python` for Python commands instead of activation.
The server defaults to **`http://127.0.0.1:8765`**, path `/socket.io/`, namespace
`/`, Engine.IO 4 / Socket.IO 4-compatible protocol. It supports polling and
WebSocket so client upgrade paths can be tested. Authentication connect payload:

```json
{"token":"dev-only-alice-token"}
```

The other synthetic user is `dev-only-bob-token`. These are intentionally public
local-test tokens, **not production credentials**. Alice can see a synthetic
private home sensor in addition to the public fixture; Bob sees the public one
only. Requests cannot select another user's identity.

For the iOS Simulator running on the same Mac, use `http://127.0.0.1:8765`.
The Swift starter accepts `url:` for this override. For a physical device, run
the mock with `--host 0.0.0.0`, use that computer's LAN IP, and configure the
app's development local-network/transport permissions as appropriate. Do not
disable production TLS verification. The mock is not intended for public hosting.

Check the protocol from another terminal:

```sh
cd backend
python scripts/check_mock_api.py
```

For a self-contained check that starts and cleans up its own loopback mock:
`python scripts/check_mock_api.py --self-contained`.

The mock stores data in memory and loses it on restart. It exercises the client
contract, not JetStream persistence or the production spatial/history engine.
Submit near the fixture at latitude `25.7617`, longitude `-80.1918` to get a match;
far-away coordinates return `no_match`. All mock readings are marked simulated.

## The three app events

1. `location:update` with `emitWithAck`: send a UUID `eventId`, source timestamp,
   latitude, longitude, optional accuracy, and `schemaVersion: 1`. A successful
   real-server ACK means the position was persisted. Preserve the same event ID
   and payload on timeout/retry.
2. `exposure:update`: receive one JSON object, correlate `locationEventId`, and
   upsert by `exposureId`. The exposure can arrive before or after the position ACK.
3. `exposure:history` with `emitWithAck`: query `[from,to)`, max 31 days/request,
   page size 1–200, then follow `nextCursor` with the same bounds/limit. Query the
   disconnect gap after every reconnect and merge with live records.

Swift ACK callbacks wrap the single response object as `data[0]`. Payloads are
objects, not stringified JSON. Tokens go in the connect payload, not the URL.
Handle connection/auth failure separately from request error ACKs and timeouts.

## UI and decoding requirements

- Show the position source time, reading time, units, distance, accuracy if known,
  quality, public/private visibility, and simulated/sensor provenance.
- `no_match` is a valid result. Show a data gap, not zeros or a healthy/safe badge.
- Measurements are extensible. Handle missing air or water data, unknown metric
  names, and missing optional rolling statistics. An absent field is unknown.
- Ignore additional response fields. Requests must follow the strict schema.
- Keep offline fixes locally; do not depend on a continuously connected iOS
  background socket. Real history is user-scoped and persisted by the backend.
- Do not fetch the kiosk's Supabase tables as a substitute for this API contract,
  or reuse broker/Portainer/tunnel credentials in the app.

## Copy/paste task for the iOS agent

> Read `AGENTS.md`, `docs/ios-agent-handoff.md`, and
> `backend/docs/api-v1.md`. Integrate the iOS app with the official Swift
> Socket.IO client using the three defined events. Use the JSON fixtures for
> typed decoding tests and the local mock for live/ACK/history integration.
> Make the base URL and personal token configurable, retain the SocketManager,
> queue/retry GPS fixes with stable event IDs, upsert exposures, paginate history,
> and recover the disconnect gap on reconnect. Implement matched/no-match,
> missing metrics, private/public, and simulated states without inventing health
> scores. The production gateway is pending; report mock versus real-server
> validation separately. Do not change event names or schemas without updating
> the shared contract and coordinating with the backend owner.
