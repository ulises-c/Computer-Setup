"""No hardware probes: synthetic sysfs/proc fixtures and stub collectors only."""
import importlib.util
import unittest
import tempfile
from types import SimpleNamespace
from pathlib import Path

spec = importlib.util.spec_from_file_location('telemetry', Path(__file__).with_name('telemetry.py'))
telemetry = importlib.util.module_from_spec(spec)
spec.loader.exec_module(telemetry)


class StorageTests(unittest.TestCase):
    def test_filesystem_cache_only_queries_proven_solid_state_backing(self):
        self.assertTrue(hasattr(telemetry, 'filesystem_provider'), 'safe filesystem cache is missing')
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            blocks = root / 'sys/dev/block'
            blocks.mkdir(parents=True)
            for name, devno, rotational in [('nvme0n1', '259:0', '0'), ('sda', '8:0', '1')]:
                node = root / 'sys/devices' / name
                (node / 'queue').mkdir(parents=True)
                (node / 'device').mkdir()
                (node / 'queue/rotational').write_text(rotational)
                (blocks / devno).symlink_to(node)
            # A mapper reports rotational=0, but its slave is an HDD.
            dm = root / 'sys/devices/dm-1'
            (dm / 'slaves').mkdir(parents=True)
            (dm / 'queue').mkdir()
            (dm / 'queue/rotational').write_text('0')
            (dm / 'slaves/sda').symlink_to(root / 'sys/devices/sda')
            (blocks / '253:1').symlink_to(dm)
            mounts = root / 'mountinfo'
            mounts.write_text('1 0 259:0 / /etc/hostname rw - ext4 /dev/nvme0n1 rw\n'
                              '2 0 8:0 / /mnt/hdd rw - ext4 /dev/sda rw\n'
                              '3 0 253:1 / /mnt/mapper rw - ext4 /dev/dm-1 rw\n'
                              '4 0 0:99 / /mnt/unknown rw - nfs server:/export rw\n')
            calls, now, wall = [], [0], [1000]
            def usage(mount):
                calls.append(mount)
                return SimpleNamespace(total=100, used=20, free=80, percent=20)
            plugin = SimpleNamespace(is_display_any=lambda *args: True, has_alias=lambda path: None, get_key=lambda: 'mnt_point')
            provider = telemetry.filesystem_provider(usage, blocks, mounts, lambda: now[0], wall=lambda: wall[0])
            first = provider(plugin)
            self.assertEqual(calls, ['/etc/hostname'])
            self.assertEqual(first[0]['collected_at'], 1000)
            self.assertEqual(first[0]['collection_interval_seconds'], 300)
            for second in range(1, 300):
                now[0], wall[0] = second, 1000 + second
                rows = provider(plugin)
            self.assertEqual(calls, ['/etc/hostname'])
            self.assertEqual(rows[0]['collection_age_seconds'], 299)
            now[0], wall[0] = 300, 1300
            provider(plugin)
            self.assertEqual(calls, ['/etc/hostname', '/etc/hostname'])

    def test_policy_metadata_never_triggers_storage_collection(self):
        self.assertTrue(hasattr(telemetry, 'StoragePolicy'), 'capability plugin policy is missing')
        now, wall = [0], [1000]
        health = telemetry.nvme_provider(lambda *a, **k: self.fail('metadata requested a health probe'),
                                         Path('/does-not-exist'), lambda: now[0], wall=lambda: wall[0])
        fs = telemetry.filesystem_provider(lambda *a: self.fail('metadata requested statvfs'),
                                           clock=lambda: now[0], wall=lambda: wall[0])
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            node = root / 'devices/usb1/sda'
            (node / 'queue').mkdir(parents=True)
            (node / 'device').mkdir()
            (node / 'queue/rotational').write_text('1')
            (node / 'size').write_text('2000')
            blocks = root / 'class/block'
            blocks.mkdir(parents=True)
            (blocks / 'sda').symlink_to(node)
            policy = telemetry.StoragePolicy(fs, health, blocks, lambda: now[0], lambda: wall[0])
            for second in range(100):
                now[0], wall[0] = second, 1000 + second
                data = policy.snapshot()
            self.assertFalse(data['hdd_health_enabled'])
            self.assertFalse(data['filesystem_hdd_enabled'])
            self.assertEqual(data['fs']['collection_count'], 0)
            self.assertEqual(data['smart']['collection_count'], 0)
            self.assertEqual(data['inventory']['collection_count'], 1)
            self.assertEqual(data['inventory']['devices'][0], dict(name='sda', rotational=True,
                             storage_class='hdd', transport='usb', capacity_bytes=1024000,
                             health='disabled', filesystem_usage='disabled'))

    def test_nvme_cache_preserves_pysmart_attribute_objects(self):
        with tempfile.TemporaryDirectory() as tmp:
            Path(tmp, 'nvme0').mkdir()
            original = SimpleNamespace(name='nvme0', if_attributes=object())
            provider = telemetry.nvme_provider(lambda *a, **k: original, Path(tmp))
            self.assertIs(provider().devices[0], original,
                          'pySMART deepcopy serializes typed NVMe attributes into dicts')

    def test_temperatures_never_read_drive_hwmon_inputs(self):
        self.assertTrue(hasattr(telemetry, 'temperature_provider'), 'pre-read hwmon filter is missing')
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for name, chip in [('hwmon0', 'coretemp'), ('hwmon1', 'nvme'), ('hwmon2', 'drivetemp'), ('hwmon3', 'unknown')]:
                node = root / name
                node.mkdir()
                (node / 'name').write_text(chip)
                (node / 'temp1_label').write_text('Package id 0' if chip == 'coretemp' else 'Composite')
                # Drive and unknown inputs deliberately fail parsing if read.
                (node / 'temp1_input').write_text('45000' if chip == 'coretemp' else 'FORBIDDEN')
            health = telemetry.nvme_provider(lambda *a, **k: self.fail('temperature read initiated SMART'), root)
            health.cache.data = [SimpleNamespace(name='nvme0', model='fixture', temperature=37)]
            health.cache.collected_at = 1000
            provider = telemetry.temperature_provider(health, root)
            original = Path.read_text
            reads = []
            def track(path, *args, **kwargs):
                reads.append(str(path))
                return original(path, *args, **kwargs)
            from unittest.mock import patch
            with patch.object(Path, 'read_text', track):
                data = provider()
            self.assertEqual(data['coretemp'][0].current, 45)
            self.assertEqual(data['nvme'][0].current, 37)
            self.assertEqual(data['nvme'][0].label, 'Composite')
            self.assertFalse(any('/hwmon1/temp' in p or '/hwmon2/temp' in p or '/hwmon3/temp' in p for p in reads))

    def test_cache_enforces_interval_even_for_empty_or_failed_collections(self):
        self.assertTrue(hasattr(telemetry, 'SampleCache'), 'slow collection cache is missing')
        now, wall, calls = [0], [1000], []
        cache = telemetry.SampleCache(300, lambda: now[0], lambda: wall[0])
        def collect():
            calls.append(now[0])
            return []
        cache.get(collect)
        for second in range(1, 300):
            now[0], wall[0] = second, 1000 + second
            cache.get(collect)
        self.assertEqual(calls, [0])
        self.assertEqual(cache.metadata()['collection_age_seconds'], 299)
        now[0], wall[0] = 300, 1300
        def broken():
            calls.append(now[0])
            raise OSError('not available')
        cache.get(broken)
        now[0], wall[0] = 301, 1301
        cache.get(collect)
        self.assertEqual(calls, [0, 300])
        self.assertEqual(cache.metadata()['status'], 'error')
        self.assertEqual(cache.metadata()['collected_at'], 1000)
        self.assertEqual(cache.metadata()['collection_age_seconds'], 301)
        self.assertEqual(cache.metadata()['collection_count'], 2)


if __name__ == '__main__':
    unittest.main()
