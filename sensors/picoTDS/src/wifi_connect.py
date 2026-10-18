"""
WiFi Connection Manager for Raspberry Pi Pico W
Handles WiFi connection, reconnection, and network status
"""

import network
import time
import machine
import sys

# Import configuration
try:
    import wifi as wifi_config
    print(f"WiFi config loaded: SSID={wifi_config.WIFI_SSID}")
except ImportError:
    print("Warning: WiFi config not found, using defaults")
    class wifi_config:
        WIFI_SSID = "your_network"
        WIFI_PASSWORD = "your_password"
        USE_STATIC_IP = False
        STATIC_IP = "192.168.1.100"
        STATIC_SUBNET = "255.255.255.0"
        STATIC_GATEWAY = "192.168.1.1"
        STATIC_DNS = "8.8.8.8"


class WiFiManager:
    """Manages WiFi connection for Pico W"""

    def __init__(self):
        self.wlan = network.WLAN(network.STA_IF)
        self.connected = False
        self.ip_address = None

    def connect(self, ssid=None, password=None, timeout=10):
        """
        Connect to WiFi network

        Args:
            ssid: Network SSID (default from config)
            password: Network password (default from config)
            timeout: Connection timeout in seconds

        Returns:
            True if connected, False otherwise
        """
        ssid = ssid or wifi_config.WIFI_SSID
        password = password or wifi_config.WIFI_PASSWORD

        print(f"Connecting to WiFi: {ssid}")

        # Set the regulatory domain before bringing the radio up. Leaving it unset can cause
        # connection/channel issues on the CYW43 radio.
        try:
            import rp2
            rp2.country(getattr(wifi_config, "WIFI_COUNTRY", "US"))
        except Exception:
            pass

        # Activate WiFi
        self.wlan.active(True)

        # Disable WiFi power-save. The CYW43 defaults to aggressive power-saving, which drops and
        # delays inbound packets -- that makes the web server and MQTT appear dead even while WiFi
        # reports "connected". A device acting as a server must turn this off.
        try:
            self.wlan.config(pm=0xa11140)  # WLAN.PM_NONE
        except Exception:
            pass

        # Configure static IP if enabled
        if wifi_config.USE_STATIC_IP:
            self.wlan.ifconfig((
                wifi_config.STATIC_IP,
                wifi_config.STATIC_SUBNET,
                wifi_config.STATIC_GATEWAY,
                wifi_config.STATIC_DNS
            ))
            print(f"Static IP configured: {wifi_config.STATIC_IP}")

        # Connect to network
        self.wlan.connect(ssid, password)

        # Wait for connection
        start_time = time.time()
        while not self.wlan.isconnected():
            if time.time() - start_time > timeout:
                try:
                    status = self.wlan.status()
                except Exception:
                    status = "unknown"
                print(f"\nWiFi connection timeout (status={status})")
                return False
            time.sleep(0.5)
            print(".", end="")

        print("\nWiFi connected!")
        self.connected = True
        self.ip_address = self.wlan.ifconfig()[0]
        print(f"IP Address: {self.ip_address}")

        return True

    def disconnect(self):
        """Disconnect from WiFi"""
        if self.wlan.isconnected():
            self.wlan.disconnect()
            self.connected = False
            self.ip_address = None
            print("WiFi disconnected")

    def is_connected(self):
        """Check if connected to WiFi"""
        return self.wlan.isconnected()

    def get_ip(self):
        """Get current IP address"""
        if self.wlan.isconnected():
            return self.wlan.ifconfig()[0]
        return None

    def get_rssi(self):
        """Get WiFi signal strength (RSSI)"""
        if self.wlan.isconnected():
            return self.wlan.status('rssi')
        return None

    def check_connection(self):
        """Check and maintain connection, reconnect if needed"""
        if not self.wlan.isconnected():
            print("WiFi disconnected, attempting to reconnect...")
            self.connected = False
            return self.connect()
        return True

    def scan_networks(self):
        """Scan for available WiFi networks"""
        self.wlan.active(True)
        networks = self.wlan.scan()
        print("\nAvailable networks:")
        for net in networks:
            ssid = net[0].decode('utf-8')
            rssi = net[3]
            auth = net[4]
            print(f"  {ssid} (RSSI: {rssi}, Auth: {auth})")
        return networks


def test_connection():
    """Test internet connectivity by connecting to a server"""
    import socket

    try:
        # Try to connect to Google DNS
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(5)
        s.connect(('8.8.8.8', 53))
        s.close()
        return True
    except:
        return False


def main():
    """Test WiFi connection"""
    print("WiFi Connection Test")
    print("=" * 40)

    wifi = WiFiManager()

    # Scan networks first
    wifi.scan_networks()

    # Connect
    if wifi.connect():
        print(f"RSSI: {wifi.get_rssi()} dBm")

        # Test internet
        print("Testing internet connectivity...")
        if test_connection():
            print("Internet connection: OK")
        else:
            print("Internet connection: Failed")

        # Keep connection alive
        print("\nKeeping connection alive (Ctrl+C to stop)...")
        try:
            while True:
                if wifi.check_connection():
                    print(f"Connected - IP: {wifi.get_ip()}, RSSI: {wifi.get_rssi()} dBm")
                else:
                    print("Connection lost")
                time.sleep(10)
        except KeyboardInterrupt:
            print("\nStopped by user")
            wifi.disconnect()
    else:
        print("Failed to connect to WiFi")


if __name__ == "__main__":
    main()
