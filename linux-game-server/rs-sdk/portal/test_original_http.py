import hashlib
import os
import socket
from contextlib import closing
from pathlib import Path
import sqlite3
import tempfile
import threading
import unittest
from urllib.error import HTTPError
from urllib.request import urlopen

import server
from test_policy import fresh_policy, stamp
from unittest.mock import patch
from datetime import datetime, timezone
import json


class OriginalHTTPTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.image = b'\x89PNG\r\n\x1a\nfixture'
        self.digest = hashlib.sha256(self.image).hexdigest()
        (self.root / 'assets').mkdir()
        (self.root / 'assets' / self.digest).write_bytes(self.image)
        with closing(sqlite3.connect(self.root / 'scraped-wiki.sqlite')) as db, db:
            stamp(db)
            db.execute('CREATE TABLE pages (id,source,title,text,fetched_at,revid,raw_html,styles)')
            db.execute('INSERT INTO pages VALUES (1,\'osrs\',\'Oak\',\'Readable fallback\',0,1,?,\'[]\')', ('<p>Original oak</p><script>evil()</script>',))
            db.execute('INSERT INTO pages VALUES (2,\'osrs\',\'Old\',\'Old text\',0,1,NULL,\'[]\')')
            db.execute('CREATE TABLE assets (source,url,sha256,mime,size)')
            db.execute('INSERT INTO assets VALUES (\'osrs\',\'/images/Oak.png\',?,\'image/png\',?)', (self.digest, len(self.image)))
            db.execute('INSERT INTO assets VALUES (\'osrs\',\'/images/Oak (grown).png\',?,\'image/png\',?)', (self.digest, len(self.image)))
            db.execute('CREATE TABLE redirects (source,from_title,to_title)')
            db.execute('INSERT INTO redirects VALUES (\'osrs\',\'Oak tree\',\'Oak\')')
        self.wanted = self.root / 'wanted' / 'wanted.sqlite'
        self.wanted.parent.mkdir()
        self.http = server.PortalHTTPServer(('127.0.0.1', 0), server.Handler)
        self.http.portal = server.Portal(self.root, 'https://game.example', 'https://home.example', self.wanted)
        self.worker = threading.Thread(target=self.http.serve_forever, daemon=True)
        self.worker.start()
        self.addCleanup(self.stop)
        self.base = f'http://127.0.0.1:{self.http.server_port}'

    def stop(self):
        self.http.shutdown()
        self.http.server_close()
        self.worker.join()

    def test_expiry_and_missing_policy_block_every_wiki_http_surface(self):
        policy = fresh_policy()
        expiry = datetime.fromisoformat(policy['expiresAt'].replace('Z', '+00:00')).timestamp()
        routes = ['/rs-sdk/wiki/scraped', '/wiki/scraped?q=Oak',
                  '/rs-sdk/wiki/scraped/article?id=1', '/rs-sdk/wiki/scraped/w/osrs/Oak',
                  '/rs-sdk/wiki/scraped/w/osrs/Oak?view=clean',
                  '/rs-sdk/wiki/scraped/document?id=1',
                  '/rs-sdk/wiki/scraped/images/osrs/Oak.png',
                  '/rs-sdk/wiki/scraped/asset/' + self.digest]
        with closing(sqlite3.connect(self.root / 'scraped-wiki.sqlite')) as db, db:
            db.execute('UPDATE wiki_policy SET policy=?', (json.dumps(policy),))
        with patch('time.time', return_value=expiry - 0.001):
            for route in routes:
                with self.subTest(route=route):
                    status, _, headers, _ = self.fetch(route)
                    self.assertEqual(status, 200)
                    self.assertEqual(headers['Cache-Control'], 'no-store')
        for state in ('expired', 'missing'):
            if state == 'missing':
                with closing(sqlite3.connect(self.root / 'scraped-wiki.sqlite')) as db, db:
                    db.execute('DROP TABLE wiki_policy')
            with patch('time.time', return_value=expiry):
                for route in routes:
                    with self.subTest(state=state, route=route):
                        status, body, _, _ = self.fetch(route)
                        self.assertNotEqual(status, 200)
                        self.assertNotIn(b'Original oak', body)
                        self.assertNotIn(b'Readable fallback', body)
                        self.assertNotEqual(body, self.image)
        self.assertEqual(self.wanted_rows(), [])

    def test_cached_asset_metadata_cannot_bypass_expiry(self):
        policy = fresh_policy(datetime(2004, 5, 18, tzinfo=timezone.utc))
        with closing(sqlite3.connect(self.root / 'scraped-wiki.sqlite')) as db, db:
            db.execute('UPDATE wiki_policy SET policy=?', (json.dumps(policy),))
        with self.assertRaises(sqlite3.Error):
            self.http.portal.asset(self.digest, {'mime': 'image/png', 'size': len(self.image)})

    def test_override_original_document_is_labelled(self):
        policy = dict(fresh_policy(), mode='override', asOf='2004-05-18',
                      deployment=None, expiresAt=None, status='missing-or-invalid')
        with closing(sqlite3.connect(self.root / 'scraped-wiki.sqlite')) as db, db:
            db.execute('UPDATE wiki_policy SET policy=?', (json.dumps(policy),))
        status, body, _, _ = self.fetch('/rs-sdk/wiki/scraped/document?id=1')
        self.assertEqual(status, 200)
        self.assertTrue(b'Date-preview override: 2004-05-18' in body)

    def test_original_frame_is_isolated_and_clean_view_remains(self):
        with urlopen(self.base + '/rs-sdk/wiki/scraped/article?id=1') as response:
            body = response.read().decode()
            self.assertIn('<iframe', body)
            self.assertIn('sandbox="allow-top-navigation-by-user-activation"', body)
            self.assertNotIn('allow-same-origin', body)
            self.assertIn('/rs-sdk/wiki/scraped/document?id=1', body)
            self.assertIn('view=clean', body)
            self.assertIn("frame-src 'self'", response.headers['Content-Security-Policy'])
        with urlopen(self.base + '/rs-sdk/wiki/scraped/article?id=1&view=clean') as response:
            body = response.read().decode()
            self.assertNotIn('<iframe', body)
            self.assertIn('Readable fallback', body)
        with urlopen(self.base + '/rs-sdk/wiki/scraped/article?id=2') as response:
            self.assertNotIn('<iframe', response.read().decode())
        with urlopen(self.base + '/rs-sdk/') as response:
            self.assertNotIn('frame-src', response.headers['Content-Security-Policy'])

    def test_document_is_sanitized_and_has_strict_csp(self):
        with urlopen(self.base + '/rs-sdk/wiki/scraped/document?id=1') as response:
            body = response.read().decode()
            self.assertIn('Original oak', body)
            self.assertNotIn('<script', body)
            csp = response.headers['Content-Security-Policy']
            self.assertIn("default-src 'none'", csp)
            self.assertIn("frame-ancestors 'self'", csp)
            self.assertIn("form-action 'none'", csp)
            self.assertIn('sandbox allow-top-navigation-by-user-activation', csp)
        for path in ('/rs-sdk/wiki/rs-sdk/document?id=1', '/rs-sdk/wiki/scraped/document?id=2'):
            with self.assertRaises(HTTPError) as error:
                urlopen(self.base + path)
            self.assertEqual(error.exception.code, 404)
            error.exception.close()

    def test_only_manifest_raster_assets_are_served(self):
        with urlopen(self.base + '/rs-sdk/wiki/scraped/asset/' + self.digest) as response:
            self.assertEqual(response.read(), self.image)
            self.assertEqual(response.headers['Content-Type'], 'image/png')
            self.assertEqual(response.headers['X-Content-Type-Options'], 'nosniff')
        (self.root / 'assets' / self.digest).unlink()
        (self.root / 'assets' / self.digest).symlink_to(self.root / 'scraped-wiki.sqlite')
        for tail in (self.digest, '../scraped-wiki.sqlite', '%2e%2e%2fscraped-wiki.sqlite', '0' * 64):
            with self.assertRaises(HTTPError) as error:
                urlopen(self.base + '/rs-sdk/wiki/scraped/asset/' + tail)
            self.assertEqual(error.exception.code, 404)
            error.exception.close()


    def wanted_rows(self):
        if not self.wanted.exists():
            return []
        with closing(sqlite3.connect(self.wanted)) as db:
            return [tuple(r) for r in db.execute('SELECT source,kind,key FROM wanted ORDER BY kind,key')]

    def fetch(self, path):
        try:
            with urlopen(self.base + path) as response:
                return response.status, response.read(), response.headers, response.url
        except HTTPError as error:
            with error:
                return error.code, error.read(), error.headers, error.url

    def test_pages_route_by_title_with_aliases_and_redirects(self):
        status, body, headers, final = self.fetch('/rs-sdk/wiki/scraped/w/osrs/Oak')
        self.assertEqual(status, 200)
        self.assertIn(b'/rs-sdk/wiki/scraped/document?id=1', body)
        self.assertIn("frame-src 'self'", headers['Content-Security-Policy'])
        self.assertIn(b'href="/rs-sdk/wiki/scraped/w/osrs/Oak?view=clean"', body)
        for alias in ('/rs-sdk/wiki/scraped/article?id=1', '/rs-sdk/wiki/scraped/w/osrs/oak',
                      '/rs-sdk/wiki/scraped/w/osrs/Oak%20tree', '/rs-sdk/wiki/scraped/w/osrs/Oak_tree'):
            status, body, _, final = self.fetch(alias)
            self.assertEqual((status, final), (200, self.base + '/rs-sdk/wiki/scraped/w/osrs/Oak'), alias)
        status, body, _, final = self.fetch('/rs-sdk/wiki/scraped/article?id=1&view=clean')
        self.assertTrue(final.endswith('/w/osrs/Oak?view=clean'))
        self.assertNotIn(b'<iframe', body)
        self.assertEqual(self.wanted_rows(), [])

    def test_uncached_pages_are_requested_once_and_link_upstream(self):
        for _ in range(2):
            status, body, _, _ = self.fetch('/rs-sdk/wiki/scraped/w/rs3/Bronze_axe')
            self.assertEqual(status, 404)
            self.assertIn(b'has been requested', body)
            self.assertIn(b'https://runescape.wiki/w/Bronze_axe', body)
        status, body, _, _ = self.fetch('/rs-sdk/wiki/scraped/w/osrs/Category:Axes')
        self.assertEqual(status, 404)
        self.assertIn(b'isn\xe2\x80\x99t fetched on request', body)
        for bad in ('/rs-sdk/wiki/scraped/w/evil/Oak', '/rs-sdk/wiki/scraped/w/osrs/a%3Cb', '/rs-sdk/wiki/scraped/w/osrs/..'):
            self.assertIn(self.fetch(bad)[0], (400, 404), bad)
        self.assertEqual(self.wanted_rows(), [('rs3', 'page', 'Bronze axe')])

    def test_images_route_serves_cached_rasters_or_requests_a_placeholder(self):
        for path in ('/rs-sdk/wiki/scraped/images/osrs/Oak.png', '/rs-sdk/wiki/scraped/images/osrs/Oak_%28grown%29.png'.replace('_', '%20')):
            status, body, headers, _ = self.fetch(path)
            self.assertEqual((status, body, headers['Content-Type']), (200, self.image, 'image/png'), path)
        status, body, headers, _ = self.fetch('/rs-sdk/wiki/scraped/images/osrs/thumb/Pike.png/120px-Pike.png')
        self.assertEqual((status, headers['Content-Type'], headers['Cache-Control']), (200, 'image/svg+xml', 'no-store'))
        for bad in ('/rs-sdk/wiki/scraped/images/osrs/..%2fscraped-wiki.sqlite', '/rs-sdk/wiki/scraped/images/osrs/a//b.png',
                    '/rs-sdk/wiki/scraped/images/evil/Oak.png', '/rs-sdk/wiki/scraped/images/osrs/'):
            self.assertEqual(self.fetch(bad)[0], 404, bad)
        self.assertEqual(self.wanted_rows(), [('osrs', 'image', 'thumb/Pike.png/120px-Pike.png')])

    def test_nothing_is_recorded_without_a_wanted_file(self):
        self.http.portal.wanted.path = None
        status, body, _, _ = self.fetch('/rs-sdk/wiki/scraped/w/osrs/Shark')
        self.assertEqual(status, 404)
        self.assertIn(b'can\xe2\x80\x99t be recorded', body)
        self.assertFalse(self.wanted.exists())

    def test_fifo_and_swapped_asset_directory_do_not_hang_or_leak(self):
        fifo = 'f' * 64
        os.mkfifo(self.root / 'assets' / fifo)
        with closing(sqlite3.connect(self.root / 'scraped-wiki.sqlite')) as db, db:
            db.execute('INSERT INTO assets VALUES (\'osrs\',\'/images/Fifo.png\',?,\'image/png\',4)', (fifo,))
        self.addCleanup(lambda: os.path.lexists(self.root / 'assets' / fifo) and os.unlink(self.root / 'assets' / fifo))
        socket.setdefaulttimeout(3)
        self.addCleanup(socket.setdefaulttimeout, None)
        with self.assertRaises(HTTPError) as error:
            urlopen(self.base + '/rs-sdk/wiki/scraped/asset/' + fifo)
        self.assertEqual(error.exception.code, 404)
        error.exception.close()


if __name__ == '__main__':
    unittest.main()
