# Kiosk presence integration with Dewin

Status, 18 October 2026: implemented in `pi/dewin_presence.py`, verified end to end against the
local mock gateway (`backend/scripts/mock_api.py`). Waiting on two things from the backend owner:
per-user tokens for the enrolled people, and the real gateway URL once it is deployed.

## What the kiosk is in the Dewin architecture

Dewin attaches nearby sensor readings to a user's timeline from positions the user's phone submits
over Socket.IO (`location:update`). The kiosk is a second position source for the same pipeline:
a person without a phone, or indoors without a GPS fix, taps their card and shows their face, and
for as long as they are checked in the kiosk submits `location:update` events on their behalf at the
kiosk's configured WGS84 coordinates, every five seconds, using that person's own personal API token.
The backend does what it does for a phone: spatial join against registered sensors within
`matchRadiusM`, and `exposure:update` records come back to the kiosk's socket for that user.

Nothing in the API changes. The kiosk is an ordinary Socket.IO client acting for the checked-in user.
No user ID is sent; the server derives it from the token, exactly as for the app. Card UIDs, face
templates and check-in events never leave the kiosk.

## Data flow

```text
card tap + face match  (tapwatch.py)  -->  ~/envlab/sessions.json  {person_id: {uid, start}}
                                                   |
                                   dewin_presence.py (one Socket.IO connection per checked-in person)
                                                   |
                       location:update every 5 s at (KIOSK_LAT, KIOSK_LON, KIOSK_ACCURACY_M)
                                                   |
                       exposure:update  -->  ~/envlab/dewin_exposure.jsonl  (the person's exposure record)
check-out tap  -->  session removed  -->  that person's connection is closed
```

Retry semantics follow the contract: a submission that gets no ACK is retried with the same `eventId`
and identical payload; the server answers `duplicate: true` for an already stored event. Events wait
in a bounded per-user queue while the gateway is unreachable; the two-per-second limit is respected
when a backlog drains.

## Configuration on the kiosk Pi

`~/envlab/.env` (see `pi/envlab.env.example`):

```text
DEWIN_API_URL=http://127.0.0.1:8765    # mock today; the deployed gateway URL when it exists
KIOSK_LAT=25.7617                      # installed position of this kiosk, WGS84
KIOSK_LON=-80.1918
KIOSK_ACCURACY_M=5
DEWIN_INTERVAL_S=5
```

`~/envlab/dewin_tokens.json`, never committed: `{"<person_id>": "<personal api token>", ...}`,
keyed by the same person ids used by `facekit.py enroll` and `tapwatch.py --bind`.

Run alongside the kiosk and the uplink:

```bash
python3 ~/envlab/repo/pi/tapwatch.py          # kiosk
python3 ~/envlab/repo/pi/dewin_presence.py    # presence -> Dewin
python3 ~/envlab/repo/pi/cloudsync.py         # optional: the kiosk's own Supabase record (legacy path)
```

Against the mock, use its dev tokens (`dev-only-alice-token`, `dev-only-bob-token`) and the fixture
coordinates above so the synthetic `pico-01` sensor is within range.

## Open points for the backend owner

1. Tokens. The kiosk needs one personal token per enrolled person. For the demo these can be issued
   like app tokens and shared privately. If holding user tokens on a shared kiosk is not acceptable,
   the alternative is a kiosk-scoped token plus a server-trusted binding from card UID to user, with a
   new `presence:update` event; that is an API change and is not implemented here.
2. Gateway URL. `DEWIN_API_URL` switches from the mock to the deployed gateway with no code change.
3. Sensor registration. The kiosk itself publishes no air or water telemetry today (its Nano 33 IoT
   carries only an IMU, used for reader tamper detection). If a DHT11 or other environmental sensor is
   attached to the kiosk, it will publish MQTT per `backend/docs/pico-contract.md` as `kiosk-pi5-01`
   with the kiosk coordinates and must be registered like any other node.

## Not changed

`pi/cloudsync.py` and the Supabase schema remain as the kiosk's own visit record and the local demo
path; they are not a sensor-to-app transport and `sensors.jsonl` is no longer the contract sensor
teammates write to. Sensor firmware publishes MQTT per the backend contract.
