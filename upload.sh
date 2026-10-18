#!/bin/bash
# Upload script for PicoTDS
# Usage: ./upload.sh [port]

PORT=${1:-"/dev/tty.usbmodem101"}

echo "PicoTDS Upload Script"
echo "====================="
echo "Port: $PORT"
echo ""

# Check if rshell is installed
if ! command -v rshell &> /dev/null; then
    echo "Error: rshell not installed"
    echo "Install with: pip install rshell"
    exit 1
fi

# Check if port exists
if [ ! -e "$PORT" ]; then
    echo "Error: Port $PORT not found"
    echo "Available ports:"
    ls /dev/tty.usbmodem* 2>/dev/null || ls /dev/ttyACM* 2>/dev/null || echo "No Pico devices found"
    exit 1
fi

# Upload files
echo "Uploading files to Pico W..."
rshell -p "$PORT" --buffer-size 32 <<EOF
cp config/wifi.py /wifi.py
cp config/tds_config.py /tds_config.py
cp config/mqtt.py /mqtt.py
cp config/web.py /web.py
cp src/tds_sensor.py /tds_sensor.py
cp src/wifi_connect.py /wifi_connect.py
cp src/mqtt_client.py /mqtt_client.py
cp src/web_server.py /web_server.py
cp src/main.py /main.py
echo "Upload complete!"
EOF

echo ""
echo "Files uploaded successfully!"
echo "Press the reset button on your Pico W to run the code."
