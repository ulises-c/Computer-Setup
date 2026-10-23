"""Lost City / RS-SDK status producer: read-only data access and card summaries."""
import importlib.util
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('game_status', ROOT / '2004scape' / 'game_status.py')
game_status = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(game_status)


def make_db(path, journal='delete'):
    connection = sqlite3.connect(path)
    connection.execute(f'PRAGMA journal_mode={journal}')
    connection.executescript('''
        CREATE TABLE account (id INTEGER PRIMARY KEY, username TEXT);
        CREATE TABLE account_login (account_id INTEGER, profile TEXT, logged_in INTEGER,
                                    login_time TEXT, logged_out INTEGER, logout_time TEXT);
        INSERT INTO account (username) VALUES ('a'), ('b'), ('c');
        INSERT INTO account_login VALUES (1, 'main', 10, '2026-10-21 09:00:00', 0, NULL);
        INSERT INTO account_login VALUES (2, 'main', 0, '2026-10-21 08:00:00', 10, '2026-10-21 09:30:00');
    ''')
    connection.commit()
    return connection


class DatabaseTests(unittest.TestCase):
    def test_counts_accounts_online_and_latest_activity_without_sidecars(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'db.sqlite'
            make_db(path).close()
            before = sorted(p.name for p in Path(tmp).iterdir())
            self.assertEqual(game_status.database(path),
                             {'accounts': 3, 'online': 1, 'last_seen': '2026-10-21T09:30:00Z'})
            self.assertEqual(sorted(p.name for p in Path(tmp).iterdir()), before,
                             'a read-only status read must not create journal/WAL files')

    def test_reads_a_live_wal_database(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'db.sqlite'
            writer = make_db(path, 'wal')
            try:
                self.assertEqual(game_status.database(path)['accounts'], 3)
            finally:
                writer.close()

    def test_missing_or_foreign_database_is_unknown_not_zero(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertIsNone(game_status.database(Path(tmp) / 'absent.sqlite'))
            other = Path(tmp) / 'other.sqlite'
            sqlite3.connect(other).close()
            other.write_bytes(b'not a database')
            self.assertIsNone(game_status.database(other))


class ParsingTests(unittest.TestCase):
    def test_docker_nanosecond_utc_timestamps(self):
        self.assertEqual(game_status.iso_epoch('2026-10-21T08:11:02.015649867Z'), 1792570262)
        self.assertIsNone(game_status.iso_epoch('0001-01-01T00:00:00Z'))
        self.assertIsNone(game_status.iso_epoch('2026-10-21T08:11:02+02:00'))

    def test_env_values_are_parsed_not_executed(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = Path(tmp) / '.env'
            env.write_text('# comment\nA=/srv/game\nB="quoted value"\nC=$(touch pwned)\nbroken\nD=x # trailing\n')
            values = game_status.read_env(env)
            self.assertEqual(values['A'], '/srv/game')
            self.assertEqual(values['B'], 'quoted value')
            self.assertEqual(values['C'], '$(touchpwned)')
            self.assertEqual(values['D'], 'x')
            self.assertFalse((Path(tmp) / 'pwned').exists())

    def test_lan_address_comes_from_the_default_route_device(self):
        outputs = {
            ('ip', '-4', 'route', 'show', 'default'): 'default via 192.0.2.1 dev eth9 proto dhcp',
            ('ip', '-4', '-o', 'addr', 'show', 'dev', 'eth9', 'scope', 'global'):
                '2: eth9    inet 192.0.2.10/24 brd 192.0.2.255 scope global eth9',
        }
        with mock.patch.object(game_status, 'run', side_effect=lambda cmd, timeout=5: outputs.get(tuple(cmd))):
            self.assertEqual(game_status.lan_ip(), '192.0.2.10')
        with mock.patch.object(game_status, 'run', return_value=None):
            self.assertEqual(game_status.lan_ip(), '')


class MaintenanceTests(unittest.TestCase):
    def test_uninstalled_timer_says_so_and_keeps_failure_markers_visible(self):
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / 'rs-sdk.failed').write_text('abc\n')
            with mock.patch.object(game_status, 'systemd', return_value='inactive'):
                summary, upcoming = game_status.maintenance({}, 'rs-sdk', Path(tmp))
            self.assertEqual(summary, 'timer not installed · last update failed')
            self.assertEqual(upcoming, '')

    def test_next_window_is_the_countdown_before_the_backup_on_the_maintenance_day(self):
        # 2026-10-21 is a Wednesday; the next Monday backup at 10:00 UTC is 2026-10-26.
        backup = 1792576800  # 2026-10-21T10:00:00Z
        with tempfile.TemporaryDirectory() as tmp, \
                mock.patch.object(game_status, 'systemd', side_effect=lambda unit, prop: 'active'), \
                mock.patch.object(game_status, 'run', return_value=str(backup)), \
                mock.patch.dict('os.environ', {'TZ': 'UTC'}):
            game_status.time.tzset()
            try:
                summary, upcoming = game_status.maintenance(
                    {'MAINTENANCE_DAY': 'Mon', 'AUTO_UPDATE': 'false', 'COUNTDOWN_MINUTES': '10'},
                    'lostcity', Path(tmp))
            finally:
                game_status.time.tzset()
        self.assertEqual(summary, 'weekly Mon · auto-update off')
        self.assertEqual(upcoming, '2026-10-26T09:48:00Z')


class RsSdkTests(unittest.TestCase):
    def test_bot_gateway_rules_and_live_player_count(self):
        info = {'Id': 'f' * 64, 'RestartCount': 0,
                'State': {'Status': 'running', 'StartedAt': '2026-10-21T08:00:00.1Z',
                          'Health': {'Status': 'healthy'}},
                'Config': {'Env': ['NODE_XPRATE=1', 'NODE_TICKRATE=600', 'NODE_MEMBERS=true',
                                   'NODE_RANDOM_EVENTS=true', 'NODE_INFINITE_RUN=false',
                                   'GATEWAY_PUBLIC_PORT=7781', 'WEB_PORT=8080']}}
        responses = {
            'http://127.0.0.1:8080/playercount': {'count': 2},
            'http://127.0.0.1:8080/status': {'bots': {'a': {'status': 'active'}, 'b': {'status': 'stale'}},
                                             'sdks': {'x': {}}},
            'http://127.0.0.1:8080/api/market/status': {'enabled': True},
        }
        with tempfile.TemporaryDirectory() as tmp, \
                mock.patch.object(game_status, 'inspect', return_value=info), \
                mock.patch.object(game_status, 'http_json', side_effect=responses.get), \
                mock.patch.object(game_status, 'listening', return_value=True), \
                mock.patch.object(game_status, 'lan_ip', return_value='192.0.2.10'), \
                mock.patch.object(game_status, 'run', return_value=None), \
                mock.patch.object(game_status, 'resources', return_value={}), \
                mock.patch.object(game_status, 'BACKUP_STATUS', Path(tmp) / 'absent.json'):
            make_db(Path(tmp) / 'db.sqlite').close()
            result = game_status.rs_sdk(tmp, tmp, Path(tmp) / 'h.json', 'boot', ('weekly Mon', ''))
        self.assertEqual(result['status'], 'running · healthy')
        self.assertEqual(result['players_summary'],
                         '2 online · 3 accounts · 2 bots (1 active, 1 stale) · 1 SDK client')
        self.assertEqual(result['rules_summary'],
                         'members · 1× XP · 600 ms ticks · random events · normal run energy')
        self.assertEqual(result['connect_lan'], 'http://192.0.2.10:8080 · ws://192.0.2.10:7781 (listening) · GE on')
        self.assertEqual(result['backup_status'], 'unknown')
        json.dumps(result, allow_nan=False)

    def test_stopped_engine_is_not_queried(self):
        info = {'Id': 'f' * 64, 'RestartCount': 1, 'State': {'Status': 'exited'}, 'Config': {'Env': []}}
        with tempfile.TemporaryDirectory() as tmp, \
                mock.patch.object(game_status, 'inspect', return_value=info), \
                mock.patch.object(game_status, 'http_json', side_effect=AssertionError('queried')), \
                mock.patch.object(game_status, 'listening', return_value=False), \
                mock.patch.object(game_status, 'lan_ip', return_value=''), \
                mock.patch.object(game_status, 'run', return_value=None), \
                mock.patch.object(game_status, 'resources', return_value={}):
            result = game_status.rs_sdk(tmp, tmp, Path(tmp) / 'h.json', 'boot', ('', ''))
        self.assertEqual(result['status'], 'exited')
        self.assertEqual(result['uptime_display'], '—')
        self.assertEqual(result['players_summary'], '? online · accounts unknown')


class DeploymentTests(unittest.TestCase):
    def test_status_nginx_is_loopback_only_and_started_by_serve(self):
        compose = (ROOT / '2004scape' / 'docker-compose.yml').read_text()
        self.assertIn('"127.0.0.1:8097:80"', compose)
        self.assertIn('./status:/usr/share/nginx/html:ro', compose)
        self.assertIn('2004scape)', (ROOT / 'serve.conf').read_text())
        self.assertIn('2004scape/status', (ROOT / 'scaffold.py').read_text())

    def test_timer_runs_the_producer_unprivileged(self):
        unit = (ROOT / '2004scape' / '2004scape-status.service.template').read_text()
        self.assertIn('User=@USER@', unit)
        self.assertIn('ExecStart=/usr/bin/env python3 @STATUS_SCRIPT@', unit)
        self.assertIn('OnUnitActiveSec=15s', (ROOT / '2004scape' / '2004scape-status.timer').read_text())


if __name__ == '__main__':
    unittest.main()
