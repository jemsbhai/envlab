# Dewin: start here for iOS agents

## Scope and current status

Build a map/timeline that submits phone GPS positions and receives nearby air
and water measurements, live and historically. The app does not speak NATS.
Food analysis, glasses, face recognition, and Home Assistant are outside this
mobile MVP.

The real Socket.IO gateway and NEX spatial worker are deployed, backed by
JetStream streams/KV. The public API passed the real integration check on
18 October 2026; see [the deployment notes](../backend/docs/deployment-zerod.md).
Use the connection settings below now. The local mock remains available for
isolated app development.

## Real API connection

| Setting | Value |
| --- | --- |
| Base URL | `https://dewin-api.cbnsndwch.dev` |
| Socket.IO path / namespace | `/socket.io/` / `/` |
| Protocol | Socket.IO 4 / Engine.IO 4 |
| Connect payload | `{"token":"0"}` — token is the literal one-character string `0` |
| App events | `location:update`, `exposure:update`, `exposure:history` |

**Connect with auth payload `{"token":"0"}`.** Use string `"0"`, not numeric
`0`. This is a public demo value; no secret or login UI is needed. Token-free
connections still work. These demo connections share identity `demo-ios`, live updates,
history, and access to that identity's private demo sensor. They are not isolated
from each other. Do not send a user ID in location or history requests.

An optional valid token selects its separate provisioned identity. An explicitly
supplied invalid token is rejected; use `"0"` for shared demo access. Keep any
optional token out of query strings, logs, and source control.
Use a Socket.IO client, not URLSessionWebSocketTask with plain JSON frames or a
NATS client. The former `dewin-events.cbnsndwch.dev` route is retired.
Use HTTPS with normal certificate validation. `/healthz` reports readiness.

For a controlled synthetic test, submit a current-timestamp demo fix at
`25.7617, -80.1918`. Simulator water-temperature and air-humidity observations
are marked `source: "simulated"`; `demo-ios` can see public `sim-pico-01` and
`sim-pico-02` plus its own private `sim-pico-03`. All anonymous app connections
use this same identity. An optional token for the other demo identity sees
only the public sensors. Actual phone positions may correctly return
`no_match` until real nearby devices are registered. Keep test fixes separate
from captured device locations and label simulated measurements in the UI.

## Canonical files

| File | Purpose |
| --- | --- |
| [`backend/docs/api-v1.md`](../backend/docs/api-v1.md) | Events, fields, ACKs, authentication, matching/privacy, history, errors |
| [`backend/docs/api-v1.schema.json`](../backend/docs/api-v1.schema.json) | JSON Schema 2020-12 payload definitions |
| [`backend/docs/api-v1.examples.json`](../backend/docs/api-v1.examples.json) | Synthetic JSON fixtures for UI/decoding tests |
| [`backend/examples/DewinSocket.swift`](../backend/examples/DewinSocket.swift) | Official Swift Socket.IO client starter; configurable URL |
| [`backend/scripts/mock_api.py`](../backend/scripts/mock_api.py) | Local Socket.IO integration mock |
| [`backend/scripts/check_mock_api.py`](../backend/scripts/check_mock_api.py) | Executable contract/transport check |
| [`backend/scripts/check_live_api.py`](../backend/scripts/check_live_api.py) | Real JetStream-backed API integration check |
| [`backend/docs/pico-contract.md`](../backend/docs/pico-contract.md) | MQTT firmware handoff; not the app's API |

The Swift starter has not been compiled in the team's Xcode project. Keep its
manager alive, register listeners before connecting, and confirm compatibility
with the project's installed `socket.io-client-swift` version.

## NOAA air forecast extension: iOS changes now

**Live now, publicly verified on 18 October 2026:** a GPS fix with token `"0"`
returned PM2.5 and ozone forecasts, with the same snapshot returned in history.
Keep the same Socket.IO connection and events. Decode optional
`Exposure.regionalAir` on both `exposure:update` and `exposure:history.items`:

```text
regionalAir?: {
  provider: "NOAA/NWS", dataType: "forecast", label: "NOAA forecast data",
  status: "available" | "partial" | "unavailable", fetchedAt: ISO8601,
  measurements: [{
    metric: "pm2_5" | "ozone", value: number, unit: "µg/m³" | "ppb",
    validFrom: ISO8601, validTo: ISO8601, issuedAt: ISO8601,
    sourceUrl: official NOAA URL
  }], error?: string
}
```

Render a separate **“NOAA forecast data”** card: PM2.5 in `µg/m³`, ozone in
`ppb`, forecast interval and issuance time. Keep local air/water sensor cards
and their provenance unchanged. `status: "no_match"` only means no eligible
nearby physical sensors; show available NOAA forecasts anyway. These are
regional model forecasts, not physical measurements, a 100 m match, or AQI.
Do not calculate a health score or AQI badge from these concentrations.

`available` means both pollutants, `partial` one, `unavailable` none. Missing
`regionalAir` is normal for older history. Show missing/unavailable data as a
gap, never zero. The phone's original timestamp selects the forecast interval;
both live and history carry the same persisted snapshot. No new app request or
provider key is needed. [Optional Swift decoding types](../backend/examples/DewinRegionalAir.swift)
illustrate adding the field without replacing the app's existing exposure model.
Use the synthetic `ExposureWithRegionalAir` fixture for decoding tests. The
canonical `Exposure` and local mock omit NOAA data; the mock does not call NOAA.

Copy/paste for the iOS agent:

> Keep connecting to https://dewin-api.cbnsndwch.dev with Socket.IO auth
> {"token":"0"}. Add optional regionalAir to exposure decoding for live events
> and history. Read backend/docs/api-v1.md and its JSON Schema for the exact
> shape. Display a separate card labeled “NOAA forecast data”: pm2_5 in µg/m³
> and ozone in ppb, with validFrom/validTo and issuedAt. Preserve sensors[] and
> render NOAA independently of matched/no_match. Treat absent/partial/unavailable
> data explicitly; never substitute zero, derive AQI, or call it a local sensor.
> Upsert the stored exposure normally; do not fetch NOAA from the phone.

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
WebSocket so client upgrade paths can be tested. This older local mock retains
its synthetic token fixture; the deployed real demo requires no token. Mock
connect payload:

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
Handle connection failure separately from request error ACKs and timeouts.

## UI and decoding requirements

- Show the position source time, reading time, units, distance, accuracy if known,
  quality, public/private visibility, and simulated/sensor provenance.
- `no_match` is a valid result. Show a data gap, not zeros or a healthy/safe badge.
- Measurements are extensible. Handle missing air or water data, unknown metric
  names, and missing optional rolling statistics. An absent field is unknown.
- Ignore additional response fields. Requests must follow the strict schema.
- Keep offline fixes locally; do not depend on a continuously connected iOS
  background socket. Real history is identity-scoped and persisted by the backend;
  anonymous phones share the `demo-ios` timeline.
- Do not fetch the kiosk's Supabase tables as a substitute for this API contract,
  or reuse broker/Portainer/tunnel credentials in the app.

## Copy/paste task for the iOS agent

> Read `AGENTS.md`, `docs/ios-agent-handoff.md`, and
> `backend/docs/api-v1.md`. Integrate the iOS app with the official Swift
> Socket.IO client using the three defined events. Use the JSON fixtures for
> typed decoding tests. The real base URL is https://dewin-api.cbnsndwch.dev,
> path /socket.io/, namespace /, Engine.IO 4. Connect with auth {"token":"0"};
> the token is the literal one-character STRING "0", not numeric 0. No secret
> or login UI is needed. Demo phones share demo-ios history and
> live results. Optional valid tokens select separate identities. The API is live;
> the local mock is available for isolated live/ACK/history integration.
> Make the base URL configurable and any token optional, retain the SocketManager,
> queue/retry GPS fixes with stable event IDs, upsert exposures, paginate history,
> and recover the disconnect gap on reconnect. Implement matched/no-match,
> missing metrics, private/public, and simulated states without inventing health
> scores. Report mock versus real-server validation separately. Do not change
> event names or schemas without updating
> the shared contract and coordinating with the backend owner.
