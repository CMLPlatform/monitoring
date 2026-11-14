"""Forward Grafana notifications without exposing destination capabilities."""

import base64
import http.client
import os
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import quote, unquote, urlsplit

MAX_BODY = 1024 * 1024
TIMEOUT = 5


def validate_target(url):
    """Reject invalid configured destinations without including secrets in errors."""
    try:
        parts = urlsplit(url)
        if (
            parts.scheme not in ("http", "https")
            or not parts.hostname
            or parts.fragment
        ):
            raise ValueError
        _ = parts.port
        if any(ord(char) < 32 or ord(char) == 127 for char in url):
            raise ValueError
    except ValueError:
        raise ValueError("invalid notification destination") from None


class RelayServer(HTTPServer):
    """Keep destinations outside Grafana's environment and contact point store."""

    def __init__(self, address, targets):
        self.targets = targets
        super().__init__(address, Handler)

    def handle_error(self, request, client_address):
        # Tracebacks from HTTP libraries may contain credential-bearing URLs.
        print("notification request failed", flush=True)


class Handler(BaseHTTPRequestHandler):
    """Accept only bounded POST bodies on two fixed routes."""

    def setup(self):
        super().setup()
        self.connection.settimeout(TIMEOUT)

    def log_message(self, format, *args):
        # Request paths and headers are untrusted and may contain credentials.
        pass

    def reply(self, status):
        self.send_response(status)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        self.reply(204 if self.path == "/health" else 404)

    def do_POST(self):
        assert isinstance(self.server, RelayServer)
        if self.path not in ("/alerts", "/heartbeat"):
            self.reply(404)
            return
        url = self.server.targets.get(self.path, "")
        if not url:
            self.reply(503)
            return
        lengths = self.headers.get_all("Content-Length", [])
        if (
            self.headers.get("Transfer-Encoding")
            or len(lengths) != 1
            or not lengths[0].isdigit()
        ):
            self.reply(400)
            return
        try:
            length = int(lengths[0])
        except ValueError:
            self.reply(400)
            return
        if length > MAX_BODY:
            self.reply(413)
            return
        try:
            body = self.rfile.read(length)
            if len(body) != length:
                self.reply(400)
                return
            parts = urlsplit(url)
            connection_type = (
                http.client.HTTPSConnection
                if parts.scheme == "https"
                else http.client.HTTPConnection
            )
            connection = connection_type(parts.hostname, parts.port, timeout=TIMEOUT)
            try:
                headers = {"Content-Type": "application/json"}
                if parts.username is not None:
                    credentials = (
                        f"{unquote(parts.username)}:{unquote(parts.password or '')}"
                    )
                    headers["Authorization"] = (
                        "Basic " + base64.b64encode(credentials.encode()).decode()
                    )
                path = parts.path or "/"
                if parts.query:
                    path += "?" + parts.query
                # Redirects must not move notification data or credentials elsewhere.
                connection.request(
                    "POST", quote(path, safe="/%?&=:+,@!$'()*;-._~"), body, headers
                )
                status = connection.getresponse().status
            finally:
                connection.close()
            self.reply(204 if 200 <= status < 300 else 502)
        except (OSError, http.client.HTTPException, ValueError):
            self.reply(502)


def make_server(address, targets):
    """Validate fixed destinations before accepting any requests."""
    for target in targets.values():
        if target:
            validate_target(target)
    return RelayServer(address, targets)


if __name__ == "__main__":
    try:
        server = make_server(
            ("0.0.0.0", 8080),
            {
                "/alerts": os.environ.get("ALERT_WEBHOOK_URL", ""),
                "/heartbeat": os.environ.get("HEARTBEAT_URL", ""),
            },
        )
    except ValueError:
        raise SystemExit("invalid notification destination") from None
    server.serve_forever()
