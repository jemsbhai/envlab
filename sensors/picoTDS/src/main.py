"""
PicoTDS - Main Application
Connects to WiFi and reads TDS values from sensor
"""

import time
import machine
import sys

# Add current directory to path (for Pico W flat filesystem)
sys.path.append('')

# Import modules (all in root directory on Pico W)
from wifi_connect import WiFiManager
from tds_sensor import TDSSensor
from mqtt_client import MQTTManager
from web_server import WebServer

# Optional configs are independent; a missing web config must not disable MQTT.
try:
    import tds_config
except ImportError:
    tds_config = None
try:
    import web as web_config
except ImportError:
    web_config = None


class PicoTDS:
    """Main application class"""

    def __init__(self):
        self.wifi = None
        self.tds_sensor = None
        self.mqtt = None
        self.web_server = None
        self.running = False

    def initialize(self):
        """Initialize all components"""
        print("Initializing PicoTDS...")
        print("=" * 50)

        # Initialize WiFi
        self.wifi = WiFiManager()
        if not self.wifi.connect():
            print("Warning: WiFi connection failed, continuing in offline mode")

        # Initialize TDS sensor
        try:
            self.tds_sensor = TDSSensor()
            print("TDS sensor initialized")
        except Exception as e:
            print(f"Error initializing TDS sensor: {e}")
            return False

        # Keep the manager after network failures so reconnects remain possible.
        try:
            self.mqtt = MQTTManager()
            if self.wifi.is_connected() and self.mqtt.connect():
                print("MQTT initialized")
            else:
                print("MQTT pending; will retry when WiFi/broker is available")
        except Exception as e:
            print(f"Warning: MQTT initialization failed: {e}")
            self.mqtt = None

        # Initialize Web Server (only if WiFi is connected)
        if self.wifi and self.wifi.is_connected() and web_config and web_config.WEB_SERVER_ENABLED:
            try:
                self.web_server = WebServer()
                if self.web_server.start():
                    print("Web server initialized")
                else:
                    print("Warning: Web server failed to start")
                    self.web_server = None
            except Exception as e:
                print(f"Warning: Web server initialization failed: {e}")
                self.web_server = None
        else:
            print("Web server skipped (WiFi not connected or config not found)")

        print("\nInitialization complete!")
        return True

    def read_and_display(self):
        """Read TDS and display results"""
        # Check WiFi connection
        if self.wifi:
            self.wifi.check_connection()

        # Check MQTT connection
        if self.mqtt and self.wifi and self.wifi.is_connected():
            self.mqtt.check_connection()

        # Read TDS
        reading = self.tds_sensor.read_tds()

        # Display
        timestamp = time.ticks_ms()
        wifi_status = "WiFi: OK" if self.wifi and self.wifi.is_connected() else "WiFi: OFFLINE"
        mqtt_status = "MQTT: OK" if self.mqtt and self.mqtt.is_connected() else "MQTT: OFFLINE"
        web_status = "Web: OK" if self.web_server else "Web: OFF"

        print(f"[{timestamp}] {wifi_status} | {mqtt_status} | {web_status} | "
              f"TDS: {reading['tds_ppm']:6.1f} ppm | "
              f"V: {reading['voltage']:4.3f}V | "
              f"T: {reading['temperature']}°C (None = unavailable)")

        # Publish to MQTT if connected and it's time to publish
        if self.mqtt and self.mqtt.is_connected() and self.mqtt.should_publish():
            self.mqtt.publish_tds_reading(reading)

        # Update web server with latest reading
        if self.web_server:
            self.web_server.update_reading(reading)

        return reading

    def run(self):
        """Main application loop"""
        if not self.initialize():
            print("Initialization failed!")
            return

        self.running = True
        print("\nStarting TDS monitoring...")
        print("Press Ctrl+C to stop\n")

        try:
            while self.running:
                reading = self.read_and_display()

                # Handle web server requests (non-blocking)
                if self.web_server:
                    self.web_server.handle_request()

                time.sleep(getattr(tds_config, "READ_INTERVAL", 1))

        except KeyboardInterrupt:
            print("\n\nStopping...")
            self.running = False

        finally:
            self.cleanup()

    def cleanup(self):
        """Clean up resources"""
        print("Cleaning up...")
        if self.web_server:
            self.web_server.stop()
        if self.mqtt:
            self.mqtt.disconnect()
        if self.wifi:
            self.wifi.disconnect()
        print("Done")

    def calibrate(self, known_tds):
        """Calibrate the sensor with a known TDS solution"""
        print(f"\nCalibration Mode")
        print("=" * 50)
        print(f"Known TDS value: {known_tds} ppm")
        print("Place sensor in calibration solution and press Enter")

        # Wait for user confirmation (simple implementation)
        time.sleep(5)

        if self.tds_sensor:
            new_factor = self.tds_sensor.calibrate(known_tds)
            print(f"\nCalibration complete!")
            print(f"New calibration factor: {new_factor:.4f}")
            print("Update this value in config/tds_config.py")


def main():
    """Entry point"""
    app = PicoTDS()

    # Check for calibration mode
    if len(sys.argv) > 1 and sys.argv[1] == "--calibrate":
        if len(sys.argv) > 2:
            known_tds = float(sys.argv[2])
            app.initialize()
            app.calibrate(known_tds)
        else:
            print("Usage: main.py --calibrate <known_tds_ppm>")
    else:
        app.run()


if __name__ == "__main__":
    main()
