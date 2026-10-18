"""
MQTT Client for PicoTDS
Publishes TDS sensor data to MQTT broker
Supports Home Assistant auto-discovery
"""

import time
import json
import sys
import machine
import ubinascii
import network
import socket

# Try to import umqtt (standard MicroPython MQTT library)
try:
    from umqtt.simple import MQTTClient
except ImportError:
    print("Error: umqtt library not installed")
    print("Install with: mip install umqtt.simple")
    raise

# Import configuration
try:
    import mqtt as mqtt_config
except ImportError:
    print("Warning: MQTT config not found, using defaults")
    class mqtt_config:
        MQTT_BROKER = "192.168.1.100"
        MQTT_PORT = 1883
        MQTT_CLIENT_ID = "picotds"
        MQTT_USER = ""
        MQTT_PASSWORD = ""
        MQTT_BASE_TOPIC = "picotds"
        MQTT_TDS_TOPIC = "tds"
        MQTT_VOLTAGE_TOPIC = "voltage"
        MQTT_TEMP_TOPIC = "temperature"
        MQTT_STATUS_TOPIC = "status"
        MQTT_QOS = 1
        MQTT_RETAIN = True
        ENABLE_HA_DISCOVERY = True
        HA_DISCOVERY_PREFIX = "homeassistant"
        MQTT_PUBLISH_INTERVAL = 10
        MQTT_KEEPALIVE = 60
        MQTT_RECONNECT_DELAY = 5


class MQTTManager:
    """Manages MQTT connection and publishing for PicoTDS"""

    def __init__(self):
        self.client = None
        self.connected = False
        self.last_publish_time = 0
        self.device_id = self._get_device_id()

    def _get_device_id(self):
        """Generate unique device ID from MAC address"""
        try:
            wlan = network.WLAN(network.STA_IF)
            wlan.active(True)
            mac = wlan.config('mac')
            mac_str = ubinascii.hexlify(mac).decode('ascii')
            return f"picotds_{mac_str[-6:]}"
        except:
            # Fallback to configured client ID with random suffix
            import random
            suffix = random.randint(1000, 9999)
            return f"{mqtt_config.MQTT_CLIENT_ID}_{suffix}"

    def _get_topic(self, *parts):
        """Build full topic path"""
        parts = [mqtt_config.MQTT_BASE_TOPIC] + list(parts)
        return "/".join(parts)

    def discover_broker(self, timeout=10):
        """
        Discover MQTT broker on the network

        Args:
            timeout: Discovery timeout in seconds

        Returns:
            Broker IP address if found, None otherwise
        """
        print("Scanning network for MQTT broker...")

        # Get network info
        wlan = network.WLAN(network.STA_IF)
        if not wlan.isconnected():
            print("WiFi not connected, cannot discover broker")
            return None

        # Get network configuration
        ifconfig = wlan.ifconfig()
        my_ip = ifconfig[0]
        gateway = ifconfig[2]

        print(f"My IP: {my_ip}, Gateway: {gateway}")

        # Try common broker IPs first
        common_brokers = [
            gateway,  # Often router/gateway
            "192.168.1.1",
            "192.168.0.1",
            "192.168.1.10",
            "192.168.1.100",
            "10.0.0.1",
            "10.0.0.100",
        ]

        for broker in common_brokers:
            if self._test_mqtt_port(broker, mqtt_config.MQTT_PORT):
                print(f"Found MQTT broker at: {broker}")
                return broker

        # Scan local subnet for MQTT port
        print("Scanning local subnet for MQTT brokers...")
        broker = self._scan_subnet_for_mqtt(my_ip, timeout)
        if broker:
            return broker

        print("No MQTT broker found on network")
        return None

    def _test_mqtt_port(self, host, port, timeout=2):
        """
        Test if MQTT port is open on a host

        Args:
            host: IP address to test
            port: Port number (default 1883)
            timeout: Connection timeout in seconds

        Returns:
            True if port is open, False otherwise
        """
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.settimeout(timeout)
            result = s.connect_ex((host, port))
            s.close()
            return result == 0
        except:
            return False

    def _scan_subnet_for_mqtt(self, my_ip, timeout=10):
        """
        Scan local subnet for MQTT brokers

        Args:
            my_ip: Current device IP
            timeout: Scan timeout in seconds

        Returns:
            Broker IP if found, None otherwise
        """
        # Parse IP to get subnet
        ip_parts = my_ip.split('.')
        if len(ip_parts) != 4:
            return None

        subnet = f"{ip_parts[0]}.{ip_parts[1]}.{ip_parts[2]}"

        # Scan range 1-254 (common range)
        print(f"Scanning subnet {subnet}.x for MQTT brokers...")
        start_time = time.time()

        for i in range(1, 255):
            if time.time() - start_time > timeout:
                print("Scan timeout reached")
                break

            host = f"{subnet}.{i}"
            if host == my_ip:
                continue  # Skip self

            if self._test_mqtt_port(host, mqtt_config.MQTT_PORT, timeout=0.5):
                print(f"Found MQTT broker at: {host}")
                return host

            # Small delay to avoid flooding network
            time.sleep(0.01)

        return None

    def connect(self):
        """
        Connect to MQTT broker

        Returns:
            True if connected, False otherwise
        """
        broker = mqtt_config.MQTT_BROKER

        # Use dynamic broker discovery if enabled
        if getattr(mqtt_config, 'USE_BROKER_DISCOVERY', False):
            print("Broker discovery enabled")
            discovered_broker = self.discover_broker()
            if discovered_broker:
                broker = discovered_broker
            else:
                print("Discovery failed, falling back to configured broker")

        print(f"Connecting to MQTT broker: {broker}")

        try:
            # Create MQTT client
            self.client = MQTTClient(
                client_id=self.device_id,
                server=broker,
                port=mqtt_config.MQTT_PORT,
                user=mqtt_config.MQTT_USER if mqtt_config.MQTT_USER else None,
                password=mqtt_config.MQTT_PASSWORD if mqtt_config.MQTT_PASSWORD else None,
                keepalive=mqtt_config.MQTT_KEEPALIVE
            )

            # Set Last Will and Testament (LWT)
            lwt_topic = self._get_topic(mqtt_config.MQTT_STATUS_TOPIC)
            self.client.set_last_will(lwt_topic, b"offline", qos=1, retain=True)

            # Connect
            self.client.connect()
            self.connected = True

            # Publish online status
            self.client.publish(lwt_topic, b"online", qos=1, retain=True)

            print(f"MQTT connected! Client ID: {self.device_id}")

            # Send Home Assistant discovery if enabled
            if mqtt_config.ENABLE_HA_DISCOVERY:
                self.send_ha_discovery()

            return True

        except Exception as e:
            print(f"MQTT connection failed: {e}")
            self.connected = False
            return False

    def disconnect(self):
        """Disconnect from MQTT broker"""
        if self.client and self.connected:
            try:
                # Publish offline status
                lwt_topic = self._get_topic(mqtt_config.MQTT_STATUS_TOPIC)
                self.client.publish(lwt_topic, b"offline", qos=1, retain=True)
                self.client.disconnect()
                self.connected = False
                print("MQTT disconnected")
            except Exception as e:
                print(f"Error during disconnect: {e}")

    def is_connected(self):
        """Check if connected to MQTT broker"""
        return self.connected

    def publish(self, topic, payload, qos=None, retain=None):
        """
        Publish message to MQTT broker

        Args:
            topic: Topic suffix (base topic will be prepended)
            payload: Message payload (string or bytes)
            qos: QoS level (default from config)
            retain: Retain flag (default from config)
        """
        if not self.connected:
            return False

        try:
            full_topic = self._get_topic(topic)
            qos = qos if qos is not None else mqtt_config.MQTT_QOS
            retain = retain if retain is not None else mqtt_config.MQTT_RETAIN

            if isinstance(payload, str):
                payload = payload.encode('utf-8')

            self.client.publish(full_topic, payload, qos=qos, retain=retain)
            return True

        except Exception as e:
            print(f"MQTT publish error: {e}")
            self.connected = False
            return False

    def publish_tds_reading(self, reading):
        """
        Publish TDS sensor reading to MQTT

        Args:
            reading: Dictionary with TDS reading data
        """
        if not self.connected:
            return False

        try:
            # Publish individual values
            self.publish(mqtt_config.MQTT_TDS_TOPIC, str(reading['tds_ppm']))
            self.publish(mqtt_config.MQTT_VOLTAGE_TOPIC, str(reading['voltage']))
            self.publish(mqtt_config.MQTT_TEMP_TOPIC, str(reading['temperature']))

            # Publish full reading as JSON
            json_payload = json.dumps(reading)
            self.publish("reading", json_payload)

            print(f"MQTT: Published TDS={reading['tds_ppm']} ppm")
            return True

        except Exception as e:
            print(f"Error publishing TDS reading: {e}")
            return False

    def should_publish(self):
        """Check if it's time to publish (based on interval)"""
        if mqtt_config.MQTT_PUBLISH_INTERVAL == 0:
            return True  # Publish every reading

        current_time = time.time()
        if current_time - self.last_publish_time >= mqtt_config.MQTT_PUBLISH_INTERVAL:
            self.last_publish_time = current_time
            return True

        return False

    def check_connection(self):
        """Check and maintain MQTT connection, reconnect if needed"""
        if not self.connected:
            print("MQTT disconnected, attempting to reconnect...")
            return self.connect()
        return True

    def send_ha_discovery(self):
        """Send Home Assistant auto-discovery configuration"""
        if not mqtt_config.ENABLE_HA_DISCOVERY:
            return

        print("Sending Home Assistant discovery config...")

        try:
            # Device info for HA
            device_info = {
                "identifiers": [self.device_id],
                "name": "PicoTDS",
                "model": "Raspberry Pi Pico W",
                "manufacturer": "Raspberry Pi"
            }

            # TDS sensor
            tds_config_payload = {
                "device": device_info,
                "name": "PicoTDS TDS",
                "state_topic": self._get_topic(mqtt_config.MQTT_TDS_TOPIC),
                "unit_of_measurement": "ppm",
                "value_template": "{{ value | float }}",
                "state_class": "measurement",
                "unique_id": f"{self.device_id}_tds",
                "icon": "mdi:water"
            }

            # Voltage sensor
            voltage_config_payload = {
                "device": device_info,
                "name": "PicoTDS Voltage",
                "state_topic": self._get_topic(mqtt_config.MQTT_VOLTAGE_TOPIC),
                "unit_of_measurement": "V",
                "value_template": "{{ value | float }}",
                "state_class": "measurement",
                "unique_id": f"{self.device_id}_voltage",
                "icon": "mdi:lightning-bolt"
            }

            # Temperature sensor
            temp_config_payload = {
                "device": device_info,
                "name": "PicoTDS Temperature",
                "state_topic": self._get_topic(mqtt_config.MQTT_TEMP_TOPIC),
                "unit_of_measurement": "°C",
                "value_template": "{{ value | float }}",
                "device_class": "temperature",
                "state_class": "measurement",
                "unique_id": f"{self.device_id}_temperature",
                "icon": "mdi:thermometer"
            }

            # Publish discovery configs
            discovery_prefix = mqtt_config.HA_DISCOVERY_PREFIX

            self.client.publish(
                f"{discovery_prefix}/sensor/{self.device_id}_tds/config",
                json.dumps(tds_config_payload),
                retain=True
            )

            self.client.publish(
                f"{discovery_prefix}/sensor/{self.device_id}_voltage/config",
                json.dumps(voltage_config_payload),
                retain=True
            )

            self.client.publish(
                f"{discovery_prefix}/sensor/{self.device_id}_temperature/config",
                json.dumps(temp_config_payload),
                retain=True
            )

            print("Home Assistant discovery sent successfully")

        except Exception as e:
            print(f"Error sending HA discovery: {e}")


def main():
    """Test MQTT connection"""
    print("MQTT Client Test")
    print("=" * 40)

    mqtt = MQTTManager()

    if mqtt.connect():
        print("Connected successfully!")

        # Test publish
        print("Publishing test message...")
        mqtt.publish("test", "Hello from PicoTDS!")

        # Test TDS reading publish
        test_reading = {
            'tds_ppm': 150.5,
            'voltage': 0.75,
            'temperature': 25.0,
            'raw_adc': 15000
        }
        mqtt.publish_tds_reading(test_reading)

        time.sleep(2)

        print("Disconnecting...")
        mqtt.disconnect()
    else:
        print("Failed to connect")


if __name__ == "__main__":
    main()
