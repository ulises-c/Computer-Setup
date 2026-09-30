import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class IngestCommandTests(unittest.TestCase):
    def test_stdin_ingest_and_cursor_round_trip(self):
        with tempfile.TemporaryDirectory() as temp:
            env = os.environ | {'TELEMETRY_DB': str(Path(temp) / 'activity.sqlite')}
            def call(action, input=None):
                return subprocess.run([sys.executable, str(ROOT / 'ingest.py'), action, 'host-a:one'],
                                      input=input, text=True, capture_output=True, env=env)
            self.assertEqual(json.loads(call('cursor').stdout), {'id': 0, 'digest': None, 'first_digest': None})
            row = {'id': 10, 'ts_created': 1700000100, 'model_id': 'a',
                   'resp_status_code': 200, 'input_tokens': 1, 'output_tokens': 2, 'cache_tokens': 0,
                   'prompt_per_second': 200, 'tokens_per_second': 30, 'duration_ms': 200}
            self.assertEqual(call('ingest', json.dumps(row) + '\n').stdout.strip(), '1')
            state = json.loads(call('cursor').stdout)
            self.assertEqual(state['id'], 10)
            self.assertEqual(state['first_digest'], state['digest'])


if __name__ == '__main__':
    unittest.main()
