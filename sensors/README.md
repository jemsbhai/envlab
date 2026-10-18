# PicoTDS

Raspberry Pi Pico W project for reading TDS (Total Dissolved Solids) measurements using a TDS Meter shield with MQTT support for IoT integration.

## Hardware Requirements

- Raspberry Pi Pico W
- TDS Meter Shield (typically uses analog output)
- Jumper wires
- Water source for testing
- MQTT broker (for IoT integration - optional)

## Wiring

### TDS Shield to Pico W

Typical TDS shield connections:
- VCC → 3.3V or 5V (check your shield specs)
- GND → GND
- Analog Output → GP26 (ADC0) or other ADC pin

Note: Some TDS shields output 0-2.5V analog signal, which is compatible with Pico's ADC.

## Software Setup

### Flash MicroPython to Pico W

1. Download MicroPython for Raspberry Pi Pico W from https://micropython.org/download/RPI_PICO_W/
2. Hold BOOTSEL button while connecting USB
3. Drag and drop the .uf2 file to the RPI-RP2 drive

### Install Dependencies

```bash
# Install thonny for easy development
brew install --cask thonny

# Or use rshell for file transfer
pip install rshell
```

### Upload Code

Using Thonny:
1. Connect Pico W via USB
2. Open Thonny, select MicroPython interpreter
3. Upload all files from config/ and src/ to the device

Using rshell:
```bash
rshell -p /dev/tty.usbmodem... connect
rshell cp config/*.py /
rshell cp src/*.py /
```

Or use the provided upload script:
```bash
./upload.sh
```

## Configuration

### WiFi Configuration

Copy `config/wifi.py.example` to `config/wifi.py` and edit:
```python
WIFI_SSID = "your_network_name"
WIFI_PASSWORD = "your_password"
```

### MQTT Configuration (Optional)

For IoT integration with Home Assistant or other platforms:

1. Copy `config/mqtt.py.example` to `config/mqtt.py`
2. Edit with your broker details:
```python
# For dynamic broker discovery (recommended for changing IPs)
USE_BROKER_DISCOVERY = True
DISCOVERY_TIMEOUT = 15

# Or for static broker IP
USE_BROKER_DISCOVERY = False
MQTT_BROKER = "192.168.1.100"
MQTT_USER = "your_username"
MQTT_PASSWORD = "your_password"
```

The PicoTDS can automatically discover MQTT brokers on the network or use a static IP. See [MQTT_SETUP.md](docs/MQTT_SETUP.md) for detailed instructions.

## Usage

The Pico W will:
1. Connect to WiFi
2. Discover MQTT broker on network (if discovery enabled) or connect to configured broker
3. Start web server for HTTP access
4. Read TDS values from the sensor
5. Display readings on the serial console
6. Publish readings to MQTT topics (if configured)
7. Auto-discover in Home Assistant (if enabled)

## TDS Reading Notes

- TDS is calculated from electrical conductivity
- Typical values:
  - 0-50 ppm: Ultra-pure water
  - 50-500 ppm: Drinking water
  - 500-1000 ppm: Fresh water
  - 1000+ ppm: Brackish/saline water
- Temperature compensation may be needed for accurate readings

## Calibration

Most TDS shields require calibration:
1. Use a known TDS solution (e.g., 342 ppm calibration solution)
2. Adjust the calibration factor in code until readings match

See [CALIBRATION.md](docs/CALIBRATION.md) for detailed calibration procedures.

## MQTT Topics

When MQTT is configured, PicoTDS publishes to:
- `picotds/tds` - TDS value in ppm
- `picotds/voltage` - Voltage reading in volts
- `picotds/temperature` - Temperature in Celsius
- `picotds/reading` - Full reading as JSON
- `picotds/status` - Device status (online/offline)

## Web Server Access

PicoTDS includes a built-in HTTP web server for easy status viewing:

- **HTML Status**: `http://<pico-ip>/` - Beautiful web interface
- **JSON Status**: `http://<pico-ip>/status` - JSON data for scripts
- **API Endpoint**: `http://<pico-ip>/api` - Full API response

See [WEB_SERVER.md](docs/WEB_SERVER.md) for details.

## Documentation

- [QUICKSTART.md](docs/QUICKSTART.md) - 5-minute setup guide
- [WIRING.md](docs/WIRING.md) - Detailed wiring diagrams
- [CALIBRATION.md](docs/CALIBRATION.md) - Sensor calibration
- [MQTT_SETUP.md](docs/MQTT_SETUP.md) - MQTT and Home Assistant integration
- [WEB_SERVER.md](docs/WEB_SERVER.md) - Web server access and API

## License

MIT License
