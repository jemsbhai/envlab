# MQTT Setup Guide

This guide explains how to configure PicoTDS to send sensor data to an MQTT broker, including Home Assistant integration.

## What is MQTT?

MQTT (Message Queuing Telemetry Transport) is a lightweight messaging protocol ideal for IoT devices. It allows PicoTDS to publish sensor data to a broker, which can then be consumed by Home Assistant, Node-RED, or other IoT platforms.

## Prerequisites

- Running MQTT broker (Mosquitto, EMQX, Home Assistant MQTT, etc.)
- MQTT broker accessible from your network
- MQTT credentials (username/password if authentication is enabled)

## Setting Up MQTT Broker

### Option 1: Home Assistant (Built-in MQTT)

If you use Home Assistant with the MQTT integration:

1. Go to Settings → Devices & Services → Add Integration → MQTT
2. Configure your broker settings
3. Note the broker IP and credentials

### Option 2: Mosquitto (Standalone)

```bash
# Install Mosquitto
# macOS
brew install mosquitto

# Linux (Ubuntu/Debian)
sudo apt-get install mosquitto mosquitto-clients

# Start the broker
mosquitto -v
```

Default settings:
- Broker: `localhost` or your server IP
- Port: `1883` (unencrypted) or `8883` (TLS)
- No authentication by default (enable for security)

### Option 3: Docker

```bash
docker run -it -p 1883:1883 -p 9001:9001 eclipse-mosquitto
```

## Configure PicoTDS

### Step 1: Create MQTT Configuration

Copy the example configuration:
```bash
cp config/mqtt.py.example config/mqtt.py
```

### Option A: Dynamic Broker Discovery (Recommended for Dynamic Networks)

If your MQTT broker has a dynamic IP address or changes frequently, enable automatic broker discovery:

Edit `config/mqtt.py`:
```python
USE_BROKER_DISCOVERY = True     # Enable automatic discovery
DISCOVERY_TIMEOUT = 15         # Scan duration in seconds
MQTT_BROKER = "192.168.1.1"    # Fallback (usually gateway)
MQTT_PORT = 1883
MQTT_USER = ""                  # Leave empty if no auth
MQTT_PASSWORD = ""              # Leave empty if no auth
```

**How Discovery Works:**
1. PicoTDS scans common broker IPs (gateway, 192.168.1.1, etc.)
2. If not found, it scans the entire local subnet (1-254)
3. Tests each IP for open MQTT port (1883)
4. Connects to the first broker found
5. Falls back to configured MQTT_BROKER if discovery fails

**Discovery Output:**
```
Scanning network for MQTT broker...
My IP: 192.168.1.50, Gateway: 192.168.1.1
Found MQTT broker at: 192.168.1.100
Connecting to MQTT broker: 192.168.1.100
MQTT connected! Client ID: picotds_abc123
```

### Option B: Static Broker IP

If your broker has a static IP, disable discovery:

Edit `config/mqtt.py`:
```python
USE_BROKER_DISCOVERY = False    # Disable discovery
MQTT_BROKER = "192.168.1.100"  # Your broker IP
MQTT_PORT = 1883
MQTT_USER = "your_username"    # Leave empty if no auth
MQTT_PASSWORD = "your_password" # Leave empty if no auth
```

### Step 2: Install umqtt Library

The Pico W needs the umqtt library. Install it via Thonny or rshell:

**Using Thonny:**
1. Tools → Manage Packages
2. Search for "umqtt.simple"
3. Click Install

**Using rshell:**
```bash
rshell -p /dev/tty.usbmodem... repl
>>> import mip
>>> mip.install("umqtt.simple")
```

### Step 3: Upload Files

Upload the MQTT configuration and client:
```bash
./upload.sh
```

Or manually:
```bash
rshell -p /dev/tty.usbmodem... connect
cp config/mqtt.py /mqtt.py
cp src/mqtt_client.py /mqtt_client.py
cp src/main.py /main.py
```

### Step 4: Restart Pico W

Press the reset button or power cycle. You should see:
```
Connecting to MQTT broker: 192.168.1.100
MQTT connected! Client ID: picotds_abc123
MQTT initialized
```

## MQTT Topics

PicoTDS publishes to the following topics (under the base topic):

```
picotds/tds          - TDS value in ppm
picotds/voltage      - Voltage reading in volts
picotds/temperature  - Temperature in Celsius
picotds/reading      - Full reading as JSON
picotds/status       - Device status (online/offline)
```

### Example Messages

**TDS:**
```
Topic: picotds/tds
Payload: 150.5
```

**Full Reading (JSON):**
```json
{
  "tds_ppm": 150.5,
  "voltage": 0.75,
  "temperature": 25.0,
  "raw_adc": 15000
}
```

## Home Assistant Integration

### Auto-Discovery (Recommended)

PicoTDS supports Home Assistant's MQTT auto-discovery. When enabled, sensors appear automatically!

**Requirements:**
- MQTT broker must support retained messages
- Home Assistant MQTT integration configured
- `ENABLE_HA_DISCOVERY = True` in mqtt.py (default)

**Sensors will appear as:**
- `sensor.picotds_tds` - TDS in ppm
- `sensor.picotds_voltage` - Voltage in V
- `sensor.picotds_temperature` - Temperature in °C

### Manual Configuration

If auto-discovery doesn't work, add this to your `configuration.yaml`:

```yaml
sensor:
  - platform: mqtt
    name: "PicoTDS TDS"
    state_topic: "picotds/tds"
    unit_of_measurement: "ppm"
    value_template: "{{ value | float }}"
    device_class: "none"

  - platform: mqtt
    name: "PicoTDS Voltage"
    state_topic: "picotds/voltage"
    unit_of_measurement: "V"
    value_template: "{{ value | float }}"
    device_class: "voltage"

  - platform: mqtt
    name: "PicoTDS Temperature"
    state_topic: "picotds/temperature"
    unit_of_measurement: "°C"
    value_template: "{{ value | float }}"
    device_class: "temperature"
```

### Binary Sensor for Online Status

```yaml
binary_sensor:
  - platform: mqtt
    name: "PicoTDS Status"
    state_topic: "picotds/status"
    payload_on: "online"
    payload_off: "offline"
    device_class: "connectivity"
```

## Testing MQTT Connection

### Using mosquitto_sub

```bash
# Subscribe to all PicoTDS topics
mosquitto_sub -h 192.168.1.100 -t "picotds/#" -v

# Subscribe to TDS only
mosquitto_sub -h 192.168.1.100 -t "picotds/tds"
```

### Using MQTT Explorer

1. Download [MQTT Explorer](http://mqtt-explorer.com/)
2. Connect to your broker
3. Subscribe to `picotds/#`
4. Watch messages appear

## Advanced Configuration

### Custom Topics

Edit `config/mqtt.py` to change topic structure:
```python
MQTT_BASE_TOPIC = "home/sensors/water"  # Custom base
MQTT_TDS_TOPIC = "tds_level"
# Results in: home/sensors/water/tds_level
```

### Publishing Interval

Control how often data is sent:
```python
MQTT_PUBLISH_INTERVAL = 10  # Every 10 seconds
MQTT_PUBLISH_INTERVAL = 0   # Every reading (1 second default)
```

### QoS and Retain

```python
MQTT_QOS = 1        # 0=at most once, 1=at least once, 2=exactly once
MQTT_RETAIN = True  # Broker keeps last message
```

### Authentication

Always use authentication in production:
```python
MQTT_USER = "picotds"
MQTT_PASSWORD = "secure_password"
```

On Mosquitto, create a password file:
```bash
mosquitto_passwd -c /etc/mosquitto/passwd picotds
```

## Troubleshooting

### "MQTT connection failed"

- Check broker IP is correct
- Verify broker is running: `mosquitto -v`
- Check firewall allows port 1883
- Verify credentials if authentication enabled

### "No MQTT broker found on network" (Discovery Mode)

- Ensure broker is running and accessible
- Check that broker is on the same subnet as Pico W
- Increase `DISCOVERY_TIMEOUT` in config (default 15 seconds)
- Verify broker is listening on port 1883
- Try static broker IP mode instead of discovery

### Broker discovery takes too long

- Reduce `DISCOVERY_TIMEOUT` in config
- Add your broker's common IP to the code's common_brokers list
- Use static broker IP if broker IP is known

### Broker discovery finds wrong broker

- If multiple brokers exist, disable discovery and use static IP
- Or modify the discovery priority in mqtt_client.py to prefer your broker

### "umqtt library not installed"

Install via Thonny or:
```python
import mip
mip.install("umqtt.simple")
```

### Sensors not appearing in Home Assistant

- Check MQTT integration is configured in HA
- Verify auto-discovery is enabled
- Check HA logs for errors
- Manually add sensors if auto-discovery fails

### Old data showing in Home Assistant

- Check `MQTT_RETAIN = True` in config
- Restart Home Assistant
- Clear retained messages:
  ```bash
  mosquitto_pub -h broker -t "picotds/#" -r -n
  ```

### Connection drops frequently

- Increase `MQTT_KEEPALIVE` (default 60 seconds)
- Check WiFi signal strength
- Ensure broker isn't overloaded

## Security Best Practices

1. **Use Authentication**: Never run an open broker on the internet
2. **TLS/SSL**: Use port 8883 with certificates for encryption
3. **Separate Credentials**: Create dedicated MQTT user for PicoTDS
4. **Network Isolation**: Keep IoT devices on a separate VLAN
5. **Regular Updates**: Keep Mosquitto and PicoTDS updated

## Next Steps

- Set up automation in Home Assistant based on TDS levels
- Add Grafana dashboards for historical data
- Integrate with Node-RED for complex logic
- Add alerts for high/low TDS values
