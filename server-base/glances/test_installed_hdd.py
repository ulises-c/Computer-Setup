"""Run inside each installed Glances image, in its own process (telemetry.install is one-shot).

Synthetic sysfs only: no drive is touched."""
import json
import tempfile
import unittest
from argparse import Namespace
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
import telemetry

try:
    import glances.plugins.fs as fs
    import glances.plugins.diskio as diskio
    import glances.plugins.smart as smart
    import glances.plugins.sensors as sensors
    from glances.plugins.sensors.sensor.glances_hddtemp import GlancesGrabHDDTemp
    from glances.stats import GlancesStats
    from glances.config import Config
    from glances.outputs.glances_restful_api import GlancesRestfulApi
    from glances.timer import Timer
except ImportError:
    GlancesStats = None


@unittest.skipIf(GlancesStats is None, 'run in installed Glances image')
class InstalledHddActivityTests(unittest.TestCase):
    def test_activity_gated_hdd_rows_survive_every_real_fs_handler(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            disk = root / 'devices/sda'
            part = disk / 'sda1'
            for path in (disk / 'queue', disk / 'device', part):
                path.mkdir(parents=True)
            (disk / 'queue/rotational').write_text('1')
            (part / 'partition').write_text('1')
            (disk / 'stat').write_text('1 0 0 0 1 0 0 0 0 0 0\n')
            blocks = root / 'blocks'
            blocks.mkdir()
            (blocks / '8:1').symlink_to(part)
            (root / 'mountinfo').write_text('1 0 8:1 / /mnt/hdd rw - ext4 /dev/sda1 rw\n')
            wall, calls = [1000], []
            def usage(mount):
                calls.append(mount)
                return SimpleNamespace(total=1000, used=250, free=750, percent=25.0)
            hdd = telemetry.HddActivityStats(usage, wall=lambda: wall[0])
            filesystems = telemetry.filesystem_provider(usage, blocks, root / 'mountinfo',
                                                        wall=lambda: wall[0], hdd=hdd)
            health = telemetry.nvme_provider(lambda *a, **k: self.fail('health probe'), root / 'none')
            policy = telemetry.StoragePolicy(filesystems, health, blocks, wall=lambda: wall[0])
            policy.temperatures = lambda: {}
            def selected_plugins(stats, args=None):
                for name in ('fs', 'smart', 'alert', 'sensors', 'diskio'):
                    stats._load_plugin(name, args, stats.config)
            with patch.object(GlancesStats, 'load_plugins', selected_plugins), \
                 patch.object(sensors.psutil, 'sensors_temperatures', side_effect=AssertionError('BROAD HWMON READ')), \
                 patch.object(sensors.psutil, 'sensors_fans', return_value={}), \
                 patch.object(diskio.psutil, 'disk_io_counters', return_value={}), \
                 patch.object(GlancesGrabHDDTemp, 'fetch', side_effect=AssertionError('HDD TEMP FETCH')):
                telemetry.install(policy=policy)
                args = Namespace(time=2, disable_history=True, disable_all=False, disable_fs=False, disable_smart=False)
                stats = GlancesStats(Config(), args)
                api = GlancesRestfulApi.__new__(GlancesRestfulApi)
                api.stats, api.timer = stats, Timer(0)
                api.args = Namespace(cached_time=0)
                api.plugins_list = stats.getPluginsList()
                def refresh():
                    for plugin in stats._plugins.values():
                        plugin.refresh_timer.set(0)
                        plugin.refresh_timer.reset()
                        plugin.update()
                refresh()
                self.assertEqual(json.loads(api._api('fs').body), [])
                hdd.tick()
                (disk / 'stat').write_text('2 0 0 0 1 0 0 0 0 0 0\n')
                wall[0] = 1030
                hdd.tick()
                wall[0] = 1090
                refresh()
                for name in ('fs', 'storagepolicy'):
                    api._api(name)
                    api._api_top(name, 2)
                    api._api_views(name)
                    api._api_limits(name)
                    api._api_history(name)
                api._api_all()
                rows = json.loads(api._api('fs').body)
                self.assertEqual([r['mnt_point'] for r in rows], ['/mnt/hdd'])
                self.assertEqual(rows[0]['collected_at'], 1030)
                self.assertEqual(rows[0]['collection_age_seconds'], 60)
                self.assertEqual(calls, ['/mnt/hdd'])
                policy_data = json.loads(api._api('storagepolicy').body)
                self.assertTrue(policy_data['filesystem_hdd_enabled'])
                self.assertEqual(policy_data['hdd']['mounts'][0]['mnt_point'], '/mnt/hdd')


if __name__ == '__main__':
    unittest.main()
