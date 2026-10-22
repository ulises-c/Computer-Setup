from contextlib import closing
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

import server
import sync


def fresh_policy(now=None):
    now = now or datetime.now(timezone.utc)
    observed = now.isoformat(timespec='milliseconds').replace('+00:00', 'Z')
    expires = (now + timedelta(minutes=10)).isoformat(timespec='milliseconds').replace('+00:00', 'Z')
    return {'version': 1, 'mode': 'automatic', 'effectiveDate': '2004-05-18', 'asOf': None,
            'deployment': {'version': 1, 'protocolRevision': 289, 'historicalContentDate': '2004-05-18',
                           'historicalContentDateSource': 'content-readme', 'contentIdentity': 'sha256:fixture',
                           'observedAt': observed, 'confidence': 'declared-target'},
            'expiresAt': expires, 'status': 'fresh'}


def stamp(db, policy=None):
    db.execute('CREATE TABLE wiki_policy (policy TEXT NOT NULL)')
    db.execute('INSERT INTO wiki_policy VALUES (?)', (json.dumps(policy or fresh_policy()),))


class RequestPolicyTests(unittest.TestCase):
    def test_invalid_or_unknown_policy_fails_closed(self):
        good = fresh_policy()
        invalid = [None, [], {}, dict(good, version=True), dict(good, mode='historical'),
                   dict(good, effectiveDate='2004-02-30'), dict(good, effectiveDate='2004-05-19'),
                   dict(good, asOf='2004-05-18'), dict(good, deployment=None),
                   dict(good, status='expired'), dict(good, status='missing-or-invalid'),
                   dict(good, mode='override'), dict(good, expiresAt=None)]
        for key in good:
            invalid.append({k: v for k, v in good.items() if k != key})
        for timestamp in ('garbage', '2099-01-01T00:00:00Z', '2004-05-18',
                          '2026-02-30T01:00:00Z', '2026-10-22T24:00:00Z',
                          '2026-10-22T12:00:00+00:00', '2026-10-22 12:00:00Z'):
            invalid.append(dict(good, expiresAt=timestamp))
        for key, value in [('version', True), ('protocolRevision', False), ('protocolRevision', 0),
                           ('historicalContentDate', '2004-02-30'), ('historicalContentDateSource', 'engine-readme'),
                           ('contentIdentity', ''), ('contentIdentity', 'bad\nidentity'),
                           ('observedAt', '2099-01-01T00:00:00Z'), ('confidence', 'verified')]:
            invalid.append(dict(good, deployment=dict(good['deployment'], **{key: value})))
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            path = root / 'rs-sdk-wiki.sqlite'
            with closing(sqlite3.connect(path)) as db, db:
                db.execute('CREATE TABLE pages (id,source,title,text,fetched_at,revid)')
                db.execute("INSERT INTO pages VALUES (1,'rs-sdk','Secret','UNSAFE_SENTINEL',0,1)")
                stamp(db)
            portal = server.Portal(root, 'https://game.example', 'https://home.example')
            for policy in invalid:
                with self.subTest(policy=policy):
                    with closing(sqlite3.connect(path)) as db, db:
                        db.execute('UPDATE wiki_policy SET policy=?', (json.dumps(policy),))
                    status, body = portal.render('/rs-sdk/wiki/rs-sdk', {})
                    self.assertEqual(status, 503)
                    self.assertNotIn('UNSAFE_SENTINEL', body)

    def test_override_is_labelled_date_preview_independent_of_deployment_expiry(self):
        missing = dict(fresh_policy(), mode='override', effectiveDate='2004-06-01', asOf='2004-06-01',
                       deployment=None, expiresAt=None, status='missing-or-invalid')
        expired = fresh_policy(datetime(2004, 5, 18, tzinfo=timezone.utc))
        expired.update(mode='override', effectiveDate='2004-06-01', asOf='2004-06-01', status='expired')
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            portal = server.Portal(root, 'https://game.example', 'https://home.example')
            for _, filename, _ in server.WIKIS.values():
                with closing(sqlite3.connect(root / filename)) as db, db:
                    for table, columns in sync.TABLES[filename].items():
                        db.execute(f'CREATE TABLE {table} ({",".join(columns)})')
                    db.execute('INSERT INTO pages (id,source,title,text) VALUES (1,?,\'Secret\',\'PREVIEW_CONTEXT\')',
                               (sync.PAGE_SOURCES[filename][0],))
                    stamp(db)
            for policy in (missing, expired):
                for collection, (_, filename, _) in server.WIKIS.items():
                    with closing(sqlite3.connect(root / filename)) as db, db:
                        db.execute('UPDATE wiki_policy SET policy=?', (json.dumps(policy),))
                    for suffix in ('', '/article'):
                        with self.subTest(policy=policy, collection=collection, suffix=suffix):
                            status, body = portal.render('/rs-sdk/wiki/' + collection + suffix, {'id': ['1']})
                            if status == 302:
                                status, body = portal.render(body, {})
                            self.assertEqual(status, 200)
                            self.assertIn('Date-preview override', body)
                            self.assertIn('2004-06-01', body)
                            self.assertIn('PREVIEW_CONTEXT', body)

    def test_portal_image_packages_policy_reader(self):
        dockerfile = Path(server.__file__).with_name('Dockerfile').read_text()
        self.assertTrue(any(line.startswith('COPY ') and 'snapshot_policy.py' in line for line in dockerfile.splitlines()))

    def test_receiver_validates_policy_schema_rows_and_lifetime_before_install(self):
        import io
        import tarfile
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            stage, target = root / 'stage', root / 'target'
            stage.mkdir()
            good = fresh_policy()
            for name, tables in sync.TABLES.items():
                with closing(sqlite3.connect(stage / name)) as db, db:
                    for table, columns in tables.items():
                        db.execute(f'CREATE TABLE {table} ({",".join(columns)})')
                    if name in sync.PAGE_SOURCES:
                        stamp(db, good)

            def archive():
                payload = io.BytesIO()
                with tarfile.open(fileobj=payload, mode='w:gz') as out:
                    for name in sync.TABLES:
                        out.add(stage / name, arcname=name)
                payload.seek(0)
                return payload

            sync.receive(archive(), target)
            before = {name: (target / name).read_bytes() for name in sync.TABLES}
            invalid_policies = [None, {}, dict(good, mode='historical'), dict(good, expiresAt='2099-01-01T00:00:00Z'),
                                dict(good, mode='override', asOf='2004-02-30'),
                                dict(good, effectiveDate=None, deployment=None, expiresAt=None, status='missing-or-invalid')]
            invalid_rows = [[json.dumps(policy)] for policy in invalid_policies]
            invalid_rows += [[], [json.dumps(good)] * 2, ['{bad json'], [b'not text']]
            for rows in invalid_rows:
                with self.subTest(rows=rows):
                    with closing(sqlite3.connect(stage / 'scraped-wiki.sqlite')) as db, db:
                        db.execute('DELETE FROM wiki_policy')
                        db.executemany('INSERT INTO wiki_policy VALUES (?)', [(row,) for row in rows])
                    with self.assertRaises(ValueError):
                        sync.receive(archive(), target)
                    self.assertEqual(before, {name: (target / name).read_bytes() for name in before})
            for schema in ('policy', 'policy BLOB NOT NULL', 'policy TEXT NOT NULL,extra',
                           'policy TEXT NOT NULL,extra AS (policy) VIRTUAL'):
                with self.subTest(schema=schema):
                    with closing(sqlite3.connect(stage / 'scraped-wiki.sqlite')) as db, db:
                        db.execute('DROP TABLE wiki_policy')
                        db.execute(f'CREATE TABLE wiki_policy ({schema})')
                        db.execute('INSERT INTO wiki_policy (policy) VALUES (?)', (json.dumps(good),))
                    with self.assertRaises(ValueError):
                        sync.receive(archive(), target)
                    self.assertEqual(before, {name: (target / name).read_bytes() for name in before})
            with closing(sqlite3.connect(stage / 'scraped-wiki.sqlite')) as db, db:
                db.execute('DROP TABLE wiki_policy')
                stamp(db, good)
            expiry = datetime.fromisoformat(good['expiresAt'].replace('Z', '+00:00')).timestamp()
            with patch('time.time', return_value=expiry), self.assertRaisesRegex(ValueError, 'Expired'):
                sync.receive(archive(), target)
            self.assertEqual(before, {name: (target / name).read_bytes() for name in before})

    def test_unmarked_snapshots_never_serve_wiki_content(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for collection, (_, filename, _) in server.WIKIS.items():
                with closing(sqlite3.connect(root / filename)) as db, db:
                    for table, columns in sync.TABLES[filename].items():
                        db.execute(f'CREATE TABLE {table} ({",".join(columns)})')
                    db.execute('INSERT INTO pages (id,source,title,text) VALUES (1,?,\'Secret\',\'UNSAFE_SENTINEL\')',
                               (sync.PAGE_SOURCES[filename][0],))
                portal = server.Portal(root, 'https://game.example', 'https://home.example')
                routes = [('', {}), ('/article', {'id': ['1']})]
                if collection != 'rs-sdk':
                    routes.append(('/w/' + ('osrs/' if collection == 'scraped' else '') + 'Secret', {}))
                for suffix, params in routes:
                    with self.subTest(collection=collection, suffix=suffix):
                        status, body = portal.render('/rs-sdk/wiki/' + collection + suffix, params)
                        self.assertEqual(status, 503)
                        self.assertNotIn('UNSAFE_SENTINEL', body)


if __name__ == '__main__':
    unittest.main()
