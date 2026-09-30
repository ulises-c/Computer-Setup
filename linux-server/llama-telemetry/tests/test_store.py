import io
import sqlite3
import tempfile
import unittest
from contextlib import closing
from pathlib import Path

from store import INGEST_COLUMNS, aggregate, cursor, ingest


class StoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.db = Path(self.temp.name) / 'telemetry.sqlite'

    def row(self, row_id=1, **changes):
        value = {
            'id': row_id, 'ts_created': 1_700_000_100, 'model_id': 'model-a',
            'resp_status_code': 200,
            'input_tokens': 100, 'output_tokens': 20, 'cache_tokens': 0,
            'prompt_per_second': 500.0, 'tokens_per_second': 40.0,
            'duration_ms': 1000,
        }
        value.update(changes)
        self.assertEqual(set(value), set(INGEST_COLUMNS))
        return value

    def test_ingest_is_idempotent_and_isolated_by_source(self):
        import json
        batch = json.dumps(self.row()) + '\n'
        self.assertEqual(ingest(self.db, 'host-a:one', io.StringIO(batch)), 1)
        self.assertEqual(ingest(self.db, 'host-a:one', io.StringIO(batch)), 0)
        self.assertEqual(ingest(self.db, 'host-a:two', io.StringIO(batch)), 1)
        self.assertEqual(cursor(self.db, 'host-a:one'), 1)
        self.assertEqual(cursor(self.db, 'host-a:two'), 1)
        with closing(sqlite3.connect(self.db)) as db:
            self.assertEqual(db.execute('select count(*) from activity').fetchone()[0], 2)

    def test_aggregate_distinguishes_throughput_from_per_request_speeds(self):
        import json
        rows = [
            self.row(1, ts_created=1_700_000_100),
            self.row(2, ts_created=1_700_000_200, input_tokens=50, output_tokens=10,
                     prompt_per_second=-1, tokens_per_second=-1, resp_status_code=500),
            self.row(3, ts_created=1_700_000_300, model_id='model-b', output_tokens=60,
                     prompt_per_second=1000, tokens_per_second=60),
        ]
        ingest(self.db, 'host-a:one', io.StringIO(''.join(json.dumps(r) + '\n' for r in rows)))
        result = aggregate(self.db, start=1_700_000_000, end=1_700_003_600, bucket_seconds=3600)
        a = next(r for r in result if r['model'] == 'model-a')
        self.assertEqual((a['requests'], a['errors'], a['input_tokens'], a['output_tokens']), (2, 1, 150, 30))
        self.assertEqual((a['pp_tps'], a['tg_tps'], a['pp_samples'], a['tg_samples']), (500, 40, 1, 1))
        self.assertAlmostEqual(a['output_tps'], 30 / (a['bucket'] + 3600 - 1_700_000_000))
        self.assertEqual(len(result), 2)

    def test_bad_batch_rolls_back_without_advancing_cursor(self):
        import json
        with self.assertRaises(ValueError):
            ingest(self.db, 'host-a:one', io.StringIO(json.dumps(self.row()) + '\n' + '{"id":2}\n'))
        self.assertEqual(cursor(self.db, 'host-a:one'), 0)

    def test_storage_is_private_even_with_public_umask(self):
        import json
        path = Path(self.temp.name) / 'private' / 'activity.sqlite'
        previous = __import__('os').umask(0o022)
        try:
            ingest(path, 'host-a:one', io.StringIO(json.dumps(self.row()) + '\n'))
        finally:
            __import__('os').umask(previous)
        self.assertEqual(path.parent.stat().st_mode & 0o777, 0o700)
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_partial_bucket_rate_uses_elapsed_window(self):
        import json
        row = self.row(ts_created=1_700_000_100, output_tokens=60)
        ingest(self.db, 'host-a:one', io.StringIO(json.dumps(row) + '\n'))
        result = aggregate(self.db, start=1_699_999_900, end=1_700_000_200, bucket_seconds=3600)
        bucket = result[0]['bucket']
        elapsed = min(1_700_000_200, bucket + 3600) - max(1_699_999_900, bucket)
        self.assertAlmostEqual(result[0]['output_tps'], 60 / elapsed)


if __name__ == '__main__':
    unittest.main()
