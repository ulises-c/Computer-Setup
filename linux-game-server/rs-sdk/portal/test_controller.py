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
        {'id': 'mining', 'label': 'Mining', 'runner': 'session', 'routine': 'mining', 'safeStart': True, 'denyBots': ['bot_pioneer'],
         'args': [{'name': 'spot', 'label': 'Spot', 'type': 'enum', 'values': ['tin-barbarian-village', 'coal-barbarian-village'], 'default': 'tin-barbarian-village'},
                  {'name': 'seconds', 'label': 'Seconds', 'type': 'int', 'min': 60, 'max': 21600, 'default': 600}],
         'spotLimit': {'arg': 'spot', 'limits': {'tin-barbarian-village': 2}}},
        {'id': 'chickens', 'label': 'Chickens 24/7', 'runner': 'chickens-247', 'denyBots': ['bot_pioneer'],
         'args': [{'name': 'pen', 'type': 'enum', 'values': ['lumbridge-east'], 'default': 'lumbridge-east'},
                  {'name': 'policy', 'type': 'enum', 'values': ['str-atk', 'str-atk-def'], 'default': 'str-atk'}]},
        {'id': 'pioneer-fish', 'label': 'Pioneer', 'runner': 'pioneer', 'allowBots': ['bot_pioneer'], 'fixedArgs': ['fish-bank'],
         'args': [{'name': 'seconds', 'type': 'int', 'min': 60, 'max': 3600, 'default': 120}]},
        {'id': 'onboard', 'label': 'Onboard', 'runner': 'onboard', 'enabled': False, 'denyBots': ['bot_pioneer'], 'args': []},
    ],
}
ACCOUNTS = ['bot_pioneer', 'bot_tester', 'bot_wormlike', 'bot_apehood']


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
        self.assertEqual([r['id'] for r in reg['routines']], ['mining', 'chickens', 'pioneer-fish', 'onboard'])
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
                                 'args': {'spot': 'tin-barbarian-village', 'seconds': 120}})
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
        ]:
            status, _ = self.apply(request)
            self.assertEqual(status, 400, request)
        self.assertFalse((self.dir / 'desired.json').exists())
        self.assertEqual(self.store.apply({'action': 'stop', 'bots': ['bot_wormlike']}, None, ACCOUNTS, OWNER)[0], 409)
        self.assertEqual(controller.Store(None).apply({'action': 'stop', 'bots': ['bot_wormlike']}, self.reg, ACCOUNTS, OWNER)[0], 503)

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


class ControllerHTTPTests(unittest.TestCase):
    def setUp(self):
        import server
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        (root / 'live').mkdir()
        (root / 'controller').mkdir()
        live.write_atomic(root / 'live', live.shape_snapshot({'version': 1, 'bots': [{'username': 'bot_wormlike', 'status': 'active'}]}, received_at=1))
        controller.write_atomic(root / 'live' / 'controller-status.json', controller.shape_status(status_doc(), int(time.time() * 1000)))
        http = server.PortalHTTPServer(('127.0.0.1', 0), server.Handler)
        self.addCleanup(http.server_close)
        http.portal = server.Portal(Path('/nonexistent'), 'https://game.example', 'https://home.example', live_path=root / 'live' / 'live.json',
                                    controller_dir=root / 'controller', owner_login=OWNER, public_origin=ORIGIN)
        http.portal.live_accounts = lambda: ACCOUNTS
        threading.Thread(target=http.serve_forever, daemon=True).start()
        self.addCleanup(http.shutdown)
        self.base = f'http://127.0.0.1:{http.server_port}'
        self.root = root

    def get(self, path, headers=None):
        with urlopen(Request(self.base + path, headers=headers or {}), timeout=5) as response:
            return response.status, dict(response.headers), response.read()

    def post(self, body, headers):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        try:
            with urlopen(Request(self.base + '/rs-sdk/api/controller/desired', data=data, headers=headers, method='POST'), timeout=5) as response:
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
        self.assertEqual({r['username'] for r in view['bots']}, set(ACCOUNTS))
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
  visible: [L.visible({presence: 'offline'}, 'all'), L.visible({presence: 'offline'}, 'active'), L.visible({presence: 'ghost'}, 'active'), L.visible({presence: 'offline', desired: {}}, 'active')],
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
        self.assertEqual(got['desired'], ['No request', 'Run mining tin-barbarian-village 120 · r3', 'Stop (log out) · r4'])
        self.assertEqual(got['offline']['tone'], 'bad')
        self.assertIn('OFFLINE', got['offline']['text'])
        self.assertEqual(got['online']['tone'], 'ok')
        self.assertEqual(got['visible'], [True, False, True, True])
        self.assertEqual((got['set'], got['broken']), (['bot_a'], []))


if __name__ == '__main__':
    unittest.main()
