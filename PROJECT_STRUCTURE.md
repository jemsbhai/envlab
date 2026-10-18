# PicoTDS Project Structure

```
PicoTDS/
├── README.md                      # Main project documentation
├── PROJECT_STRUCTURE.md           # This file
├── .gitignore                     # Git ignore rules
├── requirements.txt               # Python dependencies for development
├── upload.sh                      # Script to upload code to Pico W
│
├── config/                        # Configuration files
│   ├── wifi.py.example           # WiFi config template (rename to wifi.py)
│   ├── mqtt.py.example           # MQTT config template (rename to mqtt.py)
│   ├── web.py                    # Web server configuration
│   └── tds_config.py             # TDS sensor configuration
│
├── src/                          # Source code (MicroPython)
│   ├── main.py                   # Main application entry point
│   ├── tds_sensor.py             # TDS sensor driver
│   ├── wifi_connect.py           # WiFi connection manager
│   ├── mqtt_client.py            # MQTT client for IoT integration
│   └── web_server.py             # HTTP web server for status viewing
│
└── docs/                         # Documentation
    ├── QUICKSTART.md             # Quick start guide
    ├── WIRING.md                 # Wiring diagrams and pinouts
    ├── CALIBRATION.md            # Sensor calibration guide
    ├── MQTT_SETUP.md             # MQTT and Home Assistant setup
    └── WEB_SERVER.md             # Web server access and API
```

## File Descriptions

### Configuration Files

**config/wifi.py** (create from wifi.py.example)
- WiFi network credentials
- Static IP configuration (optional)
- This file is gitignored to protect credentials

**config/tds_config.py**
- ADC pin configuration
- TDS calibration factor
- Temperature compensation settings
- Reading intervals and sample counts

**config/mqtt.py** (create from mqtt.py.example)
- MQTT broker connection settings
- Authentication credentials
- Topic configuration
- Home Assistant auto-discovery settings
- Publishing intervals
- This file is gitignored to protect credentials

**config/web.py**
- Web server enable/disable
- Port configuration
- No credentials needed (public access)

### Source Files

**src/main.py**
- Main application orchestrator
- Initializes WiFi, TDS sensor, MQTT, and web server
- Main reading loop with publishing
- Calibration mode

**src/tds_sensor.py**
- TDS sensor driver class
- ADC reading and voltage conversion
- TDS calculation with temperature compensation
- Calibration functions

**src/wifi_connect.py**
- WiFi connection manager
- Network scanning
- Connection maintenance
- Internet connectivity testing

**src/mqtt_client.py**
- MQTT client implementation
- Connection management with auto-reconnect
- TDS reading publishing
- Home Assistant auto-discovery
- Last Will and Testament (LWT) for status
- Dynamic broker discovery

**src/web_server.py**
- Simple HTTP web server
- HTML status page with beautiful UI
- JSON status endpoint for scripts
- API endpoint with full data
- Non-blocking request handling

### Documentation

**docs/QUICKSTART.md**
- 5-minute setup guide
- Basic wiring
- Code upload instructions

**docs/WIRING.md**
- Detailed wiring diagrams
- Pin reference
- Power considerations
- Troubleshooting

**docs/CALIBRATION.md**
- Why calibration is needed
- Step-by-step calibration procedure
- Multi-point calibration
- Troubleshooting

**docs/MQTT_SETUP.md**
- MQTT broker setup instructions
- PicoTDS MQTT configuration
- Home Assistant auto-discovery
- Manual Home Assistant configuration
- Testing and troubleshooting

**docs/WEB_SERVER.md**
- Web server access via browser
- HTML status page
- JSON and API endpoints
- Configuration options
- Security considerations
- Usage examples (curl, Python, JavaScript)

## Usage Workflow

1. **Setup**: Follow QUICKSTART.md
2. **Configure**: Copy wifi.py.example to wifi.py and add credentials
3. **Wire**: Follow WIRING.md for physical connections
4. **Upload**: Use upload.sh or Thonny IDE
5. **Calibrate**: Follow CALIBRATION.md for accurate readings
6. **MQTT (Optional)**: Follow MQTT_SETUP.md for IoT integration
7. **Deploy**: Pico W auto-runs main.py on boot

## Development

### Adding Features

1. Create new modules in `src/`
2. Add configuration options to `config/`
3. Update documentation in `docs/`
4. Test on Pico W before committing

### Testing

Test individual modules:
```python
# Test TDS sensor
import tds_sensor
sensor = tds_sensor.TDSSensor()
print(sensor.read_tds())

# Test WiFi
import wifi_connect
wifi = wifi_connect.WiFiManager()
wifi.connect()
```

### Deployment

```bash
# Upload all files
./upload.sh

# Or specify port
./upload.sh /dev/tty.usbmodem14201
```
