#!/usr/bin/env python3
"""Exercise provisioning scripts with isolated command/state fixtures, no daemon."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]

STUB = r'''#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
root = pathlib.Path(os.environ['FIXTURE'])
scenario = json.loads(os.environ.get('SCENARIO', '{}'))
with (root / 'calls.jsonl').open('a') as f:
    f.write(json.dumps([name, *args]) + '\n')
if name == 'sudo':
    sys.exit(subprocess.call(args))
if name == 'uname':
    print('Linux')
elif name == 'hostname':
    print('192.0.2.10' if args == ['-I'] else 'fixture-host')
elif name == 'tailscale':
    if args == ['status', '--json']:
        print(json.dumps({'BackendState': 'Running', 'Self': {'DNSName': 'host.example.ts.net.'}}))
    elif args[:2] == ['serve', 'status']:
        count_path = root / 'status_reads'
        count = int(count_path.read_text()) + 1 if count_path.exists() else 1
        count_path.write_text(str(count))
        if scenario.get('status_fail_at') == count: sys.exit(1)
        if scenario.get('status_fail'): sys.exit(1)
        state = json.loads((root / 'serve.json').read_text())
        if '--json' in args:
            state['fixture-padding'] = 'x' * scenario.get('status_padding', 0)
            if scenario.get('status_malformed'):
                print('unreadable status')
                sys.exit(0)
            print(json.dumps(state))
        else:
            for key, web in state.get('Web', {}).items():
                print('https://' + key)
                for path in web['Handlers']: print('|-- ' + path + ' proxy http://127.0.0.1:8080')
            print('x' * scenario.get('status_padding', 0))
    elif args[0] == 'serve' and args[-1] == 'off':
        if scenario.get('off_fail'): sys.exit(1)
        current = json.loads((root / 'serve.json').read_text())
        current_port = next(a.split('=')[1] for a in args if a.startswith('--https='))
        current_handlers = current.get('Web', {}).get('host.example.ts.net:' + current_port, {}).get('Handlers', {})
        if '--set-path' in args:
            if args[args.index('--set-path') + 1] not in current_handlers: sys.exit(1)
        elif not current_handlers:
            sys.exit(1)
        if not scenario.get('keep_retired'):
            state = json.loads((root / 'serve.json').read_text())
            port = next(a.split('=')[1] for a in args if a.startswith('--https='))
            key = 'host.example.ts.net:' + port
            if '--set-path' in args:
                state.get('Web', {}).get(key, {}).get('Handlers', {}).pop(args[args.index('--set-path') + 1], None)
            else:
                state.get('TCP', {}).pop(port, None)
                state.get('Web', {}).pop(key, None)
            (root / 'serve.json').write_text(json.dumps(state))
    elif '--bg' in args:
        (root / 'published').touch()
elif name == 'docker':
    if scenario.get('require_timezone') and 'compose' in args:
        zonefile = root / 'checkout/server-base/timezone.env'
        if not zonefile.exists():
            (root / 'compose_before_timezone').touch()
            sys.exit(1)
        if zonefile.read_text() != 'TZ=Etc/UTC\n': sys.exit(1)
        (root / 'compose_after_timezone').touch()
    if 'adguard' in ' '.join(args):
        state_path = root / 'adguard.json'
        state = json.loads(state_path.read_text()) if state_path.exists() else {}
        if 'up' in args:
            files = [args[i + 1] for i, arg in enumerate(args) if arg == '-f']
            override = pathlib.Path(files[-1]).read_text() if len(files) > 1 else ''
            binding = '127.0.0.1:3053' if '127.0.0.1:3053' in override else '192.0.2.10:3053'
            state.update(running=True, binding=binding)
            if not state.get('configured') and binding != '127.0.0.1:3053':
                state['exposed_wizard'] = True
        if 'stop' in args or 'down' in args: state['running'] = False
        state_path.write_text(json.dumps(state))
        if 'up' in args and scenario.get('up_fail'): sys.exit(1)
    if scenario.get('compose_fail'): sys.exit(1)
elif name == 'curl':
    if any('/control/install/' in a for a in args):
        state_path = root / 'adguard.json'
        state = json.loads(state_path.read_text())
        if any('/configure' in a for a in args):
            payload = json.load(sys.stdin)
            (root / 'install.json').write_text(json.dumps(payload))
            if scenario.get('post_fail'): sys.exit(1)
            state['configured'] = True
            state_path.write_text(json.dumps(state))
            (root / 'adguard/conf').mkdir(exist_ok=True)
            (root / 'adguard/conf/AdGuardHome.yaml').write_text('users:\n  - name: admin\n    password: test-hash\n')
        elif scenario.get('wizard_unready'): sys.exit(1)
    if scenario.get('ready_fail'): sys.exit(1)
elif name == 'ufw':
    if args == ['status']:
        print('Status: inactive' if scenario.get('ufw_inactive') else 'Status: active')
        if scenario.get('ufw_existing_allow'): print('3053/tcp ALLOW 192.0.2.0/24')
    if scenario.get('ufw_fail'): sys.exit(1)
elif name == 'dig':
    print('192.0.2.20')
elif name == 'sleep':
    pass
elif name == 'timedatectl':
    if scenario.get('timezone_fail'): sys.exit(1)
    print('Etc/UTC')
elif name == 'sed':
    if args[0] == '-i':
        import re
        path = pathlib.Path(args[-1])
        if path.exists() and root in path.resolve().parents:
            _, pattern, replacement, _ = args[1].split(args[1][1])
            path.write_text(re.sub(pattern, replacement, path.read_text(), flags=re.M))
    else:
        sys.stdout.write(sys.stdin.read().rstrip('.\n'))
elif name == 'pre-serve':
    if scenario.get('pre_fail'): sys.exit(1)
'''


class ProvisioningSafety(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=os.environ.get('TMPDIR'))
        self.addCleanup(self.tmp.cleanup)
        self.fixture = Path(self.tmp.name)
        self.bin = self.fixture / 'bin'
        self.bin.mkdir()
        for name in ('sudo', 'uname', 'tailscale', 'docker', 'curl', 'pre-serve', 'ufw', 'dig', 'sleep',
                     'timedatectl', 'systemctl', 'loginctl', 'sed', 'hostname'):
            path = self.bin / name
            path.write_text(STUB)
            path.chmod(0o755)
        self.env = {**os.environ, 'PATH': f'{self.bin}:{os.environ["PATH"]}',
                    'FIXTURE': str(self.fixture), 'HOME': str(self.fixture / 'home')}
        self.host = self.fixture / 'host'
        self.host.mkdir()
        (self.fixture / 'serve.json').write_text(json.dumps({
            'TCP': {'443': {'HTTPS': True}, '3443': {'HTTPS': True}},
            'Web': {'host.example.ts.net:443': {'Handlers': {'/dragonwilds': {'Proxy': 'http://127.0.0.1:8080'}}},
                    'host.example.ts.net:3443': {'Handlers': {'/': {'Proxy': 'http://127.0.0.1:8081'}}}}}))
        (self.host / 'serve.conf').write_text('''COMPOSE_DIRS=(app)
PRE_SERVE=(pre-serve)
WAIT_URL=http://127.0.0.1:3000
RETIRED_PORTS=(3443)
RETIRED_PATHS=("443 /dragonwilds")
ROUTES=("443 / http://127.0.0.1:3000")
''')

    def run_serve(self, **scenario):
        self.env['SCENARIO'] = json.dumps(scenario)
        return subprocess.run(['bash', str(ROOT / 'server-base/serve.sh'), str(self.host)],
                              env=self.env, text=True, capture_output=True, timeout=15)

    def calls(self):
        path = self.fixture / 'calls.jsonl'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def test_retirement_precedes_fallible_startup(self):
        result = self.run_serve(compose_fail=True)
        self.assertNotEqual(result.returncode, 0)
        state = json.loads((self.fixture / 'serve.json').read_text())
        self.assertNotIn('/dragonwilds', state['Web']['host.example.ts.net:443']['Handlers'])
        self.assertNotIn('3443', state['TCP'])
        calls = self.calls()
        status = next(i for i, c in enumerate(calls) if c[:3] == ['tailscale', 'serve', 'status'])
        pre = next(i for i, c in enumerate(calls) if c[0] == 'pre-serve')
        self.assertLess(status, pre)

    def test_failed_removal_blocks_setup(self):
        with (self.host / 'serve.conf').open('a') as f:
            f.write('RETIRED_PATHS=()\n')
        result = self.run_serve(off_fail=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.fixture / 'published').exists())
        self.assertFalse(any(c[0] == 'pre-serve' for c in self.calls()))

    def test_final_status_failure_after_removal_blocks_setup(self):
        result = self.run_serve(status_fail_at=3)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(c[0] == 'pre-serve' for c in self.calls()))
        self.assertFalse((self.fixture / 'published').exists())

    def test_pre_serve_failure_occurs_only_after_retirement(self):
        result = self.run_serve(pre_fail=True)
        self.assertNotEqual(result.returncode, 0)
        state = json.loads((self.fixture / 'serve.json').read_text())
        self.assertNotIn('/dragonwilds', state['Web']['host.example.ts.net:443']['Handlers'])
        self.assertNotIn('3443', state['TCP'])

    def test_artwork_setup_failure_occurs_only_after_retirement(self):
        (self.host / 'homepage').mkdir()
        (self.host / 'homepage/assets').write_text('blocks directory creation')
        result = self.run_serve()
        self.assertNotEqual(result.returncode, 0)
        state = json.loads((self.fixture / 'serve.json').read_text())
        self.assertNotIn('/dragonwilds', state['Web']['host.example.ts.net:443']['Handlers'])
        self.assertNotIn('3443', state['TCP'])
        self.assertFalse((self.fixture / 'published').exists())

    def test_readiness_failure_occurs_only_after_retirement(self):
        result = self.run_serve(ready_fail=True)
        self.assertNotEqual(result.returncode, 0)
        state = json.loads((self.fixture / 'serve.json').read_text())
        self.assertNotIn('/dragonwilds', state['Web']['host.example.ts.net:443']['Handlers'])
        self.assertNotIn('3443', state['TCP'])

    def test_unreadable_status_blocks_setup(self):
        result = self.run_serve(status_fail=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.fixture / 'published').exists())
        self.assertFalse(any(c[0] == 'pre-serve' for c in self.calls()))

    def test_retired_path_in_large_status_blocks_setup(self):
        with (self.host / 'serve.conf').open('a') as f:
            f.write('RETIRED_PORTS=()\n')
        result = self.run_serve(keep_retired=True, status_padding=1024 * 1024)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.fixture / 'published').exists())

    def test_retired_port_still_published_blocks_setup(self):
        with (self.host / 'serve.conf').open('a') as f:
            f.write('RETIRED_PATHS=()\n')
        result = self.run_serve(keep_retired=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.fixture / 'published').exists())

    def test_foreground_retired_path_blocks_setup(self):
        state = json.loads((self.fixture / 'serve.json').read_text())
        state['Foreground'] = {'fixture-session': {'Web': state['Web']}}
        (self.fixture / 'serve.json').write_text(json.dumps(state))
        result = self.run_serve()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.fixture / 'published').exists())

    def test_malformed_successful_status_blocks_setup(self):
        result = self.run_serve(status_malformed=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(c[0] == 'pre-serve' for c in self.calls()))

    def test_serve_rerun_skips_only_verified_absent_retirements(self):
        first = self.run_serve()
        self.assertEqual(first.returncode, 0, first.stderr)
        before = len(self.calls())
        second = self.run_serve()
        self.assertEqual(second.returncode, 0, second.stderr)
        second_calls = self.calls()[before:]
        self.assertTrue(any(c[:3] == ['tailscale', 'serve', 'status'] for c in second_calls))
        self.assertFalse(any(c[0] == 'tailscale' and c[-1] == 'off' for c in second_calls))

    def run_adguard(self, **scenario):
        if os.geteuid() == 0:
            self.skipTest('AdGuard setup intentionally requires a non-root login user')
        adguard = self.fixture / 'adguard'
        if not adguard.exists():
            adguard.mkdir()
            for name in ('setup.sh', 'docker-compose.yml'):
                shutil.copy2(ROOT / 'linux-game-server/adguard' / name, adguard / name)
            (adguard / '.env').write_text('LAN_IP=192.0.2.10\nLAN_CIDR=192.0.2.0/24\nADGUARD_USER=admin\nADGUARD_PASSWORD=fixture-password\n')
        self.env['SCENARIO'] = json.dumps(scenario)
        return subprocess.run(['bash', str(adguard / 'setup.sh')], env=self.env,
                              text=True, capture_output=True, timeout=15)

    def test_adguard_wizard_is_loopback_with_inactive_firewall(self):
        result = self.run_adguard(ufw_inactive=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        state = json.loads((self.fixture / 'adguard.json').read_text())
        self.assertFalse(state.get('exposed_wizard', False))
        self.assertTrue(state['configured'])
        self.assertTrue(state['running'])
        self.assertEqual(state['binding'], '192.0.2.10:3053')
        payload = json.loads((self.fixture / 'install.json').read_text())
        self.assertEqual(payload['web']['ip'], '192.0.2.10')
        self.assertEqual(payload['dns']['ip'], '192.0.2.10')

    def test_adguard_failed_post_stops_only_fresh_wizard(self):
        result = self.run_adguard(post_fail=True)
        self.assertNotEqual(result.returncode, 0)
        state = json.loads((self.fixture / 'adguard.json').read_text())
        self.assertFalse(state['running'])
        self.assertFalse(state.get('exposed_wizard', False))
        self.assertFalse(any(c[0] == 'ufw' for c in self.calls()))

    def test_adguard_unready_wizard_is_stopped_without_post(self):
        result = self.run_adguard(wizard_unready=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.fixture / 'install.json').exists())
        self.assertFalse(json.loads((self.fixture / 'adguard.json').read_text())['running'])

    def test_adguard_retry_after_failed_post_with_old_allow_rule_is_isolated(self):
        first = self.run_adguard(post_fail=True)
        self.assertNotEqual(first.returncode, 0)
        second = self.run_adguard(ufw_inactive=True, ufw_existing_allow=True)
        self.assertEqual(second.returncode, 0, second.stderr)
        state = json.loads((self.fixture / 'adguard.json').read_text())
        self.assertFalse(state.get('exposed_wizard', False))
        self.assertTrue(state['configured'])
        self.assertTrue(state['running'])
        self.assertEqual(state['binding'], '192.0.2.10:3053')

    def test_adguard_configured_rerun_error_does_not_stop_service(self):
        first = self.run_adguard()
        self.assertEqual(first.returncode, 0, first.stderr)
        original = (self.fixture / 'adguard/conf/AdGuardHome.yaml').read_bytes()
        before = len(self.calls())
        second = self.run_adguard(ufw_fail=True)
        self.assertNotEqual(second.returncode, 0)
        calls = self.calls()[before:]
        self.assertFalse(any(c[0] == 'docker' and ('stop' in c or 'down' in c) for c in calls))
        self.assertFalse(any('/control/install/' in ' '.join(c) for c in calls))
        self.assertEqual((self.fixture / 'adguard/conf/AdGuardHome.yaml').read_bytes(), original)
        self.assertTrue(json.loads((self.fixture / 'adguard.json').read_text())['running'])

    def test_adguard_partial_start_failure_stops_loopback_wizard(self):
        result = self.run_adguard(up_fail=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(json.loads((self.fixture / 'adguard.json').read_text())['running'])
        self.assertFalse((self.fixture / 'install.json').exists())

    def test_adguard_dry_run_never_starts_wizard_or_writes_config(self):
        self.run_adguard()
        shutil.rmtree(self.fixture / 'adguard/conf')
        (self.fixture / 'calls.jsonl').unlink()
        result = subprocess.run(['bash', str(self.fixture / 'adguard/setup.sh'), '--dry-run'],
                                env=self.env, text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('127.0.0.1:3053', result.stdout)
        self.assertFalse((self.fixture / 'adguard/conf').exists())
        self.assertFalse(any(c[0] in ('sudo', 'docker', 'curl', 'ufw', 'dig') for c in self.calls()))

    def run_root_bootstrap(self, **scenario):
        checkout = self.fixture / 'checkout'
        checkout.mkdir()
        tracked = subprocess.check_output(['git', 'ls-files', '-z', '--', 'setup.sh', 'packages.json',
                                           'lib', 'platforms', 'linux-server', 'server-base'], cwd=ROOT)
        for relative in tracked.decode().split('\0'):
            if not relative:
                continue
            src, dst = ROOT / relative, checkout / relative
            dst.parent.mkdir(parents=True, exist_ok=True)
            if src.is_symlink():
                dst.symlink_to(os.readlink(src))
            else:
                shutil.copy2(src, dst)
        self.assertFalse((checkout / 'server-base/timezone.env').exists())
        self.env.update(SCENARIO=json.dumps({'require_timezone': True, **scenario}),
                        SETUP_ROOT=str(checkout), LOCALTIME_PATH=str(self.fixture / 'no-localtime'))
        Path(self.env['HOME']).mkdir()
        # Skip unrelated package/user installation, but retain the real root
        # platform_main -> linux_main -> server_extras call chain and run().
        skipped = ('core_prime_sudo', 'platform_bootstrap', 'platform_install_tier', 'linux_nvm_flow',
                   'platform_tailscale_step', 'claude_code_step', 'opencode_step', 'rust_toolchain_step',
                   'set_default_shell', 'deploy_dotfiles', 'server_preclone_antidote',
                   'platform_docker_optional', 'server_docker_daemon_step', 'server_ups_step',
                   'custom_reminders_section', 'server_footer')
        command = 'set -euo pipefail\nsource "$SETUP_ROOT/lib/core.sh"\ncore_parse_args --profile server\ncore_detect_platform\nsource "$SETUP_ROOT/platforms/server.sh"\n'
        command += '\n'.join(f'{name}() {{ :; }}' for name in skipped)
        command += '\nplatform_main\n'
        return subprocess.run(['bash', '-c', command], env=self.env, text=True,
                              capture_output=True, timeout=30)

    def test_root_bootstrap_generates_timezone_before_first_compose_in_clean_checkout(self):
        result = self.run_root_bootstrap()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.fixture / 'compose_before_timezone').exists(), result.stdout)
        self.assertTrue((self.fixture / 'compose_after_timezone').exists())
        self.assertEqual((self.fixture / 'checkout/server-base/timezone.env').read_text(), 'TZ=Etc/UTC\n')

    def test_timezone_documentation_matches_project_convergence(self):
        readme = (ROOT / 'server-base/README.md').read_text()
        section = readme.split('## Time zone\n', 1)[1].split('\n## ', 1)[0]
        self.assertNotIn('up -d --no-deps', section)
        self.assertIn('every running service', section)
        self.assertIn('dependencies', section)
        self.assertIn('interrupt', section)

    def test_root_timezone_failure_aborts_before_any_compose(self):
        result = self.run_root_bootstrap(timezone_fail=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.fixture / 'compose_before_timezone').exists())
        self.assertFalse((self.fixture / 'compose_after_timezone').exists())


if __name__ == '__main__':
    unittest.main()
