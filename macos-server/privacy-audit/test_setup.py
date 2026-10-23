import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('setup.py')


class LaunchAgentTests(unittest.TestCase):
    def test_agents_use_private_runtime_and_do_not_start_on_load(self):
        self.assertTrue(SCRIPT.exists(), 'privacy installer is missing')
        spec = importlib.util.spec_from_file_location('privacy_setup', SCRIPT)
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        runtime = Path('/private-audit/runtime')
        config = Path('/private-audit/config.json')
        agents = module.render_agents(runtime, config, '/usr/bin/python3', '/usr/bin:/bin')
        self.assertEqual(len(agents), 2)
        for label, raw in agents.items():
            data = plistlib.loads(raw)
            self.assertEqual(data['Label'], label)
            args = data['ProgramArguments']
            self.assertEqual(args[:5], ['/usr/bin/python3', '-I', str(runtime / 'privacy-audit.py'), '--config', str(config)])
            self.assertEqual(data['WorkingDirectory'], str(runtime))
            self.assertEqual(args[-1], 'run')
            self.assertFalse(data.get('RunAtLoad', False))
            self.assertFalse(data.get('KeepAlive', False))
            self.assertNotIn('Computer-Setup/scripts', ' '.join(args))
            self.assertEqual(data['EnvironmentVariables']['PATH'], '/usr/bin:/bin')
        daily = plistlib.loads(agents['net.computer-setup.privacy-daily'])
        monthly = plistlib.loads(agents['net.computer-setup.privacy-monthly'])
        self.assertNotIn('Day', daily['StartCalendarInterval'])
        self.assertEqual(monthly['StartCalendarInterval']['Day'], 1)
        self.assertIn('--full', monthly['ProgramArguments'])

    def test_install_copies_trusted_runtime_with_private_permissions(self):
        spec = importlib.util.spec_from_file_location('privacy_setup', SCRIPT)
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            source = root / 'source'
            source.mkdir()
            for name in ('privacy-audit.py', 'check-privacy.py'):
                (source / name).write_text('print("trusted")\n')
            config = root / 'private' / 'config.json'
            config.parent.mkdir(mode=0o700)
            config.write_text(json.dumps({'repo_path': str(root / 'checkout')}))
            config.chmod(0o600)
            agents = root / 'LaunchAgents'
            self.assertTrue(hasattr(module, 'install'), 'installer missing')
            module.install(source, config, agents, '/usr/bin/python3', '/usr/bin:/bin')
            for name in ('privacy-audit.py', 'check-privacy.py'):
                target = config.parent / 'runtime' / name
                self.assertEqual(target.read_bytes(), (source / name).read_bytes())
                self.assertEqual(target.stat().st_mode & 0o777, 0o600)
            self.assertEqual((config.parent / 'runtime').stat().st_mode & 0o777, 0o700)
            self.assertEqual(len(list(agents.glob('*.plist'))), 2)
            for cadence in ('daily', 'monthly'):
                for stream in ('stdout', 'stderr'):
                    self.assertEqual((config.parent / f'{cadence}.{stream}.log').stat().st_mode & 0o777, 0o600)

    def test_install_rejects_symlink_runtime(self):
        spec = importlib.util.spec_from_file_location('privacy_setup', SCRIPT)
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            config = root / 'config.json'
            config.write_text('{}\n')
            outside = root / 'outside'
            outside.mkdir()
            (root / 'runtime').symlink_to(outside, target_is_directory=True)
            self.assertTrue(hasattr(module, 'install'), 'installer missing')
            with self.assertRaises(ValueError):
                module.install(root, config, root / 'agents', '/usr/bin/python3', '/usr/bin:/bin')

    def test_install_rejects_runtime_inside_audited_checkout(self):
        spec = importlib.util.spec_from_file_location('privacy_setup', SCRIPT)
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            source = root / 'scripts'
            source.mkdir()
            for name in ('privacy-audit.py', 'check-privacy.py'):
                (source / name).write_text('print("trusted")\n')
            private = root / 'private'
            private.mkdir()
            config = private / 'config.json'
            config.write_text(json.dumps({'repo_path': str(root)}))
            with self.assertRaises(ValueError):
                module.install(source, config, root / 'agents', '/usr/bin/python3', '/usr/bin:/bin')
            self.assertFalse((private / 'runtime').exists())


if __name__ == '__main__':
    unittest.main()
