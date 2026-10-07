import importlib.util
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

spec = importlib.util.spec_from_file_location('telemetry', Path(__file__).with_name('telemetry.py'))
telemetry = importlib.util.module_from_spec(spec) if spec else None
try:
    spec.loader.exec_module(telemetry)
except FileNotFoundError:
    telemetry = SimpleNamespace()

class TelemetryTests(unittest.TestCase):
    def test_nvme_only_enumeration_never_scans_or_opens_hdds_and_caches(self):
        self.assertTrue(callable(getattr(telemetry, 'nvme_provider', None)), 'NVMe-only provider is missing')
        with tempfile.TemporaryDirectory() as tmp:
            for name in ('nvme0', 'nvme1', 'sda', 'nvme0n1', 'nvme-bad'):
                Path(tmp, name).mkdir()
            calls = []
            def device(path, interface):
                calls.append((path, interface))
                return SimpleNamespace(name=path)
            now = [1]
            provider = telemetry.nvme_provider(device, Path(tmp), lambda: now[0])
            self.assertEqual([d.name for d in provider().devices], ['/dev/nvme0','/dev/nvme1'])
            provider()
            self.assertEqual(len(calls), 2)
            now[0] = 600
            provider()
            self.assertEqual(len(calls), 2, 'NVMe health must not be recollected before 600s')
            now[0] = 601
            provider()
            self.assertEqual(calls, [('/dev/nvme0','nvme'),('/dev/nvme1','nvme')] * 2)

    def test_gpu_enrichment_preserves_percent_and_exposes_bytes_without_guessing(self):
        self.assertTrue(callable(getattr(telemetry, 'gpu_memory', None)), 'GPU byte enrichment is missing')
        stats = [{'gpu_id':'nvidia0','mem':12.5}, {'gpu_id':'nvidia1','mem':None}]
        def memory(handle):
            if handle == 'broken':
                raise OSError('unsupported')
            return SimpleNamespace(used=1024, total=8192)
        actual = telemetry.gpu_memory(stats, ['ok','broken'], memory)
        self.assertEqual(actual[0], {'gpu_id':'nvidia0','mem':12.5,'memory_used':1024,'memory_total':8192})
        self.assertEqual(actual[1], {'gpu_id':'nvidia1','mem':None})

    def test_install_replaces_unsafe_smart_provider_and_wraps_gpu_once(self):
        self.assertTrue(callable(getattr(telemetry, 'install', None)), 'startup adapters are missing')
        import sys
        import types
        from unittest.mock import patch
        smart = types.ModuleType('glances.plugins.smart')
        smart.DeviceList = lambda: self.fail('unsafe broad scan invoked')
        class NvidiaGPU:
            device_handles = ['gpu']
            def get_device_stats(self):
                return [{'gpu_id':'nvidia0','mem':25}]
        nvidia = types.ModuleType('glances.plugins.gpu.cards.nvidia')
        nvidia.NvidiaGPU = NvidiaGPU
        nvidia.pynvml = SimpleNamespace(nvmlDeviceGetMemoryInfo=lambda h: SimpleNamespace(used=2,total=8))
        pysmart = types.ModuleType('pySMART')
        pysmart.Device = lambda *a, **k: SimpleNamespace(name='nvme0', model='fixture')
        fs = types.ModuleType('glances.plugins.fs')
        fs.psutil = SimpleNamespace(disk_usage=lambda *a: None)
        class FsPlugin:
            def update_local(self):
                self.fail('uncached filesystem collector invoked')
            def get_raw(self):
                return []
        fs.FsPlugin = FsPlugin
        stats = types.ModuleType('glances.stats')
        class GlancesStats:
            def load_plugins(self, args=None):
                pass
        stats.GlancesStats = GlancesStats
        model = types.ModuleType('glances.plugins.plugin.model')
        model.GlancesPluginModel = type('GlancesPluginModel', (), {})
        sensors = types.ModuleType('glances.plugins.sensors')
        class GlancesGrabSensors:
            def _GlancesGrabSensors__fetch_data(self):
                return {}
            def update(self):
                return []
        sensors.GlancesGrabSensors = GlancesGrabSensors
        hddtemp = types.ModuleType('glances.plugins.sensors.sensor.glances_hddtemp')
        hddtemp.GlancesGrabHDDTemp = type('GlancesGrabHDDTemp', (), {})
        modules = {'glances':types.ModuleType('glances'), 'glances.plugins':types.ModuleType('glances.plugins'),
                   'glances.plugins.sensors':sensors,
                   'glances.plugins.sensors.sensor':types.ModuleType('glances.plugins.sensors.sensor'),
                   'glances.plugins.sensors.sensor.glances_hddtemp':hddtemp,
                   'glances.plugins.fs':fs, 'glances.stats':stats,
                   'glances.plugins.plugin':types.ModuleType('glances.plugins.plugin'),
                   'glances.plugins.plugin.model':model,
                   'glances.plugins.smart':smart, 'glances.plugins.gpu':types.ModuleType('glances.plugins.gpu'),
                   'glances.plugins.gpu.cards':types.ModuleType('glances.plugins.gpu.cards'),
                   'glances.plugins.gpu.cards.nvidia':nvidia, 'pySMART':pysmart}
        with patch.dict(sys.modules, modules):
            telemetry.install(gpu=True)
            telemetry.install(gpu=True)
            self.assertIsInstance(smart.DeviceList().devices, list)
            self.assertEqual(NvidiaGPU().get_device_stats()[0]['memory_total'], 8)

if __name__ == '__main__':
    unittest.main()
