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
            db.execute('CREATE TABLE pages (id,source,title,text,fetched_at,revid,raw_html,styles)')
            db.execute('INSERT INTO pages VALUES (1,\'osrs\',\'Oak\',\'Readable fallback\',0,1,?,\'[]\')', ('<p>Original oak</p><script>evil()</script>',))
            db.execute('INSERT INTO pages VALUES (2,\'osrs\',\'Old\',\'Old text\',0,1,NULL,\'[]\')')
            db.execute('CREATE TABLE assets (source,url,sha256,mime,size)')
            db.execute('INSERT INTO assets VALUES (\'osrs\',\'/images/Oak.png\',?,\'image/png\',?)', (self.digest, len(self.image)))
        self.http = server.PortalHTTPServer(('127.0.0.1', 0), server.Handler)
        self.http.portal = server.Portal(self.root, 'https://game.example', 'https://home.example')
        self.worker = threading.Thread(target=self.http.serve_forever, daemon=True)
        self.worker.start()
        self.addCleanup(self.stop)
        self.base = f'http://127.0.0.1:{self.http.server_port}'

    def stop(self):
        self.http.shutdown()
        self.http.server_close()
        self.worker.join()

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
