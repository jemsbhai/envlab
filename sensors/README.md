# sensors

Sensor-node firmware and the Pi-side logger go here (one folder per node, e.g. `pico_greenhouse/`, `uno_r4_water/`,
plus `logger/` for the Pi script that reads them).

The one thing this side owes the kiosk: append one JSON object per line to `~/envlab/sensors.jsonl` on the Pi 5.

```json
{"ts": 1760810000.5, "node": "pico-greenhouse", "channel": "tds_ppm", "value": 312, "unit": "ppm"}
```

or one sweep per line (every numeric key becomes a channel):

```json
{"ts": "2026-10-18T15:40:00", "node": "uno-r4", "tds_ppm": 312, "water_temp_c": 22.4, "air_temp_c": 24.1, "humidity_pct": 48}
```

`ts` is epoch seconds or ISO-8601. Channel names to use: `tds_ppm`, `water_temp_c`, `air_temp_c`, `humidity_pct`,
`gas_raw`, `soil_moisture_pct`. `cloudsync.py` picks the file up within two seconds and the readings appear in the
`visit_exposure` view for whoever is checked in at that moment.
