import importlib.util
from contextlib import closing, redirect_stdout
import io
from pathlib import Path
import sqlite3
import tarfile
import tempfile
import threading
import unittest
from test_policy import stamp
from urllib.error import HTTPError
from urllib.request import Request, urlopen


class PortalTests(unittest.TestCase):
    def test_game_and_wiki_theme_shells(self):
        import server
        game = server.layout('Accounts', '<h1>Accounts</h1>')
        self.assertIn('class="game-page"', game)
        self.assertIn('class="tool-menu"', game)
        self.assertIn('/rs-sdk/assets/background2.jpg', game)
        wiki = server.layout('Wiki', '<h1>Wiki</h1>', wiki=True)
        self.assertIn('class="wiki-page"', wiki)
        self.assertIn('Read-only article cache', wiki)

    def test_wiki_article_has_contents_headings_tables_and_safe_text(self):
        import server
        self.assertTrue(hasattr(server, 'render_article'), 'Formatted wiki reader is missing')
        text = '# Woodcutting\n\nA skill. <script>evil()</script>\n\n## Axes\n| Axe | Level |\n| Bronze | 1 |\n| Rune | 41 |\n\n## Notes\n- Bank your logs\n- <img src=x onerror=evil()>\n'
        body = server.render_article(text, 'Woodcutting', 'rs-sdk')
        self.assertIn('<summary>Contents</summary>', body)
        self.assertLess(body.index('A skill.'), body.index('<summary>Contents</summary>'))
        self.assertIn('href="#section-1"', body)
        self.assertIn('<h2 id="section-1">Axes</h2>', body)
        self.assertIn('<th>Axe</th>', body)
        self.assertIn('<td>Rune</td>', body)
        self.assertIn('<li>Bank your logs</li>', body)
        self.assertIn('&lt;script&gt;evil()&lt;/script&gt;', body)
        self.assertNotIn('<script>', body)
        self.assertNotIn('<img ', body)
        self.assertNotIn('>Woodcutting</h2>', body)
        info = server.render_article('| Bronze axe |\n| Value | 16 coins |\n\nA bronze axe.', 'Bronze axe', 'osrs')
        self.assertIn('wiki-infobox', info)

    def test_landing_links_stay_under_mount(self):
        path = Path(__file__).with_name('server.py')
        self.assertTrue(path.exists(), 'Portal implementation is missing')
        spec = importlib.util.spec_from_file_location('portal', path)
        assert spec is not None and spec.loader is not None
        portal = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(portal)
        app = portal.Portal(Path('/nonexistent'), 'https://game.example:9445', 'https://game.example')
        status, body = app.render('/rs-sdk/', {})
        self.assertEqual(status, 200)
        for text in ('Account Database', 'Benchmarks', 'Wiki', 'Play', 'HiScores', 'Grand Exchange'):
            self.assertIn(text, body)
        self.assertIn('href="/rs-sdk/accounts"', body)
        self.assertIn('https://game.example:9445/hiscores', body)

    def test_accounts_hide_credentials_and_do_not_block_writer(self):
        import server
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            data = root
            with closing(sqlite3.connect(data / 'accounts.sqlite')) as writer, writer:
                writer.executescript('''
                    PRAGMA journal_mode=WAL;
                    CREATE TABLE accounts (username, password, status, purpose, notes,
                        server, runs_on, created_at, first_login_at, last_login_at, login_count);
                    CREATE TABLE deaths (username, died_at, x, z, plane, cause, context);
                    INSERT INTO accounts VALUES ('test_bot','SECRET_SENTINEL','active',
                        '<script>evil</script>','PRIVATE_NOTES','PRIVATE_HOST','PRIVATE_RUNNER',
                        '2026-01-01',NULL,NULL,2);
                    INSERT INTO deaths VALUES ('test_bot',NULL,1,2,0,'goblin','PRIVATE_CONTEXT');
                ''')
                app = server.Portal(root, 'https://game.example', 'https://home.example')
                writer.execute('BEGIN IMMEDIATE')
                status, body = app.render('/rs-sdk/accounts', {})
                self.assertEqual(status, 200)
                self.assertIn('test_bot', body)
                self.assertIn('class="scroll account-table"', body)
                self.assertIn('&lt;script&gt;evil&lt;/script&gt;', body)
                for private in ('SECRET_SENTINEL', 'PRIVATE_NOTES', 'PRIVATE_HOST', 'PRIVATE_RUNNER', 'PRIVATE_CONTEXT'):
                    self.assertNotIn(private, body)
                writer.execute("UPDATE accounts SET login_count=3")
                writer.commit()
                self.assertIn('3', app.render('/rs-sdk/accounts', {})[1])
                with server.read_db(data / 'accounts.sqlite') as reader:
                    with self.assertRaises(sqlite3.OperationalError):
                        reader.execute('DELETE FROM accounts')
                self.assertEqual(writer.execute('SELECT count(*) FROM accounts').fetchone()[0], 1)
                self.assertNotIn('test_bot', app.render('/rs-sdk/accounts', {'q': ["' OR 1=1 --"]})[1])
                self.assertEqual(app.render('/rs-sdk/accounts', {'page': ['bad']})[0], 400)
                self.assertEqual(app.render('/rs-sdk/data/accounts.sqlite', {})[0], 404)
                self.assertEqual(app.render('/rs-sdk/accounts', {'page': ['-1']})[0], 400)

    def test_missing_database_is_not_created(self):
        import server
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            app = server.Portal(root, 'https://game.example', 'https://home.example')
            self.assertEqual(app.render('/rs-sdk/accounts', {})[0], 503)
            self.assertEqual(list(root.iterdir()), [])

    def test_benchmark_summary_and_steps(self):
        import server
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            with closing(sqlite3.connect(root / 'benchmarks.sqlite')) as db, db:
                db.executescript('''
                    CREATE TABLE runs (id, benchmark, username, routine_sha, started_at,
                        finished_at, success, total_ms, routine_ms, ticks, steps, mode);
                    INSERT INTO runs VALUES (1,'tutorial','test_bot','abcd','2026-01-01',
                        '2026-01-01',1,1000,900,2,'[{"step":"Cooking","ms":100,"ticks":1}]','full');
                    INSERT INTO runs VALUES (2,'tutorial','test_bot','abcd','2026-01-01',
                        NULL,0,200,NULL,NULL,'[]','resume:cook');
                ''')
            app = server.Portal(root, 'https://game.example', 'https://home.example')
            status, body = app.render('/rs-sdk/benchmarks', {})
            self.assertEqual(status, 200)
            self.assertIn('Full-run summary', body)
            self.assertIn('100.0%', body)
            self.assertIn('resume:cook', body)
            self.assertIn('/rs-sdk/benchmark?id=1', body)
            status, body = app.render('/rs-sdk/benchmark', {'id': ['1']})
            self.assertEqual(status, 200)
            self.assertIn('Cooking', body)
            self.assertEqual(app.render('/rs-sdk/benchmark', {'id': ['999']})[0], 404)

    def test_wiki_search_and_escaped_article(self):
        import server
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            with closing(sqlite3.connect(root / 'rs-sdk-wiki.sqlite')) as db, db:
                stamp(db)
                db.executescript('''
                    CREATE TABLE pages (id, source, title, text, fetched_at, revid);
                    INSERT INTO pages VALUES (1,'rs-sdk','Oak tree','Woodcutting <script>evil</script>',0,1);
                ''')
            with closing(sqlite3.connect(root / 'scraped-wiki.sqlite')) as db, db:
                stamp(db)
                db.executescript('''
                    CREATE TABLE pages (id, source, title, text, fetched_at, revid);
                    INSERT INTO pages VALUES (1,'osrs','Raw shark','Fishing and Woodcutting',0,2);
                ''')
            app = server.Portal(root, 'https://game.example', 'https://home.example')
            status, chooser = app.render('/rs-sdk/wiki', {})
            self.assertEqual(status, 200)
            self.assertIn('RS-SDK Wiki', chooser)
            self.assertIn('Scraped Wiki', chooser)
            self.assertNotIn('<input type="search"', chooser)
            status, body = app.render('/rs-sdk/wiki/rs-sdk', {'q': ['woodcutting']})
            self.assertEqual(status, 200)
            self.assertIn('Oak tree', body)
            self.assertNotIn('Raw shark', body)
            self.assertIn('action="/rs-sdk/wiki/rs-sdk"', body)
            self.assertIn('/rs-sdk/wiki/rs-sdk/article?id=1', body)
            self.assertIn('Snapshot exported', body)
            status, body = app.render('/rs-sdk/wiki/rs-sdk/article', {'id': ['1']})
            self.assertEqual(status, 200)
            self.assertIn('&lt;script&gt;evil&lt;/script&gt;', body)
            self.assertNotIn('<script>', body)
            self.assertNotIn('Raw shark', body)
            status, body = app.render('/rs-sdk/wiki/scraped', {'q': ['woodcutting']})
            self.assertEqual(status, 200)
            self.assertIn('Raw shark', body)
            self.assertNotIn('Oak tree', body)
            self.assertIn('action="/rs-sdk/wiki/scraped"', body)
            self.assertIn('href="/rs-sdk/wiki/scraped/w/osrs/Raw_shark"', body)
            self.assertEqual(app.render('/rs-sdk/wiki/scraped/article', {'id': ['1']}), (302, '/rs-sdk/wiki/scraped/w/osrs/Raw_shark'))
            status, body = app.render('/rs-sdk/wiki/scraped/w/osrs/Raw_shark', {})
            self.assertEqual(status, 200)
            self.assertIn('oldschool.runescape.wiki/w/Raw_shark', body)
            self.assertIn('CC BY-NC-SA 3.0', body)
            self.assertEqual(app.render('/rs-sdk/wiki/scraped/article', {'id': ['999']})[0], 404)
            self.assertEqual(app.render('/rs-sdk/wiki/../accounts', {})[0], 404)
            (root / 'rs-sdk-wiki.sqlite').unlink()
            self.assertEqual(app.render('/rs-sdk/wiki/rs-sdk', {})[0], 503)
            self.assertEqual(app.render('/rs-sdk/wiki/scraped', {})[0], 200)
            self.assertFalse((root / 'wiki.sqlite').exists())

    def test_wiki_pagination_keeps_its_collection_and_query(self):
        import server
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            with closing(sqlite3.connect(root / 'rs-sdk-wiki.sqlite')) as db, db:
                stamp(db)
                db.execute('CREATE TABLE pages (id,source,title,text,fetched_at,revid)')
                db.executemany('INSERT INTO pages VALUES (?,\'rs-sdk\',?,\'Woodcutting\',0,1)', [(i, f'Tree {i:02}') for i in range(51)])
            app = server.Portal(root, 'https://game.example', 'https://home.example')
            status, body = app.render('/rs-sdk/wiki/rs-sdk', {'q': ['Woodcutting']})
            self.assertEqual(status, 200)
            self.assertIn('/rs-sdk/wiki/rs-sdk?q=Woodcutting&amp;page=2', body)
            status, body = app.render('/rs-sdk/wiki/rs-sdk', {'q': ['Woodcutting'], 'page': ['2']})
            self.assertEqual(status, 200)
            self.assertIn('Tree 50', body)
            self.assertNotIn('Tree 00', body)

    def test_snapshot_exports_only_allowed_columns(self):
        import sync
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / 'source.sqlite'
            dest = root / 'public.sqlite'
            with closing(sqlite3.connect(source)) as db, db:
                db.executescript('''CREATE TABLE accounts (username,password,status,purpose,
                    created_at,first_login_at,last_login_at,login_count);
                    CREATE TABLE deaths (username,context);
                    INSERT INTO accounts VALUES ('test_bot','SECRET_SENTINEL','active','test',NULL,NULL,NULL,1);
                    INSERT INTO deaths VALUES ('test_bot','PRIVATE_CONTEXT');''')
            original = source.read_bytes()
            sync.export_db(source, dest, sync.TABLES['accounts.sqlite'])
            self.assertEqual(source.read_bytes(), original)
            self.assertNotIn(b'SECRET_SENTINEL', dest.read_bytes())
            self.assertNotIn(b'PRIVATE_CONTEXT', dest.read_bytes())
            with closing(sqlite3.connect(dest)) as db, db:
                self.assertNotIn('password', [r[1] for r in db.execute('PRAGMA table_info(accounts)')])
                self.assertEqual(db.execute('SELECT username FROM accounts').fetchone()[0], 'test_bot')

    def test_wiki_exports_are_physically_separate_and_source_filtered(self):
        import sync
        self.assertIn('rs-sdk-wiki.sqlite', sync.TABLES)
        self.assertIn('scraped-wiki.sqlite', sync.TABLES)
        self.assertNotIn('wiki.sqlite', sync.TABLES)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / 'source.sqlite'
            with closing(sqlite3.connect(source)) as db, db:
                db.execute('CREATE TABLE pages (id,source,title,text,fetched_at,revid)')
                db.executemany('INSERT INTO pages VALUES (?,?,?,\'Cached text\',0,1)', [(1,'rs-sdk','Local'), (2,'osrs','External'), (3,'rs3','External 3'), (4,'unknown','Unclassified')])
            before = source.read_bytes()
            for name, expected in [('rs-sdk-wiki.sqlite', ['rs-sdk']), ('scraped-wiki.sqlite', ['osrs', 'rs3'])]:
                dest = root / name
                sync.export_db(source, dest, sync.TABLES[name], sources=sync.PAGE_SOURCES[name])
                with closing(sqlite3.connect(dest)) as db, db:
                    self.assertEqual([row[0] for row in db.execute('SELECT source FROM pages ORDER BY id')], expected)
            self.assertEqual(before, source.read_bytes())

    def test_receiver_rejects_paths_and_incomplete_archives(self):
        import sync
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / 'data'
            for name in ('../escape', 'accounts.sqlite'):
                payload = io.BytesIO()
                with tarfile.open(fileobj=payload, mode='w:gz') as archive:
                    entry = tarfile.TarInfo(name)
                    archive.addfile(entry, io.BytesIO())
                payload.seek(0)
                with self.assertRaises(ValueError):
                    sync.receive(payload, target)
                self.assertEqual(list(target.iterdir()), [])
                self.assertFalse((Path(tmp) / 'escape').exists())

    def test_receiver_checks_wiki_collection_before_publishing(self):
        import sync
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            stage, target = root / 'stage', root / 'published'
            stage.mkdir()
            target.mkdir()
            legacy = target / 'wiki.sqlite'
            legacy.write_bytes(b'Legacy file must not be deleted by sync')
            for name, tables in sync.TABLES.items():
                with closing(sqlite3.connect(stage / name)) as db, db:
                    for table, columns in tables.items():
                        db.execute(f'CREATE TABLE {table} ({",".join(columns)})')
                    if name in sync.PAGE_SOURCES:
                        db.execute('INSERT INTO pages (id,source,title,text,fetched_at,revid) VALUES (1,?,\'Fixture page\',\'Text\',0,1)', (sync.PAGE_SOURCES[name][0],))
            before = {}
            for corrupt in (False, True):
                if corrupt:
                    with closing(sqlite3.connect(stage / 'rs-sdk-wiki.sqlite')) as db, db:
                        db.execute("UPDATE pages SET source='osrs'")
                payload = io.BytesIO()
                with tarfile.open(fileobj=payload, mode='w:gz') as archive:
                    for name in sync.TABLES:
                        archive.add(stage / name, arcname=name)
                payload.seek(0)
                if not corrupt:
                    with redirect_stdout(io.StringIO()):
                        sync.receive(payload, target)
                    before = {name: (target / name).read_bytes() for name in sync.TABLES}
                else:
                    with self.assertRaisesRegex(ValueError, 'collection'):
                        sync.receive(payload, target)
                    self.assertEqual(before, {name: (target / name).read_bytes() for name in sync.TABLES})
                self.assertEqual(legacy.read_bytes(), b'Legacy file must not be deleted by sync')

    def test_benchmark_snapshot_projects_nested_steps(self):
        import json
        import sync
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / 'source.sqlite'
            dest = Path(tmp) / 'public.sqlite'
            columns = sync.TABLES['benchmarks.sqlite']['runs']
            values = dict.fromkeys(columns)
            values.update(id=1, benchmark='tutorial', steps=json.dumps([
                {'step': 'Cooking', 'ms': 100, 'ticks': 1, 'error': 'SECRET_SENTINEL', 'context': {'password': 'PRIVATE_CONTEXT'}},
                {'step': {'password': 'NESTED_SECRET'}, 'ms': 'NUMERIC_SECRET', 'ticks': 2},
            ]))
            with closing(sqlite3.connect(source)) as db, db:
                db.execute('CREATE TABLE runs (' + ','.join(columns) + ')')
                db.execute('INSERT INTO runs VALUES (' + ','.join('?' for _ in columns) + ')', tuple(values.values()))
            sync.export_db(source, dest, sync.TABLES['benchmarks.sqlite'])
            for secret in (b'SECRET_SENTINEL', b'PRIVATE_CONTEXT', b'NESTED_SECRET', b'NUMERIC_SECRET'):
                self.assertFalse(secret in dest.read_bytes(), 'Nested private fields reached snapshot')
            with closing(sqlite3.connect(dest)) as db, db:
                steps = json.loads(db.execute('SELECT steps FROM runs').fetchone()[0])
            self.assertEqual(steps, [{'step': 'Cooking', 'ms': 100, 'ticks': 1}])

    def test_http_prefix_security_headers_and_no_writes(self):
        import server
        http = server.PortalHTTPServer(('127.0.0.1', 0), server.Handler)
        http.portal = server.Portal(Path('/nonexistent'), 'https://game.example', 'https://home.example')
        assets = tempfile.TemporaryDirectory()
        self.addCleanup(assets.cleanup)
        http.assets_dir = Path(assets.name)
        image = b'\xff\xd8\xff\xd9'
        (http.assets_dir / 'background2.jpg').write_bytes(image)
        worker = threading.Thread(target=http.serve_forever, daemon=True)
        worker.start()
        try:
            base = f'http://127.0.0.1:{http.server_port}'
            for path in ('/', '/rs-sdk', '/rs-sdk/'):
                with urlopen(base + path) as response:
                    self.assertEqual(response.status, 200)
                    self.assertIn('Wiki', response.read().decode())
                    self.assertEqual(response.headers['Cache-Control'], 'no-store')
                    self.assertIn("default-src 'none'", response.headers['Content-Security-Policy'])
                    self.assertIn("img-src 'self'", response.headers['Content-Security-Policy'])
            with urlopen(base + '/rs-sdk/assets/background2.jpg') as response:
                self.assertEqual(response.headers['Content-Type'], 'image/jpeg')
                self.assertEqual(response.read(), image)
            for path in ('/assets/server.py', '/assets/%2e%2e/server.py'):
                with self.assertRaises(HTTPError) as rejected:
                    urlopen(base + path)
                self.assertEqual(rejected.exception.code, 404)
                rejected.exception.close()
            with self.assertRaises(HTTPError) as caught:
                urlopen(Request(base + '/accounts', data=b'x', method='POST'))
            self.assertEqual(caught.exception.code, 501)
            caught.exception.close()
            with self.assertRaises(HTTPError) as caught:
                urlopen(base + '/accounts')
            self.assertEqual(caught.exception.code, 503)
            caught.exception.close()
        finally:
            http.shutdown()
            http.server_close()
            worker.join()


if __name__ == '__main__':
    unittest.main()
