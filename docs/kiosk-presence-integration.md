# Identification kiosk: how it plugs into Dewin

Owner: Muntaser. Code: `pi/` (kiosk) and `nano/` (card reader). Status, 18 October 2026, 17:00:
verified end to end against the live gateway at `https://dewin-api.cbnsndwch.dev` with the shared
demo token. Nothing on the backend needs to change for the demo. Section 3 lists the one thing that
would make it better.

## 1. What the kiosk is, in one paragraph

A Raspberry Pi 5 with a camera and an RC522 card reader. A person taps their card and shows their face;
the kiosk verifies the face against the template bound to that card (one-to-one match, no gallery
search) and opens a session. A second tap closes it. While the session is open the kiosk acts as that
person's phone: it connects to the Socket.IO gateway and submits `location:update` every five seconds
at the kiosk's configured coordinates, exactly as the iOS app does. The backend answers with
`exposure:update`, which the kiosk logs per person. That is the whole integration: the kiosk is an
ordinary app client, and the API is unchanged.

Card UIDs, face templates, names and check-in events never leave the kiosk. Only positions and the
connect token go to the gateway.

## 2. What the backend sees from the kiosk

- Socket.IO connections to `/socket.io/`, namespace `/`, auth `{"token": "0"}` for now, one socket per
  checked-in person. With five people checked in there are five sockets from the Pi's address, all
  under the shared `demo-ios` identity until personal tokens exist.
- `location:update` from each socket every 5 s: `latitude 25.7617, longitude -80.1918, accuracyM 5`
  (the kiosk's configured position; it never moves), `measuredAt` from the Pi's NTP clock, a fresh UUID
  `eventId` per event. Retries after a lost ACK reuse the same `eventId` and payload, so `duplicate:
  true` answers are expected and handled.
- Sockets close on check-out. Nothing is retained on the MQTT side; the kiosk publishes no telemetry
  and has no device to enroll.

The kiosk filters `exposure:update` by `locationEventId` against the events it submitted, so the fact
that every `demo-ios` client receives every record is harmless on our side.

## 3. What would improve it: one token per person

Enrolled ids on the kiosk: `joe`, `katiana`, `muntaser`, `serge`, `vincent`. If the backend issues one
personal token per id (shared privately, same mechanism as app tokens), the kiosk uses them instead of
`0` by editing one file on the Pi (`~/envlab/dewin_tokens.json`, not in git) and each person's history
becomes their own on the backend. No code change on either side. Until then, all kiosk check-ins land
on `demo-ios`.

If holding personal tokens on a shared kiosk is not acceptable, the alternative is a kiosk-scoped token
plus a server-side mapping from a kiosk-supplied person id to a user, with a new event such as
`presence:update`. That is an API change; it is not implemented and not needed for the demo.

## 4. Coordinates

The kiosk position is configuration (`KIOSK_LAT`, `KIOSK_LON` in the Pi's `.env`). It is set to the demo
coordinates so the simulated sensors match. If the kiosk is placed next to a real enrolled sensor node,
set it to that node's coordinates; the spatial join uses `matchRadiusM` 100, so anything within the
room matches.

## 5. Running it (kiosk owner)

```bash
python3 ~/envlab/repo/pi/tapwatch.py          # kiosk: tap + face -> sessions.json, events.jsonl
python3 ~/envlab/repo/pi/dewin_presence.py    # presence: sessions.json -> location:update per person
python3 ~/envlab/repo/pi/cloudsync.py         # optional: the kiosk's own visit record in Supabase
```

`~/envlab/.env` carries `DEWIN_API_URL`, `KIOSK_LAT`, `KIOSK_LON`, `KIOSK_ACCURACY_M`, `DEWIN_INTERVAL_S`
(see `pi/envlab.env.example`). `~/envlab/dewin_tokens.json` maps person id to token.

## 6. Not changed

`pi/cloudsync.py` and the Supabase schema remain the kiosk's own visit record and the local demo path.
They are not a sensor-to-app transport, and `sensors.jsonl` is not a contract anyone writes to. Sensor
firmware publishes MQTT per `backend/docs/pico-contract.md`.
