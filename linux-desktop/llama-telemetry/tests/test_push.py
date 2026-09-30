import io
import sqlite3
import tempfile
import unittest
from contextlib import closing
from pathlib import Path

from push import push_once, source_id
from store import cursor, cursor_state, ingest


class FakeTransport:
    def __init__(self, destination):
        self.destination = destination

    def cursor(self, source):
        return cursor_state(self.destination, source)

    def ingest(self, source, payload):
        return ingest(self.destination, source, io.StringIO(payload))


class PushTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.source = root / 'source.sqlite'
        self.destination = root / 'remote.sqlite'
        with closing(sqlite3.connect(self.source)) as db, db:
            db.execute('''CREATE TABLE activity (
                id INTEGER PRIMARY KEY, ts_created INTEGER, model_id TEXT, req_path TEXT,
                resp_status_code INTEGER, input_tokens INTEGER, output_tokens INTEGER,
                cache_tokens INTEGER, prompt_per_second REAL, tokens_per_second REAL,
                duration_ms INTEGER, metadata_json TEXT)''')
            for i in range(1, 6):
                db.execute('INSERT INTO activity VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
                           (i, 1_700_000_000 + i, 'model-a', '/v1/chat/completions', 200,
                            i, i * 2, 0, 300, 40, i * 100, '{"sensitive":"not-synced"}'))

    def test_push_is_batched_idempotent_and_excludes_metadata(self):
        transport = FakeTransport(self.destination)
        sent = []
        original = transport.ingest
        def inspect(source, payload):
            sent.append(payload)
            self.assertNotIn('sensitive', payload)
            self.assertNotIn('req_path', payload)
            return original(source, payload)
        transport.ingest = inspect
        self.assertEqual(push_once(self.source, transport, batch_size=2), 5)
        self.assertEqual(len(sent), 3)
        self.assertEqual(push_once(self.source, transport, batch_size=2), 0)
        self.assertEqual(cursor(self.destination, source_id(self.source)), 5)

    def test_recreated_source_database_gets_new_identity(self):
        previous = source_id(self.source)
        replacement = self.source.with_name('replacement.sqlite')
        replacement.touch()
        replacement.replace(self.source)
        self.assertNotEqual(previous, source_id(self.source))

    def test_in_place_reset_does_not_skip_new_requests(self):
        transport = FakeTransport(self.destination)
        self.assertEqual(push_once(self.source, transport), 5)
        with closing(sqlite3.connect(self.source)) as db, db:
            db.execute('DELETE FROM activity')
            db.execute('INSERT INTO activity VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
                       (1, 1_800_000_001, 'new-model', '/v1/chat/completions', 200,
                        10, 20, 0, 300, 40, 100, '{}'))
        self.assertEqual(push_once(self.source, transport), 1)
        with closing(sqlite3.connect(self.destination)) as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM activity').fetchone()[0], 6)

    def test_reused_cursor_with_changed_first_row_rotates_generation(self):
        transport = FakeTransport(self.destination)
        self.assertEqual(push_once(self.source, transport), 5)
        with closing(sqlite3.connect(self.source)) as db, db:
            db.execute('UPDATE activity SET model_id = ? WHERE id = 1', ('rebuilt-model',))
        self.assertEqual(push_once(self.source, transport), 5)
        self.assertEqual(push_once(self.source, transport), 0)
        with closing(sqlite3.connect(self.destination)) as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM activity').fetchone()[0], 10)


if __name__ == '__main__':
    unittest.main()
