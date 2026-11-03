#!/usr/bin/env python3
import importlib.util
import json
import os
import subprocess
from unittest import mock
import pathlib
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).with_name('privacy-audit.py')


def load():
    spec = importlib.util.spec_from_file_location('privacy_audit', SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class InventoryTests(unittest.TestCase):
    def test_canonical_filters(self):
        self.assertTrue(SCRIPT.exists(), 'privacy inventory implementation missing')
        audit = load()
        for value in ['127.0.0.1', '::', 'ff02::1', 'fe80::1%en0', '192.0.2.7', '2001:db8::1', '169.254.2.3']:
            self.assertIsNone(audit.canonical_ip(value))
        self.assertEqual(audit.canonical_ip('fd12:0000::1%en0'), 'fd12::1')
        self.assertEqual(audit.canonical_ip('10.23.45.6'), '10.23.45.6')


    def test_stale_retains_history_and_manual(self):
        audit = load()
        inventory = audit.merge_inventory({}, {'host': [('hostname', 'madeup-device')]}, [], ['manual-value'], 'one')
        inventory = audit.merge_inventory(inventory, {}, ['host'], [], 'two')
        records = {r['value']: r for r in inventory['entries']}
        self.assertEqual(set(records), {'madeup-device', 'manual-value'})
        self.assertEqual(records['madeup-device']['first_seen'], 'one')
        self.assertEqual(records['madeup-device']['last_seen'], 'one')
        self.assertEqual(inventory['sources']['host']['status'], 'unavailable')
        self.assertEqual(records['manual-value']['type'], 'manual')

    def test_linux_interface_metadata_and_mac_parser(self):
        audit = load()
        data = [{'ifname': 'en0', 'addr_info': [{'local': '10.23.45.6'}]},
                {'ifname': 'br-abc', 'addr_info': [{'local': '10.23.45.7'}]},
                {'ifname': 'en1', 'linkinfo': {'info_kind': 'bridge'}, 'addr_info': [{'local': '10.23.45.8'}]}]
        self.assertEqual(audit.linux_addresses(data), ['10.23.45.6'])
        text = 'en0: flags=1\n\tinet 10.23.45.6 netmask 0xff\n\tinet6 fd12::1%en0 prefixlen 64\nbridge100: flags=1\n\tinet 10.23.45.7 netmask 0xff\n'
        self.assertEqual(audit.mac_addresses(text), ['10.23.45.6', 'fd12::1'])

    def test_tagged_names_not_added_but_full_dns_and_ips_kept(self):
        audit = load()
        records = audit.tailnet_records({'Self': {'HostName': 'madeup-box', 'DNSName': 'madeup-box.example.ts.net.', 'TailscaleIPs': ['100.77.23.9']}, 'Peer': {'one': {'HostName': 'container-short', 'DNSName': 'container-short.example.ts.net.', 'Tags': ['tag:service'], 'TailscaleIPs': ['100.77.23.10']}, 'two': {'HostName': 'localhost'}}})
        values = {v for _, v in records}
        self.assertIn('madeup-box', values)
        self.assertIn('container-short.example.ts.net', values)
        self.assertNotIn('container-short', values)
        self.assertNotIn('localhost', values)

    def test_tailnet_public_endpoint_candidates_only(self):
        audit = load()
        records = audit.tailnet_records({'Self': {
            'Addrs': ['8.8.8.8:41641', '[2606:4700:4700::1111]:443',
                      '10.23.45.6:41641', '172.23.45.6:41641', '[fd12::1]:443',
                      '100.77.23.9:41641', '127.0.0.1:1', '192.0.2.7:1',
                      'unknown', '8.8.4.4', '8.8.4.4:99999', '[::ffff:10.23.45.6]:443',
                      '8.8.4.4:notaport', '2606:4700:4700::1111:443',
                      '[4000::1]:443', '[fec0::1]:443'],
            'CurAddr': '8.8.4.4:41641'},
            'Peer': {'one': {'CurAddr': '[2001:4860:4860::8888]:41641'}}})
        self.assertEqual(set(records), {('ip', '8.8.8.8'), ('ip', '8.8.4.4'),
                                       ('ip', '2606:4700:4700::1111'),
                                       ('ip', '2001:4860:4860::8888')})

    def test_state_permissions_symlinks_and_lock(self):
        audit = load()
        with tempfile.TemporaryDirectory(dir=pathlib.Path(tempfile.gettempdir()).resolve()) as temp:
            state = pathlib.Path(temp) / 'private'
            with audit.State(state) as store:
                store.write('inventory.json', {'entries': []})
                self.assertEqual(state.stat().st_mode & 0o777, 0o700)
                self.assertEqual((state / 'inventory.json').stat().st_mode & 0o777, 0o600)
                with self.assertRaises(audit.AuditError):
                    with audit.State(state):
                        pass
                (state / 'bad').symlink_to(state / 'inventory.json')
                with self.assertRaises(audit.AuditError):
                    store.write('bad', {})
            link = pathlib.Path(temp) / 'link'
            link.symlink_to(state)
            with self.assertRaises(audit.AuditError):
                with audit.State(link):
                    pass

    def test_ssh_alias_validation_before_execution(self):
        audit = load()
        with self.assertRaises(audit.AuditError):
            audit.collect_host({'ssh': 'bad;touch marker'})
        with self.assertRaises(audit.AuditError):
            audit.collect_host({'ssh': '-oProxyCommand=bad'})


class AuditTests(unittest.TestCase):
    def setUp(self):
        self.module = load()
        self.temp = tempfile.TemporaryDirectory(dir=pathlib.Path(tempfile.gettempdir()).resolve())
        self.addCleanup(self.temp.cleanup)
        self.base = pathlib.Path(self.temp.name)
        self.repo = self.base / 'repo'
        self.repo.mkdir()
        self.git('init', '-q')
        self.git('config', 'user.email', 'fixture@example.com')
        self.git('config', 'user.name', 'Fixture')
        (self.repo / '.gitignore').write_text('.privacy-denylist\n')
        self.git('add', '.')
        self.git('commit', '-qm', 'root')
        self.seed = self.base / 'seed'
        self.seed.write_text('madeup-private-device\n')
        self.config = {'repo_path': str(self.repo), 'state_dir': str(self.base / 'state'),
                       'denylist_path': str(self.seed), 'hosts': [], 'sync_secret': False}

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.repo), *args], stderr=subprocess.DEVNULL).decode().strip()

    def test_refresh_only_renders_ignored_untracked_denylist(self):
        with self.module.State(self.config['state_dir']) as store:
            result = self.module.refresh(self.config, store)
            self.assertEqual(result['unavailable_sources'], 0)
            self.assertEqual((self.repo / '.privacy-denylist').read_text(), 'madeup-private-device\n')
            self.assertEqual((self.repo / '.privacy-denylist').stat().st_mode & 0o777, 0o600)
            self.git('add', '-f', '.privacy-denylist')
            with self.assertRaises(self.module.AuditError):
                self.module.refresh(self.config, store)

    def test_reachable_removed_blob_paths_metadata_and_new_identifier_rescan(self):
        name = 'madeup-private-device\n--evil;$(touch marker).txt'
        (self.repo / name).write_text('madeup-private-device\n' * 40)
        self.git('add', '.')
        self.git('commit', '-qm', 'madeup-private-device')
        removed = self.git('rev-parse', 'HEAD')
        self.git('rm', '--', name)
        self.git('commit', '-qm', 'removed')
        (self.repo / 'innocent').write_text('second-private-device\n')
        self.git('add', '.')
        self.git('commit', '-qm', 'another')
        with self.module.State(self.config['state_dir']) as store:
            self.module.refresh(self.config, store)
            first = self.module.audit(self.config, store)
            self.assertGreater(first['findings_count'], 0)
            report = (store.path / 'report.json').read_text()
            self.assertNotIn('madeup-private-device', report)
            self.assertNotIn('second-private-device', report)
            self.assertIn(removed, report)
            self.assertFalse((self.repo / 'marker').exists())
            second = self.module.audit(self.config, store)
            self.assertEqual(second['commits_scanned'], 0)
            self.seed.write_text('madeup-private-device\nsecond-private-device\n')
            self.module.refresh(self.config, store)
            third = self.module.audit(self.config, store)
            self.assertGreater(third['commits_scanned'], 0)
            self.assertEqual(third['mode'], 'full')
            self.assertLess(len(json.loads((store.path / 'report.json').read_text())['findings']), 15)

    def test_missing_manual_seed_keeps_inventory_and_run_continues(self):
        (self.repo / 'data').write_text('madeup-private-device')
        self.git('add', '.')
        self.git('commit', '-qm', 'fixture')
        with self.module.State(self.config['state_dir']) as store:
            self.module.refresh(self.config, store)
        self.seed.unlink()
        config_path = self.base / 'config.json'
        config_path.write_text(json.dumps(self.config))
        config_path.chmod(0o600)
        result = subprocess.run(['python3', str(SCRIPT), '--config', str(config_path), 'run'],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertTrue(result.stdout.strip(), 'missing seed aborted run instead of reporting degraded coverage')
        summary = json.loads(result.stdout)
        self.assertTrue(summary['refresh']['degraded'])
        self.assertEqual(summary['refresh']['unavailable_sources'], 1)
        self.assertGreater(summary['audit']['findings_count'], 0)
        with self.module.State(self.config['state_dir']) as store:
            inventory = store.read('inventory.json', {})
            self.assertEqual(inventory['sources']['manual']['status'], 'unavailable')
            self.assertIn('madeup-private-device', (store.path / '.privacy-denylist').read_text())
        self.assertEqual((self.repo / '.privacy-denylist').read_text(), 'madeup-private-device\n')

    def test_partial_refresh_keeps_values_and_sanitizes_diagnostics(self):
        self.config['hosts'] = [{'name': 'node', 'ssh': 'example-alias'}]
        with self.module.State(self.config['state_dir']) as store:
            with mock.patch.object(self.module, 'collect_host', return_value=[('hostname', 'old-private-device')]):
                self.module.refresh(self.config, store)
            with mock.patch.object(self.module, 'collect_host', side_effect=self.module.AuditError('old-private-device')):
                result = self.module.refresh(self.config, store)
            self.assertEqual(result['unavailable_sources'], 1)
            self.assertNotIn('old-private-device', json.dumps(result))
            self.assertIn('old-private-device', (store.path / '.privacy-denylist').read_text())

    def test_github_pagination_and_inaccessible_surface(self):
        self.config['github_repo'] = 'example/project'
        calls = []
        def fake(argv, **kwargs):
            calls.append(argv)
            endpoint = argv[-1]
            if '/pulls/comments' in endpoint:
                raise self.module.AuditError('madeup-private-device')
            if 'page=2' in endpoint:
                return b'[]'
            return json.dumps([{'number': i, 'id': i, 'title': 'madeup-private-device', 'body': 'madeup-private-device'} for i in range(100)]).encode()
        with self.module.State(self.config['state_dir']) as store:
            self.module.refresh(self.config, store)
            with mock.patch.object(self.module, 'command', side_effect=fake):
                report = self.module.github_scan(self.config, self.module.Findings(self.module.load_scanner(), ['madeup-private-device']))
            self.assertIn('github_review_comments', report['unavailable'])
            self.assertTrue(any('page=2' in c[-1] for c in calls))
            self.assertNotIn('madeup-private-device', json.dumps(report))

    def test_config_mirror_and_repo_validation(self):
        self.assertEqual(self.module.validate_config(self.config)['repo_path'], str(self.repo))
        for url in ['ssh://example.com/project', 'https://github.com/example/project;touch-bad.git', 'https://github.com/example/project.git?x=y']:
            with self.assertRaises(self.module.AuditError):
                self.module.validate_config(dict(self.config, mirror_url=url))
        for repo in ('../..', '.hidden/project', 'example/-bad'):
            with self.assertRaises(self.module.AuditError):
                self.module.validate_config(dict(self.config, github_repo=repo))
        self.module.validate_config(dict(self.config, mirror_url='https://github.com/example/project.git'))

    def test_cli_real_run_and_secret_opt_in(self):
        config_path = self.base / 'config.json'
        config_path.write_text(json.dumps(self.config))
        config_path.chmod(0o600)
        completed = subprocess.run(['python3', str(SCRIPT), '--config', str(config_path), 'run'], capture_output=True, text=True)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(json.loads(completed.stdout)['audit']['commits_scanned'], 1)
        self.assertEqual((self.base / 'state' / 'summary.json').stat().st_mode & 0o777, 0o600)
        self.assertNotIn('madeup-private-device', completed.stdout + completed.stderr)
        self.config.update(github_repo='example/project', sync_secret=True)
        real_command = self.module.command
        calls = []
        def fake(argv, **kwargs):
            if argv[0] != 'gh':
                return real_command(argv, **kwargs)
            calls.append((argv, kwargs))
            return json.dumps({'name': 'PRIVACY_DENYLIST', 'updated_at': '2026-01-01T00:00:00Z'}).encode()
        with self.module.State(self.config['state_dir']) as store:
            with mock.patch.object(self.module, 'command', side_effect=fake):
                result = self.module.refresh(self.config, store)
        self.assertTrue(result['secret_synced'])
        self.assertEqual(len(calls), 2)
        self.assertNotIn('madeup-private-device', repr([args for args, _ in calls]))
        self.assertIn('madeup-private-device', calls[0][1]['input_data'])

    def test_annotated_tags_and_git_config_cannot_execute_repo_code(self):
        marker = self.base / 'executed'
        (self.repo / '.gitattributes').write_text('* filter=evil diff=evil\n')
        (self.repo / 'data').write_text('madeup-private-device')
        self.git('add', '.')
        self.git('commit', '-qm', 'safe')
        self.git('tag', '-a', 'example-tag', '-m', 'madeup-private-device')
        self.git('config', 'core.fsmonitor', f'touch {marker}')
        self.git('config', 'diff.external', f'touch {marker}')
        self.git('config', 'diff.evil.command', f'touch {marker}')
        self.git('config', 'filter.evil.smudge', f'touch {marker}')
        with self.module.State(self.config['state_dir']) as store:
            self.module.refresh(self.config, store)
            result = self.module.audit(self.config, store)
            report = store.read('report.json', {})
        self.assertFalse(marker.exists())
        self.assertIn('git_tag_metadata', {i['surface'] for i in report['findings']})
        self.assertFalse(result['degraded'])

    def test_mirror_commands_are_fixed_and_use_private_directory(self):
        self.config['mirror_url'] = 'https://github.com/example/project.git'
        calls = []
        with self.module.State(self.config['state_dir']) as store:
            def fake(repo, *args, **kwargs):
                calls.append((str(repo), args))
                if args[0] == 'clone':
                    (store.path / 'public-mirror.git').mkdir()
                return self.config['mirror_url'].encode() + b'\n'
            with mock.patch.object(self.module, 'git', side_effect=fake):
                self.assertEqual(self.module.mirror_repo(self.config, store), store.path / 'public-mirror.git')
                self.module.mirror_repo(self.config, store)
        self.assertIn('--mirror', calls[0][1])
        self.assertTrue(any('fetch' in args for _, args in calls))
        self.assertFalse(any(repo == str(self.repo) for repo, _ in calls))

    def test_collector_isolates_hostile_cwd_and_python_environment(self):
        marker = self.base / 'executed'
        (self.repo / 'platform.py').write_text(f"from pathlib import Path\nPath({str(marker)!r}).touch()\n")
        old_cwd = os.getcwd()
        try:
            os.chdir(self.repo)
            with mock.patch.dict(os.environ, {'PYTHONPATH': str(self.repo)}):
                result = self.module.host_command({'local': True}, ['python3', '-I', '-'],
                                                 'import platform; print(platform.system())')
            self.assertFalse(marker.exists())
            self.assertTrue(result.strip())
            with mock.patch.dict(os.environ, {'PYTHONHOME': str(self.repo)}):
                self.module.host_command({'local': True}, ['python3', '-I', '-'], 'print(1)')
            collector = 'import platform,json; print(json.dumps({"hostname":"fixture-host","fqdn":"fixture-host","login":"fixture-user","interfaces":[]}))'
            with mock.patch.object(self.module, 'COLLECTOR', collector), mock.patch.dict(
                    os.environ, {'PYTHONPATH': str(self.repo), 'PYTHONHOME': str(self.repo)}):
                self.module.collect_host({'local': True})
            self.assertFalse(marker.exists())
            with mock.patch.object(self.module, 'command', return_value=b'1') as remote:
                self.module.host_command({'ssh': 'example-alias'}, ['python3', '-I', '-'], collector)
            result = subprocess.run(['/bin/sh', '-c', remote.call_args.args[0][-1]],
                                    input=collector, text=True, capture_output=True, cwd=self.repo,
                                    env=dict(os.environ, PYTHONPATH=str(self.repo), PYTHONHOME=str(self.repo)))
            self.assertEqual(result.returncode, 0)
            self.assertFalse(marker.exists())
            with self.assertRaises(self.module.AuditError):
                self.module.host_command({'ssh': 'example-alias'}, ['python3', '-'], collector)
            data = b'{"hostname":"fixture-host","fqdn":"fixture-host","login":"fixture-user","interfaces":[]}'
            with mock.patch.object(self.module, 'command', return_value=data) as run:
                self.module.collect_host({'local': True})
        finally:
            os.chdir(old_cwd)
        self.assertEqual(run.call_args.args[0], ['python3', '-I', '-'])
        self.assertEqual(run.call_args.kwargs['cwd'], '/')

    def test_tailnet_local_fallback_and_fixed_ssh_command(self):
        calls = []
        def fake(argv, input_data=None, **kwargs):
            calls.append((argv, dict(kwargs, input_data=input_data)))
            if argv[0] == 'tailscale':
                raise self.module.AuditError('unavailable')
            return b'{"BackendState":"Running","Self":{"HostName":"fixture-device"}}'
        with mock.patch.object(self.module, 'command', side_effect=fake):
            self.module.collect_tailnet({'local': True})
            self.module.host_command({'ssh': 'example-alias'}, ['python3', '-I', '-'], 'print(1)')
        self.assertIn('/Applications/Tailscale.app/', calls[1][0][0])
        self.assertEqual(calls[2][0][-1], 'cd / && exec env -u PYTHONPATH -u PYTHONHOME python3 -I -')
        self.assertIn('-oBatchMode=yes', calls[2][0])
        self.assertEqual(calls[2][1]['input_data'], 'print(1)')

    def test_other_branch_root_history_is_scanned(self):
        initial_branch = self.git('branch', '--show-current')
        self.git('checkout', '--orphan', 'detached-fixture')
        self.git('rm', '-rf', '--', '.')
        (self.repo / 'old-data').write_text('madeup-private-device')
        self.git('add', '.')
        self.git('commit', '-qm', 'branch-only')
        root = self.git('rev-parse', 'HEAD')
        self.git('checkout', initial_branch)
        with self.module.State(self.config['state_dir']) as store:
            self.module.refresh(self.config, store)
            result = self.module.audit(self.config, store)
            report = store.read('report.json', {})
        self.assertEqual(result['commits_scanned'], 2)
        self.assertIn(root, json.dumps(report))
        self.assertTrue(any(item['surface'] == 'git_blobs' for item in report['findings']))

    def test_reports_redact_allow_markers_and_control_characters(self):
        scanner = self.module.load_scanner()
        findings = self.module.Findings(scanner, ['madeup-private-device'])
        findings.scan('git_blobs', 'madeup-private-device privacy-check: allow', 'madeup-private-device privacy-check: allow')
        findings.scan('git_blobs', 'odd\nlocator', 'madeup-private-device')
        report = findings.result()
        self.assertEqual(report['findings_count'], 2)
        self.assertNotIn('madeup-private-device', json.dumps(report))
        self.assertNotIn('odd', json.dumps(report))

    def test_cli_failure_diagnostics_are_generic(self):
        config_path = self.base / 'config.json'
        config_path.write_text(json.dumps(dict(self.config, repo_path=str(self.base / 'madeup-private-device'))))
        config_path.chmod(0o600)
        process = subprocess.run(['python3', str(SCRIPT), '--config', str(config_path), 'run'], capture_output=True, text=True)
        self.assertEqual(process.returncode, 2)
        self.assertNotIn('madeup-private-device', process.stderr + process.stdout)
        self.assertNotIn('Traceback', process.stderr)

    def test_redacted_paths_remain_distinct(self):
        for suffix in ('one', 'two'):
            (self.repo / (suffix + ' madeup-private-device')).write_text('madeup-private-device ' + suffix)
        self.git('add', '.')
        self.git('commit', '-qm', 'fixture')
        with self.module.State(self.config['state_dir']) as store:
            self.module.refresh(self.config, store)
            self.module.audit(self.config, store)
            report = store.read('report.json', {})
        for surface in ('git_paths', 'git_blobs'):
            items = [i for i in report['findings'] if i['surface'] == surface]
            self.assertEqual(len(items), 2)
            self.assertEqual(len({i['locator'] for i in items}), 2)
        self.assertNotIn('madeup-private-device', json.dumps(report))

    def test_non_utf8_paths_remain_distinct(self):
        for suffix in ('one', 'two'):
            (self.repo / ('madeup-private-device ' + suffix)).write_text('madeup-private-device')
        self.git('add', '.')
        self.git('commit', '-qm', 'fixture')
        real_git = self.module.git
        def raw_paths(repo, *args, **kwargs):
            result = real_git(repo, *args, **kwargs)
            if args[0] == 'diff-tree':
                result = result.replace(b' one\x00', b' \xfe\x00').replace(b' two\x00', b' \xff\x00')
            return result
        with self.module.State(self.config['state_dir']) as store:
            self.module.refresh(self.config, store)
            with mock.patch.object(self.module, 'git', side_effect=raw_paths):
                self.module.audit(self.config, store)
            report = store.read('report.json', {})
        items = [i for i in report['findings'] if i['surface'] == 'git_paths']
        self.assertEqual(len(items), 2)
        self.assertNotIn('madeup-private-device', json.dumps(report))

    def test_redacted_path_keeps_safe_commit_locator(self):
        findings = self.module.Findings(self.module.load_scanner(), ['madeup-private-device'])
        commit = 'a' * 40
        findings.scan('git_paths', commit + ':madeup-private-device', 'madeup-private-device')
        locator = findings.result()['findings'][0]['locator']
        self.assertTrue(locator.startswith(commit + ':[redacted path]:'))
        self.assertRegex(locator.rsplit(':', 1)[1], r'^[0-9a-f]{24}$')

    def test_failed_full_retains_findings_and_forces_next_full(self):
        (self.repo / 'data').write_text('madeup-private-device')
        self.git('add', '.')
        self.git('commit', '-qm', 'fixture')
        with self.module.State(self.config['state_dir']) as store:
            self.module.refresh(self.config, store)
            first = self.module.audit(self.config, store)
            checkpoint = store.read('checkpoint.json', {})
            with mock.patch.object(self.module, 'git_scan', side_effect=self.module.AuditError('failed')):
                failed = self.module.audit(self.config, store, full=True)
            self.assertTrue(failed['degraded'])
            self.assertEqual(failed['findings_count'], first['findings_count'])
            self.assertEqual(store.read('checkpoint.json', {}), checkpoint)
            recovered = self.module.audit(self.config, store)
            self.assertEqual(recovered['mode'], 'full')
            self.assertGreater(recovered['commits_scanned'], 0)
            self.assertEqual(recovered['findings_count'], first['findings_count'])

    def test_truncated_full_retains_previous_findings(self):
        (self.repo / 'data').write_text('madeup-private-device')
        self.git('add', '.')
        self.git('commit', '-qm', 'fixture')
        with self.module.State(self.config['state_dir']) as store:
            self.module.refresh(self.config, store)
            first = self.module.audit(self.config, store)
            baseline = store.read('report.json', {})
            checkpoint = store.read('checkpoint.json', {})
            def truncated(repo, findings, known):
                for number in range(5000):
                    findings.items[('git_blobs', f'fixture:{number}', 'denylist entry')] = {
                        'surface': 'git_blobs', 'locator': f'fixture:{number}',
                        'category': 'denylist entry', 'line': 1}
                findings.overflow = True
                return {'reachable': [], 'commits_scanned': 0}
            with mock.patch.object(self.module, 'git_scan', side_effect=truncated):
                failed = self.module.audit(self.config, store, full=True)
            self.assertTrue(failed['degraded'])
            self.assertTrue(failed['findings_truncated'])
            self.assertEqual(failed['findings_count'], 5000)
            self.assertTrue(all(item in store.read('report.json', {})['findings']
                                for item in baseline['findings']))
            self.assertEqual(store.read('checkpoint.json', {}), checkpoint)

    def test_missing_report_forces_reconciliation(self):
        (self.repo / 'data').write_text('madeup-private-device')
        self.git('add', '.')
        self.git('commit', '-qm', 'fixture')
        with self.module.State(self.config['state_dir']) as store:
            self.module.refresh(self.config, store)
            self.module.audit(self.config, store)
            (store.path / 'report.json').unlink()
            result = self.module.audit(self.config, store)
        self.assertEqual(result['mode'], 'full')
        self.assertGreater(result['findings_count'], 0)

    def test_command_bounds_and_stderr_never_leak(self):
        with self.assertRaises(self.module.AuditError) as error:
            self.module.command(['python3', '-c', "import sys;sys.stderr.write('madeup-private-device');sys.exit(1)"])
        self.assertNotIn('madeup-private-device', str(error.exception))
        with self.assertRaises(self.module.AuditError):
            self.module.command(['python3', '-c', "print('a'*10000)"], limit=100)


if __name__ == '__main__':
    unittest.main()
