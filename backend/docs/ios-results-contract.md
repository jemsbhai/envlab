# Dewin iOS meal results

**Superseded:** food tracking is outside the current MVP. The iOS app now uses
[the Socket.IO environmental API](api-v1.md). This file records the earlier
meal-result proposal; do not use it for the current app integration.

This is a separate channel from the environmental telemetry and HA dashboard.
The meal-analysis service produces results; this repository provides the broker,
durable transport, and the integration contract. No nutritional analysis is
derived from the water/temperature simulator.

## Broker-side setup

`ZERO_RESULTS` is deployed on `zerod` with file-backed storage:

| Setting | Value |
| --- | --- |
| Captured subjects | `zero.v1.*.meals.*.result` |
| Retention | Limits; 30 days, 128 MiB, or 100,000 messages, whichever is reached first |
| Maximum result size | 16 KiB |
| Replicas | 1, on this Pi |
| App durable | `zero-app-{clientId}` |
| App filter | `zero.v1.{clientId}.meals.*.result` |
| Acknowledgements | Explicit, after saving locally |
| Fetch | Up to 10 messages, 30-second long poll |
| Optional progress | Core NATS `zero.v1.{clientId}.meals.{mealId}.status` |

Create/inspect the stream and run a transport test from this laptop:

```powershell
.\.venv\Scripts\python scripts/setup_results_stream.py --ssh zerod --check
```

The script executes inside the existing NEX container using its private pipeline
identity. It does not put passwords in command-line arguments, change existing
streams, or create an app-wide administrator credential. The smoke test publishes
a clearly marked failed test result while no pull subscriber is active, fetches
and acknowledges it, checks durable progress after rebinding, and removes only
its own test message and consumer afterward.

The stream persists across container restarts in the existing JetStream volume.
Offline delivery is bounded by the retention limits above and is at least once.
The app should handle duplicates by meal ID and result version/time rather than
incrementing nutrition totals on every delivery.

## Producer contract supplied by the iOS teammate

Publish UTF-8 JSON to `zero.v1.{clientId}.meals.{mealId}.result`. Preserve the
upload's `Zero-Meal-Id` as both the subject meal token and JSON `mealId`.
The upload/analysis service must also carry the originating phone's `clientId`;
an environmental Pico's `device_id` is unrelated.

- `mealId` is required; a mismatch with the uploaded meal is dropped by the app.
- `status`: `analyzed`, `not_food`, or `failed`; the app treats other values as failed.
- `meal.name`: displayed title.
- `meal.totals`: numeric `calories`, `proteinG`, `carbsG`, `fatG`, `fiberG`,
  `sugarG`, `sodiumMg`. Missing fields mean unknown. Do not fill them with zero.
  If totals are absent, the app sums item nutrients.
- `meal.items[]`: `name`, free-text `portion`, and `nutrients` with the same keys.
- `meal.healthScore`: 0–100; the app uses a calorie-weighted daily average.
- `meal.tags[]`: kebab-case strings; `meal.tips[]`: sentences.
- `meal.spokenSummary`: one short sentence for the glasses.
- `error`: short user-facing message for non-analyzed results.
- `processedAt`: ISO 8601 with `Z` or an explicit offset.

All app-visible information belongs in the JSON body because the app ignores
headers. A producer can additionally use a NATS message ID for broker-side
deduplication, but it does not replace `mealId` in the body. Prefer JetStream
publish acknowledgements when the producer needs proof the result was stored;
ordinary Core NATS publishing is also captured by this stream.

Example of a transport-valid failed result, with no fabricated nutrition:

```json
{
  "mealId": "the-original-upload-meal-id",
  "status": "failed",
  "error": "Meal analysis could not complete. Please try again.",
  "processedAt": "2026-10-18T12:31:09-04:00"
}
```

## iOS connection and permission handoff

The earlier proposal used `wss://dewin-events.cbnsndwch.dev`, retired during
the environmental API cutover. The legacy `viewer`
identity can read the environmental live feed only; it cannot operate JetStream
consumers or read meal results. Do not give the app the internal pipeline login.

Before issuing a phone credential, confirm its Swift NATS package/version, WSS
transport support, stable `clientId`, and consumer-creation API. A normal
Cloudflare HTTP tunnel carries NATS-over-WebSocket; it does not make a raw
`nats://` TCP client work over HTTPS. No iOS connection has been verified yet.

Use a credential scoped to that phone's consumer and result/progress subjects,
with its own reply inbox prefix. Consumer creation must constrain the filter
on the server; permitting a generic create API and merely asking the app to
send the right filter does not isolate phones. An older client API may require
server-side consumer creation and app binding instead. Match the actual SDK
before enabling these permissions.
