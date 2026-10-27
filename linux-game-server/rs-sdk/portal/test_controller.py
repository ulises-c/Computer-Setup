import io
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import time
import unittest
from urllib.error import HTTPError
from urllib.request import Request, urlopen

import controller
import live

OWNER = 'owner@example.com'
ORIGIN = 'https://portal.example'
THIEVING_DANGER = ('Suicide pickpocketing at Lumbridge castle with NO food: the account dies again and again and relies on death recovery '
                   'to pick its drop back up. Anything not recovered within ~2 min is lost for good. Bank your valuables first.')
PIONEER_NOTE = 'pioneer-fish.ts refuses runs over 1 h: bot_pioneer is the R&D account and only does short supervised runs.'
# Mirror of 2004Scape-Botting routines/registry.json (trimmed descriptions).
REGISTRY = {
    'version': 1, 'excludedBots': ['bot_tester'],
    'routines': [
        {'id': 'mining', 'label': 'Mining', 'runner': 'session', 'routine': 'mining', 'safeStart': True, 'denyBots': ['bot_pioneer'], 'allowPlayers': True,
         'args': [{'name': 'spot', 'label': 'Spot', 'type': 'enum', 'values': ['tin-barbarian-village', 'coal-barbarian-village'], 'default': 'tin-barbarian-village'},
                  {'name': 'seconds', 'label': 'Duration', 'type': 'int', 'unit': 'seconds', 'min': 60, 'max': 604800, 'default': 600}],
         'spotLimit': {'arg': 'spot', 'limits': {'tin-barbarian-village': 2}}},
        {'id': 'chickens', 'label': 'Chickens 24/7', 'runner': 'chickens-247', 'denyBots': ['bot_pioneer'],
         'args': [{'name': 'pen', 'type': 'enum', 'values': ['lumbridge-east'], 'default': 'lumbridge-east'},
                  {'name': 'policy', 'type': 'enum', 'values': ['str-atk', 'str-atk-def'], 'default': 'str-atk'}]},
        {'id': 'pioneer-fish', 'label': 'Pioneer', 'runner': 'pioneer', 'allowBots': ['bot_pioneer'], 'fixedArgs': ['fish-bank'],
         'args': [{'name': 'seconds', 'type': 'int', 'unit': 'seconds', 'min': 60, 'max': 3600, 'default': 120, 'maxNote': PIONEER_NOTE}]},
        {'id': 'onboard', 'label': 'Onboard', 'runner': 'onboard', 'enabled': False, 'denyBots': ['bot_pioneer'], 'args': []},
        {'id': 'scavenge', 'label': 'Scavenger 24/7', 'runner': 'scavenge-247', 'allowBots': ['bot_magpie'], 'denyBots': ['bot_pioneer'],
         'args': [{'name': 'pen', 'type': 'enum', 'values': ['lumbridge-east'], 'default': 'lumbridge-east'}]},
        {'id': 'thieving', 'label': 'Thieving (suicide, Lumbridge)', 'runner': 'session', 'routine': 'thieving', 'denyBots': ['bot_pioneer'], 'allowPlayers': True,
         'danger': THIEVING_DANGER, 'args': [{'name': 'seconds', 'label': 'Duration', 'type': 'int', 'unit': 'seconds', 'min': 60, 'max': 604800, 'default': 600}]},
    ],
}
ACCOUNTS = ['bot_pioneer', 'bot_tester', 'bot_wormlike', 'bot_apehood']
PLAYER = 'player_cantpvm'
FLEET_PASSWORD = 'Fleet-Secret-77'


def status_doc(**extra):
    doc = {'version': 1, 'updatedAt': 5, 'registry': REGISTRY, 'fleet': {'pause': False},
           'daemon': {'pid': 42, 'host': 'bot-workstation', 'startedAt': 1, 'intervalMs': 5000, 'dryRun': False, 'portalOk': True, 'commit': 'abc1234', 'error': None},
           'bots': {'bot_wormlike': {'state': 'running', 'message': 'mining running', 'rev': 3, 'action': 'run',
                                     'job': {'kind': 'run', 'routine': 'mining', 'args': ['tin-barbarian-village', '120'], 'pid': 9, 'startedAt': 2, 'stopping': False},
                                     'gates': [], 'foreign': [], 'lastResult': None, 'updatedAt': 5}}}
    doc.update(extra)
    return doc


class RegistryTests(unittest.TestCase):
    def test_registry_parses_and_rejects_unsafe_entries(self):
        reg = controller.parse_registry(REGISTRY)
        self.assertEqual([r['id'] for r in reg['routines']], ['mining', 'chickens', 'pioneer-fish', 'onboard', 'scavenge', 'thieving'])
        self.assertEqual([r['id'] for r in reg['routines'] if r['allowPlayers']], ['mining', 'thieving'])
        self.assertEqual([(r['id'], r['danger']) for r in reg['routines'] if r['danger']], [('thieving', THIEVING_DANGER)])
        self.assertIsNone(reg['routines'][0]['danger'])
        self.assertFalse(reg['routines'][3]['enabled'])

        def bad(mutate):
            raw = json.loads(json.dumps(REGISTRY))
            mutate(raw)
            with self.assertRaises(ValueError):
                controller.parse_registry(raw)
        bad(lambda r: r.update(excludedBots=[]))
        bad(lambda r: r['routines'][0]['args'][0]['values'].append('--evil'))
        bad(lambda r: r['routines'][0]['args'][0]['values'].append('a b'))
        bad(lambda r: r['routines'][0].update(runner='shell'))
        bad(lambda r: r['routines'][0].update(routine='mining;id'))
        bad(lambda r: r['routines'][0].update(denyBots=[]))
        bad(lambda r: r['routines'][2].update(allowBots=['bot_wormlike']))
        bad(lambda r: r['routines'][0]['args'][1].update(min=10, max=5))
        bad(lambda r: r['routines'][0]['args'][1].update(default=5))
        bad(lambda r: r['routines'][1].update(id='mining'))
        # allowPlayers: explicit boolean, session routines only, never with a fleet allowlist.
        bad(lambda r: r['routines'][1].update(allowPlayers=True))
        bad(lambda r: r['routines'][4].update(allowPlayers=True))
        bad(lambda r: r['routines'][0].update(allowPlayers='yes'))
        # danger: non-empty printable text up to 400 characters.
        for value in ('', '   ', 'x' * 401, 'line\nbreak', 5, ['x']):
            bad(lambda r, value=value: r['routines'][0].update(danger=value))

    @unittest.skipUnless(Path.home().joinpath('forgejo/2004Scape-Botting/routines/registry.json').exists(), 'bot repo not on this machine')
    def test_the_bot_repo_registry_is_accepted(self):
        raw = json.loads(Path.home().joinpath('forgejo/2004Scape-Botting/routines/registry.json').read_text())
        reg = controller.parse_registry(raw)
        self.assertIn('mining', [r['id'] for r in reg['routines']])
        # Any runner the daemon's registry uses must be one the portal accepts (else registryError drops it all).
        self.assertTrue({r['runner'] for r in raw['routines']} <= set(controller.RUNNERS))
        thieving = next((r for r in reg['routines'] if r['id'] == 'thieving'), None)
        if thieving is not None:
            self.assertTrue(thieving['allowPlayers'])
            self.assertIn('Bank your valuables', thieving['danger'])

    def test_run_validation(self):
        reg = controller.parse_registry(REGISTRY)
        self.assertEqual(controller.validate_run(reg, 'bot_wormlike', 'mining', {'spot': 'tin-barbarian-village', 'seconds': 120}),
                         {'spot': 'tin-barbarian-village', 'seconds': 120})
        self.assertEqual(controller.validate_run(reg, 'bot_wormlike', 'mining', {}), {'spot': 'tin-barbarian-village', 'seconds': 600})
        self.assertEqual(controller.validate_run(reg, 'bot_pioneer', 'pioneer-fish', {'seconds': 300}), {'seconds': 300})
        for bot, routine, args, reason in [
            ('bot_tester', 'mining', {}, 'not launchable'), ('bot_pioneer', 'mining', {}, 'not allowed'),
            ('bot_wormlike', 'pioneer-fish', {}, 'only for bot_pioneer'), ('bot_wormlike', 'onboard', {}, 'disabled'),
            ('bot_wormlike', 'eval', {}, 'unknown routine'), ('bot_wormlike', 'mining', {'spot': 'iron-se-varrock'}, 'spot'),
            ('bot_wormlike', 'mining', {'seconds': 59}, 'seconds'), ('bot_wormlike', 'mining', {'seconds': '120'}, 'seconds'),
            ('bot_wormlike', 'mining', {'seconds': True}, 'seconds'), ('bot_wormlike', 'mining', {'seconds': 1.5}, 'seconds'),
            ('bot_wormlike', 'mining', {'cmd': 'rm'}, 'unknown args'), ('bot_wormlike', 'mining', ['x'], 'object'),
            ('Bot Wormlike', 'mining', {}, 'bad bot'),
        ]:
            with self.assertRaises(ValueError) as caught:
                controller.validate_run(reg, bot, routine, args)
            self.assertIn(reason, str(caught.exception), (bot, routine, args))

    def test_regular_accounts_and_modes(self):
        reg = controller.parse_registry(REGISTRY)
        self.assertEqual(controller.account_type('bot_wormlike'), 'bot')
        self.assertEqual(controller.account_type(PLAYER), 'player')
        for bad in ('player_', 'player_Cant', 'Cant Pvm', 'player_cant pvm', 'player_abcdefghijklm'):
            self.assertIsNone(controller.account_type(bad), bad)
        self.assertEqual(controller.validate_run(reg, PLAYER, 'mining', {}, 'browser'), {'spot': 'tin-barbarian-village', 'seconds': 600})
        for bot, routine, mode, reason in [
            (PLAYER, 'chickens', 'headless', 'fleet routine'), (PLAYER, 'scavenge', 'headless', 'fleet routine'),
            ('bot_wormlike', 'chickens', 'browser', 'browser view'), ('bot_wormlike', 'mining', 'popup', 'mode'),
        ]:
            with self.assertRaises(ValueError) as caught:
                controller.validate_run(reg, bot, routine, {}, mode)
            self.assertIn(reason, str(caught.exception), (bot, routine, mode))


class StatusTests(unittest.TestCase):
    def test_status_is_allowlisted_and_a_bad_registry_is_dropped(self):
        raw = status_doc()
        raw['password'] = 'hunter2'
        raw['bots']['bot_wormlike']['secret'] = 'hunter2'
        raw['bots']['bot_wormlike']['state'] = 'pwned'
        raw['bots']['bot_wormlike']['job']['args'].append('$(id)')
        raw['bots']['bad name'] = {'state': 'running'}
        shaped = controller.shape_status(raw, 123)
        self.assertNotIn('hunter2', json.dumps(shaped))
        self.assertEqual(list(shaped['bots']), ['bot_wormlike'])
        self.assertEqual(shaped['bots']['bot_wormlike']['state'], 'unknown')
        self.assertEqual(shaped['bots']['bot_wormlike']['job']['args'], ['tin-barbarian-village', '120'])
        self.assertEqual(shaped['receivedAt'], 123)
        self.assertEqual(shaped['registry'], controller.parse_registry(REGISTRY))
        # The shaped registry survives a second shaping (the portal re-reads the stored file).
        self.assertEqual(controller.parse_registry(shaped['registry']), shaped['registry'])
        broken = controller.shape_status(status_doc(registry={'version': 1, 'excludedBots': [], 'routines': []}), 1)
        self.assertIsNone(broken['registry'])
        self.assertIn('bot_tester', broken['registryError'])
        with self.assertRaises(ValueError):
            controller.shape_status({'version': 2}, 1)

    def test_status_carries_account_types_sanitized_logs_and_never_a_password(self):
        raw = status_doc()
        raw['bots']['bot_wormlike'].update(type='player', presence='present', client='headless', log=[
            'start: mining', 'GET /state/bot_wormlike?password=hunter2&x=1', 'PASSWORD=s3cret', 'Authorization: Bearer tok.en.value',
            '{"token":"abc999"}', 'x' * 500, 7, 'esc \x1b[31mred'] + ['line'] * 60)
        raw['bots'][PLAYER] = {'type': 'player', 'displayName': 'Cant Pvm', 'presence': 'present', 'client': 'frame', 'state': 'running', 'mode': 'browser',
                               'job': {'kind': 'run', 'routine': 'mining', 'args': [], 'mode': 'browser', 'pid': 7, 'startedAt': 1}}
        raw['bots']['player_evil'] = {'displayName': 'Evil<script>', 'state': 'idle'}
        raw['frames'] = {'bot_wormlike': FLEET_PASSWORD}
        shaped = controller.shape_status(raw, 1)
        text = json.dumps(shaped)
        for secret in (FLEET_PASSWORD, 'hunter2', 's3cret', 'tok.en.value', 'abc999'):
            self.assertNotIn(secret, text)
        self.assertNotIn('frames', shaped)
        worm, player = shaped['bots']['bot_wormlike'], shaped['bots'][PLAYER]
        self.assertEqual((worm['type'], worm['presence'], worm['client']), ('bot', 'present', 'headless'))  # type comes from the name
        self.assertLessEqual(len(worm['log']), 40)
        self.assertTrue(all(isinstance(l, str) and len(l) <= 200 and '\x1b' not in l for l in worm['log']))
        self.assertEqual((player['type'], player['displayName'], player['client'], player['mode'], player['job']['mode']), ('player', 'Cant Pvm', 'frame', 'browser', 'browser'))
        self.assertIsNone(shaped['bots']['player_evil']['displayName'])

    def test_sanitize_log_redacts_credentials(self):
        lines = controller.sanitize_log(['password=hunter2', 'my_PASSWORD=x1y2', 'url?password=p%40ss&b=1', "'secret': 'zzz'", 'Bearer abc.def', 'ok line'])
        self.assertEqual(lines[-1], 'ok line')
        for secret in ('hunter2', 'x1y2', 'p%40ss', 'zzz', 'abc.def'):
            self.assertNotIn(secret, ' '.join(lines))

    def test_exchange_stores_status_and_answers_desired(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        desired_dir, status_dir = Path(tmp.name) / 'controller', Path(tmp.name) / 'live'
        out = io.StringIO()
        controller.exchange(io.BytesIO(json.dumps(status_doc()).encode()), out, desired_dir, status_dir, clock=lambda: 1000)
        self.assertEqual(json.loads(out.getvalue()), controller.empty_desired())
        stored = json.loads((status_dir / 'controller-status.json').read_text())
        self.assertEqual(stored['receivedAt'], 1_000_000)
        desired_dir.mkdir()
        (desired_dir / 'desired.json').write_text(json.dumps({'version': 1, 'seq': 4, 'updatedAt': 9, 'bots': {
            'bot_wormlike': {'action': 'stop', 'rev': 4, 'at': 9, 'by': OWNER}, 'bot_x;y': {'action': 'stop', 'rev': 1, 'at': 1}}}))
        out = io.StringIO()
        controller.exchange(io.BytesIO(b'not json\n'), out, desired_dir, status_dir)
        self.assertEqual(list(json.loads(out.getvalue())['bots']), ['bot_wormlike'])
        # A rejected status line leaves the previous report in place.
        self.assertEqual(json.loads((status_dir / 'controller-status.json').read_text())['receivedAt'], 1_000_000)

    def test_exchange_keeps_frame_logins_out_of_the_status(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        desired_dir, status_dir = Path(tmp.name) / 'controller', Path(tmp.name) / 'live'
        doc = status_doc(frames={'bot_wormlike': FLEET_PASSWORD, 'player_cantpvm': 'never', 'bot_x;y': 'bad', 'bot_apehood': 'x' * 65})
        controller.exchange(io.BytesIO(json.dumps(doc).encode()), io.StringIO(), desired_dir, status_dir, clock=lambda: 1000)
        self.assertNotIn(FLEET_PASSWORD, (status_dir / 'controller-status.json').read_text())
        frames = status_dir / 'controller-frames.json'
        self.assertEqual(frames.stat().st_mode & 0o777, 0o600)
        self.assertEqual(controller.read_frames(frames), {'bot_wormlike': FLEET_PASSWORD})
        # The next report without frames clears them.
        controller.exchange(io.BytesIO(json.dumps(status_doc()).encode()), io.StringIO(), desired_dir, status_dir, clock=lambda: 1001)
        self.assertEqual(controller.read_frames(frames), {})
        self.assertEqual(controller.read_frames(Path(tmp.name) / 'missing.json'), {})

    def test_status_carries_an_allowlisted_maintenance_banner(self):
        raw = status_doc(maintenance={'active': True, 'hold': True, 'phase': 'down', 'reason': 'weekly restart window (Mon 02:55 America/Los_Angeles): server down',
                                      'since': 1793008500000, 'resumeAt': None, 'lastResumeAt': None, 'staggerMs': 120000, 'reachable': False,
                                      'nextWeekly': 1793613300000, 'tz': 'America/Los_Angeles', 'extra': 'dropped', 'phaseX': 1})
        shaped = controller.shape_status(raw, 7)
        self.assertEqual(shaped['maintenance'], {'active': True, 'hold': True, 'phase': 'down',
                                                 'reason': 'weekly restart window (Mon 02:55 America/Los_Angeles): server down',
                                                 'since': 1793008500000, 'resumeAt': None, 'lastResumeAt': None, 'staggerMs': 120000,
                                                 'reachable': False, 'nextWeekly': 1793613300000, 'tz': 'America/Los_Angeles'})
        bad = controller.shape_status(status_doc(maintenance={'active': 'yes', 'phase': 'rm -rf', 'reason': 5, 'since': -1, 'reachable': 'no'}), 7)['maintenance']
        self.assertEqual((bad['active'], bad['phase'], bad['reason'], bad['since'], bad['reachable']), (False, None, None, None, None))
        self.assertIsNone(controller.shape_status(status_doc(), 7)['maintenance'])
        self.assertIsNone(controller.shape_status(status_doc(maintenance='x'), 7)['maintenance'])

    @unittest.skipUnless(shutil.which('node'), 'node not installed')
    def test_maintenance_banner_text_in_bot_controller_js(self):
        script = Path(__file__).with_name('bot_controller.js')
        probe = """
const L = require(process.argv[1]);
const t = Date.UTC(2026, 9, 26, 9, 58, 0);   // 02:58 PDT
console.log(JSON.stringify([
  L.maintenanceBanner(null, t),
  L.maintenanceBanner({active: false, hold: false}, t),
  L.maintenanceBanner({active: true, hold: true, phase: 'settling', reason: 'weekly restart window: server back, settling until 03:02:49', since: Date.UTC(2026, 9, 26, 9, 55), resumeAt: Date.UTC(2026, 9, 26, 10, 2, 49), staggerMs: 120000, tz: 'America/Los_Angeles'}, t),
  L.maintenanceBanner({active: false, hold: false, lastResumeAt: Date.UTC(2026, 9, 26, 10, 2, 49), staggerMs: 120000, tz: 'America/Los_Angeles'}, Date.UTC(2026, 9, 26, 10, 3, 30)),
  L.maintenanceBanner({active: false, hold: false, lastResumeAt: Date.UTC(2026, 9, 26, 10, 2, 49), staggerMs: 120000, tz: 'America/Los_Angeles'}, Date.UTC(2026, 9, 26, 10, 9)),
]));
"""
        result = subprocess.run(['node', '-e', probe, str(script)], capture_output=True, text=True, timeout=20, check=True)
        got = json.loads(result.stdout)
        self.assertEqual(got[0], None)
        self.assertEqual(got[1], None)
        self.assertIn('Server maintenance: weekly restart window: server back, settling until 03:02:49', got[2])
        self.assertIn('since 02:55:00 (America/Los_Angeles)', got[2])
        self.assertIn('logins resume from 03:02:49, staggered over 120 s', got[2])
        self.assertEqual(got[3], 'Server maintenance over: staggered relogs until 03:04:49 (America/Los_Angeles)')
        self.assertEqual(got[4], None)

    def test_reservation_is_allowlisted(self):
        good = {'holder': 'hermes:host-a:session-1', 'label': 'trip agent', 'host': 'host-a', 'purpose': 'thieving trip',
                'since': '2026-10-27T03:07:20.886Z', 'expires': '2026-11-03T03:07:20.886Z', 'auto': None, 'pid': 5, 'password': 'x'}
        raw = status_doc()
        raw['bots']['bot_wormlike']['reservation'] = good
        raw['bots']['bot_wormlike']['state'] = 'reserved'
        shaped = controller.shape_status(raw, 7)['bots']['bot_wormlike']
        self.assertEqual(shaped['state'], 'reserved')
        self.assertEqual(shaped['reservation'], {'holder': 'hermes:host-a:session-1', 'label': 'trip agent', 'host': 'host-a',
                                                 'purpose': 'thieving trip', 'since': '2026-10-27T03:07:20.886Z',
                                                 'expires': '2026-11-03T03:07:20.886Z', 'auto': None})
        for bad in ('x', {'holder': 'bad holder <script>', 'since': good['since'], 'expires': good['expires']},
                    {'holder': 'a:b', 'since': 'yesterday', 'expires': good['expires']}):
            self.assertIsNone(controller.shape_reservation(bad))
        self.assertEqual(controller.shape_reservation({**good, 'auto': 'rm -rf'})['auto'], None)
        self.assertIsNone(controller.shape_status(status_doc(), 7)['bots']['bot_wormlike']['reservation'])

    @unittest.skipUnless(shutil.which('node'), 'node not installed')
    def test_reservation_text_in_bot_controller_js(self):
        script = Path(__file__).with_name('bot_controller.js')
        probe = """
const L = require(process.argv[1]);
const now = Date.UTC(2026, 9, 27, 3, 7, 0);
console.log(JSON.stringify([
  L.reservationText(null, now),
  L.reservationText({holder: 'runner:host-a:skill', host: 'host-a', purpose: '24/7 skill runner', since: '2026-10-27T03:00:00.000Z', expires: '2026-10-27T05:07:00.000Z'}, now),
  L.reservationText({holder: 'a:b', label: 'trip', host: 'h', purpose: 'p', since: '2026-10-27T03:00:00.000Z', expires: '2026-10-27T03:37:00.000Z', auto: 'run-bot'}, now),
  L.tone('reserved'),
]));
"""
        result = subprocess.run(['node', '-e', probe, str(script)], capture_output=True, text=True, timeout=20, check=True)
        got = json.loads(result.stdout)
        self.assertIsNone(got[0])
        self.assertEqual(got[1], 'Reserved by runner:host-a:skill on host-a: 24/7 skill runner · since 2026-10-27 03:00Z · 2h left')
        self.assertEqual(got[2], 'Reserved by a:b (trip) on h: p · since 2026-10-27 03:00Z · 30m left · auto-claim (run-bot)')
        self.assertEqual(got[3], 'warn')

    def test_view_passes_the_maintenance_banner_through(self):
        status = controller.shape_status(status_doc(maintenance={'active': True, 'hold': True, 'phase': 'window', 'reason': 'manual: test'}), 7)
        status.update({'available': True, 'ageMs': 0, 'online': True, 'error': None})
        page = controller.view(ACCOUNTS, {'bots': []}, status, {'bots': {}}, {'canWrite': False})
        self.assertEqual(page['maintenance']['reason'], 'manual: test')
        self.assertIsNone(controller.view(ACCOUNTS, {'bots': []}, controller.read_status(None), {'bots': {}}, {'canWrite': False})['maintenance'])

    def test_read_status_reports_heartbeat(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        path = Path(tmp.name) / 'controller-status.json'
        self.assertFalse(controller.read_status(path)['available'])
        controller.write_atomic(path, controller.shape_status(status_doc(), 1_000_000))
        fresh = controller.read_status(path, now_ms=1_010_000)
        self.assertTrue(fresh['online'])
        stale = controller.read_status(path, now_ms=1_000_000 + controller.HEARTBEAT_STALE_MS + 1)
        self.assertFalse(stale['online'])
        self.assertIn('No controller heartbeat', stale['error'])


class Headers(dict):
    def get(self, key, default=None):
        for k, v in self.items():
            if k.lower() == key.lower():
                return v
        return default


class AuthTests(unittest.TestCase):
    def setUp(self):
        self.auth = controller.Auth(OWNER, ORIGIN, secret=b'k' * 32)
        self.good = Headers({'Tailscale-User-Login': OWNER, 'Origin': ORIGIN, 'Sec-Fetch-Site': 'same-origin',
                             'Content-Type': 'application/json', 'X-CSRF-Token': self.auth.token(OWNER)})

    def test_only_the_owner_with_origin_json_and_csrf_may_write(self):
        self.assertIsNone(self.auth.check_write(self.good))
        self.assertIsNone(self.auth.check_write(Headers(self.good, **{'Tailscale-User-Login': 'Owner@Example.com'})))
        cases = {
            'no identity': Headers({k: v for k, v in self.good.items() if k != 'Tailscale-User-Login'}),
            'other user': Headers(self.good, **{'Tailscale-User-Login': 'mallory@example.com'}),
            'other origin': Headers(self.good, Origin='https://evil.example'),
            'no origin': Headers({k: v for k, v in self.good.items() if k != 'Origin'}),
            'cross-site': Headers(self.good, **{'Sec-Fetch-Site': 'cross-site'}),
            'form post': Headers(self.good, **{'Content-Type': 'application/x-www-form-urlencoded'}),
            'bad token': Headers(self.good, **{'X-CSRF-Token': 'x' * 64}),
            'token for another login': Headers(self.good, **{'X-CSRF-Token': self.auth.token('mallory@example.com')}),
        }
        for name, headers in cases.items():
            self.assertIsNotNone(self.auth.check_write(headers), name)
        self.assertIn('no owner', controller.Auth('', ORIGIN).check_write(self.good))
        self.assertEqual(self.auth.can_write(Headers({'Tailscale-User-Login': 'mallory@example.com'}))[0], False)


class StoreTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.dir = Path(tmp.name)
        self.store = controller.Store(self.dir, clock=lambda: 1000)
        self.reg = controller.parse_registry(REGISTRY)

    def apply(self, request):
        return self.store.apply(request, self.reg, ACCOUNTS, OWNER)

    def test_valid_requests_are_recorded_with_increasing_revisions_and_audited(self):
        status, body = self.apply({'action': 'run', 'bots': ['bot_wormlike'], 'routine': 'mining', 'args': {'seconds': 120}})
        self.assertEqual(status, 200, body)
        entry = self.store.read()['bots']['bot_wormlike']
        self.assertEqual(entry, {'action': 'run', 'rev': 1, 'at': 1_000_000, 'by': OWNER, 'routine': 'mining',
                                 'args': {'spot': 'tin-barbarian-village', 'seconds': 120}, 'mode': 'headless'})
        self.assertEqual(self.apply({'action': 'stop', 'bots': ['bot_wormlike', 'bot_apehood']})[0], 200)
        bots = self.store.read()['bots']
        self.assertEqual((bots['bot_wormlike']['rev'], bots['bot_apehood']['rev']), (2, 3))
        self.assertEqual(self.apply({'action': 'clear', 'bots': ['bot_apehood']})[0], 200)
        self.assertNotIn('bot_apehood', self.store.read()['bots'])
        audit = [json.loads(line) for line in (self.dir / 'audit.jsonl').read_text().splitlines()]
        self.assertEqual([a['action'] for a in audit], ['run', 'stop', 'clear'])
        self.assertTrue(all(a['by'] == OWNER for a in audit))

    def test_invalid_requests_change_nothing(self):
        for request in [
            {'action': 'run', 'bots': ['bot_wormlike', 'bot_tester'], 'routine': 'mining', 'args': {}},
            {'action': 'run', 'bots': ['bot_pioneer'], 'routine': 'mining', 'args': {}},
            {'action': 'run', 'bots': ['bot_wormlike'], 'routine': 'mining', 'args': {'seconds': 10}},
            {'action': 'run', 'bots': ['bot_wormlike'], 'routine': 'mining', 'args': {'command': 'rm -rf /'}},
            {'action': 'run', 'bots': ['bot_unknown'], 'routine': 'mining', 'args': {}},
            {'action': 'stop', 'bots': ['bot_tester']},
            {'action': 'exec', 'bots': ['bot_wormlike']},
            {'action': 'stop', 'bots': []}, {'action': 'stop', 'bots': ['bot_wormlike', 'bot_wormlike']},
            {'action': 'stop', 'bots': 'bot_wormlike'}, ['stop'],
            {'action': 'run', 'bots': ['bot_wormlike', 'bot_apehood'], 'routine': 'mining', 'args': {}, 'mode': 'browser'},
            {'action': 'run', 'bots': ['bot_wormlike'], 'routine': 'mining', 'args': {}, 'mode': 'popup'},
            {'action': 'run', 'bots': [PLAYER], 'routine': 'chickens', 'args': {}},
        ]:
            status, _ = self.apply(request)
            self.assertEqual(status, 400, request)
        self.assertFalse((self.dir / 'desired.json').exists())
        self.assertEqual(self.store.apply({'action': 'stop', 'bots': ['bot_wormlike']}, None, ACCOUNTS, OWNER)[0], 409)
        self.assertEqual(controller.Store(None).apply({'action': 'stop', 'bots': ['bot_wormlike']}, self.reg, ACCOUNTS, OWNER)[0], 503)

    def test_regular_accounts_and_browser_view_requests(self):
        status, body = self.store.apply({'action': 'run', 'bots': [PLAYER], 'routine': 'mining', 'args': {}, 'mode': 'browser'}, self.reg, ACCOUNTS + [PLAYER], OWNER)
        self.assertEqual(status, 200, body)
        self.assertEqual(self.store.read()['bots'][PLAYER]['mode'], 'browser')
        # A player id the daemon never reported is not a known account.
        self.assertEqual(self.apply({'action': 'stop', 'bots': ['player_nobody']})[0], 400)

    def test_dangerous_routines_need_the_explicit_confirmation(self):
        request = {'action': 'run', 'bots': [PLAYER], 'routine': 'thieving', 'args': {'seconds': 600}}
        for extra in ({}, {'confirmDanger': False}, {'confirmDanger': 'yes'}, {'confirmDanger': 1}):
            status, body = self.store.apply({**request, **extra}, self.reg, ACCOUNTS + [PLAYER], OWNER)
            self.assertEqual(status, 400, extra)
            self.assertIn('dangerous', body['error'])
            self.assertIn('Bank your valuables', body['error'])
        self.assertFalse((self.dir / 'desired.json').exists())
        status, body = self.store.apply({**request, 'confirmDanger': True}, self.reg, ACCOUNTS + [PLAYER], OWNER)
        self.assertEqual(status, 200, body)
        self.assertEqual(self.store.read()['bots'][PLAYER]['routine'], 'thieving')
        audit = [json.loads(line) for line in (self.dir / 'audit.jsonl').read_text().splitlines()]
        self.assertTrue(audit[-1]['confirmedDanger'])
        # Routines without a danger note need no confirmation; stop never does.
        self.assertEqual(self.apply({'action': 'run', 'bots': ['bot_wormlike'], 'routine': 'mining', 'args': {}})[0], 200)
        self.assertEqual(self.apply({'action': 'stop', 'bots': ['bot_wormlike']})[0], 200)

    def test_rate_limit(self):
        for _ in range(30):
            self.assertEqual(self.apply({'action': 'hold', 'bots': ['bot_wormlike']})[0], 200)
        self.assertEqual(self.apply({'action': 'hold', 'bots': ['bot_wormlike']})[0], 429)

    def test_view_merges_accounts_live_status_and_desired(self):
        self.apply({'action': 'stop', 'bots': ['bot_apehood']})
        status = controller.shape_status(status_doc(), int(time.time() * 1000))
        status.update(online=True, ageMs=0, error=None)
        live_payload = {'available': True, 'stale': False, 'bots': [
            {'username': 'bot_wormlike', 'presence': 'controlled', 'activity': {'label': 'mining: mining tin', 'status': {'state': 'running', 'phase': 'mining tin', 'routine': 'mining'}}}]}
        view = controller.view(ACCOUNTS, live_payload, status, self.store.read(), {'canWrite': False})
        rows = {r['username']: r for r in view['bots']}
        self.assertEqual(sorted(rows), sorted(ACCOUNTS))
        self.assertEqual(rows['bot_wormlike']['eligible'], ['mining', 'chickens', 'thieving'])
        self.assertEqual(rows['bot_pioneer']['eligible'], ['pioneer-fish'])
        self.assertEqual((rows['bot_tester']['launchable'], rows['bot_tester']['eligible']), (False, []))
        self.assertEqual(rows['bot_wormlike']['phase'], 'mining tin')
        self.assertEqual(rows['bot_wormlike']['controller']['state'], 'running')
        self.assertEqual(rows['bot_apehood']['desired']['action'], 'stop')
        self.assertEqual({r['type'] for r in view['bots']}, {'bot'})

    def test_view_lists_regular_accounts_with_type_and_frame_offers(self):
        self.apply({'action': 'run', 'bots': ['bot_wormlike'], 'routine': 'mining', 'args': {}, 'mode': 'browser'})
        raw = status_doc()
        raw['bots'][PLAYER] = {'type': 'player', 'displayName': 'Cant Pvm', 'presence': 'absent', 'state': 'idle'}
        raw['bots']['bot_apehood'] = {'state': 'running', 'client': 'headless'}
        status = controller.shape_status(raw, int(time.time() * 1000))
        status.update(online=True, ageMs=0, error=None)
        view = controller.view(ACCOUNTS, {'available': False, 'bots': []}, status, self.store.read(), {'canWrite': True})
        rows = {r['username']: r for r in view['bots']}
        self.assertEqual((rows[PLAYER]['type'], rows[PLAYER]['displayName'], rows[PLAYER]['presence']), ('player', 'Cant Pvm', 'offline'))
        self.assertEqual(rows[PLAYER]['eligible'], ['mining', 'thieving'])
        self.assertEqual(rows['bot_wormlike']['type'], 'bot')
        self.assertTrue(rows[PLAYER]['frame']['offered'])
        self.assertFalse(rows[PLAYER]['frame']['login'])
        self.assertTrue(rows['bot_wormlike']['frame']['offered'])          # browser-view run requested
        self.assertTrue(rows['bot_wormlike']['frame']['login'])
        self.assertFalse(rows['bot_apehood']['frame']['offered'])          # headless client running
        self.assertIn('headless', rows['bot_apehood']['frame']['reason'])
        self.assertFalse(rows['bot_tester']['frame']['offered'])
        self.assertNotIn('password', json.dumps(view).lower())


class ControllerHTTPTests(unittest.TestCase):
    def setUp(self):
        import server
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        (root / 'live').mkdir()
        (root / 'controller').mkdir()
        live.write_atomic(root / 'live', live.shape_snapshot({'version': 1, 'bots': [{'username': 'bot_wormlike', 'status': 'active'}]}, received_at=1))
        raw = status_doc()
        raw['bots'][PLAYER] = {'type': 'player', 'displayName': 'Cant Pvm', 'presence': 'absent', 'state': 'idle'}
        raw['bots']['bot_apehood'] = {'state': 'running', 'client': 'headless'}
        controller.write_atomic(root / 'live' / 'controller-status.json', controller.shape_status(raw, int(time.time() * 1000)))
        controller.write_atomic(root / 'live' / 'controller-frames.json', {'bot_wormlike': FLEET_PASSWORD, 'bot_apehood': FLEET_PASSWORD})
        http = server.PortalHTTPServer(('127.0.0.1', 0), server.Handler)
        self.addCleanup(http.server_close)
        http.portal = server.Portal(Path('/nonexistent'), 'https://game.example', 'https://home.example', live_path=root / 'live' / 'live.json',
                                    controller_dir=root / 'controller', owner_login=OWNER, public_origin=ORIGIN)
        self.game = 'https://game.example'
        http.portal.live_accounts = lambda: ACCOUNTS
        threading.Thread(target=http.serve_forever, daemon=True).start()
        self.addCleanup(http.shutdown)
        self.base = f'http://127.0.0.1:{http.server_port}'
        self.root = root

    def get(self, path, headers=None):
        with urlopen(Request(self.base + path, headers=headers or {}), timeout=5) as response:
            return response.status, dict(response.headers), response.read()

    def post(self, body, headers, path='/rs-sdk/api/controller/desired'):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        try:
            with urlopen(Request(self.base + path, data=data, headers=headers, method='POST'), timeout=5) as response:
                return response.status, json.loads(response.read())
        except HTTPError as error:
            with error:
                return error.code, json.loads(error.read() or b'{}')

    def test_page_api_and_writes(self):
        status, headers, body = self.get('/rs-sdk/bot-controller/')
        self.assertEqual(status, 200)
        self.assertIn("script-src 'self'", headers['Content-Security-Policy'])
        self.assertIn("connect-src 'self'", headers['Content-Security-Policy'])
        self.assertIn(b'src="/rs-sdk/bot-controller.js"', body)
        self.assertIn(b'data-refresh-ms="3000"', body)   # its own poll, not the live map's per-tick default
        self.assertNotIn(b'<script>', body)
        _, headers, _ = self.get('/rs-sdk/bot-controller.js')
        self.assertIn('text/javascript', headers['Content-Type'])
        # Anonymous (tagged device / no identity): readable, no token, writes refused.
        _, _, body = self.get('/rs-sdk/api/controller')
        view = json.loads(body)
        self.assertFalse(view['auth']['canWrite'])
        self.assertIsNone(view['auth']['csrf'])
        self.assertTrue(view['online'])
        self.assertEqual({r['username'] for r in view['bots']}, set(ACCOUNTS) | {PLAYER})
        request = {'action': 'run', 'bots': ['bot_wormlike'], 'routine': 'mining', 'args': {'seconds': 120}}
        self.assertEqual(self.post(request, {'Content-Type': 'application/json', 'Origin': ORIGIN})[0], 403)
        # The owner gets a token and may write from the portal's origin.
        _, _, body = self.get('/rs-sdk/api/controller', {'Tailscale-User-Login': OWNER})
        token = json.loads(body)['auth']['csrf']
        self.assertTrue(token)
        owner = {'Tailscale-User-Login': OWNER, 'Origin': ORIGIN, 'Content-Type': 'application/json', 'X-CSRF-Token': token}
        self.assertEqual(self.post(request, dict(owner, Origin='https://evil.example'))[0], 403)
        self.assertEqual(self.post(request, dict(owner, **{'X-CSRF-Token': 'nope'}))[0], 403)
        self.assertEqual(self.post(request, dict(owner, **{'Tailscale-User-Login': 'mallory@example.com'}))[0], 403)
        status, body = self.post(request, owner)
        self.assertEqual(status, 200, body)
        self.assertEqual(json.loads((self.root / 'controller' / 'desired.json').read_text())['bots']['bot_wormlike']['args'], {'spot': 'tin-barbarian-village', 'seconds': 120})
        status, body = self.post({'action': 'run', 'bots': ['bot_tester'], 'routine': 'mining', 'args': {}}, owner)
        self.assertEqual(status, 400)
        self.assertIn('bot_tester', body['bots'])
        self.assertEqual(self.post(b'x' * (controller.MAX_BODY + 1), owner)[0], 413)
        self.assertEqual(self.post(b'{not json', owner)[0], 400)
        _, _, body = self.get('/rs-sdk/api/controller')
        row = next(r for r in json.loads(body)['bots'] if r['username'] == 'bot_wormlike')
        self.assertEqual((row['desired']['action'], row['desired']['routine']), ('run', 'mining'))
        with self.assertRaises(HTTPError) as caught:
            urlopen(Request(self.base + '/rs-sdk/api/live', data=b'{}', method='POST'), timeout=5)
        self.assertEqual(caught.exception.code, 501)
        caught.exception.close()
        # Other pages keep the script-free CSP.
        _, headers, _ = self.get('/rs-sdk/')
        self.assertNotIn('script-src', headers['Content-Security-Policy'])
        self.assertNotIn('frame-src', headers['Content-Security-Policy'])

    def test_page_frames_only_the_game_client_and_has_the_account_filter(self):
        status, headers, body = self.get('/rs-sdk/bot-controller/?show=regular')
        csp = headers['Content-Security-Policy']
        self.assertIn('frame-src https://game.example', csp)
        self.assertIn("frame-ancestors 'none'", csp)
        for value, label in (('all', b'All'), ('bots', b'Bots'), ('regular', b'Regular')):
            self.assertIn(f'data-show="{value}"'.encode(), body)
            self.assertIn(label, body)
        self.assertIn(b'data-show-initial="regular"', body)
        _, _, body = self.get('/rs-sdk/bot-controller/?show=evil')
        self.assertIn(b'data-show-initial=""', body)

    def test_public_status_lists_both_account_types_without_passwords(self):
        for headers in ({}, {'Tailscale-User-Login': OWNER}):
            _, _, body = self.get('/rs-sdk/api/controller', headers)
            self.assertNotIn(FLEET_PASSWORD.encode(), body)
            self.assertNotIn(b'password', body.lower())
            rows = {r['username']: r for r in json.loads(body)['bots']}
            self.assertEqual(rows[PLAYER]['type'], 'player')
            self.assertEqual(rows['bot_wormlike']['type'], 'bot')

    def test_frame_url_is_owner_only_and_never_offered_beside_a_headless_client(self):
        _, _, body = self.get('/rs-sdk/api/controller', {'Tailscale-User-Login': OWNER})
        token = json.loads(body)['auth']['csrf']
        owner = {'Tailscale-User-Login': OWNER, 'Origin': ORIGIN, 'Sec-Fetch-Site': 'same-origin', 'Content-Type': 'application/json', 'X-CSRF-Token': token}
        frame = lambda account, headers: self.post({'account': account}, headers, '/rs-sdk/api/controller/frame')
        # Refusals: no identity (tagged device), another user, forged origin, cross-site, missing/forged CSRF, form post.
        for name, headers in {
            'anonymous': {'Content-Type': 'application/json', 'Origin': ORIGIN},
            'other user': dict(owner, **{'Tailscale-User-Login': 'mallory@example.com'}),
            'forged origin': dict(owner, Origin='https://evil.example'),
            'cross-site': dict(owner, **{'Sec-Fetch-Site': 'cross-site'}),
            'no csrf': {k: v for k, v in owner.items() if k != 'X-CSRF-Token'},
            'bad csrf': dict(owner, **{'X-CSRF-Token': 'f' * 64}),
            'form post': dict(owner, **{'Content-Type': 'text/plain'}),
        }.items():
            status, out = frame('bot_wormlike', headers)
            self.assertEqual(status, 403, name)
            self.assertNotIn(FLEET_PASSWORD, json.dumps(out), name)
        # Regular account: the client's login screen, no password, the stored in-game name verbatim.
        status, out = frame(PLAYER, owner)
        self.assertEqual(status, 200, out)
        self.assertEqual(out['url'], self.game + '/bot?bot=Cant%20Pvm')
        # Fleet bot: only with a browser-view run requested; then the login is filled in.
        status, out = frame('bot_wormlike', owner)
        self.assertEqual(status, 409, out)
        self.assertNotIn(FLEET_PASSWORD, json.dumps(out))
        self.assertEqual(self.post({'action': 'run', 'bots': ['bot_wormlike'], 'routine': 'mining', 'args': {}, 'mode': 'browser'}, owner)[0], 200)
        status, out = frame('bot_wormlike', owner)
        self.assertEqual(status, 200, out)
        self.assertEqual(out['url'], self.game + '/bot?bot=bot_wormlike&password=' + FLEET_PASSWORD)
        # Never next to a headless client, never for unknown or excluded accounts, never logged in the audit.
        self.assertEqual(self.post({'action': 'run', 'bots': ['bot_apehood'], 'routine': 'mining', 'args': {}, 'mode': 'browser'}, owner)[0], 200)
        self.assertEqual(frame('bot_apehood', owner)[0], 409)
        self.assertEqual(frame('bot_tester', owner)[0], 400)
        self.assertEqual(frame('player_nobody', owner)[0], 400)
        self.assertEqual(self.post(b'{"account": 5}', owner, '/rs-sdk/api/controller/frame')[0], 400)
        audit = (self.root / 'controller' / 'audit.jsonl').read_text()
        self.assertIn('"frame"', audit)
        self.assertNotIn(FLEET_PASSWORD, audit)


class DurationTests(unittest.TestCase):
    """Duration args (unit seconds): at most 7 days, wire value whole seconds; mirror of bot-controller.ts."""

    def mutated(self, mutate):
        raw = json.loads(json.dumps(REGISTRY))
        mutate(raw)
        return raw

    def test_unit_and_max_note_are_validated_and_carried(self):
        self.assertEqual(controller.MAX_DURATION_S, 604800)
        reg = controller.parse_registry(REGISTRY)
        mining = next(r for r in reg['routines'] if r['id'] == 'mining')
        self.assertEqual((mining['args'][1]['unit'], mining['args'][1]['max']), ('seconds', 604800))
        self.assertNotIn('unit', mining['args'][0])
        pioneer = next(r for r in reg['routines'] if r['id'] == 'pioneer-fish')
        self.assertEqual(pioneer['args'][0]['maxNote'], PIONEER_NOTE)
        bad = [
            (lambda r: r['routines'][0]['args'][1].update(max=604801), '7 days'),
            (lambda r: r['routines'][0]['args'][1].update(unit='minutes'), 'unit'),
            (lambda r: r['routines'][0]['args'][0].update(unit='seconds'), 'only on int'),
            (lambda r: r['routines'][0]['args'][1].update(maxNote='why'), 'maxNote'),              # max is already 7 days
            (lambda r: r['routines'][2]['args'][0].update(maxNote=''), 'maxNote'),
            (lambda r: r['routines'][2]['args'][0].pop('unit'), 'maxNote'),                    # a note needs the unit
            (lambda r: r['routines'][2]['args'][0].update(maxNote='x' * 201), 'maxNote'),
        ]
        for mutate, why in bad:
            with self.assertRaisesRegex(ValueError, why):
                controller.parse_registry(self.mutated(mutate))
        # Without the unit an int keeps the generic cap.
        plain = self.mutated(lambda r: (r['routines'][0]['args'][1].pop('unit'), r['routines'][0]['args'][1].update(max=700000)))
        self.assertEqual(controller.parse_registry(plain)['routines'][0]['args'][1]['max'], 700000)

    def test_run_requests_accept_up_to_seven_days(self):
        reg = controller.parse_registry(REGISTRY)
        self.assertEqual(controller.validate_run(reg, PLAYER, 'thieving', {'seconds': 604800}), {'seconds': 604800})
        self.assertEqual(controller.validate_run(reg, 'bot_wormlike', 'mining', {'seconds': 90061}), {'spot': 'tin-barbarian-village', 'seconds': 90061})
        for args in ({'seconds': 604801}, {'seconds': 59}, {'seconds': '604800'}, {'seconds': 6.5}):
            with self.assertRaisesRegex(ValueError, 'seconds: integer 60..604800'):
                controller.validate_run(reg, PLAYER, 'thieving', args)
        with self.assertRaisesRegex(ValueError, 'seconds: integer 60..3600'):
            controller.validate_run(reg, 'bot_pioneer', 'pioneer-fish', {'seconds': 3601})

    @unittest.skipUnless(shutil.which('node'), 'node not installed')
    def test_duration_logic_in_bot_controller_js(self):
        script = Path(__file__).with_name('bot_controller.js')
        probe = """
const L = require(process.argv[1]);
const reg = JSON.parse(process.argv[2]);
const thieving = L.routineById(reg, 'thieving');
const sec = thieving.args[0];
const pioneer = L.routineById(reg, 'pioneer-fish').args[0];
const out = {
  max: L.MAX_DURATION_S,
  parts: L.DURATION_PARTS.map(p => [p[0], p[1], p[3]]),
  isDur: [L.isDuration(sec), L.isDuration(L.routineById(reg, 'mining').args[0]), L.isDuration({type: 'int', name: 'seconds'}), L.isDuration(null)],
  split: [L.splitDuration(0), L.splitDuration(95400), L.splitDuration(604800), L.splitDuration(691200)],
  text: [L.durationText(0), L.durationText(600), L.durationText(95400), L.durationText(604800), L.durationText(3661)],
  total: [L.durationTotal({days: '1', hours: '2', minutes: '30', seconds: ''}), L.durationTotal({minutes: '90'}), L.durationTotal({}),
          L.durationTotal({hours: '-1'}), L.durationTotal({minutes: '1.5'}), L.durationTotal({days: '1e3'})],
  carry: L.splitDuration(L.durationTotal({minutes: '90', seconds: '75'})),
  checks: [L.checkDuration(sec, {minutes: '10'}), L.checkDuration(sec, {seconds: '30'}), L.checkDuration(sec, {days: '7', seconds: '1'}),
           L.checkDuration(sec, {days: '7'}), L.checkDuration(sec, {hours: 'x'}), L.checkDuration(pioneer, {hours: '2'})],
  range: [L.durationRange(sec), L.durationRange(pioneer)],
  valid: [L.validateArgs(thieving, {seconds: '604800'}), L.validateArgs(thieving, {seconds: '604801'}), L.validateArgs(thieving, {seconds: ''}),
          L.validateArgs(thieving, {seconds: '30'})],
  defaults: L.defaults(thieving),
  desired: [L.desiredText({action: 'run', routine: 'thieving', args: {seconds: 6000}, rev: 2}, reg),
            L.desiredText({action: 'run', routine: 'mining', args: {spot: 'tin-barbarian-village', seconds: 95400}, rev: 3}, reg),
            L.desiredText({action: 'run', routine: 'thieving', args: {seconds: 6000}, rev: 2})],
};
console.log(JSON.stringify(out));
"""
        result = subprocess.run(['node', '-e', probe, str(script), json.dumps(controller.parse_registry(REGISTRY))],
                                capture_output=True, text=True, timeout=20, check=True)
        got = json.loads(result.stdout)
        self.assertEqual(got['max'], 604800)
        self.assertEqual(got['parts'], [['days', 'Days', 7], ['hours', 'Hours', 23], ['minutes', 'Minutes', 59], ['seconds', 'Seconds', 59]])
        self.assertEqual(got['isDur'], [True, False, False, False])
        self.assertEqual(got['split'], [{'days': 0, 'hours': 0, 'minutes': 0, 'seconds': 0}, {'days': 1, 'hours': 2, 'minutes': 30, 'seconds': 0},
                                        {'days': 7, 'hours': 0, 'minutes': 0, 'seconds': 0}, {'days': 8, 'hours': 0, 'minutes': 0, 'seconds': 0}])
        self.assertEqual(got['text'], ['0 s', '10 min', '1 d 2 h 30 min', '7 d', '1 h 1 min 1 s'])
        self.assertEqual(got['total'], [95400, 5400, 0, None, None, None])
        self.assertEqual(got['carry'], {'days': 0, 'hours': 1, 'minutes': 31, 'seconds': 15})   # 90 min 75 s carries
        ok, low, high, full, junk, pio = got['checks']
        self.assertEqual(ok, {'total': 600, 'text': '= 10 min', 'error': None})
        self.assertEqual((low['total'], low['error']), (30, 'at least 1 min'))
        self.assertEqual((high['total'], high['error']), (604801, 'at most 7 d (7 days)'))
        self.assertIsNone(full['error'])
        self.assertEqual((junk['total'], junk['error']), (None, 'whole numbers only (0 or more) in each box'))
        self.assertEqual(pio['error'], 'at most 1 h')
        self.assertEqual(got['range'], ['1 min to 7 d', '1 min to 1 h'])
        self.assertEqual(got['valid'][0], {'ok': True, 'args': {'seconds': 604800}, 'errors': {}})
        self.assertEqual(got['valid'][1]['errors'], {'seconds': 'at most 7 d (7 days)'})
        self.assertFalse(got['valid'][2]['ok'])
        self.assertEqual(got['valid'][3]['errors'], {'seconds': 'at least 1 min'})
        self.assertEqual(got['defaults'], {'seconds': 600})
        self.assertEqual(got['desired'], ['Run thieving 1 h 40 min · r2', 'Run mining tin-barbarian-village 1 d 2 h 30 min · r3', 'Run thieving 6000 · r2'])


class ControllerJSTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('node'), 'node not installed')
    def test_view_logic_in_bot_controller_js(self):
        script = Path(__file__).with_name('bot_controller.js')
        probe = """
const L = require(process.argv[1]);
const reg = JSON.parse(process.argv[2]);
const mining = L.routineById(reg, 'mining');
const out = {
  defaults: L.defaults(mining),
  ok: L.validateArgs(mining, {spot: 'tin-barbarian-village', seconds: '120'}),
  bad: L.validateArgs(mining, {spot: 'nope', seconds: '12x'}),
  low: L.validateArgs(mining, {spot: 'tin-barbarian-village', seconds: '59'}),
  none: L.validateArgs(null, {}),
  common: L.commonEligible([{eligible: ['mining', 'chickens']}, {eligible: ['chickens']}]),
  commonEmpty: L.commonEligible([]),
  tones: ['running', 'blocked', 'failed', 'whatever'].map(L.tone),
  desired: [L.desiredText(null), L.desiredText({action: 'run', routine: 'mining', args: {spot: 'tin-barbarian-village', seconds: 120}, rev: 3}), L.desiredText({action: 'stop', rev: 4})],
  offline: L.heartbeat({daemon: {host: 'bot-workstation'}, online: false, ageMs: 90000}),
  online: L.heartbeat({daemon: {host: 'bot-workstation', commit: 'abc', portalOk: true}, online: true, ageMs: 2000}),
  visible: [L.visible({presence: 'offline'}, 'all'), L.visible({presence: 'offline'}, 'all', true), L.visible({presence: 'ghost'}, 'all', true), L.visible({presence: 'offline', desired: {}}, 'all', true)],
  byType: [['all', 'bots', 'regular'].map(s => L.visible({type: 'bot'}, s)), ['all', 'bots', 'regular'].map(s => L.visible({type: 'player'}, s))],
  shows: [L.initialShow('?show=regular', 'bots'), L.initialShow('?show=nope', 'bots'), L.initialShow('', 'junk'), L.withShow('?a=1', 'bots')],
  frameLines: L.frameNote({type: 'player', displayName: 'Cant Pvm'}),
  modes: [L.modesFor({runner: 'session'}, 1), L.modesFor({runner: 'session'}, 2), L.modesFor({runner: 'chickens-247'}, 1)],
  logShown: [L.showLog({controller: {log: ['a']}}), L.showLog({controller: {log: []}}), L.showLog({})],
  danger: [L.dangerOf(L.routineById(reg, 'thieving')), L.dangerOf(mining), L.dangerOf(null), L.dangerOf({danger: '  '})],
  optionLabels: [L.optionLabel(L.routineById(reg, 'thieving')), L.optionLabel(mining)],
  confirm: [L.dangerConfirm(L.routineById(reg, 'thieving'), ['player_cantpvm']), L.dangerConfirm(mining, ['bot_a'])],
  allowed: L.allowedValues(mining.args[0], {}),
  set: [...L.parseSet('["bot_a", 1]')], broken: [...L.parseSet('{')],
};
console.log(JSON.stringify(out));
"""
        result = subprocess.run(['node', '-e', probe, str(script), json.dumps(controller.parse_registry(REGISTRY))],
                                capture_output=True, text=True, timeout=20, check=True)
        got = json.loads(result.stdout)
        self.assertEqual(got['defaults'], {'spot': 'tin-barbarian-village', 'seconds': 600})
        self.assertEqual(got['ok'], {'ok': True, 'args': {'spot': 'tin-barbarian-village', 'seconds': 120}, 'errors': {}})
        self.assertEqual(sorted(got['bad']['errors']), ['seconds', 'spot'])
        self.assertFalse(got['low']['ok'])
        self.assertFalse(got['none']['ok'])
        self.assertEqual((got['common'], got['commonEmpty']), (['chickens'], []))
        self.assertEqual(got['tones'], ['ok', 'warn', 'bad', 'muted'])
        self.assertEqual(got['desired'], ['No request', 'Run mining tin-barbarian-village 120 · r3', 'Stop · r4'])
        self.assertEqual(got['offline']['tone'], 'bad')
        self.assertIn('OFFLINE', got['offline']['text'])
        self.assertEqual(got['online']['tone'], 'ok')
        self.assertEqual(got['visible'], [True, False, True, True])
        self.assertEqual(got['byType'], [[True, True, False], [True, False, True]])
        self.assertEqual(got['shows'], ['regular', 'bots', 'all', '?a=1&show=bots'])
        self.assertIn('only while this page', got['frameLines'])
        self.assertEqual(got['modes'], [['headless', 'browser'], ['headless'], ['headless']])
        self.assertEqual(got['logShown'], [True, False, False])
        self.assertEqual((got['set'], got['broken']), (['bot_a'], []))
        self.assertEqual(got['danger'], [THIEVING_DANGER, None, None, None])
        self.assertEqual(got['optionLabels'], ['\u26a0 Thieving (suicide, Lumbridge) (dangerous)', 'Mining'])
        self.assertIn('DANGEROUS for player_cantpvm', got['confirm'][0])
        self.assertIn(THIEVING_DANGER, got['confirm'][0])
        self.assertIsNone(got['confirm'][1])
        self.assertEqual(got['allowed'], ['tin-barbarian-village', 'coal-barbarian-village'])


# Mirror of a gathering entry (2004Scape-Botting tools/gather-registry.ts output, trimmed).
GATHER = {
    'id': 'gather-woodcutting', 'label': 'Woodcutting', 'runner': 'session', 'routine': 'gather', 'gather': 'woodcutting', 'safeStart': True,
    'denyBots': ['bot_pioneer'], 'allowPlayers': True,
    'args': [
        {'name': 'resource', 'label': 'Resource', 'type': 'enum', 'values': ['best', 'tree', 'oak', 'maple'], 'default': 'best',
         'valueLabels': {'best': 'Best (most XP/h)', 'oak': 'Oak (Woodcutting 15)'}},
        {'name': 'location', 'label': 'Location', 'type': 'enum', 'values': ['best', 'closest', 'varrock-northwest-trees', 'varrock-west-oaks'], 'default': 'best',
         'valuesBy': {'arg': 'resource', 'map': {'best': ['best', 'closest', 'varrock-northwest-trees', 'varrock-west-oaks'],
                                                 'tree': ['best', 'closest', 'varrock-northwest-trees'], 'oak': ['best', 'closest', 'varrock-west-oaks'],
                                                 'maple': ['best', 'closest']}}},
        {'name': 'handling', 'label': 'Handling', 'type': 'enum', 'values': ['bank', 'burn', 'drop'], 'default': 'bank', 'playersOnly': ['burn', 'drop'],
         'valueLabels': {'bank': 'Bank', 'burn': 'Consume (burn logs)', 'drop': 'Drop'}},
        {'name': 'seconds', 'label': 'Duration', 'type': 'int', 'unit': 'seconds', 'min': 60, 'max': 604800, 'default': 600},
    ],
}
RETIRED = {'id': 'chopbank', 'label': 'Chop and bank', 'runner': 'session', 'routine': 'chopbank', 'denyBots': ['bot_pioneer'], 'allowPlayers': True, 'hidden': True,
           'args': [{'name': 'spot', 'type': 'enum', 'values': ['oak-varrock'], 'default': 'oak-varrock'}]}


def gather_registry():
    raw = json.loads(json.dumps(REGISTRY))
    raw['routines'] = [json.loads(json.dumps(GATHER)), json.loads(json.dumps(RETIRED))] + raw['routines']
    return raw


CHOICES = {'c0': {'off': {'resource': {'by': None, 'map': {'': {'maple': 'Woodcutting 35 < 45; no verified spot yet'}}},
                          'location': {'by': 'resource', 'map': {'best': {}, 'tree': {'varrock-northwest-trees': 'full: 2/2 (bot_a, bot_b)'}}},
                          'handling': {'by': 'resource', 'map': {'best': {}, 'oak': {'burn': 'Firemaking 10 < 15'}}}},
                  'notes': ['Banked tools are not known yet.']}}


class GatherTests(unittest.TestCase):
    def test_dependent_args_hidden_entries_and_players_only_values(self):
        reg = controller.parse_registry(gather_registry())
        wc = reg['routines'][0]
        self.assertEqual((wc['gather'], wc['hidden'], reg['routines'][1]['hidden']), ('woodcutting', False, True))
        self.assertEqual(controller.allowed_values(wc['args'][1], {'resource': 'oak'}), ['best', 'closest', 'varrock-west-oaks'])
        self.assertEqual(controller.allowed_values(wc['args'][1], {}), [])
        self.assertEqual(controller.validate_run(reg, PLAYER, 'gather-woodcutting', {}),
                         {'resource': 'best', 'location': 'best', 'handling': 'bank', 'seconds': 600})
        self.assertEqual(controller.validate_run(reg, PLAYER, 'gather-woodcutting', {'resource': 'oak', 'location': 'varrock-west-oaks', 'handling': 'burn'})['handling'], 'burn')
        self.assertEqual(controller.validate_run(reg, 'bot_wormlike', 'gather-woodcutting', {'resource': 'tree'})['resource'], 'tree')
        for bot, args, reason in [
            (PLAYER, {'resource': 'oak', 'location': 'varrock-northwest-trees'}, 'location: one of best, closest, varrock-west-oaks'),
            ('bot_wormlike', {'handling': 'drop'}, 'regular accounts only'),
            ('bot_wormlike', {'handling': 'burn'}, 'regular accounts only'),
            (PLAYER, {'handling': 'cook'}, 'handling: one of'),
        ]:
            with self.assertRaises(ValueError) as caught:
                controller.validate_run(reg, bot, 'gather-woodcutting', args)
            self.assertIn(reason, str(caught.exception), (bot, args))
        # Retired entries still validate (a running daemon's in-flight requests) but are never offered.
        self.assertEqual(controller.validate_run(reg, PLAYER, 'chopbank', {}), {'spot': 'oak-varrock'})

        def bad(mutate):
            raw = gather_registry()
            mutate(raw['routines'][0])
            with self.assertRaises(ValueError):
                controller.parse_registry(raw)
        bad(lambda r: r['args'][1]['valuesBy'].update(arg='handling'))
        bad(lambda r: r['args'][1]['valuesBy'].update(arg='seconds'))
        bad(lambda r: r['args'][1]['valuesBy']['map'].pop('oak'))
        bad(lambda r: r['args'][1]['valuesBy']['map'].update(nowhere=['best']))
        bad(lambda r: r['args'][1]['valuesBy']['map'].update(oak=['best', 'lumbridge']))
        bad(lambda r: r['args'][1]['valuesBy']['map'].update(oak=[]))
        bad(lambda r: r['args'][1]['valuesBy']['map'].update(oak=['closest']))
        bad(lambda r: r['args'][0]['valueLabels'].update(nowhere='x'))
        bad(lambda r: r['args'][2].update(playersOnly=['bank']))
        bad(lambda r: r.update(allowPlayers=False))
        bad(lambda r: r.update(gather='thieving'))
        bad(lambda r: r.update(routine='chopbank'))
        bad(lambda r: r.update(hidden='yes'))

    def test_status_carries_choices_and_the_resolution_note_and_the_store_refuses_retired_entries(self):
        doc = status_doc(registry=gather_registry(), gatherChoices={**CHOICES, 'evil id': {}, 'c1': {'off': {'resource': {'by': 'x', 'map': {'a b': {'x': 'y'}}}}}})
        doc['bots'][PLAYER] = {'displayName': 'Cant Pvm', 'state': 'running', 'gather': {'gather-woodcutting': 'c0', 'x y': 'c0', 'gather-mining': 'zz'},
                               'job': {'kind': 'run', 'routine': 'gather', 'args': ['woodcutting', 'tree', 'varrock-northwest-trees', 'burn', '600'],
                                       'pid': 7, 'startedAt': 1, 'note': 'resolved resource best -> tree, location best -> varrock-northwest-trees'}}
        shaped = controller.shape_status(doc, 9)
        self.assertIsNone(shaped['registryError'])
        self.assertEqual(shaped['gatherChoices']['c0'], CHOICES['c0'])
        self.assertEqual(shaped['gatherChoices']['c1'], {'off': {'resource': {'by': None, 'map': {}}}, 'notes': []})
        self.assertNotIn('evil id', shaped['gatherChoices'])
        self.assertEqual(shaped['bots'][PLAYER]['gather'], {'gather-woodcutting': 'c0'})
        self.assertIn('-> tree', shaped['bots'][PLAYER]['job']['note'])
        reg = controller.parse_registry(gather_registry())
        with tempfile.TemporaryDirectory() as d:
            store = controller.Store(d)
            code, body = store.apply({'action': 'run', 'bots': [PLAYER], 'routine': 'chopbank', 'args': {}}, reg, [PLAYER], OWNER)
            self.assertEqual(code, 400)
            self.assertIn('retired', body['error'])
            code, body = store.apply({'action': 'run', 'bots': ['bot_wormlike'], 'routine': 'gather-woodcutting', 'args': {'handling': 'drop'}}, reg, ['bot_wormlike'], OWNER)
            self.assertEqual(code, 400)
            self.assertIn('regular accounts only', body['bots']['bot_wormlike'])
            code, body = store.apply({'action': 'run', 'bots': [PLAYER], 'routine': 'gather-woodcutting', 'args': {'handling': 'burn'}}, reg, [PLAYER], OWNER)
            self.assertEqual(code, 200, body)
        status = {**shaped, 'online': True}
        page = controller.view([PLAYER], {}, status, controller.empty_desired(), {})
        self.assertEqual(page['gatherChoices']['c0'], CHOICES['c0'])
        row = next(r for r in page['bots'] if r['username'] == PLAYER)
        self.assertIn('gather-woodcutting', row['eligible'])
        self.assertNotIn('chopbank', row['eligible'])

    @unittest.skipUnless(shutil.which('node'), 'node not installed')
    def test_page_logic_for_dependent_and_greyed_out_values(self):
        script = Path(__file__).with_name('bot_controller.js')
        probe = """
const L = require(process.argv[1]);
const reg = JSON.parse(process.argv[2]);
const choices = JSON.parse(process.argv[3]).c0;
const wc = L.routineById(reg, 'gather-woodcutting');
const [res, loc, hand] = wc.args;
const me = [{username: 'player_cantpvm', type: 'player', choices}];
const bot = [{username: 'bot_a', type: 'bot', choices: null}];
const both = [...me, ...bot];
const offMe = (a, chosen) => L.offReasons(a, chosen, me);
console.log(JSON.stringify({
  locOak: L.allowedValues(loc, {resource: 'oak'}),
  locNone: L.allowedValues(loc, {}),
  resOff: L.offReasons(res, {}, me),
  locOffTree: L.offReasons(loc, {resource: 'tree'}, me),
  handOak: L.offReasons(hand, {resource: 'oak'}, me),
  handBot: L.offReasons(hand, {resource: 'tree'}, bot),
  handBoth: L.offReasons(hand, {resource: 'oak'}, both),
  pick: [L.pickValue(['best', 'closest', 'varrock-northwest-trees'], {'varrock-northwest-trees': 'full'}, 'varrock-northwest-trees', 'best'),
         L.pickValue(['a', 'b'], {a: 'x'}, 'a', 'a'), L.pickValue(['a'], {a: 'x'}, 'a', 'a')],
  labels: [L.valueText(hand, 'burn'), L.valueText(loc, 'varrock-west-oaks')],
  okBurn: L.validateArgs(wc, {resource: 'tree', location: 'best', handling: 'burn', seconds: '600'}, offMe),
  badBurn: L.validateArgs(wc, {resource: 'oak', location: 'best', handling: 'burn', seconds: '600'}, offMe),
  badMaple: L.validateArgs(wc, {resource: 'maple', location: 'best', handling: 'bank', seconds: '600'}, offMe),
  badLoc: L.validateArgs(wc, {resource: 'oak', location: 'varrock-northwest-trees', handling: 'bank', seconds: '600'}),
}));
"""
        result = subprocess.run(['node', '-e', probe, str(script), json.dumps(controller.parse_registry(gather_registry())), json.dumps(CHOICES)],
                                capture_output=True, text=True, timeout=20, check=True)
        got = json.loads(result.stdout)
        self.assertEqual(got['locOak'], ['best', 'closest', 'varrock-west-oaks'])
        self.assertEqual(got['locNone'], [])
        self.assertEqual(got['resOff'], {'maple': 'Woodcutting 35 < 45; no verified spot yet'})
        self.assertEqual(got['locOffTree'], {'varrock-northwest-trees': 'full: 2/2 (bot_a, bot_b)'})
        self.assertEqual(got['handOak'], {'burn': 'Firemaking 10 < 15'})
        self.assertEqual(got['handBot'], {'burn': 'fleet bots bank their produce', 'drop': 'fleet bots bank their produce'})
        self.assertEqual(got['handBoth'], {'burn': 'player_cantpvm: Firemaking 10 < 15', 'drop': 'bot_a: fleet bots bank their produce'})
        self.assertEqual(got['pick'], ['best', 'b', 'a'])
        self.assertEqual(got['labels'], ['Consume (burn logs)', 'varrock-west-oaks'])
        self.assertTrue(got['okBurn']['ok'])
        self.assertEqual(got['badBurn']['errors'], {'handling': 'Firemaking 10 < 15'})
        self.assertEqual(got['badMaple']['errors'], {'resource': 'Woodcutting 35 < 45; no verified spot yet'})
        self.assertIn('location', got['badLoc']['errors'])


if __name__ == '__main__':
    unittest.main()
