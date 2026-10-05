"""End-to-end producer tests: real shell, jq, filesystem and resource helper."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

MOCK = r'''#!/usr/bin/env python3
import os, sys, pathlib
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
if name == 'systemctl':
    if args[0] == 'is-active': sys.exit(3)
    values = dict(ActiveState=os.environ.get('TEST_STATE', 'active'),
                  ActiveEnterTimestamp='Mon 2026-10-05 00:00:00 UTC',
                  InvocationID='fixture-run', CPUUsageNSec='123000000000',
                  MemoryCurrent=os.environ.get('TEST_MEMORY', '2048'),
                  NRestarts='2', TasksCurrent='31')
    props = [args[i + 1] for i, a in enumerate(args[:-1]) if a == '-p']
    for p in props:
        print(values.get(p, '') if '--value' in args else p + '=' + values.get(p, ''))
elif name == 'journalctl':
    with open(os.environ['MOCK_JOURNAL_ARGS'], 'a') as log: log.write(' '.join(args) + '\n')
    if '--grep' in args and 'Join succeeded: ' in args:
        print('1791158400.0 host game: Join succeeded: Fixture player')
    elif any(a.startswith('_SYSTEMD_INVOCATION_ID=') for a in args):
        print('LogNetVersion: Set ProjectVersion to 1.0.0.7. Version Checksum will be recalculated on next use.')
        print('World load SUCCEEDED Guid[0123456789ABCDEF0123456789ABCDEF] OwnerName[Fixture]')
    else:
        print('LogNetVersion: Set ProjectVersion to 9.9.9.9. Version Checksum will be recalculated on next use.')
elif name == 'ss':
    print('State Recv-Q Send-Q Local Address:Port Peer Address:Port\nUNCONN 0 0 0.0.0.0:7777 0.0.0.0:*')
elif name == 'ip':
    if 'route' in args: print('default via 192.0.2.1 dev eth0')
    else: print('2: eth0 inet 192.0.2.2/24 scope global eth0')
elif name == 'tailscale': print('100.64.0.2')
else: raise AssertionError((name, args))
'''


class ProducerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.scripts = self.root / 'scripts'
        self.scripts.mkdir()
        for name in ('dragonwilds-status.sh', 'status_metrics.py'):
            source = ROOT / 'dragonwilds' / name
            if source.exists(): shutil.copyfile(source, self.scripts / name)
        players = self.scripts / 'dragonwilds-players.sh'
        players.write_text('#!/bin/sh\nprintf "1\\tFixture player\\n"\n')
        players.chmod(0o755)
        self.install = self.root / 'installation'
        config = self.install / 'RSDragonwilds/Saved/Config/LinuxServer/DedicatedServer.ini'
        config.parent.mkdir(parents=True)
        config.write_text('ServerName=Test\tserver\nDefaultWorldName=1\nWorldPassword=fixture-password\nOwnerId=fixture\n')
        saves = self.install / 'RSDragonwilds/Saved/SaveGames'
        saves.mkdir()
        (saves / '1.sav').write_bytes(b'active world')
        (saves / 'idle.sav').write_bytes(b'idle world')
        manifest = self.install / 'steamapps/appmanifest_4019830.acf'
        manifest.parent.mkdir()
        manifest.write_text('"buildid" "25630937"\n')
        (self.install / 'content.bin').write_bytes(b'x' * 8192)
        bins = self.root / 'bin'
        bins.mkdir()
        mock = bins / 'mock'
        mock.write_text(MOCK)
        mock.chmod(0o755)
        for name in ('systemctl', 'journalctl', 'ss', 'ip', 'tailscale'):
            (bins / name).symlink_to(mock)
        self.output = self.root / 'public/status.json'
        self.env = dict(os.environ, PATH=str(bins) + ':' + os.environ['PATH'],
                        DRAGONWILDS_INSTALL_DIR=str(self.install), STATUS_JSON=str(self.output),
                        STATUS_HISTORY_FILE=str(self.root / 'private/history.json'),
                        MOCK_JOURNAL_ARGS=str(self.root / 'journal-args'))

    def run_producer(self):
        result = subprocess.run(['bash', str(self.scripts / 'dragonwilds-status.sh')],
                                env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(self.output.read_text())

    def test_software_stats_come_from_current_invocation_and_real_installation(self):
        status = self.run_producer()
        self.assertEqual(status.get('game_version'), '1.0.0.7')
        self.assertEqual(status['build'], '25630937')
        self.assertNotIn('disk_free_bytes', status)
        self.assertGreater(status['install_bytes'], 8192)
        self.assertEqual(status['tasks_current'], 31)
        self.assertEqual(status['restarts'], 2)
        self.assertEqual(status['join_password'], 'fixture-password')
        self.assertEqual(status['save_bytes'], len(b'active world'))
        self.assertEqual(status['world_count'], 2)
        self.assertEqual(status['server_name'], 'Test\tserver')
        self.assertIsNone(status['cpu_percent'])
        self.assertIn('memory samples', status['sample_window'])
        self.assertIn('_SYSTEMD_INVOCATION_ID=fixture-run', (self.root / 'journal-args').read_text())
        self.assertEqual(self.output.stat().st_mode & 0o777, 0o644)
        self.assertFalse((self.output.parent / 'history.json').exists())

    def test_unavailable_memory_is_null_not_zero(self):
        self.env['TEST_MEMORY'] = '[not set]'
        status = self.run_producer()
        self.assertIsNone(status['memory_bytes'])
        self.assertEqual(status['memory_current'], 'unknown')
        self.assertEqual(status['memory_samples'], 0)

    def test_stopped_service_does_not_claim_running_version(self):
        self.env['TEST_STATE'] = 'inactive'
        status = self.run_producer()
        self.assertEqual(status['game_version'], 'unknown')
        self.assertIsNone(status['cpu_percent'])
        self.assertIsNone(status['memory_bytes'])


    def test_partial_installation_size_is_unknown(self):
        du = self.root / 'bin/du'
        du.write_text('#!/bin/sh\nprintf "4096\\tpartial\\n"\nexit 1\n')
        du.chmod(0o755)
        status = self.run_producer()
        self.assertIsNone(status['install_bytes'])
        self.assertEqual(status['installation_footprint'], 'unknown')

    def test_failed_player_query_is_unknown_not_empty_server(self):
        (self.scripts / 'dragonwilds-players.sh').write_text('#!/bin/sh\nexit 1\n')
        status = self.run_producer()
        self.assertIsNone(status['players'])
        self.assertEqual(status['online_capacity'], 'unknown / 6')


if __name__ == '__main__':
    unittest.main()
