"""
Simple HTTP Web Server for PicoTDS
Serves current TDS sensor status over HTTP
"""

import socket
import time
import sys
import json

# Import configuration
try:
    import web as web_config
except ImportError:
    print("Warning: Web server config not found, using defaults")
    class web_config:
        WEB_SERVER_PORT = 80
        WEB_SERVER_ENABLED = True


class WebServer:
    """Simple HTTP server for PicoTDS status"""

    def __init__(self, port=None):
        self.port = port or web_config.WEB_SERVER_PORT
        self.server_socket = None
        self.listening = False
        self.last_reading = None
        self.last_update_time = 0

    def start(self):
        """Start the web server"""
        try:
            # Create socket
            self.server_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            self.server_socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)

            # Bind to all interfaces
            self.server_socket.bind(('0.0.0.0', self.port))

            # Listen for connections
            self.server_socket.listen(5)
            self.server_socket.settimeout(0.1)  # Non-blocking

            self.listening = True
            print(f"Web server started on port {self.port}")
            return True

        except Exception as e:
            print(f"Failed to start web server: {e}")
            return False

    def stop(self):
        """Stop the web server"""
        if self.server_socket:
            try:
                self.server_socket.close()
            except:
                pass
        self.listening = False
        print("Web server stopped")

    def update_reading(self, reading):
        """Update the latest sensor reading"""
        self.last_reading = reading
        self.last_update_time = time.time()

    def handle_request(self):
        """Handle all currently-pending HTTP requests (non-blocking).

        The main loop calls this once per read cycle, so draining every queued connection here
        (instead of a single accept) keeps the server responsive when a browser opens several
        connections at once (page + favicon + /status)."""
        if not self.listening or not self.server_socket:
            return

        while True:
            try:
                conn, addr = self.server_socket.accept()
            except Exception:
                return  # No more pending connections (accept timed out)
            self._handle_connection(conn)

    def _handle_connection(self, conn):
        """Read one request off an accepted connection and send the response."""
        conn.settimeout(1.0)
        try:
            request = conn.recv(1024).decode('utf-8')
            if not request:
                return

            # Parse request line defensively -- a partial/blank read won't have 3 tokens.
            first_line = request.split('\n', 1)[0]
            parts = first_line.split(' ')
            if len(parts) < 2:
                response = self._serve_404()
            else:
                path = parts[1]
                if path == '/' or path == '/index.html':
                    response = self._serve_html()
                elif path == '/status':
                    response = self._serve_json()
                elif path == '/api':
                    response = self._serve_api()
                else:
                    response = self._serve_404()

            # sendall(), not send(): MicroPython's send() may write fewer bytes than given,
            # truncating larger pages.
            conn.sendall(response)

        except Exception as e:
            print(f"Error handling request: {e}")
        finally:
            try:
                conn.close()
            except Exception:
                pass

    def _serve_html(self):
        """Serve HTML status page"""
        html = self._generate_html()
        return self._create_response('text/html', html)

    def _serve_json(self):
        """Serve JSON status"""
        if self.last_reading:
            json_data = self._generate_json()
        else:
            json_data = '{"status": "waiting", "message": "No reading available yet"}'

        return self._create_response('application/json', json_data)

    def _serve_api(self):
        """Serve API endpoint with more details"""
        if self.last_reading:
            api_data = self._generate_api()
        else:
            api_data = '{"status": "waiting", "message": "No reading available yet"}'

        return self._create_response('application/json', api_data)

    def _serve_404(self):
        """Serve 404 error"""
        html = """
        <html>
        <head><title>404 Not Found</title></head>
        <body>
        <h1>404 Not Found</h1>
        <p>The requested URL was not found on this server.</p>
        <p><a href="/">Go to PicoTDS Status</a></p>
        </body>
        </html>
        """
        return self._create_response('text/html', html, status_code=404)

    def _create_response(self, content_type, content, status_code=200):
        """Create HTTP response"""
        status_text = "OK" if status_code == 200 else "Not Found"
        # Content-Length must be the BYTE length. The page contains multi-byte UTF-8 (e.g. the
        # "°C" unit), so len(content) (character count) would understate it and truncate the body.
        body = content.encode('utf-8')
        header = (
            f"HTTP/1.1 {status_code} {status_text}\r\n"
            f"Content-Type: {content_type}\r\n"
            f"Content-Length: {len(body)}\r\n"
            "Connection: close\r\n"
            "\r\n"
        )
        return header.encode('utf-8') + body

    def _generate_html(self):
        """Generate HTML status page"""
        if self.last_reading:
            tds = self.last_reading['tds_ppm']
            voltage = self.last_reading['voltage']
            temp = self.last_reading['temperature']
            if temp is None:
                temp = "Unavailable"
            update_time = int(time.time() - self.last_update_time)
            status = "Online"
        else:
            tds = "--"
            voltage = "--"
            temp = "--"
            update_time = "--"
            status = "Waiting for data"

        html = f"""
        <!DOCTYPE html>
        <html>
        <head>
            <title>PicoTDS Status</title>
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>
                body {{
                    font-family: Arial, sans-serif;
                    max-width: 600px;
                    margin: 50px auto;
                    padding: 20px;
                    background-color: #f5f5f5;
                }}
                .container {{
                    background-color: white;
                    padding: 30px;
                    border-radius: 10px;
                    box-shadow: 0 2px 10px rgba(0,0,0,0.1);
                }}
                h1 {{
                    color: #333;
                    border-bottom: 2px solid #4CAF50;
                    padding-bottom: 10px;
                }}
                .status {{
                    display: inline-block;
                    padding: 5px 15px;
                    border-radius: 20px;
                    font-weight: bold;
                    margin-bottom: 20px;
                }}
                .status.online {{
                    background-color: #4CAF50;
                    color: white;
                }}
                .status.waiting {{
                    background-color: #ff9800;
                    color: white;
                }}
                .reading {{
                    margin: 15px 0;
                    padding: 15px;
                    background-color: #f9f9f9;
                    border-radius: 5px;
                    border-left: 4px solid #4CAF50;
                }}
                .label {{
                    font-weight: bold;
                    color: #666;
                    font-size: 14px;
                }}
                .value {{
                    font-size: 32px;
                    font-weight: bold;
                    color: #333;
                    margin: 5px 0;
                }}
                .unit {{
                    font-size: 18px;
                    color: #888;
                }}
                .update {{
                    color: #888;
                    font-size: 12px;
                    margin-top: 20px;
                }}
                .links {{
                    margin-top: 30px;
                    padding-top: 20px;
                    border-top: 1px solid #eee;
                }}
                .links a {{
                    color: #4CAF50;
                    text-decoration: none;
                    margin-right: 20px;
                }}
                .links a:hover {{
                    text-decoration: underline;
                }}
            </style>
        </head>
        <body>
            <div class="container">
                <h1>PicoTDS Status</h1>
                <div class="status {status.lower()}">{status}</div>

                <div class="reading">
                    <div class="label">TDS (Total Dissolved Solids)</div>
                    <div class="value">{tds} <span class="unit">ppm</span></div>
                </div>

                <div class="reading">
                    <div class="label">Voltage</div>
                    <div class="value">{voltage} <span class="unit">V</span></div>
                </div>

                <div class="reading">
                    <div class="label">Temperature</div>
                    <div class="value">{temp} <span class="unit">°C</span></div>
                </div>

                <div class="update">
                    Last updated: {update_time} seconds ago
                </div>

                <div class="links">
                    <a href="/status">JSON Status</a>
                    <a href="/api">API Endpoint</a>
                </div>
            </div>
        </body>
        </html>
        """
        return html

    def _generate_json(self):
        """Generate JSON status"""
        if self.last_reading:
            data = {
                "status": "online",
                "timestamp": self.last_update_time,
                "tds_ppm": self.last_reading['tds_ppm'],
                "voltage": self.last_reading['voltage'],
                "temperature": self.last_reading['temperature']
            }
            return json.dumps(data)
        else:
            return '{"status": "waiting"}'

    def _generate_api(self):
        """Generate detailed API response"""
        if self.last_reading:
            data = {
                "device": "PicoTDS",
                "status": "online",
                "timestamp": self.last_update_time,
                "reading": self.last_reading,
                "endpoints": {
                    "html": "/",
                    "json": "/status",
                    "api": "/api"
                }
            }
            return json.dumps(data)
        else:
            return '{"status": "waiting"}'


def main():
    """Test the web server"""
    print("Web Server Test")
    print("=" * 40)

    server = WebServer()

    if server.start():
        print("Server started. Press Ctrl+C to stop.")

        # Simulate some readings
        server.update_reading({
            'tds_ppm': 150.5,
            'voltage': 0.75,
            'temperature': 25.0,
            'raw_adc': 15000
        })

        try:
            while True:
                server.handle_request()
                time.sleep(0.1)
        except KeyboardInterrupt:
            print("\nStopping...")
            server.stop()


if __name__ == "__main__":
    main()
