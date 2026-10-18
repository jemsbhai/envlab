# Kiosk prototype (card + face check-in)

Status: the kiosk now feeds the Dewin pipeline as a position source for checked-in people; see
[kiosk-presence-integration.md](kiosk-presence-integration.md). What follows is the original standalone
design. The JSONL and Supabase parts remain the kiosk's own visit record and local demo path; they are not
the sensor-to-app transport, and `sensors.jsonl` is no longer a contract sensor firmware writes to. Sensor
nodes publish MQTT per `backend/docs/pico-contract.md`.

Personal exposure record for water and air quality. A venue (home, office, restaurant) runs sensor nodes
and a check-in kiosk. A person taps their card and shows their face; while they are checked in, every
sensor sample taken at the venue is attributed to their visit. Their record is the set of visits with
what they were exposed to: time, mean, minimum and maximum of each channel, attested by the system.

Built at a hardware hackathon, October 2026. Proof of concept: the sensors are hobby grade and the
numbers describe the measurement, not safety.

## Hardware

| Role | Hardware | Code |
|---|---|---|
| Kiosk: camera, face check, cloud sync | Raspberry Pi 5, Camera Module 3 | `pi/` |
| Card reader and reader telemetry | Arduino Nano 33 IoT + RC522 (SPI), USB serial to the Pi | `nano/` |
| Water and air sensor nodes | Pico 2 W on PicoBricks, Arduino UNO R4, TDS meter, DHT11, gas, soil moisture | `sensors/` (teammates) |
| Cloud | Supabase (Postgres 17), REST inserts with the publishable key | schema below |

Wiring for the reader: `docs/nano33iot_rc522_wiring.svg`.

## Repository layout

```
pi/        facekit.py   YuNet detection + SFace recognition; enroll / verify / compare / live / test
           tapwatch.py  serial listener: card tap -> face verify -> checkin / checkout events
           cloudsync.py tails the jsonl logs and pushes them to Postgres (idempotent, offline-safe)
           setup_pi.sh  installs picamera2 + OpenCV, fetches the two ONNX models, writes ~/envlab/fk
           envlab.env.example
nano/      nano_rc522_node/  Arduino sketch: card UID, 1 Hz IMU telemetry, tamper event, ping / rebase
sensors/   sensor firmware and the Pi-side logger that writes ~/envlab/sensors.jsonl (teammates)
docs/      wiring diagram
```

## Running the kiosk (Pi 5)

```bash
git clone https://github.com/jemsbhai/envlab.git ~/envlab/repo
cd ~/envlab/repo/pi && chmod +x setup_pi.sh && ./setup_pi.sh      # once
cp envlab.env.example ~/envlab/.env && nano ~/envlab/.env            # fill in URL and key

~/envlab/fk enroll --id alice            # one template per person, one face in frame
~/envlab/fk verify --id alice            # sanity check; exit 0 on match, 2 otherwise
python3 tapwatch.py --bind alice         # tap alice's card once
python3 tapwatch.py                      # window 1: the kiosk
python3 cloudsync.py                     # window 2: the uplink
```

Runtime data stays under `~/envlab/` (models, templates, logs) and is never committed.

## Data contract between nodes

Everything flows through newline-delimited JSON files under `~/envlab/` on the Pi; `cloudsync.py`
ships them to Postgres within two seconds and never drops a line during an outage.

`events.jsonl` (written by `tapwatch.py`):

```json
{"ts": 1760816280.759, "iso": "2026-10-18T15:38:00", "type": "checkin", "uid": "52A87338", "id": "muntaser", "score": 0.623}
{"ts": 1760816290.644, "iso": "2026-10-18T15:38:10", "type": "checkout", "uid": "52A87338", "id": "muntaser", "start": 1760816280.758, "duration_s": 9.9}
```

`sensors.jsonl` (written by the sensor logger; this is the only thing the sensor side owes the kiosk).
Narrow, one sample per line:

```json
{"ts": 1760810000.5, "node": "pico-greenhouse", "channel": "tds_ppm", "value": 312, "unit": "ppm"}
```

or wide, one sweep per line, every numeric key becomes a channel:

```json
{"ts": "2026-10-18T15:40:00", "node": "uno-r4", "tds_ppm": 312, "water_temp_c": 22.4, "air_temp_c": 24.1, "humidity_pct": 48, "units": {"tds_ppm": "ppm"}}
```

`ts` is epoch seconds or ISO-8601. Use stable channel names: `tds_ppm`, `water_temp_c`, `air_temp_c`,
`humidity_pct`, `gas_raw`, `soil_moisture_pct`.

## Cloud schema (Supabase, Postgres)

- `events(ts, node, type, person_id, card_uid, payload jsonb, client_id unique)`
- `readings(ts, node, channel, value, unit, meta jsonb, client_id unique)`
- view `visits`: one row per checkin/checkout pair
- view `visit_exposure`: per visit and channel: `n_samples`, `avg_value`, `min_value`, `max_value`

The publishable key may insert and select; row level security refuses update and delete.

## Face step, for the record

OpenCV Zoo models: YuNet (`face_detection_yunet_2023mar.onnx`) for detection and SFace
(`face_recognition_sface_2021dec.onnx`) for 128-d embeddings; cosine threshold 0.363 (the OpenCV reference).
On the Pi 5 at 640x480 detection runs at 20 fps on the CPU. Enrollment averages the embedding over a few
seconds of frames with exactly one face visible. Templates are stored as 128 floats plus an int8 copy that
fits on a MIFARE Classic 1K card. Known gap: no liveness check, a printed photo passes.
