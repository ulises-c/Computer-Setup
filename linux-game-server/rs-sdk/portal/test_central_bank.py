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

import central_bank
import controller

OWNER = 'owner@example.com'
ORIGIN = 'https://portal.example'


def bridge_status(**extra):
    """What the workstation bridge pushes (2004Scape-Botting tools/lib/central-bank-bridge.ts buildStatus)."""
    now = int(time.time() * 1000)
    doc = {
        'generatedAt': now,
        'bank': {'bot': 'bot_bank', 'state': 'collecting', 'at': now, 'hub': 'Varrock west', 'holdingsAt': now, 'coins': 25},
        'items': [
            {'name': 'Steel sword', 'count': 14, 'value': 325, 'policy': 'keep', 'policyAt': 0, 'policyBy': None, 'class': 'surplus'},
            {'name': 'Iron platebody', 'count': 0, 'value': 560, 'policy': 'sell', 'policyAt': 1000, 'policyBy': 'portal:owner@example.com', 'class': 'surplus'},
            {'name': 'Bronze axe', 'count': 1, 'value': 16, 'policy': 'keep', 'policyAt': 0, 'policyBy': None, 'class': None},
        ],
        'designations': {'version': 4, 'appliedRev': 0},
        'received': [{'from': 'bot_smithing', 'at': now, 'items': {'Steel sword': 14}}],
        'handedOut': [],
        'traders': [{'bot': 'bot_staid', 'state': 'collecting', 'at': now, 'stock': {'Steel sword': 2}, 'coins': 900}],
        'sales': [{'at': now, 'bot': 'bot_staid', 'item': 'Steel sword', 'price': 130, 'store': 'varrock-general'}],
        'soldTotals': [{'item': 'Steel sword', 'count': 1, 'coins': 130}],
        'results': [],
    }
    doc.update(extra)
    return doc


class ShapeTests(unittest.TestCase):
    def test_status_is_allowlisted(self):
        raw = bridge_status()
        raw['items'].append({'name': '<img src=x>', 'count': 1})
        raw['items'][0]['password'] = 'x'
        raw['bank']['bot'] = 'Not A Bot'
        raw['traders'].append({'bot': 'not a bot', 'state': 'collecting'})
        raw['sales'][0]['store'] = '../../etc'
        raw['secret'] = 'nope'
        s = central_bank.shape_status(raw, 7)
        self.assertEqual([i['name'] for i in s['items']], ['Steel sword', 'Iron platebody', 'Bronze axe'])
        self.assertNotIn('password', s['items'][0])
        self.assertNotIn('secret', s)
        self.assertIsNone(s['bank']['bot'])
        self.assertEqual([t['bot'] for t in s['traders']], ['bot_staid'])
        self.assertIsNone(s['sales'][0]['store'])
        self.assertEqual(s['receivedAt'], 7)
        with self.assertRaises(ValueError):
            central_bank.shape_status([], 1)

    def test_bad_policy_and_counts_fall_back(self):
        raw = bridge_status()
        raw['items'][0].update(policy='burn', count=-5, value='lots', policyBy='<b>')
        row = central_bank.shape_status(raw, 1)['items'][0]
        self.assertEqual((row['policy'], row['count'], row['value'], row['policyBy']), ('keep', 0, None, None))

    def test_read_status_age_and_stale(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'central-bank-status.json'
            self.assertFalse(central_bank.read_status(path)['available'])
            controller.write_atomic(path, central_bank.shape_status(bridge_status(), 1000))
            fresh = central_bank.read_status(path, now_ms=2000)
            self.assertTrue(fresh['available'])
            self.assertFalse(fresh['stale'])
            self.assertTrue(central_bank.read_status(path, now_ms=1000 + central_bank.STALE_MS + 1)['stale'])


class StoreTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.dir = Path(tmp.name)
        self.store = central_bank.Store(self.dir, clock=lambda: 50.0)
        self.status = {**central_bank.shape_status(bridge_status(), 1), 'available': True}

    def test_records_one_pending_edit_per_item(self):
        status, body = self.store.apply({'item': 'steel sword', 'policy': 'sell', 'expectAt': 0}, self.status, OWNER)
        self.assertEqual(status, 200, body)
        self.assertEqual(body['edit']['item'], 'Steel sword')   # canonical name from the bank list
        self.store.apply({'item': 'Steel sword', 'policy': 'keep', 'expectAt': 0}, self.status, OWNER)
        wanted = self.store.read()
        self.assertEqual(list(wanted['edits']), ['steel sword'])
        self.assertEqual((wanted['edits']['steel sword']['policy'], wanted['edits']['steel sword']['rev']), ('keep', 2))
        audit = (self.dir / 'central-bank-audit.jsonl').read_text().splitlines()
        self.assertEqual(len(audit), 2)
        self.assertEqual(json.loads(audit[0])['by'], OWNER)

    def test_rejects_unknown_items_and_bad_requests(self):
        cases = [({'item': 'Rune scimitar', 'policy': 'sell', 'expectAt': 0}, 400), ({'item': 'Steel sword', 'policy': 'burn', 'expectAt': 0}, 400),
                 ({'item': 'Steel sword', 'policy': 'sell'}, 400), ({'item': 'Steel sword', 'policy': 'sell', 'expectAt': 0, 'extra': 1}, 400),
                 ({'item': '<b>', 'policy': 'sell', 'expectAt': 0}, 400), ([], 400)]
        for request, code in cases:
            self.assertEqual(self.store.apply(request, self.status, OWNER)[0], code, request)
        self.assertEqual(self.store.apply({'item': 'Steel sword', 'policy': 'sell', 'expectAt': 0}, {'available': False}, OWNER)[0], 409)
        self.assertEqual(central_bank.Store(None).apply({}, self.status, OWNER)[0], 503)
        self.assertEqual(self.store.read()['edits'], {})

    def test_applied_edits_retire_and_view_shows_pending(self):
        self.store.apply({'item': 'Steel sword', 'policy': 'sell', 'expectAt': 0}, self.status, OWNER)
        view = central_bank.view(self.status, self.store.read(), {'canWrite': True})
        row = next(i for i in view['items'] if i['name'] == 'Steel sword')
        self.assertEqual((row['policy'], row['pending'], row['total']), ('keep', 'sell', 14 * 325))
        applied = {**self.status, 'designations': {'version': 5, 'appliedRev': 1}}
        self.assertIsNone(next(i for i in central_bank.view(applied, self.store.read(), {})['items'] if i['name'] == 'Steel sword')['pending'])
        # The next write drops the applied edit and numbers the new one above it.
        self.store.apply({'item': 'Bronze axe', 'policy': 'sell', 'expectAt': 0}, applied, OWNER)
        wanted = self.store.read()
        self.assertEqual(list(wanted['edits']), ['bronze axe'])
        self.assertEqual(wanted['edits']['bronze axe']['rev'], 2)


class ExchangeTests(unittest.TestCase):
    def test_exchange_stores_status_and_returns_pending_edits(self):
        with tempfile.TemporaryDirectory() as tmp:
            wanted_dir, status_dir = Path(tmp) / 'controller', Path(tmp) / 'live'
            wanted_dir.mkdir()
            store = central_bank.Store(wanted_dir)
            status = {**central_bank.shape_status(bridge_status(), 1), 'available': True}
            store.apply({'item': 'Steel sword', 'policy': 'sell', 'expectAt': 0}, status, OWNER)
            store.apply({'item': 'Bronze axe', 'policy': 'sell', 'expectAt': 0}, status, OWNER)
            out = io.StringIO()
            central_bank.exchange(io.BytesIO(json.dumps(bridge_status(designations={'version': 6, 'appliedRev': 1})).encode()), out, wanted_dir, status_dir, clock=lambda: 9.0)
            self.assertEqual([e['item'] for e in json.loads(out.getvalue())['edits']], ['Bronze axe'])
            stored = json.loads((status_dir / 'central-bank-status.json').read_text())
            self.assertEqual((stored['receivedAt'], stored['designations']['appliedRev']), (9000, 1))
            # A bad status is dropped (the old one stays) but the edits are still answered.
            out = io.StringIO()
            central_bank.exchange(io.BytesIO(b'[1,2]'), out, wanted_dir, status_dir)
            self.assertEqual(len(json.loads(out.getvalue())['edits']), 2)
            self.assertEqual(json.loads((status_dir / 'central-bank-status.json').read_text())['receivedAt'], 9000)


class CentralBankHTTPTests(unittest.TestCase):
    def setUp(self):
        import server
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        (root / 'live').mkdir()
        (root / 'controller').mkdir()
        controller.write_atomic(root / 'live' / 'central-bank-status.json', central_bank.shape_status(bridge_status(), int(time.time() * 1000)))
        http = server.PortalHTTPServer(('127.0.0.1', 0), server.Handler)
        self.addCleanup(http.server_close)
        http.portal = server.Portal(Path('/nonexistent'), 'https://game.example', 'https://home.example', live_path=root / 'live' / 'live.json',
                                    controller_dir=root / 'controller', owner_login=OWNER, public_origin=ORIGIN)
        threading.Thread(target=http.serve_forever, daemon=True).start()
        self.addCleanup(http.shutdown)
        self.base = f'http://127.0.0.1:{http.server_port}'
        self.root = root

    def get(self, path, headers=None):
        with urlopen(Request(self.base + path, headers=headers or {}), timeout=5) as response:
            return response.status, dict(response.headers), response.read()

    def post(self, body, headers, path='/rs-sdk/api/central-bank/designation'):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        try:
            with urlopen(Request(self.base + path, data=data, headers=headers, method='POST'), timeout=5) as response:
                return response.status, json.loads(response.read())
        except HTTPError as error:
            with error:
                return error.code, json.loads(error.read() or b'{}')

    def test_page_api_and_writes(self):
        status, headers, body = self.get('/rs-sdk/central-bank/')
        self.assertEqual(status, 200)
        self.assertIn("script-src 'self'", headers['Content-Security-Policy'])
        self.assertIn("connect-src 'self'", headers['Content-Security-Policy'])
        self.assertNotIn('frame-src', headers['Content-Security-Policy'])
        self.assertIn(b'src="/rs-sdk/central-bank.js"', body)
        self.assertNotIn(b'<script>', body)
        _, headers, _ = self.get('/rs-sdk/central-bank.js')
        self.assertIn('text/javascript', headers['Content-Type'])
        self.assertIn(b'/rs-sdk/central-bank/', self.get('/rs-sdk/')[2])
        # Anonymous: readable, no token, writes refused.
        view = json.loads(self.get('/rs-sdk/api/central-bank')[2])
        self.assertTrue(view['available'])
        self.assertFalse(view['auth']['canWrite'])
        self.assertEqual(view['items'][0]['name'], 'Steel sword')
        request = {'item': 'Steel sword', 'policy': 'sell', 'expectAt': 0}
        self.assertEqual(self.post(request, {'Content-Type': 'application/json', 'Origin': ORIGIN})[0], 403)
        token = json.loads(self.get('/rs-sdk/api/central-bank', {'Tailscale-User-Login': OWNER})[2])['auth']['csrf']
        owner = {'Tailscale-User-Login': OWNER, 'Origin': ORIGIN, 'Content-Type': 'application/json', 'X-CSRF-Token': token}
        self.assertEqual(self.post(request, dict(owner, Origin='https://evil.example'))[0], 403)
        self.assertEqual(self.post(request, dict(owner, **{'X-CSRF-Token': 'nope'}))[0], 403)
        status, body = self.post(request, owner)
        self.assertEqual(status, 200, body)
        row = next(i for i in json.loads(self.get('/rs-sdk/api/central-bank')[2])['items'] if i['name'] == 'Steel sword')
        self.assertEqual(row['pending'], 'sell')
        self.assertEqual(self.post(b'{not json', owner)[0], 400)
        self.assertEqual(self.post({'item': 'Dragon chainbody', 'policy': 'sell', 'expectAt': 0}, owner)[0], 400)
        # The controller's write endpoint is unaffected, other paths stay read-only.
        with self.assertRaises(HTTPError) as caught:
            urlopen(Request(self.base + '/rs-sdk/api/central-bank', data=b'{}', method='POST'), timeout=5)
        self.assertEqual(caught.exception.code, 501)
        caught.exception.close()

    def test_redirect_without_slash(self):
        with self.assertRaises(HTTPError) as caught:
            class NoRedirect(__import__('urllib.request').request.HTTPRedirectHandler):
                def redirect_request(self, *a, **k):
                    return None
            __import__('urllib.request').request.build_opener(NoRedirect).open(self.base + '/rs-sdk/central-bank', timeout=5)
        self.assertEqual(caught.exception.code, 302)
        self.assertEqual(caught.exception.headers['Location'], '/rs-sdk/central-bank/')
        caught.exception.close()


class ScriptTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('node'), 'node not installed')
    def test_page_logic(self):
        script = Path(__file__).with_name('central_bank.js')
        probe = """
const L = require(process.argv[1]);
const items = [
  {name: 'Steel sword', count: 14, value: 325, policy: 'keep', pending: 'sell'},
  {name: 'Iron platebody', count: 0, value: 560, policy: 'sell', pending: null},
  {name: 'Mystery', count: 2, value: null, policy: 'keep', pending: null},
];
console.log(JSON.stringify([L.counts(items), L.visible(items, 'sell').map(i => i.name), L.summary(items), L.ago(30000), L.ago(600000),
  L.bankLine({available: false}, 0).text, L.bankLine({available: true, stale: false, bank: {bot: 'bot_bank', state: 'collecting', at: 1000, hub: 'Varrock west', holdingsAt: 0, coins: 0}}, 6000).text, L.kindText('surplus'), L.kindText(null)]));
"""
        out = json.loads(subprocess.run(['node', '-e', probe, str(script)], capture_output=True, text=True, timeout=20, check=True).stdout)
        self.assertEqual(out[0], {'all': 3, 'sell': 2, 'keep': 1})
        self.assertEqual(out[1], ['Steel sword', 'Iron platebody'])
        self.assertEqual(out[2], '2 kinds held, worth 4,550 gp at store value (+1 without a known value); marked Sell: 2 kinds (4,550 gp).')
        self.assertEqual((out[3], out[4]), ('30 s ago', '10 min ago'))
        self.assertIn('has not reported', out[5])
        self.assertEqual(out[6], 'bot_bank is at the Varrock west bank, receiving (heartbeat 5 s ago).')
        self.assertEqual((out[7], out[8]), ('Surplus product', 'Other'))


if __name__ == '__main__':
    unittest.main()
