# Pull, configure and flash PicoTDS

The firmware now publishes the Dewin v1 MQTT envelope. The real TDS reading is
marked uncalibrated until calibration is confirmed. Missing temperature stays
unavailable. The LAN demo needs no MQTT username/password or private MQTT config.

1. Pull the shared repo, then open the firmware folder:

   ```sh
   git pull --ff-only origin main
   cd sensors/picoTDS
   python -m pip install -r requirements.txt
   ```

2. Use a Wi-Fi-capable Pico running MicroPython. Wiring and firmware installation
   are in [WIRING.md](WIRING.md). Close Thonny and other serial monitors before
   using `mpremote`. List USB boards with `mpremote connect list`.

3. Preserve your Wi-Fi config. Create it only if missing:

   ```sh
   test -f config/wifi.py || cp config/wifi.py.example config/wifi.py
   ```

   Configure Wi-Fi SSID/password in `config/wifi.py`. No MQTT credentials are
   required. `config/mqtt.py` is optional for device/coordinate overrides; the
   upload script uses `mqtt.py.example` when it is absent. Existing local configs
   are preserved and optional existing MQTT credentials still work. If Wi-Fi or
   custom MQTT config exists only on the board, download/backup it before upload
   using `mpremote ... fs cp :/wifi.py config/wifi.py` (and `mqtt.py` as needed);
   do not overwrite existing local copies.

4. Default demo setup: `10.104.0.82:1883`, no login, device `pico-water-01`,
   location `demo-venue`, public visibility provisioned by Serge. Coordinates
   `25.7617,-80.1918` are a **demo fixture**, shared with the app's demo mode.
   Readings come from the physical sensor. Change device ID for a second board
   and ask Serge to enroll it; configure actual coordinates for real phone GPS.
   For old custom configs, use the current broker; empty `MQTT_USER` and
   `MQTT_PASSWORD` select anonymous mode. See [MQTT setup](MQTT_SETUP.md).

5. Upload and reset (the script installs `umqtt.simple` if missing, validates
   config and prints public `ENROLL` fields):

   ```sh
   bash upload.sh auto
   # Or bash upload.sh /dev/ttyACM0; macOS /dev/tty.usbmodem...; Windows COM3.
   mpremote connect auto repl
   ```

   On Windows without Bash, use PowerShell from this directory:

   ```powershell
   mpremote connect auto mip install umqtt.simple
   mpremote connect auto fs cp config/wifi.py config/tds_config.py config/web.py src/tds_sensor.py src/wifi_connect.py src/mqtt_client.py src/web_server.py src/main.py :/
   mpremote connect auto fs cp config/mqtt.py.example :/mqtt.py
   mpremote connect auto reset
   mpremote connect auto repl
   ```

   To use an existing custom MQTT config in PowerShell, substitute `config/mqtt.py`
   for `config/mqtt.py.example`. Thonny users can copy those same files to the
   board root, naming the MQTT config `/mqtt.py`, then reset.

6. Observe `MQTT connected` and `MQTT PUBACK: pico-water-01 seq ...` every five
   seconds. Send Serge the printed device/location/coordinates if you changed
   them. Ask him to confirm `ENV_RAW`; test the app in demo mode or
   with a fresh phone fix within 100 meters of the configured sensor. Expect
   `exposure:update` with `source: "sensor"`, water `tds` in `ppm`, then history
   recovery. See [MQTT acceptance checks](MQTT_SETUP.md).

Host smoke checks (synthetic hardware/network stubs; not a physical board test):

```sh
python -m unittest discover -s tests -v
python -m compileall -q src
```
