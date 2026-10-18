#!/usr/bin/env bash
# Usage: bash upload.sh [auto|/dev/ttyACM0|/dev/tty.usbmodem...|COM3]
set -euo pipefail
cd -- "$(dirname -- "$0")"
PORT="${1:-auto}"

if ! command -v mpremote >/dev/null 2>&1; then
    echo "Install host tools first: python -m pip install -r requirements.txt"
    exit 1
fi
for config in wifi; do
    if [[ ! -f "config/$config.py" ]]; then
        echo "Missing private config/$config.py; create it from its example and configure it."
        echo "Existing private configs are never overwritten by this script."
        exit 1
    fi
done
MQTT_CONFIG="config/mqtt.py"
if [[ ! -f "$MQTT_CONFIG" ]]; then
    MQTT_CONFIG="config/mqtt.py.example"
    echo "Using anonymous MQTT demo defaults; no MQTT credentials needed."
fi

echo "Uploading to $PORT. Close Thonny/other serial monitors first."
if ! mpremote connect "$PORT" exec "import umqtt.simple"; then
    mpremote connect "$PORT" mip install umqtt.simple
fi
mpremote connect "$PORT" fs cp \
    config/wifi.py config/tds_config.py config/web.py \
    src/tds_sensor.py src/wifi_connect.py src/mqtt_client.py src/web_server.py src/main.py :/
mpremote connect "$PORT" fs cp "$MQTT_CONFIG" :/mqtt.py

# This validates required config and prints only public enrollment fields.
mpremote connect "$PORT" exec "from mqtt_client import MQTTManager; m = MQTTManager(); print('ENROLL:', m.device_id, m.location_id, m.latitude, m.longitude)"
mpremote connect "$PORT" reset
echo "Upload complete. Watch MQTT connected / MQTT PUBACK messages with: mpremote connect $PORT repl"
echo "Send Serge the ENROLL fields to enable this sensor in the app."
