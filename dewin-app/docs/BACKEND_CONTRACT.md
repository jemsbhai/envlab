# Dewin backend contract (draft v3: Socket.IO)

How the Dewin iPhone app talks to the Dewin server on the Pi, through the Cloudflare Tunnel.
The app's code for this lives in `ios/Dewin/Sources/Backend/` and `ios/Dewin/Sources/Environment/`.
Keep this doc and those files in sync.

> **Air & water now follow the team's envlab API v1**
> ([jemsbhai/envlab › backend/docs/api-v1.md](https://github.com/jemsbhai/envlab/blob/main/backend/docs/api-v1.md)):
> `location:update` (ack), `exposure:update` (push) and `exposure:history` (paged), with a personal
> token in the connect payload. The app implements it in `ios/Dewin/Sources/Envlab/`. The
> `location` and `env:query` events below only describe the on-device mock that runs until the gateway
> is deployed. Meals (`meal:*`) and the 90-day report (`report:get`, `data:delete`) are **proposals**:
> they're not in envlab v1 yet, and the app answers them with its mock.

Dewin does two things:
1. **Nutrition**: the wearer snaps food with their Meta glasses, the server analyzes the photo,
   and the app shows daily and weekly totals.
2. **Air & water**: the app tells the server roughly where the phone is. The server pulls open
   sensor data for that area (e.g. OpenAQ, AirNow, USGS Water Data, EPA) and stores it. The app
   shows it on a map with a time scrubber.

The app is both a **producer** and a **consumer**:

| | Direction | Events | Needs an API? |
|---|---|---|---|
| Producer | app → server | `meal:submit`, `location` | No. The app emits and moves on (meals get an ack so the app knows they're stored). |
| Consumer | server → app | `meal:status`, `meal:result` | The server pushes; the app acks results. |
| Consumer | app → server → app | `env:query`, `report:get` | **Yes**: request/response through the Socket.IO acknowledgement. |
| Privacy | app → server → app | `data:delete` | Yes: the ack confirms the server deleted everything for this `clientId`. |

## Connection

- **Transport:** Socket.IO v4 over WebSocket only (the app sets `forceWebsockets`; no long-polling).
  Default namespace `/` and path `/socket.io/`.
- **URL:** the tunnel's `https://…` origin, entered in the app under Settings → Backend → Socket.IO.
- **Handshake auth** (`socket.handshake.auth`):

  ```json
  { "clientId": "3f2b8c1e-…", "token": "optional-shared-secret", "app": "dewin-ios", "schema": 1 }
  ```

  `clientId` is a UUID per install, also sent as the `clientId` query parameter. When a token is
  set, it also arrives as `Authorization: Bearer <token>`. Reject a bad token in middleware with
  `next(new Error("unauthorized"))`; the app shows the error in Settings.
- **Size:** set `maxHttpBufferSize: 2e6` on the server. The default is 1 MB, and meal photos can
  be up to 1.5 MB.
- **Rooms:** join each socket to a room named after its `clientId`, so results can be sent with
  `io.to(clientId).emit(…)` even after the phone reconnects with a new socket ID.

```js
const io = new Server(httpServer, { maxHttpBufferSize: 2e6, transports: ["websocket"] });
io.use((socket, next) => {
  const { clientId, token } = socket.handshake.auth;
  if (!clientId) return next(new Error("missing clientId"));
  if (process.env.DEWIN_TOKEN && token !== process.env.DEWIN_TOKEN) return next(new Error("unauthorized"));
  next();
});
io.on("connection", (socket) => {
  const { clientId } = socket.handshake.auth;
  socket.join(clientId);
  resendUnackedResults(clientId); // see meal:result
  // handlers below
});
```

## Shared conventions

- JSON objects with camelCase keys, UTF-8. Every message has a `schema` field such as `dewin.meal.result/1`.
- Dates are ISO 8601 with offset, e.g. `2026-10-18T12:31:09-04:00`. Fractional seconds are accepted.
- Unknown fields are ignored on both sides, so adding fields later is safe.
- In any nutrient or reading object, a missing key means unknown, not zero.

---

## Nutrition

### `meal:submit` (app → server, with ack)

```json
{
  "schema": "dewin.meal.submit/1",
  "mealId": "6f1c2a9e-0b7d-4c55-9a51-3c1d2e4f5a6b",
  "clientId": "3f2b8c1e-…",
  "capturedAt": "2026-10-18T12:30:41-04:00",
  "timezone": "America/New_York",
  "source": "glasses",
  "trigger": "wake_word",
  "contentType": "image/jpeg",
  "width": 1280,
  "height": 960,
  "image": "<binary JPEG>"
}
```

- `image` arrives as a binary attachment: a `Buffer` in Node, or `bytes` in python-socketio.
- `source`: `glasses` | `photo_library`. `trigger`: `wake_word` | `capture_button` | `photo_library`.
- The JPEG is at most 1280 px on the longest side, typically 150–300 KB, and never over 1.5 MB.
- **Ack** once the meal is stored: `callback({ ok: true })`, or `callback({ ok: false, error: "…" })`.
  With no ack within 30 s, the app keeps the meal queued and sends it again with the same
  `mealId` on reconnect. **Dedupe on `mealId`.**

### `meal:status` (server → app, optional)

```json
{ "schema": "dewin.meal.status/1", "mealId": "6f1c2a9e-…", "stage": "analyzing" }
```

`stage`: `received` | `analyzing`. Display only, best effort.

### `meal:result` (server → app, app acks)

```json
{
  "schema": "dewin.meal.result/1",
  "mealId": "6f1c2a9e-…",
  "status": "analyzed",
  "processedAt": "2026-10-18T12:31:09-04:00",
  "meal": {
    "name": "Tomato sandwich",
    "totals": { "calories": 356, "proteinG": 9, "carbsG": 51, "fatG": 12,
                "fiberG": 3.5, "sugarG": 5, "sodiumMg": 574 },
    "items": [
      { "name": "Sourdough bread", "portion": "2 slices",
        "nutrients": { "calories": 240, "proteinG": 8, "carbsG": 46, "fatG": 2,
                       "fiberG": 2, "sugarG": 2, "sodiumMg": 480 } },
      { "name": "Tomato", "portion": "4 slices",
        "nutrients": { "calories": 22, "proteinG": 1, "carbsG": 5, "fatG": 0,
                       "fiberG": 1.5, "sugarG": 3, "sodiumMg": 6 } },
      { "name": "Mayonnaise", "portion": "1 tbsp",
        "nutrients": { "calories": 94, "proteinG": 0, "carbsG": 0, "fatG": 10,
                       "fiberG": 0, "sugarG": 0, "sodiumMg": 88 } }
    ],
    "healthScore": 62,
    "tags": ["vegetarian", "high-sodium"],
    "tips": ["Swap mayo for avocado to cut saturated fat and add fiber."],
    "spokenSummary": "Tomato sandwich, about 360 calories."
  }
}
```

When the photo isn't food, or the analysis fails, leave out `meal` and send `error`:

```json
{ "schema": "dewin.meal.result/1", "mealId": "6f1c2a9e-…", "status": "not_food",
  "processedAt": "2026-10-18T12:31:09-04:00", "error": "No food detected in the photo." }
```

| Field | What the app does with it |
|---|---|
| `mealId` | **Required.** Must match the submitted `mealId`, or the result is dropped |
| `status` | **Required.** `analyzed` \| `not_food` \| `failed`; anything else counts as failed |
| `meal.name` | Meal title |
| `meal.totals` | `calories`, `proteinG`, `carbsG`, `fatG`, `fiberG`, `sugarG`, `sodiumMg`. These drive the totals and charts. If missing, the app adds up `items` |
| `meal.items[]` | `name`, `portion` (free text), `nutrients`. Keep names specific ("Sourdough bread"), because voice questions match on them |
| `meal.healthScore` | 0–100 badge. The daily score is a calorie-weighted average |
| `meal.tags[]` | kebab-case chips |
| `meal.tips[]` | Sentences. The latest meal's first tip appears in Today's tips |
| `meal.spokenSummary` | Read aloud through the glasses. If absent, the app builds one |
| `error` | Shown when `status` isn't `analyzed` |

**Delivery:** emit with an ack, `io.to(clientId).timeout(10_000).emit("meal:result", result, cb)`.
The app acks `{ ok: true, mealId }` after saving the result. **Keep results until they're acked,
and resend unacked ones when that `clientId` connects again**, so results produced while the phone
was offline aren't lost. Resending one that was already acked is harmless; the app ignores repeats.

---

## Air & water

### `location` (app → server, no ack)

```json
{
  "schema": "dewin.location/1",
  "clientId": "3f2b8c1e-…",
  "lat": 40.71,
  "lon": -74.01,
  "accuracyM": 1000,
  "recordedAt": "2026-10-18T15:48:49-04:00"
}
```

- Rounded on the phone to 2 decimals (about 1 km). The server only needs the area.
- Sent when the user allows location and "Share my area" is on (the default). It goes out on launch,
  then after moving about 1 km or every 15 minutes while the app is open, and again on reconnect.
- **Server job:** add the area to the set it collects for, e.g. a geohash-5 cell (about 5 km)
  plus its neighbors. Poll open data for those cells on a schedule, and store readings in a time
  series (TimescaleDB, InfluxDB, or SQLite are all fine on a Pi). Drop areas nobody has pinged
  for N days.

### `env:query` (app → server, the answer comes back in the ack)

This is the consumer API behind the map. The app asks for the visible map box and the scrubber's time range.

```json
{
  "schema": "dewin.env.query/1",
  "clientId": "3f2b8c1e-…",
  "bbox": { "minLat": 40.62, "minLon": -74.10, "maxLat": 40.80, "maxLon": -73.92 },
  "from": "2026-10-17T15:49:00-04:00",
  "to": "2026-10-18T15:49:00-04:00",
  "stepMinutes": 60,
  "kinds": ["air"]
}
```

- Sent when the map stops moving, and when the user changes Air/Water or the range.
- `stepMinutes`: 60 for the 24 h and 3-day ranges, 180 for 7 days. Average the readings into buckets of that size.
- `kinds`: `air` and/or `water`.
- Answer within 15 s: `callback(series)`.

```json
{
  "schema": "dewin.env.series/1",
  "from": "2026-10-17T15:49:00-04:00",
  "to": "2026-10-18T15:49:00-04:00",
  "stepMinutes": 60,
  "stations": [
    {
      "id": "openaq-2178",
      "kind": "air",
      "name": "Manhattan / IS 143",
      "lat": 40.8484,
      "lon": -73.9346,
      "source": "OpenAQ",
      "readings": [
        { "t": "2026-10-18T14:00:00-04:00",
          "values": { "aqi": 52, "pm25": 9.4, "pm10": 16, "o3": 41, "no2": 22 } },
        { "t": "2026-10-18T15:00:00-04:00",
          "values": { "aqi": 48, "pm25": 8.6, "pm10": 15, "o3": 44, "no2": 19 } }
      ]
    },
    {
      "id": "usgs-01376500",
      "kind": "water",
      "name": "Hackensack River at New Milford",
      "lat": 40.9476,
      "lon": -74.0187,
      "source": "USGS",
      "readings": [
        { "t": "2026-10-18T15:00:00-04:00",
          "values": { "wqi": 78, "ph": 7.4, "turbidity": 3.1, "dissolvedOxygen": 8.2, "temperature": 14.5 } }
      ]
    }
  ]
}
```

- `readings`: oldest first, one per bucket. Leave out buckets with no data; the app treats a gap
  of over 3 steps as "no reading".
- On failure, reply `{ "stations": [], "error": "short message" }`; the app shows the message above the map.
- Keep replies under about 1 MB: cap the number of stations (e.g. the 150 nearest the box center).

**Metric keys** (send the ones you have):

| Kind | Key | Unit | How the app colors it |
|---|---|---|---|
| air | `aqi` | US AQI 0–500 | EPA categories (≤50 good … >200 hazardous) |
| air | `pm25` | µg/m³ | EPA 2024 PM2.5 breakpoints |
| air | `pm10` | µg/m³ | EPA breakpoints |
| air | `o3` | ppb | 8 h breakpoints |
| air | `no2` | ppb | 1 h breakpoints |
| water | `wqi` | 0–100, higher is better | ≥90 good, ≥70 moderate, ≥50 fair, ≥25 poor |
| water | `ph` | pH | 6.5–8.5 good |
| water | `turbidity` | NTU | ≤1 good, ≤5 moderate |
| water | `dissolvedOxygen` | mg/L | ≥7 good, <3 hazardous |
| water | `temperature` | °C | ≤20 good |

If a source doesn't give an AQI, compute it from `pm25` (and `o3` where available) on the server
so every air station has `aqi`, which is what the map shows by default. The same goes for water and `wqi`.

---

## 90-day report ("How you dewin?")

The report the app shows under Health and on Home, and that the user can share with their doctor
as a PDF. **The server computes it**: it is the only side with the full location trail, the
Dewin sensor readings and the public data. The app only renders it.

### `report:get` (app → server, the answer comes back in the ack)

```json
{ "schema": "dewin.report.get/1", "clientId": "3f2b8c1e-…", "days": 90, "timezone": "America/New_York" }
```

Answer within 20 s with `callback(report)`, or `callback({ "error": "short message" })`.

```json
{
  "schema": "dewin.report/1",
  "days": 90,
  "from": "2026-03-01T00:00:00-05:00",
  "to": "2026-05-29T00:00:00-04:00",
  "score": 72,
  "summary": "Your air was worse than 68% of your city. Your water was clean.",
  "overLimit": [
    { "key": "air", "label": "Air", "days": 14, "level": "bad" },
    { "key": "water", "label": "Water", "days": 2, "level": "good" },
    { "key": "co2Indoor", "label": "CO2 indoors", "days": 31, "level": "bad" }
  ],
  "timeline": [ { "date": "2026-03-01T00:00:00-05:00", "level": "good" }, "… one per day, oldest first …" ],
  "spikes": [
    { "date": "2026-03-14T00:00:00-04:00", "label": "wildfire smoke" },
    { "date": "2026-04-02T00:00:00-04:00", "label": "school bus loop, 8am" },
    { "date": "2026-05-09T00:00:00-04:00", "label": "water cloudy at home" }
  ],
  "places": [
    { "id": "commute", "name": "Commute (Route 12 bus)", "level": "bad", "share": 1.0, "note": "worst 30 min of your day", "verified": false },
    { "id": "school", "name": "Lincoln Elementary pickup", "level": "bad", "share": 0.82, "verified": false },
    { "id": "office", "name": "Office", "level": "neutral", "share": 0.55, "note": "CO2 high after 2pm", "verified": false },
    { "id": "home", "name": "Home", "level": "good", "share": 0.22, "note": "tap verified by your Dewin", "verified": true },
    { "id": "cafe", "name": "Lucy's Café", "level": "good", "share": 0.15, "note": "Dewin Verified", "verified": true }
  ],
  "exposures": [
    { "key": "pm25", "label": "Fine particles (PM2.5)", "unit": "µg/m³", "average": 11.4, "limit": "≤ 9", "worst": 87, "worstDate": "2026-03-14T00:00:00-04:00", "withinLimit": false },
    { "key": "voc", "label": "Fumes (VOCs)", "unit": "ppb", "average": 210, "limit": "≤ 500", "worst": 1340, "worstDate": "2026-04-02T00:00:00-04:00", "withinLimit": true },
    { "key": "co2", "label": "CO2 (indoors)", "unit": "ppm", "average": 870, "limit": "≤ 1,000", "worst": 2150, "worstDate": "2026-04-28T00:00:00-04:00", "withinLimit": true },
    { "key": "ph", "label": "Water pH", "unit": "", "average": 7.3, "limit": "6.5–8.5", "worst": 8.7, "worstDate": "2026-05-09T00:00:00-04:00", "withinLimit": true },
    { "key": "turbidity", "label": "Water cloudiness", "unit": "NTU", "average": 0.4, "limit": "≤ 1", "worst": 4.2, "worstDate": "2026-05-09T00:00:00-04:00", "withinLimit": true }
  ],
  "body": { "device": "Apple Watch", "highAirDays": 14, "restingHeartRateDelta": 6, "sleepScoreDelta": -11, "symptom": "cough", "symptomDays": 5 },
  "actions": [
    { "id": "commute", "source": "Commute", "level": "bad", "text": "Take the 7:40 instead of the 8:10; readings on that bus are 40% lower before 8am." },
    { "id": "school", "source": "School pickup", "level": "bad", "text": "Wait inside or 50 m from the bus loop; the spike lasts 12 minutes." },
    { "id": "office", "source": "Office", "level": "neutral", "text": "Open a window or ask facilities about ventilation after 2pm." },
    { "id": "water", "source": "Home water (the 2 days)", "level": "neutral", "text": "Both days followed a city main flush; run the tap 2 minutes if the water looks cloudy." },
    { "id": "smoke", "source": "Wildfire day", "level": "bad", "text": "Run a HEPA purifier in the bedroom on smoke days; we'll alert you the night before." }
  ],
  "sources": {
    "text": "Sources: your Dewin home unit, 11 Dewin sensors you visited, EPA AirNow, NYC water utility.",
    "estimatedNote": "Readings labeled 'estimated' came from public data, not a Dewin sensor."
  }
}
```

| Field | Rules |
|---|---|
| `score` | 0–100, higher is better. The app colors it aqua at ≥ 70, orange below |
| `summary` | One plain sentence. Compare with the city, then say the water result |
| `level` (everywhere) | `good` (aqua) · `neutral` (gray) · `bad` (orange). The report uses only these three |
| `overLimit` | Usually 3 tiles. `days` out of `days` in the report. The doctor reads this row first |
| `timeline` | Exactly `days` entries, oldest first, one per local calendar day |
| `spikes` | 3–4 at most. `label` is lowercase and specific ("school bus loop, 8am") |
| `places` | Ranked worst first. `share` (0–1) sets the bar length, and the worst place is 1. `verified` = measured by a Dewin sensor |
| `exposures` | The only place with real units. `limit` is display text because some limits are ranges |
| `body` | Leave it out unless a wearable is connected. The app writes the sentence from the numbers |
| `actions` | **One action per finding, never a lecture.** Tie each to a source the user recognizes |
| `sources` | Name every source. Anything from public data rather than a Dewin sensor is "estimated" |

### `data:delete` (app → server, with ack)

```json
{ "schema": "dewin.data.delete/1", "clientId": "3f2b8c1e-…" }
```

Delete everything stored for that `clientId`: meals and photos, results, location history,
reports, and readings from that user's own Dewin units. Then `callback({ ok: true })`. The app only
deletes its local copy after the ack, and then starts over with a new `clientId`.

---

## What the app does

1. **Meals:** saves the photo locally first. Glasses photos wait in "To review" until the user
   swipes Send. Then it emits `meal:submit`. Without an ack, the meal stays queued and is resent
   on reconnect. On `meal:result` it saves the nutrition, acks, and speaks the summary (only for
   meals sent in the last 5 minutes). Totals, the health breakdown, tips, and "Hey Dewin" voice
   questions are all computed on the phone.
2. **Air & water:** emits `location` as described above. It calls `env:query` for whatever the map shows,
   and for a box of about ±9 km around the phone over 7 days to fill Health › Today, Week and Log.
3. **Report:** calls `report:get` when Home or Health › Today appears, and when the report opens.
   "Share with my doctor" makes a PDF on the phone. "Delete my data" calls `data:delete`.
4. **Mock mode:** until the server is ready, Settings → Backend → Mock answers meals, `env:query`
   (generated stations) and `report:get` (the design mockup's report) on the phone. Switch to Socket.IO once the tunnel URL works.

## Quick test without the app

```js
// npm i socket.io-client
const { io } = require("socket.io-client");
const s = io("https://your-tunnel.example.com", { transports: ["websocket"], auth: { clientId: "test-1" } });
s.on("connect", async () => {
  s.emit("location", { schema: "dewin.location/1", clientId: "test-1", lat: 40.71, lon: -74.01,
                       accuracyM: 1000, recordedAt: new Date().toISOString() });
  const now = Date.now();
  const reply = await s.timeout(15000).emitWithAck("env:query", {
    schema: "dewin.env.query/1", clientId: "test-1",
    bbox: { minLat: 40.6, minLon: -74.1, maxLat: 40.8, maxLon: -73.9 },
    from: new Date(now - 86400e3).toISOString(), to: new Date(now).toISOString(),
    stepMinutes: 60, kinds: ["air"] });
  console.log(reply.stations.length, "stations");
  s.close();
});
```

## Open questions

1. Auth: a shared token for now, or per-user accounts later?
2. Which open data sources for water? USGS Water Data has continuous sensors (temperature, DO, turbidity,
   pH, conductance) but no WQI, so the server needs to compute one.
3. Should `env:query` also return a gridded layer (a heatmap) as well as stations?
4. Live updates: if wanted, the server can emit `env:update` with new readings to the client's room. The app would add them to the map without re-querying.
