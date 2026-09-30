import io
import json
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path
from http.server import ThreadingHTTPServer

from server import make_handler, validate_bind_host
from store import ingest


class ServerTests(unittest.TestCase):
    def test_identity_header_server_cannot_bind_to_network_interfaces(self):
        self.assertEqual(validate_bind_host('127.0.0.1'), '127.0.0.1')
        for host in ('0.0.0.0', '::', '192.0.2.12'):
            with self.assertRaises(ValueError):
                validate_bind_host(host)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.db = Path(self.temp.name) / 'activity.sqlite'
        row = {'id': 1, 'ts_created': 1700000100, 'model_id': 'model-a',
               'resp_status_code': 200,
               'input_tokens': 100, 'output_tokens': 50, 'cache_tokens': 0,
               'prompt_per_second': 800, 'tokens_per_second': 50, 'duration_ms': 1000}
        ingest(self.db, 'host-a:one', io.StringIO(json.dumps(row) + '\n'))
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), make_handler(
            self.db, clock=lambda: 1700000400, allowed_login='owner@example.test'))
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.base = f'http://127.0.0.1:{self.server.server_port}'

    def request(self, path, login='owner@example.test'):
        headers = {'Tailscale-User-Login': login} if login else {}
        return urllib.request.urlopen(urllib.request.Request(self.base + path, headers=headers))

    def test_api_lists_models_and_returns_time_buckets(self):
        with self.request('/api/series?range=1d&model=model-a') as response:
            data = json.load(response)
            self.assertEqual(response.headers['Content-Type'], 'application/json; charset=utf-8')
            self.assertEqual(response.headers['Cache-Control'], 'no-store')
        self.assertEqual(data['models'], ['model-a'])
        self.assertEqual(data['bucket_seconds'], 3600)
        self.assertEqual(data['series'][0]['output_tokens'], 50)
        self.assertEqual(data['series'][0]['tg_tps'], 50)

    def test_invalid_range_is_rejected(self):
        with self.assertRaises(urllib.error.HTTPError) as error:
            self.request('/api/series?range=all')
        self.assertEqual(error.exception.code, 400)
        error.exception.close()

    def test_dashboard_and_health_are_served_without_secret_data(self):
        with self.request('/') as response:
            page = response.read().decode()
            self.assertIn('Model telemetry', page)
            self.assertIn("default-src 'none'", response.headers['Content-Security-Policy'])
        with urllib.request.urlopen(self.base + '/health') as response:
            self.assertEqual(response.status, 200)

    def test_identity_header_is_required_for_dashboard_and_data(self):
        for path in ('/', '/app.js', '/api/series?range=1d'):
            for login in ('', 'stranger@example.test'):
                with self.assertRaises(urllib.error.HTTPError) as error:
                    self.request(path, login=login)
                self.assertEqual(error.exception.code, 403)
                error.exception.close()


if __name__ == '__main__':
    unittest.main()
