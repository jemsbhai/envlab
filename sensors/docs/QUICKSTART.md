# PicoTDS Quick Start Guide

Get your TDS meter up and running in 5 minutes!

## 1. Hardware Setup

### What You Need
- Raspberry Pi Pico W
- TDS Meter Shield (analog output)
- USB cable
- Jumper wires

### Wiring
```
TDS Shield    →    Pico W
VCC           →    3V3(OUT)
GND           →    GND
Analog OUT    →    GP26 (ADC0)
```

See [WIRING.md](WIRING.md) for detailed diagrams.

## 2. Software Setup

### Install MicroPython
1. Download from: https://micropython.org/download/RPI_PICO_W/
2. Hold BOOTSEL button while plugging in USB
3. Drag the `.uf2` file to the RPI-RP2 drive

### Install Development Tools

**Option A: Thonny IDE (Recommended for beginners)**
```bash
# macOS
brew install --cask thonny

# Or download from https://thonny.org
```

**Option B: rshell (Command line)**
```bash
pip install rshell
```

## 3. Configure WiFi

Copy `config/wifi.py.example` to `config/wifi.py` and edit:
```python
WIFI_SSID = "your_network_name"
WIFI_PASSWORD = "your_password"
```

## 4. Configure MQTT (Optional)

For IoT integration with Home Assistant:

1. Copy `config/mqtt.py.example` to `config/mqtt.py`
2. Edit with your broker details:
   - Enable `USE_BROKER_DISCOVERY = True` for automatic broker discovery
   - Or set `USE_BROKER_DISCOVERY = False` and specify `MQTT_BROKER` IP
3. Install umqtt library on Pico W:
   - Thonny: Tools → Manage Packages → Search "umqtt.simple" → Install
   - Or run: `import mip; mip.install("umqtt.simple")`

See [MQTT_SETUP.md](MQTT_SETUP.md) for details.

## 5. Upload Code

### Using Thonny
1. Open Thonny
2. Select "MicroPython (Raspberry Pi Pico W)" as interpreter
3. Click "Run" or upload files:
   - `config/wifi.py` → `/wifi.py`
   - `config/tds_config.py` → `/tds_config.py`
   - `config/mqtt.py` → `/mqtt.py` (if using MQTT)
   - `config/web.py` → `/web.py`
   - `src/tds_sensor.py` → `/tds_sensor.py`
   - `src/wifi_connect.py` → `/wifi_connect.py`
   - `src/mqtt_client.py` → `/mqtt_client.py` (if using MQTT)
   - `src/web_server.py` → `/web_server.py`
   - `src/main.py` → `/main.py`

### Using rshell
```bash
rshell -p /dev/tty.usbmodem... connect
cp config/wifi.py /wifi.py
cp config/tds_config.py /tds_config.py
cp config/mqtt.py /mqtt.py  # if using MQTT
cp config/web.py /web.py
cp src/tds_sensor.py /tds_sensor.py
cp src/wifi_connect.py /wifi_connect.py
cp src/mqtt_client.py /mqtt_client.py  # if using MQTT
cp src/web_server.py /web_server.py
cp src/main.py /main.py
```

Or use the provided script:
```bash
./upload.sh
```

## 6. Run It!

The Pico W will automatically run `main.py` on boot. You should see:

```
Initializing PicoTDS...
==================================================
Connecting to WiFi: your_network
...
WiFi connected!
IP Address: 192.168.1.100
TDS sensor initialized
Starting TDS monitoring...
```

Readings will appear every second:
```
[12345] WiFi: OK | MQTT: OK | Web: OK | TDS:  145.2 ppm | V: 0.723V | T: 25.0°C
```

You can also view the status in a web browser by visiting `http://<pico-ip>/` (see WEB_SERVER.md for details).

**Web Server Access:**
- HTML Status: `http://<pico-ip>/`
- JSON Status: `http://<pico-ip>/status`
- API Endpoint: `http://<pico-ip>/api`

## 7. Calibrate (Important!)

Your readings won't be accurate until calibrated. See [CALIBRATION.md](CALIBRATION.md).

Quick calibration:
1. Get a 342 ppm calibration solution
2. Place sensor in solution
3. Note the reading
4. Adjust `TDS_CALIBRATION_FACTOR` in `config/tds_config.py`
5. Re-upload and test

## Common Issues

**"WiFi connection timeout"**
- Check SSID and password in config
- Ensure Pico W is close to router

**"TDS reading is 0"**
- Check wiring (VCC, GND, signal)
- Verify sensor is powered

**"Module not found" errors**
- Ensure all files are uploaded to Pico
- Check file names match exactly
- For MQTT: Install umqtt.simple via Thonny package manager

**"MQTT connection failed"**
- Check broker IP and credentials in config/mqtt.py
- Verify broker is running and accessible
- Ensure umqtt.simple library is installed

## Next Steps

- Add temperature sensor for compensation
- Set up MQTT integration for Home Assistant (see MQTT_SETUP.md)
- Set up data logging to SD card
- Add LCD display for local readings

## Support

- Wiring issues: See [WIRING.md](WIRING.md)
- Calibration: See [CALIBRATION.md](CALIBRATION.md)
- Full documentation: See [README.md](../README.md)
