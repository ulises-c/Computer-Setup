"""Read-only local dashboard for pushed llama-swap Activity telemetry."""

import argparse
import json
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

from store import aggregate, models

RANGES = {'1d': (86400, 3600), '1w': (604800, 21600),
          '1m': (2592000, 86400), '1y': (31536000, 604800)}
ASSETS = {'/': ('index.html', 'text/html; charset=utf-8'),
          '/app.js': ('app.js', 'text/javascript; charset=utf-8'),
          '/style.css': ('style.css', 'text/css; charset=utf-8')}
CSP = "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'"


def validate_bind_host(host: str) -> str:
    if host != '127.0.0.1':
        raise ValueError('Identity-header authentication requires a loopback-only listener')
    return host


def make_handler(db_path: Path, clock=time.time, allowed_login: str = ''):
    if not allowed_login:
        raise ValueError('TELEMETRY_ALLOWED_LOGIN must be configured')
    assets_dir = Path(__file__).parent / 'static'

    class Handler(BaseHTTPRequestHandler):
        def send(self, status, body, content_type):
            self.send_response(status)
            self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Cache-Control', 'no-store')
            self.send_header('Content-Security-Policy', CSP)
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.send_header('Referrer-Policy', 'no-referrer')
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            url = urlsplit(self.path)
            if url.path == '/health':
                self.send(200, b'ok\n', 'text/plain; charset=utf-8')
            elif self.headers.get('Tailscale-User-Login') != allowed_login:
                self.send(403, b'Forbidden\n', 'text/plain; charset=utf-8')
            elif url.path == '/api/series':
                query = parse_qs(url.query)
                period = query.get('range', ['1d'])[0]
                if period not in RANGES or any(len(value) != 1 for value in query.values()):
                    self.send(400, b'{"error":"invalid range"}', 'application/json; charset=utf-8')
                    return
                duration, bucket = RANGES[period]
                now = int(clock())
                model = query.get('model', [None])[0]
                if model is not None and len(model) > 512:
                    self.send(400, b'{"error":"invalid model"}', 'application/json; charset=utf-8')
                    return
                payload = json.dumps({
                    'range': period, 'bucket_seconds': bucket, 'generated_at': now,
                    'models': models(db_path),
                    'series': aggregate(db_path, now - duration, now + 1, bucket, model),
                }).encode()
                self.send(200, payload, 'application/json; charset=utf-8')
            elif url.path in ASSETS:
                filename, content_type = ASSETS[url.path]
                self.send(200, (assets_dir / filename).read_bytes(), content_type)
            else:
                self.send(404, b'not found\n', 'text/plain; charset=utf-8')

        def log_message(self, format, *args):
            pass

    return Handler


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host', default='127.0.0.1')
    parser.add_argument('--port', type=int, default=17483)
    args = parser.parse_args()
    db_path = Path(os.environ.get('TELEMETRY_DB', str(Path.home() / '.local/share/llama-telemetry/activity.sqlite')))
    allowed_login = os.environ.get('TELEMETRY_ALLOWED_LOGIN', '')
    server = ThreadingHTTPServer((validate_bind_host(args.host), args.port), make_handler(db_path, allowed_login=allowed_login))
    server.daemon_threads = True
    print(f'Listening on {args.host}:{server.server_port}', flush=True)
    server.serve_forever()


if __name__ == '__main__':
    main()
