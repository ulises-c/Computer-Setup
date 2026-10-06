"""Activity-gated HDD filesystem stats: synthetic sysfs only, no drive is ever touched."""
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

spec = importlib.util.spec_from_file_location('telemetry', Path(__file__).with_name('telemetry.py'))
telemetry = importlib.util.module_from_spec(spec)
spec.loader.exec_module(telemetry)


class Fixture:
    def __init__(self, root):
        self.root = Path(root)
        self.blocks = self.root / 'sys/dev/block'
        self.blocks.mkdir(parents=True)
        self.disks = {}
        self.mountinfo = self.root / 'mountinfo'
        self.lines = []

    def disk(self, name, devno, rotational='1', stat='0 0 0 0 0 0 0 0 0 0 0'):
        node = self.root / 'sys/devices' / name
        (node / 'queue').mkdir(parents=True)
        (node / 'device').mkdir()
        (node / 'queue/rotational').write_text(rotational)
        part = node / (name + '1')
        part.mkdir()
        (part / 'partition').write_text('1')
        (self.blocks / devno).symlink_to(part)
        self.disks[name] = node
        self.set_io(name, 0, 0)
        return node

    def set_io(self, name, reads, writes):
        (self.disks[name] / 'stat').write_text(f'{reads} 0 0 0 {writes} 0 0 0 0 0 0\n')

    def mount(self, devno, mnt, fs='ext4'):
        self.lines.append(f'1 0 {devno} / {mnt} rw - {fs} /dev/x rw\n')
        self.mountinfo.write_text(''.join(self.lines))


class HddActivityTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.fx = Fixture(self.tmp.name)
        self.fx.disk('sda', '8:1')
        self.fx.mount('8:1', '/mnt/hdd')
        self.wall = [1000]
        self.calls = []
        self.on_usage = lambda: None
        self.plugin = SimpleNamespace(is_display_any=lambda *a: True, has_alias=lambda p: None,
                                      get_key=lambda: 'mnt_point')

    def usage(self, mount):
        self.calls.append(mount)
        self.on_usage()
        return SimpleNamespace(total=1000, used=250, free=750, percent=25.0)

    def stats(self, **kwargs):
        stats = telemetry.HddActivityStats(self.usage, wall=lambda: self.wall[0], **kwargs)
        provider = telemetry.filesystem_provider(lambda *a: self.fail('solid-state statvfs'),
                                                 self.fx.blocks, self.fx.mountinfo,
                                                 clock=lambda: self.wall[0], wall=lambda: self.wall[0], hdd=stats)
        return stats, provider

    def advance(self, seconds):
        self.wall[0] += seconds

    def test_provider_registers_rotational_mounts_without_touching_them(self):
        stats, provider = self.stats()
        self.assertEqual(provider(self.plugin), [])
        self.assertEqual(self.calls, [])
        self.assertEqual(list(stats.mounts), ['/mnt/hdd'])

    def test_no_statvfs_while_the_drive_is_idle(self):
        stats, provider = self.stats()
        provider(self.plugin)
        for _ in range(50):
            self.advance(30)
            stats.tick()
        self.assertEqual(self.calls, [])
        self.assertEqual(provider.rows(), [])

    def test_activity_triggers_one_read_and_a_dated_row(self):
        stats, provider = self.stats()
        provider(self.plugin)
        stats.tick()
        self.fx.set_io('sda', 10, 0)
        self.advance(30)
        stats.tick()
        self.assertEqual(self.calls, ['/mnt/hdd'])
        row, = provider.rows()
        self.assertEqual((row['mnt_point'], row['size'], row['used'], row['free'], row['percent']),
                         ('/mnt/hdd', 1000, 250, 750, 25.0))
        self.assertEqual(row['collected_at'], 1030)
        self.assertEqual(row['collection_source'], 'activity_gated_statvfs')
        self.assertEqual(row['storage_class'], 'hdd')
        self.assertEqual(row['collection_status'], 'ok')
        self.assertEqual(row['key'], 'mnt_point')
        self.advance(100)
        self.assertEqual(provider.rows()[0]['collection_age_seconds'], 100)
        self.assertEqual(provider(self.plugin)[0]['collected_at'], 1030)

    def test_reads_at_most_once_per_interval_even_with_constant_activity(self):
        stats, provider = self.stats(interval=300)
        provider(self.plugin)
        stats.tick()
        for step in range(1, 20):
            self.fx.set_io('sda', step, step)
            self.advance(30)
            stats.tick()
        self.assertEqual(len(self.calls), 2)

    def test_own_reads_do_not_count_as_activity(self):
        self.on_usage = lambda: self.fx.set_io('sda', 99, 99)
        stats, provider = self.stats(interval=300)
        provider(self.plugin)
        stats.tick()
        self.fx.set_io('sda', 1, 1)
        self.advance(30)
        stats.tick()
        self.assertEqual(len(self.calls), 1)
        for _ in range(40):
            self.advance(30)
            stats.tick()
        self.assertEqual(len(self.calls), 1, 'the collector kept itself awake')

    def test_unreadable_counters_are_never_treated_as_activity(self):
        stats, provider = self.stats()
        provider(self.plugin)
        stats.tick()
        (self.fx.disks['sda'] / 'stat').write_text('garbage')
        self.advance(30)
        stats.tick()
        self.fx.set_io('sda', 5, 5)
        self.advance(30)
        stats.tick()
        self.assertEqual(self.calls, [], 'first good reading after a gap is only a baseline')

    def test_samples_survive_a_restart_with_their_original_date(self):
        cache = Path(self.tmp.name) / 'hdd.json'
        stats, provider = self.stats(cache_file=cache)
        provider(self.plugin)
        stats.tick()
        self.fx.set_io('sda', 1, 1)
        self.advance(30)
        stats.tick()
        self.assertEqual(json.loads(cache.read_text())['mounts']['/mnt/hdd']['collected_at'], 1030)
        self.advance(86400)
        restarted, provider2 = self.stats(cache_file=cache)
        provider2(self.plugin)
        row, = provider2.rows()
        self.assertEqual(row['collected_at'], 1030)
        self.assertEqual(row['collection_age_seconds'], 86400)
        self.assertEqual(self.calls, ['/mnt/hdd'])

    def test_corrupt_or_missing_cache_file_is_ignored(self):
        cache = Path(self.tmp.name) / 'hdd.json'
        cache.write_text('{not json')
        stats, provider = self.stats(cache_file=cache)
        provider(self.plugin)
        self.assertEqual(provider.rows(), [])
        stats, provider = self.stats(cache_file=Path(self.tmp.name) / 'missing/dir/hdd.json')
        provider(self.plugin)
        stats.tick()
        self.fx.set_io('sda', 1, 1)
        self.advance(30)
        stats.tick()
        self.assertEqual(len(provider.rows()), 1)

    def test_persisted_rows_for_unmounted_paths_are_not_reported(self):
        cache = Path(self.tmp.name) / 'hdd.json'
        cache.write_text(json.dumps({'version': 1, 'mounts': {'/mnt/gone': dict(
            collected_at=5, size=1, used=1, free=0, percent=100.0)}}))
        stats, provider = self.stats(cache_file=cache)
        provider(self.plugin)
        self.assertEqual(provider.rows(), [])

    def test_mixed_and_unproven_backing_stays_unmonitored(self):
        self.fx.disk('sdb', '8:17', rotational='0')
        dm = self.fx.root / 'sys/devices/dm-1'
        (dm / 'slaves').mkdir(parents=True)
        (dm / 'slaves/sda').symlink_to(self.fx.disks['sda'])
        (dm / 'slaves/sdb').symlink_to(self.fx.disks['sdb'])
        (self.fx.blocks / '253:1').symlink_to(dm)
        self.fx.mount('253:1', '/mnt/mixed')
        self.fx.mount('0:99', '/mnt/nfs', fs='nfs')
        self.fx.mount('8:1', '/mnt/vfat', fs='vfat')
        stats, provider = self.stats()
        provider(self.plugin)
        self.assertEqual(sorted(stats.mounts), ['/mnt/hdd'])

    def test_every_disk_behind_a_raid_or_mapper_node_is_watched(self):
        self.fx.disk('sdb', '8:17')
        md = self.fx.root / 'sys/devices/md0'
        (md / 'slaves').mkdir(parents=True)
        (md / 'slaves/sda').symlink_to(self.fx.disks['sda'])
        (md / 'slaves/sdb').symlink_to(self.fx.disks['sdb'])
        (self.fx.blocks / '9:0').symlink_to(md)
        self.fx.mount('9:0', '/mnt/raid')
        stats, provider = self.stats()
        provider(self.plugin)
        stats.tick()
        self.fx.set_io('sdb', 3, 0)
        self.advance(30)
        stats.tick()
        self.assertIn('/mnt/raid', self.calls)

    def test_display_filter_applies(self):
        self.plugin.is_display_any = lambda mnt, dev: mnt != '/mnt/hdd'
        stats, provider = self.stats()
        provider(self.plugin)
        self.assertEqual(stats.mounts, {})

    def test_policy_reports_the_gate_without_collecting(self):
        stats, provider = self.stats()
        health = telemetry.nvme_provider(lambda *a, **k: self.fail('health probe'), Path('/none'))
        policy = telemetry.StoragePolicy(provider, health, self.fx.root / 'sys/class/block',
                                         lambda: self.wall[0], lambda: self.wall[0])
        data = policy.snapshot()
        self.assertTrue(data['filesystem_hdd_enabled'])
        self.assertEqual(data['hdd']['scope'], 'activity_gated_statvfs')
        self.assertEqual(data['hdd']['interval_seconds'], 300)
        self.assertEqual(data['hdd']['mounts'], [])
        self.assertEqual(self.calls, [])

    def test_sampler_thread_survives_a_failing_tick(self):
        stats, provider = self.stats()
        ticks = []
        def tick():
            ticks.append(1)
            raise RuntimeError('boom')
        stats.tick = tick
        stop = stats.start(period=0.01)
        import time
        time.sleep(0.15)
        stop()
        self.assertGreater(len(ticks), 2)

    def test_intervals_have_floors(self):
        stats, _ = self.stats(interval=1)
        self.assertEqual(stats.interval, 300)


if __name__ == '__main__':
    unittest.main()
