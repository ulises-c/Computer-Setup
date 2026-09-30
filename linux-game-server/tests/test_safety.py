#!/usr/bin/env python3
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
MOCK = r'''#!/usr/bin/env python3
import json, os, pathlib, shutil, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
root = pathlib.Path(os.environ['MOCK_ROOT'])
statefile = root / 'state.json'
state = json.loads(statefile.read_text())
marker = root / 'maintenance/blocked'
logfile = root / 'events'
def save(): statefile.write_text(json.dumps(state))
def log(event):
    with logfile.open('a') as file: file.write(event + '\n')
def safe(path):
    path = pathlib.Path(path)
    assert path.is_relative_to(root), path
    return path
if name == 'sudo':
    os.execvp(args[0], args)
elif name == 'systemctl':
    if args[0] == 'show':
        unit = args[1]
        prop = next(x.split('=', 1)[1] for x in args if x.startswith('--property='))
        active = state.get(unit, 'inactive')
        values = {'LoadState': 'not-found' if state.get('absent') else 'loaded',
                  'ActiveState': active, 'MainPID': '17' if active == 'active' else '0',
                  'ControlPID': '17' if active in ('activating', 'deactivating') else '0',
                  'Job': '0', 'NeedDaemonReload': 'no'}
        print(values[prop])
    elif args[0] == 'daemon-reload':
        state['loaded_guard'] = marker.exists()
        save(); log('reload')
    elif args[0] == 'stop':
        for unit in args[1:]:
            log('stop ' + unit)
            if unit.endswith('.timer') and state.get('inflight'):
                log('restart blocked' if marker.exists() and state.get('loaded_guard') else 'UNSAFE restart')
                if not marker.exists(): state['dragonwilds.service'] = 'active'
            if not state.get('refuse_stop'): state[unit] = 'inactive'
        save()
    elif args[0] in ('start', 'enable'):
        for unit in (x for x in args[1:] if x.endswith(('.service', '.timer'))):
            if marker.exists() and state.get('loaded_guard'):
                log('blocked ' + unit)
            else:
                log('start ' + unit)
                state[unit] = 'active'
        save()
    elif args[0] == 'is-active':
        sys.exit(0 if state.get(args[-1]) == 'active' else 3)
    else: raise AssertionError(args)
elif name == 'busctl':
    print('a(sbbsi) 1 "ConditionPathExists" false true "' + str(marker) + '" 0'
          if state.get('loaded_guard') and not state.get('missing_condition') else 'a(sbbsi) 0')
elif name == 'install':
    mode = int(args[args.index('-m') + 1], 8)
    if '-d' in args:
        path = safe(args[-1]); path.mkdir(parents=True, exist_ok=True); path.chmod(mode)
    else:
        path = safe(args[-1]); shutil.copyfile(args[-2], path); path.chmod(mode)
    log('install ' + str(path.relative_to(root)))
elif name == 'stat':
    path = safe(args[-1])
    print('0:' + oct(path.stat().st_mode & 0o777)[2:])
elif name in ('chown', 'chmod'):
    for arg in args[1:]: safe(arg)
    if name == 'chmod':
        for arg in args[1:]: safe(arg).chmod(int(args[0], 8))
elif name == 'tee':
    safe(args[-1]).write_text(sys.stdin.read())
elif name == 'touch':
    safe(args[-1]).touch(exist_ok=True)
elif name == 'ufw':
    log('ufw ' + ' '.join(args))
    if args[0] == 'allow' and args[1].endswith('/tcp'):
        state['ssh_rule'] = args[1]; save()
    if args[0] == 'status':
        print('Status: inactive' if state.get('firewall_inactive') else
              'Status: active\nDefault: deny (incoming), allow (outgoing), disabled (routed)')
        if state.get('ssh_rule') and not state.get('missing_ssh_rule'):
            print(state['ssh_rule'] + ' ALLOW IN Anywhere')
elif name == 'flock':
    log('lock ' + ' '.join(args))
    if args[-1] == '9' and state.get('race_after_lock'):
        state['dragonwilds.service'] = 'activating'; save()
    if args[-1] == '9' and state.get('remove_guard_after_lock'):
        marker.unlink(); save()
    if pathlib.Path('/usr/bin/flock').exists():
        os.execv('/usr/bin/flock', [name] + args)
    else:
        import fcntl
        fcntl.flock(int(args[-1]), fcntl.LOCK_SH if '-s' in args else fcntl.LOCK_EX)
elif name == 'steamcmd':
    log('validate')
    if state.get('hold_steam'):
        import time
        (root / 'validating').touch()
        while not (root / 'finish_validation').exists(): time.sleep(0.02)
    if state.get('fail_steam'): sys.exit(1)
else: raise AssertionError((name, args))
'''


class SafetyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=os.environ.get('TMPDIR'))
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.game = self.root / 'deployment/dragonwilds'
        self.game.mkdir(parents=True)
        for path in ROOT.glob('dragonwilds/*.sh'):
            text = path.read_text().replace('/var/lib/dragonwilds-maintenance', str(self.root / 'maintenance'))
            text = text.replace('/etc/systemd/system', str(self.root / 'units'))
            (self.game / path.name).write_text(text)
        bin_dir = self.root / 'bin'
        bin_dir.mkdir()
        mock = bin_dir / 'mock'
        mock.write_text(MOCK)
        mock.chmod(0o755)
        for name in ('sudo', 'systemctl', 'busctl', 'install', 'stat', 'chown', 'chmod',
                     'tee', 'touch', 'ufw', 'flock', 'steamcmd'):
            (bin_dir / name).symlink_to(mock)
        self.env = dict(os.environ, MOCK_ROOT=str(self.root),
                        PATH=str(bin_dir) + ':' + os.environ['PATH'],
                        HOME=str(self.root), STEAMCMD=str(bin_dir / 'steamcmd'),
                        DRAGONWILDS_INSTALL_DIR=str(self.root / 'game'), SSH_PORT='2222')
        self.statefile = self.root / 'state.json'
        self.statefile.write_text('{}')
        install = self.root / 'game'
        install.mkdir()
        launcher = install / 'RSDragonwildsServer.sh'
        launcher.write_text('#!/bin/sh\nexit 0\n')
        launcher.chmod(0o755)
        config = install / 'RSDragonwilds/Saved/Config/LinuxServer/DedicatedServer.ini'
        config.parent.mkdir(parents=True)
        config.write_text('[/Script/Dominion.DedicatedServerSettings]\nOwnerId=fixture\n'
                          'ServerGuid=fixture\nServerName=fixture\nDefaultWorldName=fixture\n')
        saves = install / 'RSDragonwilds/Saved/SaveGames'
        saves.mkdir()
        import struct
        (saves / 'fixture.sav').write_bytes(b''.join(struct.pack('<i', len(x) + 1) + x + b'\0'
                                                   for x in (b'fixture', b'L_World')))
        # No inherited installer or save parser can write outside this fixture.
        (self.game / 'setup.sh').write_text('#!/bin/bash\nset -eu\n'
            'systemctl daemon-reload\nsystemctl enable --now dragonwilds.service\n'
            'systemctl enable --now dragonwilds-update-check.timer dragonwilds-auto-update.timer\n')
        parser = ROOT / 'dragonwilds/read-save-info.sh'
        if parser.exists(): shutil.copyfile(parser, self.game / 'read-save-info.sh')
        setup = ROOT.joinpath('setup.sh').read_text().replace('source /etc/os-release', 'ID=ubuntu')
        setup = setup.replace('$(uname -m)', 'x86_64')
        (self.game.parent / 'setup.sh').write_text(setup)
        (self.root / 'lib').mkdir()
        (self.root / 'lib/core.sh').write_text('DRY_RUN=false\nrun() { "$@"; }\n'
            'core_csv_to_json() { printf "[]"; }\n'
            'core_prime_sudo() { printf "bootstrap actions\\n" >> "$MOCK_ROOT/events"; exit 0; }\n')
        (self.root / 'platforms').mkdir()
        (self.root / 'platforms/server.sh').write_text('')

    def state(self, **values):
        data = json.loads(self.statefile.read_text())
        data.update(values)
        self.statefile.write_text(json.dumps(data))

    def run_script(self, name, *args):
        return subprocess.run(['bash', str(self.game / name), *args], env=self.env,
                              capture_output=True, text=True)

    def events(self):
        path = self.root / 'events'
        return path.read_text().splitlines() if path.exists() else []

    def enter(self):
        result = self.run_script('maintenance.sh', 'enter')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_enter_blocks_inflight_restart_before_stopping_timers_services_game(self):
        self.state(**{'dragonwilds.service': 'active', 'dragonwilds-auto-update.service': 'active',
                      'dragonwilds-update-check.service': 'activating', 'inflight': True})
        self.enter()
        events = self.events()
        stops = [line for line in events if line.startswith('stop ')]
        self.assertEqual(stops, ['stop dragonwilds-auto-update.timer', 'stop dragonwilds-update-check.timer',
                                'stop dragonwilds-auto-update.service', 'stop dragonwilds-update-check.service',
                                'stop dragonwilds.service'])
        self.assertLess(events.index('reload'), events.index(stops[0]))
        self.assertIn('restart blocked', events)
        self.assertNotIn('UNSAFE restart', events)
        self.assertTrue((self.root / 'maintenance/blocked').exists())
        for unit in ('dragonwilds.service', 'dragonwilds-auto-update.service',
                     'dragonwilds-update-check.service', 'dragonwilds-auto-update.timer',
                     'dragonwilds-update-check.timer'):
            self.assertIn('ConditionPathExists=!' + str(self.root / 'maintenance/blocked'),
                          (self.root / 'units' / (unit + '.d/90-maintenance.conf')).read_text())
        self.assertFalse(any('mask' in line for line in events))

    def test_validation_refuses_missing_guard(self):
        result = self.run_script('install.sh')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('validate', self.events())

    def test_bootstrap_rerun_refuses_running_and_transitional_game_without_stopping_it(self):
        for state in ('active', 'activating', 'deactivating'):
            with self.subTest(state=state):
                self.state(**{'dragonwilds.service': state})
                result = self.run_script('../setup.sh')
                self.assertNotEqual(result.returncode, 0, result.stderr)
                self.assertFalse(any(x.startswith('stop ') for x in self.events()))
                self.assertNotIn('bootstrap actions', self.events())

    def test_validation_rechecks_after_steam_lock(self):
        self.enter()
        self.state(race_after_lock=True)
        result = self.run_script('install.sh')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('activating', result.stderr)
        self.assertNotIn('validate', self.events())

    def test_validation_holds_guard_until_steamcmd_finishes(self):
        self.enter()
        self.state(hold_steam=True)
        process = subprocess.Popen(['bash', str(self.game / 'install.sh')], env=self.env,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(lambda: process.kill() if process.poll() is None else None)
        deadline = time.monotonic() + 15
        while not (self.root / 'validating').exists() and process.poll() is None and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue((self.root / 'validating').exists())
        leave = subprocess.Popen(['bash', str(self.game / 'maintenance.sh'), 'leave'], env=self.env,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(lambda: leave.kill() if leave.poll() is None else None)
        time.sleep(0.3)
        self.assertIsNone(leave.poll(), 'leave released the guard during Steam validation')
        self.assertTrue((self.root / 'maintenance/blocked').exists())
        (self.root / 'finish_validation').touch()
        stdout, stderr = process.communicate(timeout=15)
        self.assertEqual(process.returncode, 0, stdout + stderr)
        stdout, stderr = leave.communicate(timeout=15)
        self.assertEqual(leave.returncode, 0, stdout + stderr)
        self.assertFalse((self.root / 'maintenance/blocked').exists())
        self.assertFalse(any(x.startswith('start ') for x in self.events()))

    def test_activation_installs_guarded_then_preserves_ssh_and_deliberately_starts(self):
        self.enter()
        result = self.run_script('activate.sh')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        events = self.events()
        self.assertIn('blocked dragonwilds.service', events)
        self.assertLess(events.index('ufw allow 2222/tcp comment Dragonwilds SSH access'),
                        events.index('blocked dragonwilds.service'))
        self.assertLess(events.index('blocked dragonwilds.service'), events.index('start dragonwilds.service'))
        self.assertFalse((self.root / 'maintenance/blocked').exists())

    def test_activation_refuses_inactive_firewall_before_inherited_installer(self):
        self.enter()
        self.state(firewall_inactive=True)
        result = self.run_script('activate.sh')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('UFW must already be active', result.stderr)
        self.assertFalse(any(x.startswith(('start ', 'blocked ')) for x in self.events()))
        self.assertTrue((self.root / 'maintenance/blocked').exists())

    def test_activation_refuses_unconfirmed_ssh_rule(self):
        self.enter()
        self.state(missing_ssh_rule=True)
        result = self.run_script('activate.sh')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('SSH-preserving', result.stderr)
        self.assertFalse(any(x.startswith(('start ', 'blocked ')) for x in self.events()))

    def test_activation_refuses_mismatched_save_header(self):
        self.enter()
        save = self.root / 'game/RSDragonwilds/Saved/SaveGames/fixture.sav'
        save.write_bytes(save.read_bytes().replace(b'fixture', b'changed'))
        result = self.run_script('activate.sh')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('disagree', result.stderr)
        self.assertFalse(any(x.startswith(('start ', 'blocked ')) for x in self.events()))

    def test_activation_refuses_missing_config_identity(self):
        self.enter()
        config = self.root / 'game/RSDragonwilds/Saved/Config/LinuxServer/DedicatedServer.ini'
        config.write_text(config.read_text().replace('OwnerId=fixture', 'OwnerId='))
        result = self.run_script('activate.sh')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('config/world is missing or invalid', result.stderr)
        self.assertFalse(any(x.startswith(('start ', 'blocked ')) for x in self.events()))

    def test_enter_fails_closed_when_update_service_will_not_stop(self):
        self.state(**{'dragonwilds-auto-update.service': 'active', 'refuse_stop': True})
        result = self.run_script('maintenance.sh', 'enter')
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.root / 'maintenance/blocked').exists())
        self.assertIn('dragonwilds-auto-update.service is active', result.stderr)

    def test_loaded_condition_is_required_even_with_marker_and_dropins(self):
        self.enter()
        self.state(missing_condition=True)
        result = self.run_script('install.sh')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('condition is not loaded', result.stderr)
        self.assertNotIn('validate', self.events())

    def test_validation_refuses_guard_removed_after_steam_lock(self):
        self.enter()
        self.state(remove_guard_after_lock=True)
        result = self.run_script('install.sh')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('validate', self.events())

    def test_validation_failure_keeps_persistent_guard(self):
        self.enter()
        self.state(fail_steam=True)
        result = self.run_script('install.sh')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('validate', self.events())
        self.assertTrue((self.root / 'maintenance/blocked').exists())

    def test_reboot_reload_cannot_start_guarded_units(self):
        self.enter()
        self.state(loaded_guard=False)
        for args in (('daemon-reload',), ('start', 'dragonwilds.service'),
                     ('start', 'dragonwilds-auto-update.timer', 'dragonwilds-update-check.timer')):
            subprocess.run(['systemctl', *args], env=self.env, check=True)
        self.assertFalse(any(x.startswith('start ') for x in self.events()))
        self.assertTrue((self.root / 'maintenance/blocked').exists())

    def test_fresh_host_without_base_units_can_enter_maintenance(self):
        self.state(absent=True)
        result = self.run_script('maintenance.sh', 'prepare')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(x.startswith('stop ') for x in self.events()))
        self.assertTrue((self.root / 'maintenance/blocked').exists())


if __name__ == '__main__':
    unittest.main()
