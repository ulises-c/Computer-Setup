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
# Mirror of 2004Scape-Botting routines/registry.json (trimmed descriptions).
REGISTRY = {
    'version': 1, 'excludedBots': ['bot_tester'],
    'routines': [
        {'id': 'mining', 'label': 'Mining', 'runner': 'session', 'routine': 'mining', 'safeStart': True, 'denyBots': ['bot_pioneer'], 'allowPlayers': True,
         'args': [{'name': 'spot', 'label': 'Spot', 'type': 'enum', 'values': ['tin-barbarian-village', 'coal-barbarian-village'], 'default': 'tin-barbarian-village'},
                  {'name': 'seconds', 'label': 'Seconds', 'type': 'int', 'min': 60, 'max': 21600, 'default': 600}],
         'spotLimit': {'arg': 'spot', 'limits': {'tin-barbarian-village': 2}}},
        {'id': 'chickens', 'label': 'Chickens 24/7', 'runner': 'chickens-247', 'denyBots': ['bot_pioneer'],
         'args': [{'name': 'pen', 'type': 'enum', 'values': ['lumbridge-east'], 'default': 'lumbridge-east'},
                  {'name': 'policy', 'type': 'enum', 'values': ['str-atk', 'str-atk-def'], 'default': 'str-atk'}]},
        {'id': 'pioneer-fish', 'label': 'Pioneer', 'runner': 'pioneer', 'allowBots': ['bot_pioneer'], 'fixedArgs': ['fish-bank'],
         'args': [{'name': 'seconds', 'type': 'int', 'min': 60, 'max': 3600, 'default': 120}]},
        {'id': 'onboard', 'label': 'Onboard', 'runner': 'onboard', 'enabled': False, 'denyBots': ['bot_pioneer'], 'args': []},
        {'id': 'scavenge', 'label': 'Scavenger 24/7', 'runner': 'scavenge-247', 'allowBots': ['bot_magpie'], 'denyBots': ['bot_pioneer'],
         'args': [{'name': 'pen', 'type': 'enum', 'values': ['lumbridge-east'], 'default': 'lumbridge-east'}]},
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
        self.assertEqual([r['id'] for r in reg['routines']], ['mining', 'chickens', 'pioneer-fish', 'onboard', 'scavenge'])
        self.assertEqual([r['id'] for r in reg['routines'] if r['allowPlayers']], ['mining'])
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

    @unittest.skipUnless(Path.home().joinpath('forgejo/2004Scape-Botting/routines/registry.json').exists(), 'bot repo not on this machine')
    def test_the_bot_repo_registry_is_accepted(self):
        raw = json.loads(Path.home().joinpath('forgejo/2004Scape-Botting/routines/registry.json').read_text())
        self.assertIn('mining', [r['id'] for r in controller.parse_registry(raw)['routines']])

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
        self.assertEqual(rows['bot_wormlike']['eligible'], ['mining', 'chickens'])
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
        self.assertEqual(rows[PLAYER]['eligible'], ['mining'])
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


if __name__ == '__main__':
    unittest.main()
