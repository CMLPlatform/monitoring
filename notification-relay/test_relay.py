"""Exercise the fixed-route delivery boundary with local HTTP endpoints."""

import base64
import http.client
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import ClassVar
from unittest.mock import patch

import relay


class Destination(BaseHTTPRequestHandler):
    status = 204
    delay = 0.0
    received: ClassVar[list] = []

    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        self.received.append((self.path, body, self.headers.get("Authorization")))
        time.sleep(self.delay)
        self.send_response(self.status)
        self.send_header("Location", "/must-not-follow")
        self.end_headers()

    def log_message(self, format, *args):
        pass


class RelayTest(unittest.TestCase):
    def setUp(self):
        Destination.received = []
        Destination.status = 204
        Destination.delay = 0
        self.destination = HTTPServer(("127.0.0.1", 0), Destination)
        self.addCleanup(self.destination.server_close)
        threading.Thread(target=self.destination.serve_forever, daemon=True).start()
        self.addCleanup(self.destination.shutdown)
        port = self.destination.server_port
        self.server = relay.make_server(
            ("127.0.0.1", 0),
            {
                "/alerts": f"http://publisher:secret@127.0.0.1:{port}/topic?tpl=1",
                "/heartbeat": f"http://127.0.0.1:{port}/ping",
            },
        )
        self.addCleanup(self.server.server_close)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.shutdown)

    def request(self, path, body=b"{}", headers=None):
        conn = http.client.HTTPConnection(
            "127.0.0.1", self.server.server_port, timeout=3
        )
        self.addCleanup(conn.close)
        conn.request("POST", path, body, headers or {})
        response = conn.getresponse()
        self.assertEqual(response.read(), b"")
        return response.status

    def test_delivers_only_fixed_routes_and_keeps_auth_out_of_response(self):
        self.assertEqual(self.request("/alerts"), 204)
        self.assertEqual(self.request("/heartbeat"), 204)
        self.assertEqual(
            Destination.received,
            [
                (
                    "/topic?tpl=1",
                    b"{}",
                    "Basic " + base64.b64encode(b"publisher:secret").decode(),
                ),
                ("/ping", b"{}", None),
            ],
        )
        self.assertEqual(self.request("/alerts?url=http://elsewhere.invalid"), 404)
        self.assertEqual(len(Destination.received), 2)

    def test_encodes_native_ntfy_template_query(self):
        self.server.targets["/alerts"] += (
            '&message={{or .commonAnnotations.summary "Alert firing"}}'
        )
        self.assertEqual(self.request("/alerts"), 204)
        self.assertIn(
            "message=%7B%7Bor%20.commonAnnotations.summary%20%22Alert%20firing%22%7D%7D",
            Destination.received[0][0],
        )

    def test_upstream_failures_and_redirects_fail_closed(self):
        for status in (302, 400, 500):
            Destination.status = status
            self.assertEqual(self.request("/alerts"), 502)
        self.assertEqual(len(Destination.received), 3)

    def test_rejects_oversize_chunked_and_ambiguous_body(self):
        self.assertEqual(
            self.request(
                "/alerts", headers={"Content-Length": str(relay.MAX_BODY + 1)}
            ),
            413,
        )
        self.assertEqual(
            self.request("/alerts", headers={"Transfer-Encoding": "chunked"}), 400
        )
        self.assertEqual(Destination.received, [])

    def test_rejects_invalid_content_lengths(self):
        for length in ("-1", "bad", "²", "9" * 5000):
            self.assertEqual(
                self.request("/alerts", headers={"Content-Length": length}), 400
            )
        self.assertEqual(Destination.received, [])

    def test_upstream_timeout_is_generic_failure(self):
        Destination.delay = 0.15
        with patch.object(relay, "TIMEOUT", 0.05):
            self.assertEqual(self.request("/alerts"), 502)

    def test_rejects_duplicate_content_lengths(self):
        conn = http.client.HTTPConnection(
            "127.0.0.1", self.server.server_port, timeout=3
        )
        self.addCleanup(conn.close)
        conn.putrequest("POST", "/alerts")
        conn.putheader("Content-Length", "0")
        conn.putheader("Content-Length", "1")
        conn.endheaders()
        self.assertEqual(conn.getresponse().status, 400)
        self.assertEqual(Destination.received, [])

    def test_unconfigured_route_reports_failure(self):
        self.server.targets["/heartbeat"] = ""
        self.assertEqual(self.request("/heartbeat"), 503)

    def test_connection_failure_is_generic(self):
        self.server.targets["/alerts"] = "http://127.0.0.1:1/secret"
        self.assertEqual(self.request("/alerts"), 502)

    def test_invalid_destinations_rejected_without_echoing_credentials(self):
        for url in (
            "ftp://secret@host/path",
            "http://host:bad/path",
            "http:///path",
            "https://host/path#secret",
        ):
            with self.assertRaisesRegex(
                ValueError, "^invalid notification destination$"
            ):
                relay.make_server(("127.0.0.1", 0), {"/alerts": url})


if __name__ == "__main__":
    unittest.main()
