import importlib.util
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest
from unittest.mock import patch


HERE = Path(__file__).resolve().parent
README = '<h1>Lost City - January 17, 2005</h1>\n'
CLIENT = 'const CLIENT_VERSION = 289;\n'


class BuildMetadataTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.wiki = Path(self.tmp.name) / 'wiki'
        self.wiki.mkdir()
        self.calls = []
        self.identity = {'id': 'a' * 64, 'image': 'sha256:' + 'b' * 64,
                         'running': True, 'startedAt': '2026-10-22T00:00:00Z',
                         'restartCount': 0, 'workdir': '/opt/server'}

    def module(self):
        path = HERE / 'build_metadata.py'
        self.assertTrue(path.is_file(), 'metadata producer is missing')
        spec = importlib.util.spec_from_file_location('build_metadata', path)
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def docker(self, command, **kwargs):
        self.calls.append((command, kwargs))
        payload = self.identity if command[1] == 'inspect' else {'readme': README, 'client': CLIENT}
        return subprocess.CompletedProcess(command, 0, json.dumps(payload), '')

    def test_refresh_writes_private_running_content_metadata(self):
        module = self.module()
        with patch.object(module.subprocess, 'run', side_effect=self.docker):
            module.refresh(self.wiki)
        target = self.wiki / 'data/game-build.json'
        value = json.loads(target.read_text())
        self.assertEqual(set(value), {'version', 'protocolRevision', 'historicalContentDate',
                                     'historicalContentDateSource', 'contentIdentity', 'observedAt', 'confidence'})
        self.assertEqual(value['version'], 1)
        self.assertEqual(value['protocolRevision'], 289)
        self.assertEqual(value['historicalContentDate'], '2005-01-17')
        self.assertEqual(value['historicalContentDateSource'], 'content-readme')
        self.assertEqual(value['confidence'], 'declared-target')
        self.assertRegex(value['observedAt'], r'^\d{4}-\d\d-\d\dT.*\+00:00$')
        self.assertRegex(value['contentIdentity'], r'^sha256:[a-f0-9]{64}$')
        self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o600)
        self.assertEqual(target.stat().st_uid, os.getuid())
        self.assertEqual([c[0][1] for c in self.calls], ['inspect', 'exec', 'inspect'])
        for command, options in self.calls:
            self.assertTrue(0 < options['timeout'] <= 30)
            self.assertNotIn('.env', ' '.join(command))
        command = self.calls[1][0]
        self.assertIn('bun', command)
        self.assertIn(self.identity['id'], command)
        self.assertIn('/opt/server', command)
        self.assertIn('content/README.md', command[-1])
        self.assertNotIn('engine/README.md', command[-1])

    def test_unstable_or_stopped_container_invalidates_previous_date(self):
        module = self.module()
        target = self.wiki / 'data/game-build.json'
        target.parent.mkdir()
        for key, changed in [('id', 'c' * 64), ('image', 'sha256:' + 'd' * 64),
                             ('running', False), ('startedAt', '2026-10-22T01:00:00Z'),
                             ('restartCount', 1), ('workdir', '/other')]:
            with self.subTest(field=key):
                target.write_text('{"historicalContentDate":"2004-11-23"}')
                calls = 0
                def changed_docker(command, **kwargs):
                    nonlocal calls
                    calls += 1
                    if calls == 3:
                        return subprocess.CompletedProcess(command, 0, json.dumps(dict(self.identity, **{key: changed})), '')
                    return self.docker(command, **kwargs)
                with patch.object(module.subprocess, 'run', side_effect=changed_docker):
                    with self.assertRaises(ValueError):
                        module.refresh(self.wiki)
                self.assertFalse(target.exists())
        self.identity['running'] = False
        with patch.object(module.subprocess, 'run', side_effect=self.docker):
            with self.assertRaises(ValueError):
                module.refresh(self.wiki)

    def test_identity_binds_readme_container_and_image(self):
        module = self.module()
        identities = []
        for field, value in [(None, None), ('id', 'e' * 64), ('image', 'sha256:' + 'f' * 64)]:
            if field:
                self.identity[field] = value
            with patch.object(module.subprocess, 'run', side_effect=self.docker):
                module.refresh(self.wiki)
            identities.append(json.loads((self.wiki / 'data/game-build.json').read_text())['contentIdentity'])
        def changed_readme(command, **kwargs):
            if command[1] == 'exec':
                return subprocess.CompletedProcess(command, 0, json.dumps({'readme': README + 'changed', 'client': CLIENT}), '')
            return self.docker(command, **kwargs)
        with patch.object(module.subprocess, 'run', side_effect=changed_readme):
            module.refresh(self.wiki)
        identities.append(json.loads((self.wiki / 'data/game-build.json').read_text())['contentIdentity'])
        self.assertEqual(len(set(identities)), 4)

    def test_invalid_or_ambiguous_declarations_fail_closed(self):
        module = self.module()
        target = self.wiki / 'data/game-build.json'
        target.parent.mkdir()
        for readme, client in [
                (README.replace('January 17', 'February 30'), CLIENT),
                (README.replace('2005', '2004').replace('January 17', 'February 29'), CLIENT + CLIENT),
                (README + README, CLIENT), ('engine reconstructed 2004-11-23', CLIENT),
                (README, '// const CLIENT_VERSION = 289;'), (README, 'const CLIENT_VERSION = 0;')]:
            with self.subTest(readme=readme, client=client):
                target.write_text('{}')
                def invalid(command, **kwargs):
                    if command[1] == 'exec':
                        return subprocess.CompletedProcess(command, 0, json.dumps({'readme': readme, 'client': client}), '')
                    return self.docker(command, **kwargs)
                with patch.object(module.subprocess, 'run', side_effect=invalid):
                    with self.assertRaises(ValueError):
                        module.refresh(self.wiki)
                self.assertFalse(target.exists())

    def test_probe_failures_remove_previous_metadata_without_temporary_leaks(self):
        module = self.module()
        target = self.wiki / 'data/game-build.json'
        target.parent.mkdir()
        for step in (1, 2, 3):
            for failure in (FileNotFoundError('private path'), subprocess.TimeoutExpired('docker', 20),
                            subprocess.CalledProcessError(1, 'docker', stderr='secret diagnostic'),
                            ValueError('bad JSON')):
                with self.subTest(step=step, failure=type(failure).__name__):
                    target.write_text('{}')
                    calls = 0
                    def failing(command, **kwargs):
                        nonlocal calls
                        calls += 1
                        if calls == step:
                            raise failure
                        return self.docker(command, **kwargs)
                    with patch.object(module.subprocess, 'run', side_effect=failing):
                        with self.assertRaises(type(failure)):
                            module.refresh(self.wiki)
                    self.assertFalse(target.exists())
                    self.assertEqual(list(target.parent.glob('.game-build-*')), [])

    def test_symlink_metadata_is_removed_without_touching_referent(self):
        module = self.module()
        target = self.wiki / 'data/game-build.json'
        target.parent.mkdir()
        referent = self.wiki / 'private'
        referent.write_text('sentinel')
        target.symlink_to(referent)
        with patch.object(module.subprocess, 'run', side_effect=self.docker) as run:
            with self.assertRaises(ValueError):
                module.refresh(self.wiki)
        run.assert_not_called()
        self.assertFalse(os.path.lexists(target))
        self.assertEqual(referent.read_text(), 'sentinel')

    def test_symlink_or_foreign_data_directory_is_rejected_before_probe(self):
        module = self.module()
        outside = self.wiki / 'outside'
        outside.mkdir()
        data = self.wiki / 'data'
        data.symlink_to(outside, target_is_directory=True)
        with patch.object(module.subprocess, 'run') as run:
            with self.assertRaises(ValueError):
                module.refresh(self.wiki)
        run.assert_not_called()
        self.assertEqual(list(outside.iterdir()), [])
        data.unlink()
        data.mkdir()
        with patch.object(module.os, 'getuid', return_value=os.getuid() + 1), patch.object(module.subprocess, 'run', side_effect=self.docker):
            with self.assertRaises(ValueError):
                module.refresh(self.wiki)

    def test_concurrent_failed_refresh_cannot_leave_an_earlier_usable_date(self):
        from concurrent.futures import ThreadPoolExecutor
        import threading
        module = self.module()
        first_read = threading.Event()
        release_first = threading.Event()
        second_started = threading.Event()
        second_probed = threading.Event()
        def probe(command, **kwargs):
            if threading.current_thread().name.endswith('_1'):
                second_probed.set()
                raise ValueError('container unavailable')
            if command[1] == 'exec':
                first_read.set()
                self.assertTrue(release_first.wait(5))
            return self.docker(command, **kwargs)
        def second_refresh():
            second_started.set()
            module.refresh(self.wiki)
        with patch.object(module.subprocess, 'run', side_effect=probe), ThreadPoolExecutor(max_workers=2) as pool:
            first = pool.submit(module.refresh, self.wiki)
            self.assertTrue(first_read.wait(5))
            second = pool.submit(second_refresh)
            self.assertTrue(second_started.wait(5))
            overlapping = second_probed.wait(0.1)
            release_first.set()
            first.result(timeout=5)
            with self.assertRaises(ValueError):
                second.result(timeout=5)
        self.assertFalse(overlapping, 'metadata refreshes must serialize')
        self.assertFalse((self.wiki / 'data/game-build.json').exists())

    def test_cli_error_does_not_print_private_docker_diagnostics(self):
        import contextlib
        import io
        module = self.module()
        target = self.wiki / 'data/game-build.json'
        target.parent.mkdir()
        target.write_text('{}')
        error = subprocess.CalledProcessError(1, ['docker', 'inspect'], stderr='PRIVATE-SENTINEL')
        stream = io.StringIO()
        with patch('sys.argv', ['build_metadata.py', '--wiki-root', str(self.wiki)]), \
                patch.object(module.subprocess, 'run', side_effect=error), contextlib.redirect_stderr(stream):
            with self.assertRaises(SystemExit) as exit:
                module.main()
        self.assertEqual(exit.exception.code, 1)
        self.assertIn('historical cutoff invalidated', stream.getvalue())
        self.assertNotIn('PRIVATE-SENTINEL', stream.getvalue())
        self.assertNotIn(str(self.wiki), stream.getvalue())
        self.assertFalse(target.exists())

    def test_failed_atomic_replacement_cleans_up_and_retains_raw(self):
        module = self.module()
        data = self.wiki / 'data'
        data.mkdir()
        (data / 'game-build.json').write_text('{}')
        raw = data / 'raw-cache'
        raw.write_text('raw retained')
        with patch.object(module.subprocess, 'run', side_effect=self.docker), \
                patch.object(module.os, 'replace', side_effect=OSError('cannot replace')):
            with self.assertRaises(OSError):
                module.refresh(self.wiki)
        self.assertFalse((data / 'game-build.json').exists())
        self.assertEqual(list(data.glob('.game-build-*')), [])
        self.assertEqual(raw.read_text(), 'raw retained')

    def test_later_deployed_target_advances_without_protocol_date_mapping(self):
        module = self.module()
        for declaration, expected in [('February 29, 2004', '2004-02-29'),
                                      ('January 17, 2005', '2005-01-17'),
                                      ('March 1, 2005', '2005-03-01')]:
            def probe(command, **kwargs):
                if command[1] == 'exec':
                    return subprocess.CompletedProcess(command, 0, json.dumps({
                        'readme': '<h1>Lost City - ' + declaration + '</h1>', 'client': CLIENT}), '')
                return self.docker(command, **kwargs)
            with patch.object(module.subprocess, 'run', side_effect=probe):
                module.refresh(self.wiki)
            value = json.loads((self.wiki / 'data/game-build.json').read_text())
            self.assertEqual(value['historicalContentDate'], expected)
            self.assertEqual(value['protocolRevision'], 289)

    def test_lock_symlink_and_insecure_lock_are_rejected_without_probe(self):
        module = self.module()
        data = self.wiki / 'data'
        data.mkdir()
        lock = data / '.game-build.lock'
        outside = self.wiki / 'outside'
        outside.write_text('sentinel')
        lock.symlink_to(outside)
        with patch.object(module.subprocess, 'run') as run:
            with self.assertRaises(OSError):
                module.refresh(self.wiki)
        run.assert_not_called()
        self.assertEqual(outside.read_text(), 'sentinel')
        lock.unlink()
        lock.write_text('')
        lock.chmod(0o644)
        with patch.object(module.subprocess, 'run') as run:
            with self.assertRaises(ValueError):
                module.refresh(self.wiki)
        run.assert_not_called()

    def test_early_lock_failures_invalidate_previously_fresh_metadata(self):
        module = self.module()
        target = self.wiki / 'data/game-build.json'
        lock = self.wiki / 'data/.game-build.lock'
        outside = self.wiki / 'outside-lock'
        outside.write_text('sentinel')
        for failure in ('permissions', 'symlink', 'open'):
            with self.subTest(failure=failure):
                lock.unlink(missing_ok=True)
                with patch.object(module.subprocess, 'run', side_effect=self.docker):
                    module.refresh(self.wiki)
                self.assertTrue(target.exists())
                if failure == 'permissions':
                    lock.chmod(0o644)
                elif failure == 'symlink':
                    lock.unlink()
                    lock.symlink_to(outside)
                original_open = module.os.open
                def fail_open(path, *args, **kwargs):
                    if failure == 'open' and Path(path) == lock:
                        raise PermissionError('lock unavailable')
                    return original_open(path, *args, **kwargs)
                with patch.object(module.os, 'open', side_effect=fail_open), patch.object(module.subprocess, 'run') as run:
                    with self.assertRaises((OSError, ValueError)):
                        module.refresh(self.wiki)
                run.assert_not_called()
                self.assertFalse(target.exists())
                self.assertEqual(outside.read_text(), 'sentinel')

    def test_invalid_inspection_cannot_choose_arbitrary_content_workdir(self):
        module = self.module()
        for field, value in [('id', '--help'), ('image', ''), ('startedAt', ''),
                             ('restartCount', -1), ('workdir', ''), ('workdir', '/elsewhere')]:
            with self.subTest(field=field, value=value):
                identity = dict(self.identity, **{field: value})
                with patch.object(module.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, json.dumps(identity), '')) as run:
                    with self.assertRaises(ValueError):
                        module.refresh(self.wiki)
                self.assertEqual(run.call_count, 1)
