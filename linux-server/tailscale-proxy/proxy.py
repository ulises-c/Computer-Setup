#!/usr/bin/env python3
import json
import os
import time
import urllib.request
import urllib.parse
from http.server import HTTPServer, BaseHTTPRequestHandler
from threading import Lock

CLIENT_ID = os.environ["TAILSCALE_CLIENT_ID"]
CLIENT_SECRET = os.environ["TAILSCALE_CLIENT_SECRET"]
DEVICE_ID = os.environ["TAILSCALE_DEVICE_ID"]
PORT = int(os.environ.get("PORT", 8089))

_token = None
_token_expiry = 0
_lock = Lock()


def get_access_token():
    global _token, _token_expiry
    with _lock:
        if time.time() < _token_expiry - 60:
            return _token
        data = urllib.parse.urlencode({
            "client_id": CLIENT_ID,
            "client_secret": CLIENT_SECRET,
            "grant_type": "client_credentials",
        }).encode()
        req = urllib.request.Request("https://api.tailscale.com/api/v2/oauth/token", data=data)
        with urllib.request.urlopen(req) as resp:
            result = json.loads(resp.read())
            _token = result["access_token"]
            _token_expiry = time.time() + result.get("expires_in", 3600)
            return _token


def get_device():
    token = get_access_token()
    req = urllib.request.Request(
        f"https://api.tailscale.com/api/v2/device/{DEVICE_ID}",
        headers={"Authorization": f"Bearer {token}"},
    )
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read())


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        try:
            body = json.dumps(get_device()).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except Exception as e:
            body = json.dumps({"error": str(e)}).encode()
            self.send_response(500)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(body)

    def log_message(self, format, *args):
        pass


if __name__ == "__main__":
    print(f"Tailscale proxy listening on port {PORT}", flush=True)
    HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
