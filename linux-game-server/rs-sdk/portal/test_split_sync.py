from contextlib import closing
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import sqlite3
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

import sync
from test_policy import fresh_policy
from datetime import datetime, timezone


ACCOUNTS = {'accounts.sqlite', 'benchmarks.sqlite'}
WIKI = set(sync.TABLES) - ACCOUNTS


class SplitSyncTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.stage = self.root / 'stage'
        self.stage.mkdir()
        self.target = self.root / 'target'
        for name, tables in sync.TABLES.items():
            with closing(sqlite3.connect(self.stage / name)) as db, db:
                for table, columns in tables.items():
                    db.execute(f'CREATE TABLE {table} ({",".join(columns)})')

    def archive(self, names, blobs=()):
        payload = io.BytesIO()
        with tarfile.open(fileobj=payload, mode='w:gz') as archive:
            for name in sorted(names):
                archive.add(self.stage / name, arcname=name)
            for name, data in blobs:
                entry = tarfile.TarInfo(name)
                entry.size = len(data)
                archive.addfile(entry, io.BytesIO(data))
        payload.seek(0)
        return payload

    def wiki(self, as_of=None):
        wiki = self.root / 'authoritative-wiki'
        (wiki / 'data').mkdir(parents=True)
        with closing(sqlite3.connect(wiki / 'data/wiki.sqlite')) as db, db:
            db.execute('CREATE TABLE pages (id,source,title,text,wikitext,categories,fetched_at,revid)')
            for index, source in enumerate(('rs-sdk', 'osrs', 'rs3', '2004scape')):
                db.execute('INSERT INTO pages VALUES (?,?,?,?,?,?,?,?)',
                           (index, source, 'Tree', 'public text', '# Tree', '[]', 0, 1))
        (wiki / 'assets/osrs').mkdir(parents=True)
        css = b'body {color: red}'
        (wiki / 'assets/osrs/main.css').write_bytes(css)
        with closing(sqlite3.connect(wiki / 'data/images.sqlite')) as db, db:
            db.execute('CREATE TABLE assets (source,url,file,bytes)')
            db.execute('INSERT INTO assets VALUES (?,?,?,?)',
                       ('osrs', 'https://oldschool.runescape.wiki/load.php', 'osrs/main.css', len(css)))
        (wiki / 'bin').mkdir()
        projection = {'policy': fresh_policy(), 'pages': [
            {'id': index, 'source': source, 'title': 'Tree', 'text': 'public text',
             'html': '<p>public text</p>', 'wikitext': '# Tree', 'categories': '[]',
             'fetched_at': 0, 'revid': 1, 'raw_html': None, 'styles': '[]'}
            for index, source in enumerate(('rs-sdk', 'osrs', 'rs3', '2004scape'))]}
        if as_of is not None:
            projection['policy'].update(mode='override', asOf=as_of, effectiveDate=as_of)
        (wiki / 'visible.json').write_text(json.dumps(projection))
        command = wiki / 'bin/wiki'
        command.write_text('#!' + sys.executable + '\n'
                           'import json, pathlib, sys\n'
                           'with pathlib.Path("calls.jsonl").open("a") as out:\n'
                           '    out.write(json.dumps([sys.argv[1:], sys.stdin.read() if sys.argv[1] == "want" else ""]) + "\\n")\n'
                           'if sys.argv[1] == "export-visible":\n'
                           '    print(pathlib.Path("visible.json").read_text())\n')
        command.chmod(0o700)
        with closing(sqlite3.connect(wiki / 'data/wiki.sqlite')) as db, db:
            db.execute("UPDATE pages SET text='MODERN_RAW_SECRET'")
        return wiki, css

    def test_asset_projection_releases_source_database_before_blob_io(self):
        wiki, _ = self.wiki()
        original = sync.cached_bytes

        def read_while_writer_runs(*args):
            with closing(sqlite3.connect(wiki / 'data/images.sqlite', timeout=0.05)) as db, db:
                db.execute('UPDATE assets SET bytes=bytes')
            return original(*args)

        with patch.object(sync, 'cached_bytes', side_effect=read_while_writer_runs):
            sync.export_assets(wiki, self.stage / 'scraped-wiki.sqlite', self.stage / 'assets')

    def test_invalid_canonical_projection_never_replaces_snapshots(self):
        wiki, _ = self.wiki()
        sync.receive(self.archive(set(sync.TABLES)), self.target)
        before = {name: (self.target / name).read_bytes() for name in sync.TABLES}
        good = json.loads((wiki / 'visible.json').read_text())
        invalid = [None, [], {}, {'policy': None, 'pages': []}, {'policy': {}, 'pages': {}},
                   dict(good, pages=[None]), dict(good, pages=[{}])]
        for key, value in [('source', 'private'), ('source', []), ('id', True), ('id', -1),
                           ('title', None), ('text', []), ('html', 1), ('wikitext', []),
                           ('categories', {}), ('fetched_at', 'yesterday'), ('revid', False),
                           ('raw_html', '<p>MODERN_RAW_SECRET</p>'), ('styles', '["secret.css"]')]:
            page = dict(good['pages'][1], **{key: value})
            invalid.append(dict(good, pages=[page]))
        for key in good['pages'][1]:
            page = dict(good['pages'][1])
            del page[key]
            invalid.append(dict(good, pages=[page]))
        invalid.append(dict(good, pages=[good['pages'][0]] * 2))
        for projection in invalid:
            with self.subTest(projection=projection):
                (wiki / 'visible.json').write_text(json.dumps(projection))
                with self.assertRaises(ValueError):
                    sync.publish_wiki(wiki, self.target, curated=True)
                self.assertEqual(before, {name: (self.target / name).read_bytes() for name in sync.TABLES})
                self.assertFalse((self.target / '.wiki-authority').exists())
        (wiki / 'visible.json').write_text(json.dumps(good))
        for limit in ('MAX_ENTRIES', 'MAX_SNAPSHOT'):
            with self.subTest(limit=limit), patch.object(sync, limit, 1), self.assertRaisesRegex(ValueError, 'limit'):
                sync.publish_wiki(wiki, self.target)

    def test_publication_forwards_explicit_cutoff_to_canonical_command(self):
        wiki, _ = self.wiki(as_of='2004-05-18')
        cli = [sys.executable, str(Path(sync.__file__))]
        result = subprocess.run(cli + ['publish-wiki', '--wiki-root', str(wiki), '--target', str(self.target),
                                       '--as-of', '2004-05-18'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = [json.loads(line)[0] for line in (wiki / 'calls.jsonl').read_text().splitlines()]
        self.assertEqual(calls, [['export-visible', '--as-of', '2004-05-18']])
        with patch.object(sys, 'argv', ['sync.py', 'push', '--host', 'game.example', '--as-of', '2004-05-18']), \
                patch.object(sync, 'push') as push:
            sync.main()
        self.assertEqual(push.call_args.kwargs['as_of'], '2004-05-18')
        with self.assertRaisesRegex(ValueError, 'Accounts-only'):
            sync.push(self.root, 'game.example', 'sync.py', accounts_only=True, as_of='2004-05-18')
        result = subprocess.run(cli + ['push', '--host', 'game.example', '--accounts-only', '--as-of', '2004-05-18'],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn('--as-of', result.stderr)

    def test_publication_rejects_unrequested_or_mismatched_override(self):
        wiki, _ = self.wiki()
        good = json.loads((wiki / 'visible.json').read_text())
        sync.publish_wiki(wiki, self.target)
        before = {name: (self.target / name).read_bytes() for name in WIKI - sync.OPTIONAL_SNAPSHOTS}
        for requested, mode, cutoff in [(None, 'override', '2004-05-18'),
                                         ('2004-05-18', 'automatic', None),
                                         ('2004-05-19', 'override', '2004-05-18')]:
            projection = dict(good, policy=dict(good['policy'], mode=mode, asOf=cutoff))
            (wiki / 'visible.json').write_text(json.dumps(projection))
            with self.subTest(requested=requested, mode=mode, cutoff=cutoff):
                with self.assertRaisesRegex(ValueError, 'override'):
                    sync.publish_wiki(wiki, self.target, as_of=requested)
                self.assertEqual(before, {name: (self.target / name).read_bytes() for name in before})

    def test_publication_embeds_policy_in_every_snapshot_and_expires_without_republish(self):
        import server
        wiki, _ = self.wiki()
        policy = json.loads((wiki / 'visible.json').read_text())['policy']
        sync.publish_wiki(wiki, self.target, curated=True)
        portal = server.Portal(self.target, 'https://game.example', 'https://home.example')
        expiry = datetime.fromisoformat(policy['expiresAt'].replace('Z', '+00:00')).timestamp()
        before = {}
        for collection, (_, name, _) in server.WIKIS.items():
            with closing(sqlite3.connect(self.target / name)) as db:
                self.assertEqual(json.loads(db.execute('SELECT policy FROM wiki_policy').fetchone()[0]), policy)
            before[name] = (self.target / name).read_bytes()
            with patch('time.time', return_value=expiry - 0.001):
                self.assertEqual(portal.render('/rs-sdk/wiki/' + collection, {})[0], 200)
            with patch('time.time', return_value=expiry):
                self.assertEqual(portal.render('/rs-sdk/wiki/' + collection, {})[0], 503)
                self.assertEqual(portal.render('/rs-sdk/wiki/' + collection + '/article', {'id': ['0']})[0], 503)
        self.assertEqual(before, {name: (self.target / name).read_bytes() for name in before})
        projection = json.loads((wiki / 'visible.json').read_text())
        projection['policy'].update(effectiveDate=None, deployment=None, expiresAt=None, status='missing-or-invalid')
        (wiki / 'visible.json').write_text(json.dumps(projection))
        with self.assertRaises(ValueError):
            sync.publish_wiki(wiki, self.target, curated=True)
        self.assertEqual(before, {name: (self.target / name).read_bytes() for name in before})
        with patch('time.time', return_value=expiry + 1):
            for collection in server.WIKIS:
                self.assertEqual(portal.render('/rs-sdk/wiki/' + collection, {})[0], 503)
            projection['policy'] = fresh_policy(datetime.fromtimestamp(expiry + 1, timezone.utc))
            (wiki / 'visible.json').write_text(json.dumps(projection))
            sync.publish_wiki(wiki, self.target, curated=True)
            for collection, (_, name, _) in server.WIKIS.items():
                with closing(sqlite3.connect(self.target / name)) as db:
                    self.assertEqual(json.loads(db.execute('SELECT policy FROM wiki_policy').fetchone()[0]), projection['policy'])
                self.assertEqual(portal.render('/rs-sdk/wiki/' + collection, {})[0], 200)

    def test_canonical_non_scraped_rows_need_no_original_fields(self):
        wiki, _ = self.wiki()
        projection = json.loads((wiki / 'visible.json').read_text())
        for page in projection['pages']:
            if page['source'] not in sync.ORIGINS:
                del page['raw_html'], page['styles']
        (wiki / 'visible.json').write_text(json.dumps(projection))
        sync.publish_wiki(wiki, self.target, curated=True)
        sync.check_snapshot(self.target / '2004scape-wiki.sqlite', '2004scape-wiki.sqlite')

    def test_default_publication_invalidates_stale_optional_collection(self):
        wiki, _ = self.wiki()
        sync.receive(self.archive(set(sync.TABLES)), self.target)
        with closing(sqlite3.connect(self.target / '2004scape-wiki.sqlite')) as db, db:
            db.execute("INSERT INTO pages (id,source,title,text) VALUES (99,'2004scape','Future','MODERN_RAW_SECRET')")
        sync.publish_wiki(wiki, self.target)
        self.assertFalse((self.target / '2004scape-wiki.sqlite').exists())

    def test_projected_snapshots_block_every_original_asset_surface(self):
        import server
        wiki, _ = self.wiki()
        sync.receive(self.archive(set(sync.TABLES)), self.target)
        old_assets = self.target / 'assets'
        old_assets.mkdir()
        secret = b'MODERN_RAW_SECRET'
        digest = hashlib.sha256(secret).hexdigest()
        (old_assets / digest).write_bytes(secret)
        sync.publish_wiki(wiki, self.target, curated=True)
        portal = server.Portal(self.target, 'https://game.example', 'https://home.example', self.root / 'wanted.sqlite')
        for collection, source in [('rs-sdk', None), ('scraped', 'osrs'), ('scraped', 'rs3'), ('2004scape', None)]:
            article = '/w/' + (source + '/' if source else '') + 'Tree'
            article_params = {}
            if collection == 'rs-sdk':
                article, article_params = '/article', {'id': ['0']}
            for suffix, params in [('', {}), (article, article_params), (article, dict(article_params, view=['clean']))]:
                status, body = portal.render('/rs-sdk/wiki/' + collection + suffix, params)
                self.assertEqual(status, 200)
                self.assertNotIn('MODERN_RAW_SECRET', body)
                self.assertNotIn('<iframe', body)
        self.assertIsNone(portal.original_document(1))
        self.assertIsNone(portal.original_document(2))
        with self.assertRaisesRegex(ValueError, 'Missing asset'):
            portal.asset(digest)
        self.assertEqual((old_assets / digest).read_bytes(), secret)

    def test_collection_descriptions_reference_deployment_policy_not_fixed_date(self):
        import server
        portal = server.Portal(self.root, 'https://game.example', 'https://home.example')
        status, body = portal.render('/rs-sdk/wiki', {})
        self.assertEqual(status, 200)
        self.assertNotIn('late 2004', body)
        self.assertIn('deployment policy', body)

    def test_full_push_transports_only_canonical_visible_content(self):
        wiki, _ = self.wiki(as_of='2004-05-18')
        wiki = wiki.rename(self.root / '2004Scape-Wiki')
        bot = self.root / '2004Scape-Botting/data'
        bot.mkdir(parents=True)
        for name in ACCOUNTS:
            shutil.copyfile(self.stage / name, bot / name)
        run = sync.subprocess.run
        remote = []

        def transport(command, **kwargs):
            if command[0] != 'ssh':
                return run(command, **kwargs)
            remote.append(command[-1])
            if command[-1].endswith(' inventory') or command[-1].endswith(' take-wanted'):
                return subprocess.CompletedProcess(command, 0, stdout='[]')
            payload = kwargs['stdin'].read()
            with tarfile.open(fileobj=io.BytesIO(payload), mode='r:gz') as archive:
                self.assertEqual(set(archive.getnames()), set(sync.TABLES))
                for entry in archive:
                    content = archive.extractfile(entry)
                    assert content is not None
                    self.assertNotIn(b'MODERN_RAW_SECRET', content.read())
            sync.receive(io.BytesIO(payload), self.target)
            return subprocess.CompletedProcess(command, 0)

        with patch.object(sync.subprocess, 'run', side_effect=transport), \
                patch.object(sync, 'export_assets', side_effect=AssertionError('raw cache read')):
            sync.push(self.root, 'game.example', 'sync.py', curated=True, as_of='2004-05-18')
        with closing(sqlite3.connect(self.target / 'scraped-wiki.sqlite')) as db:
            self.assertEqual(db.execute('SELECT text,raw_html,styles FROM pages').fetchall(),
                             [('public text', None, '[]')] * 2)
        calls = [json.loads(line)[0] for line in (wiki / 'calls.jsonl').read_text().splitlines()]
        self.assertEqual(calls, [['export-visible', '--as-of', '2004-05-18']])
        (wiki / 'bin/wiki').unlink()
        remote.clear()
        with patch.object(sync.subprocess, 'run', side_effect=transport), self.assertRaises(OSError):
            sync.push(self.root, 'game.example', 'sync.py')
        self.assertEqual(remote, [])

    def test_wanted_consumer_does_not_block_portal_writers(self):
        wanted = self.root / 'wanted.sqlite'
        with closing(sqlite3.connect(wanted)) as db, db:
            db.execute('CREATE TABLE wanted (source,kind,key,requested_at)')
            db.execute("INSERT INTO wanted VALUES ('osrs','page','Tree',1)")

        def consume(entries):
            with closing(sqlite3.connect(wanted, timeout=0.05)) as db, db:
                db.execute("INSERT INTO wanted VALUES ('osrs','page','Oak',2)")

        sync.take_wanted(wanted, consumer=consume)
        self.assertEqual(sync.take_wanted(wanted), [{'source': 'osrs', 'kind': 'page', 'key': 'Oak'}])

    def test_wanted_ack_does_not_delete_a_replacement_request(self):
        wanted = self.root / 'wanted.sqlite'
        with closing(sqlite3.connect(wanted)) as db, db:
            db.execute('CREATE TABLE wanted (source,kind,key,requested_at)')
            db.execute("INSERT INTO wanted VALUES ('osrs','page','Tree',1)")

        def consume(entries):
            with closing(sqlite3.connect(wanted, timeout=0.05)) as db, db:
                db.execute('DELETE FROM wanted')
                db.execute("INSERT INTO wanted VALUES ('osrs','page','Tree',2)")

        sync.take_wanted(wanted, consumer=consume)
        self.assertEqual(sync.take_wanted(wanted), [{'source': 'osrs', 'kind': 'page', 'key': 'Tree'}])

    def test_local_publish_needs_no_bot_database_and_preserves_accounts(self):
        wiki, css = self.wiki()
        sync.receive(self.archive(set(sync.TABLES)), self.target)
        before = {name: (self.target / name).read_bytes() for name in ACCOUNTS}
        source_before = (wiki / 'data/wiki.sqlite').read_bytes()
        with patch.object(sync, 'export_assets', side_effect=AssertionError('raw cache read')):
            sync.publish_wiki(wiki, self.target, curated=True)
        self.assertEqual(before, {name: (self.target / name).read_bytes() for name in ACCOUNTS})
        for name in WIKI:
            sync.check_snapshot(self.target / name, name)
            self.assertNotIn(b'MODERN_RAW_SECRET', (self.target / name).read_bytes())
        with closing(sqlite3.connect(self.target / 'rs-sdk-wiki.sqlite')) as db:
            self.assertEqual(db.execute('SELECT source,text FROM pages').fetchall(), [('rs-sdk', 'public text')])
        with closing(sqlite3.connect(self.target / '2004scape-wiki.sqlite')) as db:
            self.assertEqual(db.execute('SELECT text,brief FROM pages').fetchall(), [('# Tree', 'public text')])
        with closing(sqlite3.connect(self.target / 'scraped-wiki.sqlite')) as db:
            self.assertEqual(db.execute('SELECT text,raw_html,styles FROM pages').fetchall(),
                             [('public text', None, '[]')] * 2)
            self.assertEqual(db.execute('SELECT * FROM assets').fetchall(), [])
            self.assertEqual(db.execute('SELECT * FROM redirects').fetchall(), [])
        self.assertFalse((self.target / 'assets').exists())
        self.assertEqual((wiki / 'assets/osrs/main.css').read_bytes(), css)
        self.assertEqual(source_before, (wiki / 'data/wiki.sqlite').read_bytes())

    def test_local_publication_omits_unsupported_cached_image_formats(self):
        wiki, css = self.wiki()
        (wiki / 'images/osrs').mkdir(parents=True)
        with closing(sqlite3.connect(wiki / 'data/images.sqlite')) as db, db:
            db.execute('CREATE TABLE images (source,path,mime,bytes,sha256,status)')
            for name, mime, data in [('font.woff2', 'font/woff2', b'font'),
                                     ('unsupported.webp', 'image/webp', b'unsupported raster')]:
                (wiki / 'images/osrs' / name).write_bytes(data)
                db.execute('INSERT INTO images VALUES (?,?,?,?,?,?)',
                           ('osrs', name, mime, len(data), hashlib.sha256(data).hexdigest(), 'ok'))
        sync.publish_wiki(wiki, self.target)
        with closing(sqlite3.connect(self.target / 'scraped-wiki.sqlite')) as db:
            self.assertEqual(db.execute('SELECT mime FROM assets').fetchall(), [])
        self.assertFalse((self.target / 'assets').exists())
        self.assertEqual((wiki / 'assets/osrs/main.css').read_bytes(), css)

    def test_local_publish_enables_authority_guard_against_legacy_push(self):
        wiki, _ = self.wiki()
        sync.publish_wiki(wiki, self.target)
        self.assertTrue((self.target / '.wiki-authority').is_file())
        before = {name: (self.target / name).read_bytes() for name in WIKI - sync.OPTIONAL_SNAPSHOTS}
        with self.assertRaisesRegex(ValueError, 'authorit'):
            sync.receive(self.archive(set(sync.TABLES)), self.target)
        sync.receive(self.archive(ACCOUNTS), self.target, accounts_only=True)
        sync.publish_wiki(wiki, self.target)
        self.assertEqual(before, {name: (self.target / name).read_bytes() for name in before})

    def test_publication_fails_closed_without_canonical_command(self):
        wiki, _ = self.wiki()
        sync.receive(self.archive(set(sync.TABLES)), self.target)
        before = {name: (self.target / name).read_bytes() for name in sync.TABLES}
        command = wiki / 'bin/wiki'
        command.unlink()
        with self.assertRaises(OSError):
            sync.publish_wiki(wiki, self.target)
        self.assertEqual(before, {name: (self.target / name).read_bytes() for name in sync.TABLES})
        command.write_text('#!' + sys.executable + '\nimport sys\nsys.exit(2)\n')
        command.chmod(0o700)
        with self.assertRaises(subprocess.CalledProcessError):
            sync.publish_wiki(wiki, self.target)
        self.assertEqual(before, {name: (self.target / name).read_bytes() for name in sync.TABLES})

    def test_local_publish_ignores_even_invalid_raw_source_blobs(self):
        wiki, _ = self.wiki()
        (wiki / 'assets/osrs/main.css').write_bytes(b'<script>MODERN_RAW_SECRET</script>')
        sync.publish_wiki(wiki, self.target)
        self.assertFalse((self.target / 'assets').exists())
        with closing(sqlite3.connect(self.target / 'scraped-wiki.sqlite')) as db:
            self.assertEqual(db.execute('SELECT * FROM assets').fetchall(), [])

    def test_local_publish_validates_targets_before_installing_any_blobs(self):
        wiki, _ = self.wiki()
        self.target.mkdir()
        sentinel = self.root / 'untouched'
        sentinel.write_text('old snapshot')
        (self.target / 'rs-sdk-wiki.sqlite').symlink_to(sentinel)
        with self.assertRaisesRegex(ValueError, 'Symlink'):
            sync.publish_wiki(wiki, self.target)
        self.assertEqual(sentinel.read_text(), 'old snapshot')
        self.assertFalse((self.target / 'assets').exists())
        self.assertFalse((self.target / '.wiki-authority').exists())

    def test_local_publish_curates_and_consumes_wanted_through_wiki_command(self):
        wiki, _ = self.wiki()
        wanted = self.target.parent / 'wanted/wanted.sqlite'
        wanted.parent.mkdir()
        with closing(sqlite3.connect(wanted)) as db, db:
            db.execute('CREATE TABLE wanted (source,kind,key,requested_at)')
            db.executemany('INSERT INTO wanted VALUES (?,?,?,?)', [
                ('osrs', 'page', 'Tree', 2), ('osrs', 'image', 'Tree.png', 1),
                ('osrs', 'image', '../secret', 3)])
        sync.publish_wiki(wiki, self.target, curated=True)
        calls = [json.loads(line) for line in (wiki / 'calls.jsonl').read_text().splitlines()]
        self.assertEqual([call[0] for call in calls], [['export-visible'], ['want']])
        self.assertEqual([json.loads(line) for line in calls[1][1].splitlines()], [
            {'source': 'osrs', 'kind': 'image', 'key': 'Tree.png'},
            {'source': 'osrs', 'kind': 'page', 'key': 'Tree'}])
        self.assertEqual(sync.take_wanted(wanted), [])
        sync.check_snapshot(self.target / '2004scape-wiki.sqlite', '2004scape-wiki.sqlite')
        self.assertFalse(any((self.target / name).exists() for name in ACCOUNTS))

    def test_failed_local_want_keeps_requests_for_next_publication(self):
        wiki, _ = self.wiki()
        wanted = self.root / 'requests.sqlite'
        with closing(sqlite3.connect(wanted)) as db, db:
            db.execute('CREATE TABLE wanted (source,kind,key,requested_at)')
            db.execute("INSERT INTO wanted VALUES ('osrs','page','Tree',1)")
        command = wiki / 'bin/wiki'
        command.write_text(command.read_text() + 'if sys.argv[1] == "want": sys.exit(2)\n')
        with self.assertRaises(subprocess.CalledProcessError):
            sync.publish_wiki(wiki, self.target, wanted=wanted)
        self.assertEqual(sync.take_wanted(wanted), [{'source': 'osrs', 'kind': 'page', 'key': 'Tree'}])

    def test_split_cli_publishes_wiki_and_receives_only_accounts(self):
        wiki, _ = self.wiki()
        cli = [sys.executable, str(Path(sync.__file__))]
        result = subprocess.run(cli + ['publish-wiki', '--wiki-root', str(wiki), '--target', str(self.target),
                                       '--wanted', str(self.root / 'missing-wanted.sqlite')],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        result = subprocess.run(cli + ['receive', '--target', str(self.target), '--accounts-only'],
                                input=self.archive(ACCOUNTS).getvalue(), capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        with patch.object(sys, 'argv', ['sync.py', 'push', '--host', 'game.example', '--accounts-only']), \
                patch.object(sync, 'push') as push:
            sync.main()
        self.assertTrue(push.call_args.kwargs['accounts_only'])
        result = subprocess.run(cli + ['push', '--host', 'game.example', '--accounts-only', '--curated'],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn('not allowed', result.stderr)

    def test_accounts_schedule_can_upload_only_allowlisted_bot_inputs(self):
        root = self.root / 'source'
        with patch.object(sys, 'argv', ['sync.py', 'push', '--host', 'game-server', '--root', str(root),
                                       '--accounts-only', '--bot-inputs']), \
                patch.object(sync, 'push') as push, patch.object(sync.subprocess, 'run') as run:
            sync.main()
        push.assert_called_once()
        command = run.call_args.args[0]
        self.assertEqual(Path(command[2]).name, 'inputs.py')
        self.assertEqual(command[3:], ['push', '--host', 'game-server', '--botting-root',
                                       str(root.resolve() / '2004Scape-Botting')])
        self.assertTrue(run.call_args.kwargs['check'])

    def test_installer_renders_explicit_accounts_mode_and_legacy_defaults(self):
        portal = Path(sync.__file__).parent
        fixture = self.root / 'checkout'
        copied = fixture / 'linux-game-server/rs-sdk/portal'
        copied.mkdir(parents=True)
        for name in ('install-sync.sh', 'net.computer-setup.rs-sdk-portal-sync.plist.template'):
            shutil.copyfile(portal / name, copied / name)
        (fixture / 'macos-server').mkdir()
        shutil.copyfile(portal.parents[2] / 'macos-server/lib.sh', fixture / 'macos-server/lib.sh')
        binaries = self.root / 'bin'
        binaries.mkdir()
        for name, body in [('launchctl', 'exit 0'), ('uname', 'printf Darwin'), ('brew', 'printf /opt/homebrew')]:
            executable = binaries / name
            executable.write_text('#!/bin/sh\n' + body + '\n')
            executable.chmod(0o700)
        home = self.root / 'home'
        env = dict(os.environ, HOME=str(home), PATH=str(binaries) + os.pathsep + os.environ['PATH'],
                   TMPDIR=str(self.root))
        for option, expected in [('--accounts-only', '--accounts-only'), ('--curated', '--curated'), (None, '--no-curated')]:
            result = subprocess.run(['bash', str(copied / 'install-sync.sh'), 'game-server'] + ([option] if option else []),
                                    env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            plist = plistlib.loads((home / 'Library/LaunchAgents/net.computer-setup.rs-sdk-portal-sync.plist').read_bytes())
            self.assertEqual(plist['ProgramArguments'][-1], expected)
            self.assertEqual('--bot-inputs' in plist['ProgramArguments'], option == '--accounts-only')
            self.assertTrue(all(isinstance(arg, str) for arg in plist['ProgramArguments']))

    def test_authority_guard_blocks_legacy_remote_wanted_consumption(self):
        wiki, _ = self.wiki()
        sync.publish_wiki(wiki, self.target)
        wanted = self.root / 'wanted/wanted.sqlite'
        wanted.parent.mkdir()
        with closing(sqlite3.connect(wanted)) as db, db:
            db.execute('CREATE TABLE wanted (source,kind,key,requested_at)')
            db.execute("INSERT INTO wanted VALUES ('osrs','page','Tree',1)")
        result = subprocess.run([sys.executable, str(Path(sync.__file__)), 'take-wanted', '--wanted', str(wanted),
                                 '--target', str(self.target)],
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('authorit', result.stderr)
        self.assertEqual(sync.take_wanted(wanted), [{'source': 'osrs', 'kind': 'page', 'key': 'Tree'}])

    def test_accounts_push_does_not_read_or_overwrite_stale_mac_wiki(self):
        bot = self.root / '2004Scape-Botting/data'
        bot.mkdir(parents=True)
        for name in ACCOUNTS:
            (bot / name).write_bytes((self.stage / name).read_bytes())
        stale = self.root / '2004Scape-Wiki/data'
        stale.mkdir(parents=True)
        (stale / 'wiki.sqlite').write_bytes(b'not a database: stale Mac wiki')
        sync.receive(self.archive(set(sync.TABLES)), self.target)
        before = {name: (self.target / name).read_bytes() for name in WIKI}
        calls = []

        def ssh(command, **kwargs):
            calls.append(command[-1])
            self.assertTrue(command[-1].endswith(' receive --accounts-only'))
            payload = kwargs['stdin'].read()
            with tarfile.open(fileobj=io.BytesIO(payload), mode='r:gz') as archive:
                self.assertEqual(set(archive.getnames()), ACCOUNTS)
            sync.receive(io.BytesIO(payload), self.target, accounts_only=True)
            return subprocess.CompletedProcess(command, 0)

        with patch.object(sync.subprocess, 'run', side_effect=ssh):
            sync.push(self.root, 'game.example', 'sync.py', accounts_only=True)
        self.assertEqual(len(calls), 1)
        self.assertEqual(before, {name: (self.target / name).read_bytes() for name in WIKI})

    def test_account_receiver_requires_exact_explicit_set_and_preserves_wiki(self):
        sync.receive(self.archive(set(sync.TABLES)), self.target)
        assets = self.target / 'assets'
        assets.mkdir()
        css = b'body{}'
        digest = hashlib.sha256(css).hexdigest()
        (assets / digest).write_bytes(css)
        before = {name: (self.target / name).read_bytes() for name in WIKI}
        sync.receive(self.archive(ACCOUNTS), self.target, accounts_only=True)
        self.assertEqual(before, {name: (self.target / name).read_bytes() for name in WIKI})
        self.assertEqual((assets / digest).read_bytes(), css)
        for names, blobs in [(ACCOUNTS - {'accounts.sqlite'}, ()),
                             (set(sync.TABLES), ()),
                             (ACCOUNTS, [('assets/' + digest, css)])]:
            with self.subTest(names=names, blobs=bool(blobs)), self.assertRaises(ValueError):
                sync.receive(self.archive(names, blobs), self.target, accounts_only=True)
        with self.assertRaisesRegex(ValueError, 'Incomplete'):
            sync.receive(self.archive(ACCOUNTS), self.target)
        self.assertEqual(before, {name: (self.target / name).read_bytes() for name in WIKI})


if __name__ == '__main__':
    unittest.main()
