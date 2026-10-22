from contextlib import closing
import hashlib
import io
import json
from pathlib import Path
import sqlite3
import tarfile
import tempfile
import unittest

import sync


class SyncAssetTests(unittest.TestCase):
    def test_cached_assets_are_projected_without_following_unsafe_files(self):
        import base64
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            wiki = root / 'wiki'
            (wiki / 'data').mkdir(parents=True)
            (wiki / 'images/osrs').mkdir(parents=True)
            (wiki / 'assets/osrs').mkdir(parents=True)
            png = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=')
            (wiki / 'images/osrs/tree.png').write_bytes(png)
            (wiki / 'images/osrs/link.png').symlink_to('tree.png')
            (wiki / 'images/osrs/bad.png').write_bytes(b'<script>bad</script>')
            (wiki / 'assets/osrs/main.css').write_text('.tree { color: green; }')
            (wiki / 'assets/osrs/font.woff').write_text('body {}')
            url = 'https://oldschool.runescape.wiki/load.php?modules=main'
            with closing(sqlite3.connect(wiki / 'data/images.sqlite')) as db, db:
                db.execute('CREATE TABLE images (source,path,status,mime,bytes,sha256)')
                for path in ('tree.png', 'link.png', 'bad.png', '../tree.png', 'missing.png'):
                    db.execute('INSERT INTO images VALUES (?,?,\'ok\',?,?,?)', ('osrs', path, 'image/png', len(png), hashlib.sha256(png).hexdigest()))
                db.execute('CREATE TABLE assets (source,url,file,bytes)')
                db.execute('INSERT INTO assets VALUES (?,?,?,?)', ('osrs', url, 'osrs/main.css', 22))
                db.execute('INSERT INTO assets VALUES (?,?,?,?)', ('osrs', url + '&font=1', 'osrs/font.woff', 7))
            snapshot = root / 'scraped.sqlite'
            with closing(sqlite3.connect(snapshot)) as db, db:
                db.execute('CREATE TABLE assets (source,url,sha256,mime,size)')
            blobs = root / 'blobs'
            sync.export_assets(wiki, snapshot, blobs)
            with closing(sqlite3.connect(snapshot)) as db, db:
                rows = db.execute('SELECT source,url,sha256,mime,size FROM assets ORDER BY mime').fetchall()
            self.assertEqual([(r[0], r[1], r[3]) for r in rows], [('osrs', '/images/tree.png', 'image/png'), ('osrs', url, 'text/css')])
            self.assertEqual((blobs / rows[0][2]).read_bytes(), png)
            self.assertEqual(len(list(blobs.iterdir())), 2)

    def snapshots(self, root, legacy=False):
        root.mkdir()
        for name, tables in sync.TABLES.items():
            with closing(sqlite3.connect(root / name)) as db, db:
                for table, columns in tables.items():
                    if legacy and name == 'scraped-wiki.sqlite':
                        if table in ('assets', 'redirects'):
                            continue
                        columns = columns[:6]
                    db.execute(f'CREATE TABLE {table} ({",".join(columns)})')

    def archive(self, stage, extra=()):
        payload = io.BytesIO()
        with tarfile.open(fileobj=payload, mode='w:gz') as archive:
            for name in sync.TABLES:
                archive.add(stage / name, arcname=name)
            for name, data in extra:
                entry = tarfile.TarInfo(name)
                entry.size = len(data)
                archive.addfile(entry, io.BytesIO(data))
        payload.seek(0)
        return payload

    def test_receiver_installs_blobs_and_accepts_incremental_and_legacy(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            stage, target = root / 'stage', root / 'target'
            self.snapshots(stage)
            css = b'body { color: red; }'
            digest = hashlib.sha256(css).hexdigest()
            with closing(sqlite3.connect(stage / 'scraped-wiki.sqlite')) as db, db:
                db.execute('INSERT INTO assets VALUES (?,?,?,?,?)', ('osrs', 'https://oldschool.runescape.wiki/load.php?a=b', digest, 'text/css', len(css)))
            sync.receive(self.archive(stage, [('assets/' + digest, css)]), target)
            self.assertEqual((target / 'assets' / digest).read_bytes(), css)
            self.assertEqual(sync.inventory(target), [digest])
            sync.receive(self.archive(stage), target)
            legacy = root / 'legacy'
            self.snapshots(legacy, legacy=True)
            sync.receive(self.archive(legacy), target)
            self.assertEqual((target / 'assets' / digest).read_bytes(), css)

    def test_push_queries_hash_inventory_and_does_not_resend_blobs(self):
        from unittest.mock import patch
        import subprocess
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            wiki = root / '2004Scape-Wiki'
            (wiki / 'data').mkdir(parents=True)
            (wiki / 'assets/osrs').mkdir(parents=True)
            bot = root / '2004Scape-Botting/data'
            bot.mkdir(parents=True)
            for name in ('accounts.sqlite', 'benchmarks.sqlite'):
                with closing(sqlite3.connect(bot / name)) as db, db:
                    for table, columns in sync.TABLES[name].items():
                        db.execute(f'CREATE TABLE {table} ({",".join(columns)})')
            with closing(sqlite3.connect(wiki / 'data/wiki.sqlite')) as db, db:
                db.execute('CREATE TABLE pages (id,source,title,text,fetched_at,revid)')
            css = b'body { color: red; }'
            (wiki / 'assets/osrs/main.css').write_bytes(css)
            with closing(sqlite3.connect(wiki / 'data/images.sqlite')) as db, db:
                db.execute('CREATE TABLE assets (source,url,file,bytes)')
                db.execute('INSERT INTO assets VALUES (?,?,?,?)', ('osrs', 'https://oldschool.runescape.wiki/load.php', 'osrs/main.css', len(css)))
            target = root / 'target'
            transfers = []
            def ssh(command, **kwargs):
                if command[-1].endswith(' inventory'):
                    return subprocess.CompletedProcess(command, 0, stdout=json.dumps(sync.inventory(target)))
                if command[-1].endswith(' take-wanted'):
                    return subprocess.CompletedProcess(command, 0, stdout='[]')
                payload = kwargs['stdin'].read()
                with tarfile.open(fileobj=io.BytesIO(payload), mode='r:gz') as archive:
                    transfers.append(archive.getnames())
                sync.receive(io.BytesIO(payload), target)
                return subprocess.CompletedProcess(command, 0)
            with patch.object(sync.subprocess, 'run', side_effect=ssh):
                sync.push(root, 'game.example', 'portal/sync.py')
                sync.push(root, 'game.example', 'portal/sync.py')
            blob = 'assets/' + hashlib.sha256(css).hexdigest()
            self.assertIn(blob, transfers[0])
            self.assertNotIn(blob, transfers[1])
            self.assertEqual(set(transfers[1]), set(sync.TABLES))
            legacy = []
            def old_receiver(command, **kwargs):
                if command[-1].endswith(' take-wanted'):
                    raise subprocess.CalledProcessError(2, command)
                if command[-1].endswith(' receive'):
                    payload = kwargs['stdin'].read()
                    with tarfile.open(fileobj=io.BytesIO(payload), mode='r:gz') as archive:
                        (root / 'old').mkdir(exist_ok=True)
                        (root / 'old/scraped-wiki.sqlite').write_bytes(archive.extractfile('scraped-wiki.sqlite').read())
                    with closing(sqlite3.connect(root / 'old/scraped-wiki.sqlite')) as db:
                        legacy.extend(r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'"))
                    return subprocess.CompletedProcess(command, 0)
                return ssh(command, **kwargs)
            with patch.object(sync.subprocess, 'run', side_effect=old_receiver):
                sync.push(root, 'game.example', 'portal/sync.py')
            self.assertEqual(sorted(legacy), ['assets', 'pages'])

    def test_interrupted_compression_preserves_previous_snapshots(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            stage, target = root / 'stage', root / 'target'
            self.snapshots(stage)
            sync.receive(self.archive(stage), target)
            before = {name: (target / name).read_bytes() for name in sync.TABLES}
            payload = self.archive(stage).getvalue()
            for broken in (payload[:-8], payload[:len(payload) // 2]):
                with self.assertRaises(ValueError):
                    sync.receive(io.BytesIO(broken), target)
                self.assertEqual(before, {name: (target / name).read_bytes() for name in sync.TABLES})
                self.assertFalse(list(target.glob('.incoming-*')))

    def test_raster_formats_are_bounded_and_structurally_validated(self):
        import base64
        fixtures = {
            'image/jpeg': '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAABAAEDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwD3+iiigD//2Q==',
            'image/gif': 'R0lGODdhAQABAIEAAP///wAAAAAAAAAAACwAAAAAAQABAAAIBAABBAQAOw==',
            'image/webp': 'UklGRiQAAABXRUJQVlA4IBgAAAAwAQCdASoBAAEAAUAmJaQAA3AA/vz0AAA=',
        }
        for mime, encoded in fixtures.items():
            data = base64.b64decode(encoded)
            with self.subTest(mime=mime):
                sync.validate_asset(data, mime)
                for broken in (data[:12], data[:-1], b'<svg/>'):
                    with self.assertRaises(ValueError):
                        sync.validate_asset(broken, mime)
                with self.assertRaises(ValueError):
                    sync.validate_asset(data, 'image/png')
        for mime in ('image/svg+xml', 'font/woff2', 'text/html'):
            with self.assertRaises(ValueError):
                sync.validate_asset(b'<svg/>', mime)

    def test_receiver_rejects_invalid_metadata_blobs_and_archive_links(self):
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            stage, target = root / 'stage', root / 'target'
            self.snapshots(stage)
            sync.receive(self.archive(stage), target)
            before = {name: (target / name).read_bytes() for name in sync.TABLES}
            css = b'body{}'
            digest = hashlib.sha256(css).hexdigest()
            good = ('osrs', 'https://oldschool.runescape.wiki/load.php', digest, 'text/css', len(css))
            invalid = [
                ('rs-sdk',) + good[1:],
                (good[0], 'https://evil.example/main.css') + good[2:],
                good[:2] + ('../escape',) + good[3:],
                good[:3] + ('image/svg+xml', len(css)),
                good[:4] + (len(css) + 1,),
                good[:4] + (-1,),
                good[:4] + (True,),
                ('osrs', '/images/../escape', digest, 'image/png', len(css)),
            ]
            for row in invalid:
                with self.subTest(row=row):
                    with closing(sqlite3.connect(stage / 'scraped-wiki.sqlite')) as db, db:
                        db.execute('DELETE FROM assets')
                        db.execute('INSERT INTO assets VALUES (?,?,?,?,?)', row)
                    with self.assertRaises(ValueError):
                        sync.receive(self.archive(stage, [('assets/' + digest, css)]), target)
                    self.assertEqual(before, {name: (target / name).read_bytes() for name in sync.TABLES})
            with closing(sqlite3.connect(stage / 'scraped-wiki.sqlite')) as db, db:
                db.execute('DELETE FROM assets')
                db.execute('INSERT INTO assets VALUES (?,?,?,?,?)', good)
            for extra in ([], [('assets/' + digest, b'wrong')], [('assets/' + digest, css)] * 2, [('assets/../escape', css)]):
                with self.assertRaises(ValueError):
                    sync.receive(self.archive(stage, extra), target)
            with patch.object(sync, 'MAX_TOTAL', 100):
                with self.assertRaisesRegex(ValueError, 'limit'):
                    sync.receive(self.archive(stage), target)
            payload = io.BytesIO()
            with tarfile.open(fileobj=payload, mode='w:gz') as archive:
                entry = tarfile.TarInfo('accounts.sqlite')
                entry.type = tarfile.SYMTYPE
                entry.linkname = '../escape'
                archive.addfile(entry)
            payload.seek(0)
            with self.assertRaises(ValueError):
                sync.receive(payload, target)
            self.assertEqual(before, {name: (target / name).read_bytes() for name in sync.TABLES})

    def test_cache_directory_symlink_swap_is_not_followed(self):
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            cache = root / 'cache'
            (cache / 'osrs').mkdir(parents=True)
            (cache / 'osrs/file.css').write_bytes(b'body{}')
            outside = root / 'outside'
            outside.mkdir()
            (outside / 'file.css').write_bytes(b'PRIVATE_SENTINEL')
            original_open = sync.os.open
            swapped = False
            def swap(path, flags, *args, **kwargs):
                nonlocal swapped
                if not swapped:
                    (cache / 'osrs').rename(cache / 'old')
                    (cache / 'osrs').symlink_to(outside, target_is_directory=True)
                    swapped = True
                return original_open(path, flags, *args, **kwargs)
            with patch.object(sync.os, 'open', side_effect=swap):
                with self.assertRaises((ValueError, OSError)):
                    sync.cached_bytes(cache, 'osrs/file.css', 100)

    def test_receiver_lock_serializes_stream_consumption(self):
        import fcntl
        import os
        import threading
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            stage, target = root / 'stage', root / 'target'
            self.snapshots(stage)
            target.mkdir()
            consumed = threading.Event()
            errors = []
            class Stream(io.BytesIO):
                def read(self, *args):
                    consumed.set()
                    return super().read(*args)
            payload = Stream(self.archive(stage).getvalue())
            def receiver():
                try:
                    sync.receive(payload, target)
                except Exception as error:
                    errors.append(error)
            fd = os.open(target, os.O_RDONLY | os.O_DIRECTORY)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX)
                worker = threading.Thread(target=receiver)
                worker.start()
                self.assertFalse(consumed.wait(.1))
            finally:
                os.close(fd)
            worker.join(5)
            self.assertFalse(worker.is_alive())
            self.assertTrue(consumed.is_set())
            self.assertEqual(errors, [])
            self.assertEqual({p.name for p in target.iterdir()}, set(sync.TABLES))

    def test_inventory_cli_is_read_only_and_ignores_invalid_blobs(self):
        import subprocess
        import sys
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            missing = root / 'missing'
            command = [sys.executable, str(Path(sync.__file__)), 'inventory', '--target']
            result = subprocess.run(command + [str(missing)], capture_output=True, text=True, check=True)
            self.assertEqual(json.loads(result.stdout), [])
            self.assertFalse(missing.exists())
            assets = root / 'assets'
            assets.mkdir()
            css = b'body{}'
            digest = hashlib.sha256(css).hexdigest()
            (assets / digest).write_bytes(css)
            (assets / ('0' * 64)).write_bytes(b'wrong hash')
            (assets / ('1' * 64)).symlink_to(digest)
            result = subprocess.run(command + [str(root)], capture_output=True, text=True, check=True)
            self.assertEqual(json.loads(result.stdout), [digest])
            alias = root / 'alias'
            alias.symlink_to(root, target_is_directory=True)
            result = subprocess.run(command + [str(alias)], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)

    def test_original_snapshot_and_legacy_fallback(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / 'wiki.sqlite'
            with closing(sqlite3.connect(source)) as db, db:
                db.execute('CREATE TABLE pages (id,source,title,text,fetched_at,revid)')
                db.execute("INSERT INTO pages VALUES (1,'osrs','Tree','Text',0,1)")
            sync.export_db(source, root / 'old.sqlite', sync.TABLES['scraped-wiki.sqlite'], ('osrs', 'rs3'))
            with closing(sqlite3.connect(root / 'old.sqlite')) as db, db:
                self.assertEqual(db.execute('SELECT raw_html,styles FROM pages').fetchone(), (None, '[]'))
                self.assertEqual(db.execute('SELECT count(*) FROM assets').fetchone()[0], 0)
            with closing(sqlite3.connect(source)) as db, db:
                db.execute('ALTER TABLE pages ADD COLUMN raw_html')
                db.execute('ALTER TABLE pages ADD COLUMN styles')
                db.execute('UPDATE pages SET raw_html=?,styles=?', ('<table>original</table>', '["https://oldschool.runescape.wiki/load.php?a=b"]'))
            before = source.read_bytes()
            sync.export_db(source, root / 'new.sqlite', sync.TABLES['scraped-wiki.sqlite'], ('osrs', 'rs3'))
            with closing(sqlite3.connect(root / 'new.sqlite')) as db, db:
                self.assertEqual(db.execute('SELECT raw_html,styles FROM pages').fetchone(), ('<table>original</table>', '["https://oldschool.runescape.wiki/load.php?a=b"]'))
            self.assertEqual(before, source.read_bytes())
            self.assertEqual(sync.TABLES['rs-sdk-wiki.sqlite']['pages'], ('id', 'source', 'title', 'text', 'fetched_at', 'revid'))

    def test_generated_columns_are_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'accounts.sqlite'
            with closing(sqlite3.connect(path)) as db, db:
                db.execute('CREATE TABLE accounts (username,status,purpose,created_at,first_login_at,last_login_at,login_count,extra AS (username) VIRTUAL)')
                db.execute('CREATE TABLE deaths (username)')
            with self.assertRaises(ValueError):
                sync.check_snapshot(path, 'accounts.sqlite')

    def test_redirects_are_projected_per_collection_and_validated(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / 'wiki.sqlite'
            with closing(sqlite3.connect(source)) as db, db:
                db.execute('CREATE TABLE pages (id,source,title,text,fetched_at,revid,raw_html,styles)')
                db.execute('CREATE TABLE redirects (source,from_title,to_title)')
                db.executemany('INSERT INTO redirects VALUES (?,?,?)', [('osrs', 'Oak tree', 'Oak'), ('rs-sdk', 'Secret', 'Oak')])
            dest = root / 'scraped-wiki.sqlite'
            sync.export_db(source, dest, sync.TABLES['scraped-wiki.sqlite'], ('osrs', 'rs3'))
            with closing(sqlite3.connect(dest)) as db:
                self.assertEqual(db.execute('SELECT * FROM redirects').fetchall(), [('osrs', 'Oak tree', 'Oak')])
            self.assertEqual(sync.check_snapshot(dest, 'scraped-wiki.sqlite'), [])
            with closing(sqlite3.connect(dest)) as db, db:
                db.execute("INSERT INTO redirects VALUES ('evil','a','b')")
            with self.assertRaises(ValueError):
                sync.check_snapshot(dest, 'scraped-wiki.sqlite')

    def test_wanted_requests_are_taken_once_and_revalidated(self):
        from unittest.mock import patch
        import subprocess
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.assertEqual(sync.take_wanted(root / 'none.sqlite'), [])
            path = root / 'wanted.sqlite'
            with closing(sqlite3.connect(path)) as db, db:
                db.execute('CREATE TABLE wanted (source,kind,key,requested_at)')
                db.executemany('INSERT INTO wanted VALUES (?,?,?,?)', [
                    ('osrs', 'page', 'Bronze axe', 2), ('osrs', 'image', 'thumb/A.png/1px-A.png', 1),
                    ('osrs', 'image', '../secret', 3), ('evil', 'page', 'X', 4), ('osrs', 'page', 'a<b', 5)])
            taken = sync.take_wanted(path)
            self.assertEqual(taken, [{'source': 'osrs', 'kind': 'image', 'key': 'thumb/A.png/1px-A.png'},
                                     {'source': 'osrs', 'kind': 'page', 'key': 'Bronze axe'}])
            self.assertEqual(sync.take_wanted(path), [])
            (root / '2004Scape-Wiki/src').mkdir(parents=True)
            (root / '2004Scape-Wiki/src/cli.ts').write_text('')
            calls = []
            def run(command, **kwargs):
                calls.append((command, kwargs['input'], kwargs['cwd']))
                return subprocess.CompletedProcess(command, 0, stdout='queued', stderr='')
            with patch.object(sync.shutil, 'which', return_value='/bin/bun'), patch.object(sync.subprocess, 'run', side_effect=run), \
                    patch('sys.stdout', io.StringIO()):
                sync.queue_wanted(root, taken + [{'source': 'osrs', 'kind': 'page', 'key': 'x', 'extra': 1}])
                sync.queue_wanted(root, [])
            self.assertEqual(len(calls), 1)
            command, payload, cwd = calls[0]
            self.assertEqual(command, ['/bin/bun', 'src/cli.ts', 'want'])
            self.assertEqual(cwd, root / '2004Scape-Wiki')
            self.assertEqual([json.loads(line) for line in payload.splitlines()], taken)


if __name__ == '__main__':
    unittest.main()
