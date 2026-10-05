import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
MODULE = ROOT / 'dragonwilds/status_metrics.py'


class MetricsTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(MODULE.is_file(), 'persistent rolling metrics implementation is missing')
        spec = importlib.util.spec_from_file_location('status_metrics', MODULE)
        self.m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.m)

    def sample(self, epoch=1000, mono=1000, cpu=100, memory=1024, invocation='run-a', boot='boot-a'):
        return dict(epoch=epoch, monotonic=mono, cpu_ns=cpu * 1_000_000_000 if cpu is not None else None,
                    memory_bytes=memory, invocation=invocation, boot=boot)

    def test_first_sample_is_unknown_cpu_not_zero(self):
        state, result = self.m.update({}, self.sample())
        self.assertIsNone(result['cpu_percent'])
        self.assertEqual(result['cpu_current'], 'unknown (warming up)')
        self.assertEqual(result['memory_bytes'], 1024)
        self.assertEqual(result['memory_samples'], 1)
        self.assertEqual(result['cpu_coverage_seconds'], 0)
        self.assertEqual(len(state['samples']), 1)

    def test_cpu_delta_and_time_weighted_average(self):
        state, _ = self.m.update({}, self.sample())
        state, result = self.m.update(state, self.sample(1060, 1060, 130, 2048))
        self.assertEqual(result['cpu_percent'], 50)
        state, result = self.m.update(state, self.sample(1180, 1180, 250, 4096))
        self.assertEqual(result['cpu_percent'], 100)
        self.assertAlmostEqual(result['cpu_avg_percent'], 100 * 150 / 180)
        self.assertEqual(result['cpu_max_percent'], 100)
        self.assertEqual(result['cpu_coverage_seconds'], 180)
        self.assertAlmostEqual(result['memory_avg_bytes'], 7168 / 3)
        self.assertEqual(result['memory_max_bytes'], 4096)


    def test_discontinuities_do_not_fabricate_cpu_samples(self):
        state, _ = self.m.update({}, self.sample())
        cases = [self.sample(1060, 1060, 900, invocation='run-b'),
                 self.sample(1060, 1060, 900, boot='boot-b'),
                 self.sample(1060, 1060, 90),
                 self.sample(1060, 1000, 130),
                 self.sample(999, 1060, 130),
                 self.sample(1600, 1600, 400),
                 self.sample(1060, 1060, None)]
        for sample in cases:
            with self.subTest(sample=sample):
                _, result = self.m.update(state, sample)
                self.assertIsNone(result['cpu_percent'])
                self.assertEqual(result['cpu_coverage_seconds'], 0)
        _, result = self.m.update(state, self.sample(1060, 1060, 130, memory=None))
        self.assertIsNone(result['memory_bytes'])
        self.assertEqual(result['memory_samples'], 1)


    def test_rolling_window_clips_cpu_interval_and_bounds_history(self):
        state, _ = self.m.update({}, self.sample(1000, 1000, 100))
        state, _ = self.m.update(state, self.sample(1060, 1060, 130))
        _, result = self.m.update(state, self.sample(1000 + 86400 + 30, 87430, 200))
        self.assertEqual(result['cpu_coverage_seconds'], 30)
        self.assertEqual(result['cpu_avg_percent'], 50)
        self.assertEqual(result['memory_samples'], 2)
        self.assertEqual(result['history_span_seconds'], 86370)
        state, result = self.m.update(state, self.sample(1061 + 86400, 87461, 200))
        self.assertEqual(result['cpu_coverage_seconds'], 0)
        self.assertIsNone(result['cpu_avg_percent'])
        self.assertEqual(len(state['samples']), 1)
        for i in range(3000):
            state, result = self.m.update(state, self.sample(90000 + i, 90000 + i, 200 + i))
        self.assertLessEqual(len(state['samples']), self.m.MAX_SAMPLES)
        self.assertEqual(self.m.MAX_SAMPLES, 2880)


    def test_cli_persists_private_bounded_state_and_recovers_corruption(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'private/history.json'
            def run(sample):
                result = subprocess.run(['python3', str(MODULE), '--history', str(path)],
                                        input=json.dumps(sample), text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue(result.stdout.strip(), 'CLI must emit computed resource metrics')
                return json.loads(result.stdout), result.stderr
            result, _ = run(self.sample())
            self.assertTrue(path.exists(), 'sample history must survive producer restarts')
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(path.parent.stat().st_mode & 0o777, 0o700)
            result, _ = run(self.sample(1060, 1060, 130))
            self.assertEqual(result['cpu_percent'], 50)
            self.assertEqual(result['cpu_avg'], '50.0%')
            self.assertEqual(result['memory_current'], '1.0 KiB')
            self.assertIn('2 memory samples', result['sample_window'])
            self.assertIn('/ 24h', result['sample_window'])
            path.write_text('{bad json')
            result, stderr = run(self.sample(1120, 1120, 160))
            self.assertIsNone(result['cpu_percent'])
            self.assertIn('history reset', stderr)
            self.assertEqual(result['memory_samples'], 1)
            self.assertEqual(json.loads(path.read_text())['schema'], 1)


if __name__ == '__main__':
    unittest.main()
