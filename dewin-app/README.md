# Dewin

Two kinds of health in one app:

- **Nutrition.** Say **"Hey Dewin"** (or double-press the capture button on your Ray-Ban Metas),
  and the glasses photograph your plate. The server analyzes it, and Dewin shows daily and weekly
  totals, a health breakdown, and tips. Ask "Hey Dewin, how many calories did I eat today?"
- **Air & water.** The phone shares its area (rounded to about 1 km). The server collects open air
  and water sensor data for that area, and Dewin shows it on a map you can scrub back through time.
- **"How you dewin?"** A 90-day report: a score, days over the limit, a timeline with labeled
  spikes, your places ranked, exposures with real units for your doctor, and one action per finding.
  You can share it as a PDF or delete all your data from it.

The app has four tabs:

| Tab | What's there |
|---|---|
| **Home** | "Welcome back, {name}": your 90-day score, food and air/water today, photos to review, quick actions |
| **Food** | Today · Week · Log: calories, nutrients, tips, every meal (rows expand) |
| **Health** | Today · Week · Log · Map: air and water near you now, the week's pattern, an hourly log, and the map with a time scrubber |
| **Settings** | Your first name, glasses, "Hey Dewin", location sharing, server, goals |

```
 glasses ──(Meta DAT SDK)──▶ iPhone ◀──── Socket.IO over WebSocket (Cloudflare Tunnel) ────▶ Pi server
                             │  produce:  meal:submit (photo) · location                      │ analyze meals
                             │  consume:  meal:status · meal:result (pushed, acked)           │ poll OpenAQ / USGS / …
                             │            env:query → stations + time series (ack = API)      │ store time series
                             │            report:get → 90-day report · data:delete            │ compute reports
                             ▼
                 Home · Food (Today/Week/Log) · Health (Today/Week/Log/Map) · Report
```

## Layout

| Path | What |
|---|---|
| `docs/BACKEND_CONTRACT.md` | **Socket.IO events and JSON for the backend team** (draft v3, with the 90-day report and open questions) |
| `ios/project.yml` | XcodeGen spec: team 5A63ZMX7US, `io.occh.dewin`, DAT + Socket.IO packages |
| `ios/Config/App.xcconfig` | Secret placeholders; real values go in gitignored `Secrets.xcconfig` |
| `ios/run-on-phone.sh` | Build, install, launch on your iPhone |
| `ios/Dewin/Sources/Glasses/` | Meta glasses: registration, on-demand camera, capture button, mock glasses |
| `ios/Dewin/Sources/Voice/` | "Hey Dewin" phrase matching, speech output, audio session |
| `ios/Dewin/Sources/Backend/` | Contract types, Socket.IO backend (socket.io-client-swift 16.1.1), mock backend |
| `ios/Dewin/Sources/App/` | App entry, `Router` (tabs and sections), `Brand` palette, `UserProfile` |
| `ios/Dewin/Sources/Environment/` | Air & water: location producer, `env:query` store for the map, contract types, mock stations |
| `ios/Dewin/Sources/Health/` | `NearbyHealthStore`: your area's air and water over 7 days, blended from nearby stations; advice |
| `ios/Dewin/Sources/Report/` | The 90-day report: contract types, store (`report:get`, `data:delete`), mock, screen and PDF |
| `ios/Dewin/Resources/` | App icon, wordmark and accent color from the Dewin logo pack |
| `ios/Dewin/Sources/Data/` | `Meal` model (SwiftData), pipeline, insights (totals, breakdown, tips), voice Q&A (`MealQA`), demo data |
| `ios/Dewin/Sources/Views/` | Home, Food (Today/Week/Log), Health (Today/Week/Log/Map), Meal detail, Settings |

## Run

```bash
cd ios && DEVICE=<your-iphone-id> ./run-on-phone.sh   # id from: xcrun devicectl list devices
```

The app starts on the **mock backend**, which answers on device with sample meals and generated
air and water stations, so everything works before the Pi is reachable. To switch, go to
Settings → Backend → Socket.IO (Pi), enter the tunnel's `https://…` URL and token (if any), and tap Apply.

Simulator launch arguments (debug builds):
- `--mock-glasses`: Meta's mock Ray-Bans, connected automatically
- `--mock-selftest`: presses the mock capture button 3 times
- `--mock-wake-selftest`: turns on "Hey Dewin" and says it 3 times through the mock glasses
- `--mock-ask-selftest`: seeds a week plus a tomato sandwich lunch, then asks 9 questions through the mock glasses
- `--seed-week`: fills today and the past 6 days with demo meals
- `--tab=home|food|health|settings`: opens on that tab
- `--food=today|week|log`, `--health=today|week|log|map`: opens on that section
- `--report`: opens the 90-day report

Settings → Debug also has buttons to simulate a press, simulate "Hey Dewin", and seed or clear data.

## "Hey Dewin"

Recognized **on the glasses** with Meta's on-device speech (`MWDATSpeech`, experimental in
SDK 1.0). Only text crosses Bluetooth, so the phone doesn't record and the glasses stay in normal
audio mode. Turn it on in Settings → Hey Dewin. The first time, Meta AI asks for microphone permission.

After the wake phrase the app waits for the rest of the sentence: a final transcription or about
1.6 s of silence. It accepts common mishearings ("hey devin", "hey do win"…). A bare "Hey Dewin"
waits a little longer in case the question comes as a second utterance.

| You say | Dewin does |
|---|---|
| "Hey Dewin" · "Hey Dewin, log this" | Takes a photo and saves it for review |
| "Hey Dewin, how many calories did I eat today?" | "You've had 1,240 calories today. That leaves 760 of your 2,000 goal." |
| "…how much protein do I have left?" | Compares against your goal in Settings |
| "…what did I have for breakfast yesterday?" | Breakfast / lunch / dinner / snack, by time of day |
| "…how many calories were in my tomato sandwich for lunch?" | Finds the meal by name (searches the past week if no day is given) |
| "…how much bread was in the tomato sandwich?" | Finds the matching item inside the meal |
| "…how am I doing this week on sodium?" | Daily average over the week |

Answers are worked out on the phone from the log (`Data/MealQA.swift`, rule-based, no network)
and spoken through the glasses. They cover calories, protein, carbs, fat, fiber, sugar, sodium
and health score, and mention photos that haven't been analyzed yet. Taking a photo stops the
recognizer, so the app restarts it after each capture.

Meta says apps using experimental features can't be published yet. That's fine while
testing through Developer Mode.

## Health (air & water)

Health › Today, Week and Log use one blended value for **your area**: an inverse-distance-weighted
average of the stations within 15 km of the phone, hour by hour for the last 7 days
(`Health/NearbyHealth.swift`). Today shows the air quality gauge, today's hourly chart, what's in
the air, nearby water, and one piece of advice. Week shows good days, your cleanest hours to be
outside, pollutant averages and water. Log is hour by hour, and rows expand.

Health › **Map** shows the individual stations. Each dot shows the selected metric
(AQI, PM2.5, PM10, ozone or NO₂ for air; quality index, pH, turbidity, dissolved oxygen or
temperature for water), colored by EPA-style health level. Underneath:

- **Time scrubber:** a slider over hourly buckets (3-hourly for 7 days), a play button that replays
  the range, and "Now" to jump back. The range can be 24 h, 3 days or 7 days.
- **Level strip:** the worst level in view for every time bucket, so you can see the day at a glance.
- **Station sheet:** tap a dot for its history chart (with the scrubber time marked) and every reading at that time.

Producer and consumer, both over the same Socket.IO connection:
- **Producer (no API):** `location` is emitted when you allow location and "Share my area" is on
  (Settings → Air & Water). It's rounded to about 1 km and sent after moving about 1 km, every
  15 minutes, or on reconnect.
- **Consumer (API):** `env:query` sends the visible map box and time range, and the server answers
  in the Socket.IO ack with stations and their time series. It's sent again when the map stops moving.

## Status

Verified in the simulator: mock glasses → double-press or "Hey Dewin" → on-demand camera → photo →
stored meal → mock backend → result → spoken summary, 3 times in a row each. Voice questions
(`--mock-ask-selftest`) answer correctly, including a bare "Hey Dewin" followed by the question. The Today and Week dashboards render
with real and demo data. The Air & Water map renders mock stations around a simulated location
in New York, with the scrubber, level strip and AQI coloring working. The camera, button, and Developer Mode flow were verified earlier on your
iPhone with your Gen 1s.

Glasses connection: the app remembers that you want the glasses connected, connects on launch and
after registering, and reconnects whenever it comes back to the foreground. Before this, it only
connected after tapping Settings → Start glasses, which is why Zero stopped taking photos after
iOS closed it.

Not verified yet:
- **The Socket.IO backend against a real server**, including through the tunnel. Only the mock has run so far.
- **Real air and water data**: the map has only shown the on-device mock stations.
- **"Hey Dewin" on your Gen 1s**: speech recognition is experimental, and Gen 1 support isn't
  confirmed. The mock glasses never stop the recognizer after a photo, so the restart logic is
  only exercised on real hardware.
- **Voice questions on your Gen 1s**: answers verified with mock glasses only. Real transcripts may need more filler words or mishearings added to `MealQA`.
