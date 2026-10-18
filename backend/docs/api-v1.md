# Dewin API v1 — team integration contract

**Status, 18 October 2026:** the real Socket.IO gateway and NEX spatial worker
are deployed on the Pi, using JetStream streams/KV. The public API passed real
end-to-end integration checks; see [validation details](deployment-zerod.md).
The MQTT broker is live. HA is stopped.
Food/meal endpoints are outside v1.

## Connection

| Setting | Value |
| --- | --- |
| Live public API | `https://dewin-api.cbnsndwch.dev` |
| Protocol | Socket.IO 4 / Engine.IO 4, JSON event payloads |
| Socket.IO path | `/socket.io/` |
| Namespace | `/` |
| Transport | WebSocket or Engine.IO polling; use a Socket.IO client |
| Authentication | Socket.IO connect payload `{ "token": "PERSONAL_API_TOKEN" }` |

Each event carries **one JSON object**, not a JSON-encoded string. All app API
keys use camelCase. Dates are RFC 3339 with a timezone; responses use UTC `Z`.
Coordinates use WGS84 decimal degrees. Distances/accuracy use meters.

Each team/demo user receives a separate opaque token out of band. Tokens stay
out of URLs, logs, and source control. No user ID is accepted in an app request:
the server derives it from the token. An invalid/revoked token fails connection
with `connect_error`; there are no anonymous sessions. The app never needs a
NATS client, broker credentials, or JetStream consumer permissions.

The earlier `wss://dewin-events.cbnsndwch.dev` NATS-over-WebSocket route is
retired. Its ingress was removed at the API cutover.

## Events

| Event | Direction | Response |
| --- | --- | --- |
| `location:update` | App → server | Socket.IO ACK: accepted/error |
| `exposure:update` | Server → app | One persisted exposure record |
| `exposure:history` | App → server | Socket.IO ACK: history page/error |

Use `emitWithAck` / `emitWithAck(...).timingOut(after: 10)` for both app requests.
An ACK is a **single JSON object**; Swift receives it as the first callback item.
Register `exposure:update` before sending positions: enrichment may arrive before
or after the acceptance ACK. Match records using `locationEventId`.

## 1. Send location: `location:update`

```json
{
  "schemaVersion": 1,
  "eventId": "d4d01f91-5619-4693-97c5-ff9025daa1d4",
  "measuredAt": "2026-10-18T19:00:00Z",
  "latitude": 25.7617,
  "longitude": -80.1918,
  "accuracyM": 12.5
}
```

Required: `schemaVersion`, UUID `eventId`, `measuredAt`, `latitude`, `longitude`.
`accuracyM` may be omitted or null; otherwise it is a nonnegative number.
Latitude is -90…90, longitude -180…180. All numbers must be finite. Unknown
request fields are rejected to catch integration mistakes.

Start with one update every five seconds while active. Queue offline fixes
locally; preserve their original timestamp and event ID when retrying. The v1
limit is two submissions/second per user and a 16 KiB request. Timestamps over
60 seconds in the future or beyond the 90-day input horizon are rejected.

Successful Socket.IO ACK, sent **after JetStream confirms persistence**:

```json
{
  "ok": true,
  "eventId": "d4d01f91-5619-4693-97c5-ff9025daa1d4",
  "receivedAt": "2026-10-18T19:00:00.120Z",
  "duplicate": false
}
```

This confirms the position is stored; enrichment is asynchronous. Retry a
timeout with the **same** event ID and payload. The identity is `(authenticated
user, eventId)`: an identical retry returns `duplicate: true` and does not create
another exposure. Reusing that ID for different data returns `EVENT_ID_CONFLICT`.
`receivedAt` on a duplicate is the original acceptance time. Dedupe lasts while
the event's retained record exists; it is not an unlimited promise.

## 2. Receive enrichment: `exposure:update`

This same record shape appears in history. The following is an illustrative
fixture, not a live reading or health assessment:

```json
{
  "schemaVersion": 1,
  "exposureId": "a22da6f0-8809-4b35-ae35-cff645bdfad5",
  "locationEventId": "d4d01f91-5619-4693-97c5-ff9025daa1d4",
  "measuredAt": "2026-10-18T19:00:00Z",
  "receivedAt": "2026-10-18T19:00:00.120Z",
  "processedAt": "2026-10-18T19:00:00.200Z",
  "position": {"latitude": 25.7617, "longitude": -80.1918, "accuracyM": 12.5},
  "status": "matched",
  "matchRadiusM": 100,
  "maxSensorAgeSeconds": 300,
  "sensors": [
    {
      "deviceId": "pico-01",
      "locationId": "demo-school",
      "visibility": "public",
      "distanceM": 8.3,
      "position": {"latitude": 25.76175, "longitude": -80.19186},
      "measuredAt": "2026-10-18T18:59:57Z",
      "receivedAt": "2026-10-18T18:59:57.100Z",
      "observedAt": "2026-10-18T18:59:57Z",
      "source": "simulated",
      "measurements": [
        {
          "sensorId": "water-1",
          "medium": "water",
          "metric": "temperature",
          "value": 22.4,
          "unit": "°C",
          "quality": "ok",
          "rollingMean": 22.1,
          "sampleCount": 12,
          "windowSeconds": 60
        }
      ]
    }
  ]
}
```

`medium` is `air` or `water`. Metrics remain extensible strings, for example
`temperature`, `humidity`, `pm2_5`, `co2`, `ph`, `turbidity`, and `conductivity`.
The presence of a metric depends on installed sensors; the API does not synthesize
missing measurements. `unit` is explicit. Temperature is normalized to `°C`.
Rolling statistics may be omitted if unavailable; an absent field is unknown,
not zero. `source` is `sensor` or `simulated`; always label simulated results in UI.

`measuredAt` is the original sensor timestamp and can be null when its clock was
unsynchronized. `receivedAt` is original broker reception time. `observedAt` is
the effective time used for matching: source time when valid, otherwise original
reception time. Sensor timestamps are not rewritten when messages are replayed.

If no eligible, fresh measurement exists, return a normal persisted record with
`status: "no_match"` and `sensors: []`. Show “No nearby data”, not zero values or
a safe/unsafe conclusion. Temperature alone is not a water-quality assessment.

### Matching and privacy rules

- Default radius: 100 m. Use the latest eligible packet for each device **at or
  before the phone's `measuredAt`**, no more than 300 seconds older. A future
  measurement must not be attached to an earlier location.
- Use that packet's coordinates. Compute great-circle distance; return at most
  20 matching devices ordered by distance, then device ID.
- Ownership and visibility come from a trusted server device registry, not
  arbitrary MQTT fields. Public business sensors may match any nearby user.
  Private home sensors may match only their owner, including on history reads.
  Unknown/unregistered devices are not exposed to app users.
- Other users' locations, private devices, and even private match existence are
  never broadcast. Emit only to the authenticated user's sockets.
- `quality: "invalid"` readings are excluded. `uncalibrated` readings may appear
  with that label. Proximity and phone accuracy are context, not proof of consumption.
- Enrichment is an event-time snapshot. Later sensor messages do not silently
  rewrite old exposures. Buffered phone events beyond available sensor history
  receive `no_match` rather than matching today's measurements.

## 3. Load timeline: `exposure:history`

```json
{
  "requestId": "1abed955-a55d-4d82-b2dc-c73b143b919c",
  "from": "2026-10-01T00:00:00Z",
  "to": "2026-10-19T00:00:00Z",
  "limit": 100,
  "cursor": null
}
```

`requestId`, `from`, and `to` are required. Range is `[from, to)` on the phone's
`measuredAt`. Maximum range is 31 days per query; split longer intervals.
`limit` defaults to 100 and is 1…200. `cursor` is omitted/null on the first page.

ACK shape (`items` contains full exposure records from section 2):

```json
{
  "ok": true,
  "requestId": "1abed955-a55d-4d82-b2dc-c73b143b919c",
  "items": [],
  "nextCursor": null
}
```

Results are ordered by `(measuredAt, exposureId)`, oldest first. A non-null opaque
`nextCursor` requests another page with the **same** range and limit. Never parse
or manufacture a cursor. Cursors are scoped to user/query; a changed query,
invalid cursor, or expired cursor returns `INVALID_CURSOR`.

Store and upsert by `exposureId`, including live updates. Live Socket.IO delivery
is best effort; on every reconnect, query history covering the disconnect gap
and merge with live data. A history request sees records persisted at the start
of its pagination snapshot; newly persisted records arrive live or in the next
history query. Do not assume uninterrupted phone background sockets on iOS.

Target retention is **up to 90 days, bounded by configured stream capacity**.
An empty page is normal; it is not evidence of zero exposure. The app should let
users see gaps in data. History is scoped to the authenticated user and current
private-sensor authorization. There is no cross-user history endpoint.

## Errors

Both request events use the same error ACK. If validation occurs before an ID
can be parsed, the response can omit that request's `eventId`/`requestId`.

```json
{
  "ok": false,
  "eventId": "d4d01f91-5619-4693-97c5-ff9025daa1d4",
  "error": {
    "code": "INVALID_PAYLOAD",
    "message": "latitude must be between -90 and 90",
    "field": "latitude",
    "retryable": false
  }
}
```

| Code | Meaning / app action |
| --- | --- |
| `UNAUTHORIZED` | Missing/invalid/revoked token; reconnect only after fixing credentials |
| `INVALID_PAYLOAD` | Missing/wrong fields, bounds, timestamp, or unsupported schema version |
| `EVENT_ID_CONFLICT` | ID already belongs to different data; fix the producer's ID handling |
| `INVALID_CURSOR` | Restart that history query without a cursor |
| `RATE_LIMITED` | Back off; keep the same location event ID when retrying |
| `UNAVAILABLE` | Broker or processor path unavailable; retry with backoff |
| `INTERNAL_ERROR` | Generic server failure; retryable only when marked |

Do not emit success if a persistence operation failed. A transport ACK timeout is
ambiguous; retry idempotently. Errors never include tokens, raw private readings,
or internal broker credentials.

## Firmware / MQTT handoff

**Already live:** `10.104.0.82:1883`, MQTT 3.1.1, QoS 1, retain false.
Username `sensor`; obtain `SENSOR_PASSWORD` privately. Use unique MQTT client IDs.
Topic: `env/v1/<device_id>/telemetry`. The deployed v1 envelope is in
[the Pico contract](pico-contract.md).

**Accepted MQTT extension for spatial matching:** each packet adds a
`position` object with `latitude`/`longitude`; each reading adds `medium: "air"`
or `"water"`. Firmware continues using its existing snake_case fields. These
fields are accepted by the deployed validator and verified through JetStream and
NEX on the physical Pi. Legacy packets remain accepted without them, but new
firmware must include them for the spatial API. Ownership/privacy is provisioned on the
server separately, never inferred from a phone or device's claimed owner ID.

## Architecture boundary

```text
Pico MQTT ──> NATS + JetStream ──> NEX spatial/enrichment worker
                    ↑                         │
iOS Socket.IO ──> API gateway                  │
                    ↑                         ↓
                    └──── persisted exposure records ──> iOS
```

JetStream supplies persistence; gateway/worker code performs validation, spatial
joins, and authorization. No HA or meal pipeline is part of this API. Photo/blob
storage and REST submission are deferred. Public API traffic uses the existing
named Cloudflare Tunnel; only its run credential belongs on the Pi.

Machine-readable payload definitions: [api-v1.schema.json](api-v1.schema.json).
JSON fixtures: [api-v1.examples.json](api-v1.examples.json).
Swift starter: [DewinSocket.swift](../examples/DewinSocket.swift), using the
[official Swift Socket.IO client](https://github.com/socketio/socket.io-client-swift).
The starter has not been compiled against the team's Xcode project; use its
installed client version and keep the manager alive for the session.
