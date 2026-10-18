# Web Server Access Guide

PicoTDS includes a built-in HTTP web server that allows you to view sensor status from any web browser on your network.

## What is the Web Server?

The web server provides a simple HTTP interface to view current TDS readings without needing MQTT or any additional software. It's perfect for:
- Quick status checks from any device
- Integration with web-based dashboards
- Simple monitoring without MQTT setup
- Mobile access via smartphone browser

## Accessing the Web Server

### Find the Pico W IP Address

The Pico W will display its IP address when it connects to WiFi:

```
WiFi connected!
IP Address: 192.168.1.50
```

Or find it via your router's DHCP client list.

### Open in Browser

Once you have the IP address, open a web browser and navigate to:

```
http://<pico-ip>/
```

For example: `http://192.168.1.50/`

## Available Endpoints

### 1. HTML Status Page (`/` or `/index.html`)

The main page displays a beautifully formatted status page with:
- Current TDS reading in ppm
- Voltage reading
- Temperature reading
- Last update time
- Device status (Online/Waiting)

**Example:** `http://192.168.1.50/`

### 2. JSON Status (`/status`)

Returns current sensor data in JSON format:

```json
{
  "status": "online",
  "timestamp": 1234567890,
  "tds_ppm": 150.5,
  "voltage": 0.75,
  "temperature": 25.0
}
```

**Example:** `http://192.168.1.50/status`

### 3. API Endpoint (`/api`)

Returns detailed API response with all data:

```json
{
  "device": "PicoTDS",
  "status": "online",
  "timestamp": 1234567890,
  "reading": {
    "tds_ppm": 150.5,
    "voltage": 0.75,
    "temperature": 25.0,
    "raw_adc": 15000
  },
  "endpoints": {
    "html": "/",
    "json": "/status",
    "api": "/api"
  }
}
```

**Example:** `http://192.168.1.50/api`

## Configuration

Edit `config/web.py` to configure the web server:

```python
# Enable/disable web server
WEB_SERVER_ENABLED = True

# Web server port (default 80 for HTTP)
WEB_SERVER_PORT = 80
```

### Changing the Port

If port 80 is in use by another service, change it:

```python
WEB_SERVER_PORT = 8080
```

Then access with: `http://192.168.1.50:8080/`

### Disabling the Web Server

If you don't need web access:

```python
WEB_SERVER_ENABLED = False
```

## Usage Examples

### Command Line (curl)

```bash
# Get JSON status
curl http://192.168.1.50/status

# Get full API
curl http://192.168.1.50/api

# Get HTML page
curl http://192.168.1.50/
```

### Python Script

```python
import requests

# Get JSON status
response = requests.get('http://192.168.1.50/status')
data = response.json()
print(f"TDS: {data['tds_ppm']} ppm")
```

### JavaScript (Browser Console)

```javascript
// Fetch JSON status
fetch('http://192.168.1.50/status')
  .then(response => response.json())
  .then(data => console.log('TDS:', data.tds_ppm));
```

### Home Assistant (REST Sensor)

Add to your `configuration.yaml`:

```yaml
sensor:
  - platform: rest
    name: "PicoTDS TDS (Web)"
    resource: http://192.168.1.50/status
    value_template: "{{ value_json.tds_ppm }}"
    unit_of_measurement: "ppm"

  - platform: rest
    name: "PicoTDS Temperature (Web)"
    resource: http://192.168.1.50/status
    value_template: "{{ value_json.temperature }}"
    unit_of_measurement: "°C"
```

## Web Interface Features

The HTML status page includes:

- **Responsive Design**: Works on desktop, tablet, and mobile
- **Auto-Refresh**: Not implemented (refresh manually or use script)
- **Color-Coded Status**: Green for online, orange for waiting
- **Clear Readings**: Large, easy-to-read values
- **Quick Links**: Direct access to JSON and API endpoints

## Troubleshooting

### "Connection Refused"

- Check that the web server is enabled in `config/web.py`
- Verify the Pico W is connected to WiFi
- Confirm you're using the correct IP address
- Check if another device is using port 80

### "Page Not Found" (404)

- Make sure you're accessing the correct endpoint
- Try the root URL: `http://<ip>/`
- Check the serial output for web server errors

### "Slow Loading"

- The web server is non-blocking but simple
- Network delays may occur
- Check WiFi signal strength
- Reduce other network activity

### "Old Data Showing"

- The web server updates with each sensor reading
- Default TDS read interval is 1 second
- Check `READ_INTERVAL` in `config/tds_config.py`
- The page shows "Last updated" time

### Web Server Not Starting

- Check serial output for error messages
- Ensure WiFi is connected
- Verify `web.py` configuration file exists
- Check for socket errors (port already in use)

## Security Considerations

**Important:** The web server has no authentication by default. On a public network, anyone can access it.

### Recommended Security Measures

1. **Use on Private Network Only**: Keep Pico W on a secure local network
2. **Add Authentication**: Implement HTTP Basic Auth (future feature)
3. **Use VPN**: Access via VPN if on public WiFi
4. **Firewall Rules**: Block external access to port 80
5. **Disable if Not Needed**: Set `WEB_SERVER_ENABLED = False`

### Adding Basic Authentication (Advanced)

The following illustrative helper takes its expected authorization header from
private configuration supplied by the caller. Never hardcode credentials or
commit the private configuration; enforce authentication on every route if
you implement it. The current firmware does not implement this helper.

```python
def _check_auth(self, request, expected_auth_header):
    """Check for basic authentication"""
    auth_header = request.split('Authorization: ')[1].split('\r\n')[0] if 'Authorization:' in request else None
    if auth_header and expected_auth_header and auth_header == expected_auth_header:
        return True
    return False
```

## Performance Notes

- The web server is lightweight and simple
- Non-blocking design doesn't interfere with sensor readings
- Single-threaded (handles one request at a time)
- Suitable for personal use and light monitoring
- Not designed for high-traffic scenarios

## Next Steps

- Set up automated monitoring with scripts
- Integrate with Grafana for dashboards
- Add authentication for security
- Create custom dashboards
- Set up alerts based on TDS values
