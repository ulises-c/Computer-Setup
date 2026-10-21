"""Run inside each installed Glances image; all hardware collectors are stubs."""
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
class InstalledStorageTests(unittest.TestCase):
    def test_startup_all_smart_fs_and_metadata_requests_cannot_bypass_cache(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'nvme0').mkdir()
            (root / 'sda').mkdir()
            now, wall, health_calls, fs_calls = [0], [1000], [], []
            def device(path, interface):
                self.assertEqual((path, interface), ('/dev/nvme0', 'nvme'))
                health_calls.append((path, interface))
                return SimpleNamespace(name='nvme0', model='fixture', attributes=[], if_attributes=None)
            health = telemetry.nvme_provider(device, root, lambda: now[0], wall=lambda: wall[0])
            def usage(*args):
                fs_calls.append(args)
                return []
            # The integration seam uses the real FsPlugin, but fixture collection.
            filesystems = telemetry.filesystem_provider(usage, mountinfo=root / 'mountinfo', clock=lambda: now[0], wall=lambda: wall[0])
            (root / 'mountinfo').write_text('')
            blocks = root / 'blocks'
            blocks.mkdir()
            policy = telemetry.StoragePolicy(filesystems, health, blocks, lambda: now[0], lambda: wall[0])
            policy.temperatures = lambda: {'coretemp': [SimpleNamespace(label='Package id 0', current=40, high=None, critical=None)]}
            def selected_plugins(stats, args=None):
                stats._load_plugin('fs', args, stats.config)
                stats._load_plugin('smart', args, stats.config)
                stats._load_plugin('alert', args, stats.config)
                stats._load_plugin('sensors', args, stats.config)
                stats._load_plugin('diskio', args, stats.config)
            with patch.object(GlancesStats, 'load_plugins', selected_plugins), \
                 patch.object(smart, 'DeviceList', side_effect=AssertionError('BROAD SCAN')), \
                 patch.object(sensors.psutil, 'sensors_temperatures', side_effect=AssertionError('BROAD HWMON READ')), \
                 patch.object(sensors.psutil, 'sensors_fans', return_value={}), \
                 patch.object(diskio.psutil, 'disk_io_counters', return_value={}), \
                 patch.object(GlancesGrabHDDTemp, 'fetch', side_effect=AssertionError('HDD TEMP FETCH')):
                self.assertIn('policy', __import__('inspect').signature(telemetry.install).parameters,
                              'startup does not install filesystem/capability adapters')
                telemetry.install(policy=policy)
                args = Namespace(time=2, disable_history=True, disable_all=False, disable_fs=False, disable_smart=False)
                stats = GlancesStats(Config(), args)
                self.assertIn('storagepolicy', stats.getPluginsList())
                self.assertIn('sensors', stats.getPluginsList(), 'startup still tried broad drive hwmon reads')
                self.assertGreaterEqual(stats._plugins['diskio'].get_refresh(), 60, 'disk counters still collect every 2/5s')
                self.assertEqual(health_calls, [], 'startup must not eagerly query drives')
                api = GlancesRestfulApi.__new__(GlancesRestfulApi)
                api.stats, api.timer = stats, Timer(0)
                api.args = Namespace(cached_time=0)
                api.plugins_list = stats.getPluginsList()
                for second in range(0, 299, 5):
                    now[0], wall[0] = second, 1000 + second
                    for plugin in stats._plugins.values():
                        plugin.refresh_timer.set(0)
                        plugin.refresh_timer.reset()
                        plugin.update()
                    # Real REST handlers for all, direct, top, views, limits,
                    # history and capability reads (also exercise update paths).
                    api._api_all()
                    for name in ('smart', 'fs', 'storagepolicy'):
                        api._api(name)
                        api._api_top(name, 2)
                        api._api_views(name)
                        api._api_limits(name)
                        api._api_history(name)
                    data = json.loads(api._api('storagepolicy').body)
                self.assertEqual(health_calls, [('/dev/nvme0', 'nvme')])
                self.assertEqual(data['smart']['collected_at'], 1000)
                self.assertEqual(data['smart']['collection_age_seconds'], 295)
                self.assertEqual(data['fs']['collection_count'], 1)
                self.assertEqual(data['smart']['collection_count'], 1)
                self.assertEqual(fs_calls, [])
                self.assertEqual(json.loads(api._api('smart').body)[0]['DeviceName'], 'nvme0 fixture')
                now[0], wall[0] = 601, 1601
                for plugin in stats._plugins.values():
                    plugin.refresh_timer.set(0)
                    plugin.refresh_timer.reset()
                    plugin.update()
                self.assertEqual(health_calls, [('/dev/nvme0', 'nvme')] * 2)
                data = json.loads(api._api('storagepolicy').body)
                self.assertEqual(data['fs']['collection_count'], 2)
                self.assertEqual(data['smart']['collection_count'], 2)
                self.assertEqual(data['smart']['collected_at'], 1601)


if __name__ == '__main__':
    unittest.main()
