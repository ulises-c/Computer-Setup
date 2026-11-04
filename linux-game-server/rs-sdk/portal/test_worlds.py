"""World selector page (/rs-sdk/worlds): rendering, failure modes, escaping and links."""
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import tempfile
import threading
import unittest
from urllib.request import urlopen

import server
import worlds_page

NOW = datetime(2026, 1, 2, 12, 0, 0, tzinfo=timezone.utc)
HOST = 'game.example'


def world(wid, **fields):
    entry = {
        'id': wid, 'node': wid if wid != 1 else 10, 'role': 'live', 'mode': 'shared', 'online': True,
        'state': 'running · healthy', 'players': 4, 'countdown_until': None,
        'image': 'sha256:' + 'ab12cd34ef56' + '0' * 52, 'image_tags': ['example/rs-sdk:local'],
        'upstream': '1234567890abcdef1234567890abcdef12345678', 'patches': 'fedcba987654',
        'allowlist': False, 'hoppable': True,
        'web_url': f'https://{HOST}:{9400 + wid}/', 'gateway_url': f'wss://{HOST}:{9500 + wid}',
        'bot_env': {'SERVER': f'{HOST}:{9400 + wid}', 'GATEWAY_URL': f'wss://{HOST}:{9500 + wid}'},
    }
    entry.update(fields)
    return entry


def document(*worlds, generated=NOW - timedelta(seconds=10)):
    return {'version': 1, 'generated': generated.strftime('%Y-%m-%dT%H:%M:%SZ'), 'profile': 'main',
            'note': 'Worlds share accounts. Hop only to hoppable worlds.', 'worlds': list(worlds)}


SAMPLE = document(
    world(1),
    world(100, role='test', mode='isolated', players=1, allowlist=True, allowlist_size=3, hoppable=False,
          note='isolated test copy of world 1: its own accounts and saves; progress there is thrown away'),
    world(2, online=False, state='exited', players=None, hoppable=False,
          countdown_until=(NOW + timedelta(minutes=2)).strftime('%Y-%m-%dT%H:%M:%SZ')),
)


class WorldsPageTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / 'rs-sdk-worlds.json'

    def render(self, content, now=NOW):
        if content is not None:
            self.path.write_text(content if isinstance(content, str) else json.dumps(content))
        body, head = worlds_page.page(self.path, now=now)
        return body, head

    def card(self, body, wid):
        start = body.index(f'id="world-{wid}"')
        return body[start:body.index('</section>', start)]

    def test_lists_every_world_sorted_with_status(self):
        body, head = self.render(SAMPLE)
        self.assertIn('<meta http-equiv="refresh" content="30">', head)
        self.assertIn('World selector', body)
        self.assertLess(body.index('id="world-1"'), body.index('id="world-2"'))
        self.assertLess(body.index('id="world-2"'), body.index('id="world-100"'))
        self.assertIn('3 worlds · 2 online', body)
        self.assertIn('World list generated 2026-01-02 11:59:50 UTC (10 s ago)', body)
        self.assertNotIn('<b>stale</b>', body)
        self.assertIn('Worlds share accounts. Hop only to hoppable worlds.', body)

        live = self.card(body, 1)
        self.assertIn('tone-live">Live<', live)
        self.assertIn('>Online<', live)
        self.assertIn('Online · running · healthy', live)
        self.assertIn('<dt>Players online</dt><dd>4</dd>', live)
        self.assertIn('shared: accounts', live)
        self.assertIn('yes: bots may hop here', live)
        self.assertIn('none: any account can log in', live)
        self.assertIn('<code>1234567890ab</code>', live)
        self.assertIn('<code>fedcba987654</code>', live)
        self.assertIn('>ab12cd34ef56</code>', live)
        self.assertNotIn('sha256:', live)
        self.assertIn(f'class="world-play" href="https://{HOST}:9401/"', live)
        self.assertNotIn('Countdown', live)

        test = self.card(body, 100)
        self.assertIn('tone-test">Test<', test)
        self.assertIn('Isolated', test)
        self.assertIn('progress is thrown away', test)
        self.assertIn('allowlisted accounts only (3 accounts)', test)
        self.assertIn('no: bots never hop here', test)
        self.assertIn(f'href="https://{HOST}:9500/"', test)

        offline = self.card(body, 2)
        self.assertIn('>Offline<', offline)
        self.assertIn('Offline · exited', offline)
        self.assertIn('<dt>Players online</dt><dd>—</dd>', offline)
        self.assertNotIn('href=', offline)
        self.assertIn('aria-disabled="true">Play (offline)', offline)
        self.assertIn('goes down</b> at 2026-01-02 12:02:00 UTC (in 2 min)', offline)

    def test_sdk_connection_values(self):
        body, _ = self.render(SAMPLE)
        sdk = body[body.index('SDK connection'):]
        self.assertIn(f'<code>SERVER={HOST}:9401</code>', sdk)
        self.assertIn(f'<code>GATEWAY_URL=wss://{HOST}:9501</code>', sdk)
        self.assertIn(f'<code>SERVER={HOST}:9500</code>', sdk)

    def test_stale_and_unknown_generated_time(self):
        body, _ = self.render(document(world(1), generated=NOW - timedelta(minutes=10)))
        self.assertIn('<b>stale</b>', body)
        broken = document(world(1))
        broken['generated'] = 'yesterday'
        body, _ = self.render(broken)
        self.assertIn('publication time unknown', body)

    def test_missing_empty_malformed_files_say_unavailable(self):
        cases = {
            'missing': None,
            'empty': '',
            'not json': '{"worlds": [',
            'not an object': '[1, 2]',
            'no worlds': '{"version": 1}',
            'worlds not a list': '{"worlds": {"id": 1}}',
            'no valid world': '{"worlds": [{"name": "x"}, 3, {"id": "1"}]}',
        }
        for name, content in cases.items():
            with self.subTest(name):
                if self.path.exists():
                    self.path.unlink()
                body, _ = self.render(content)
                self.assertIn('World list unavailable', body)
                self.assertNotIn('world-card', body)
        self.assertIn('World list unavailable', worlds_page.page(None, now=NOW)[0])
        self.path.write_bytes(b'\xff\xfe')
        self.assertIn('not valid JSON', worlds_page.page(self.path, now=NOW)[0])
        self.path.write_text(' ' * (worlds_page.MAX_BYTES + 1))
        self.assertIn('too large', worlds_page.page(self.path, now=NOW)[0])

    def test_odd_field_types_do_not_break_the_page(self):
        odd = document(world(1, players={'x': 1}, state=['a'], image=5, upstream=None, image_tags='x',
                             bot_env='nope', countdown_until='soon', allowlist_size=True, online='yes'), 'junk')
        body, _ = self.render(odd)
        card = self.card(body, 1)
        self.assertIn('>Offline<', card)  # only a real true counts as online
        self.assertIn('<dt>Countdown</dt><dd>soon</dd>', card)
        self.assertIn('SERVER=—', body)

    def test_everything_is_escaped_and_urls_are_checked(self):
        evil = '<script>alert(1)</script>'
        body, _ = self.render(document(
            world(1, state=evil, note=evil, upstream=evil, image_tags=[evil], bot_env={'SERVER': evil, 'GATEWAY_URL': evil}),
            world(3, web_url='javascript:alert(1)'),
            world(4, web_url='https://ok.example/" onclick="x'),
        ) | {'note': evil})
        self.assertNotIn('<script>', body)
        self.assertIn('&lt;script&gt;', body)
        self.assertNotIn('javascript:', body)
        self.assertNotIn('onclick="x', body)
        self.assertIn('Play (no web address)', self.card(body, 3))
        self.assertIn('Play (no web address)', self.card(body, 4))


class WorldsPortalTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / 'rs-sdk-worlds.json'
        self.app = server.Portal(Path('/nonexistent'), 'https://game.example:9445', 'https://game.example', worlds_path=self.path)

    def test_route_renders_and_survives_bad_input(self):
        self.path.write_text(json.dumps(SAMPLE))
        status, body = self.app.render('/rs-sdk/worlds', {})
        self.assertEqual(status, 200)
        self.assertIn('<title>World selector · RS-SDK</title><meta http-equiv="refresh" content="30">', body)
        self.assertIn('id="world-100"', body)
        self.path.write_text('{oops')
        status, body = self.app.render('/rs-sdk/worlds', {})
        self.assertEqual(status, 200)
        self.assertIn('World list unavailable', body)
        status, location = self.app.render('/rs-sdk/worlds/', {})
        self.assertEqual((status, location), (302, '/rs-sdk/worlds'))
        status, body = server.Portal(Path('/nonexistent'), 'https://g.example', 'https://h.example').render('/rs-sdk/worlds', {})
        self.assertEqual(status, 200)
        self.assertIn('not configured with a world list', body)

    def test_home_nav_and_sidebar_link_the_page(self):
        status, body = self.app.render('/rs-sdk/', {})
        self.assertEqual(status, 200)
        self.assertIn('<a class="card" href="/rs-sdk/worlds"><small>09 / WORLDS</small><b>World selector ↗</b>', body)
        nav = body[body.index('<nav>'):body.index('</nav>')]
        self.assertIn('<a href="/rs-sdk/worlds">Worlds</a>', nav)
        menu = body[body.index('class="tool-menu"'):body.index('</aside>')]
        self.assertIn('<a href="/rs-sdk/worlds">World selector</a>', menu)
        # Other pages share the layout, so they carry the links too; the old layout gets no refresh.
        accounts = server.layout('Accounts', '<h1>Accounts</h1>')
        self.assertIn('<a href="/rs-sdk/worlds">World selector</a>', accounts)
        self.assertNotIn('http-equiv="refresh"', accounts)

    def test_http_route_keeps_the_strict_csp(self):
        self.path.write_text(json.dumps(SAMPLE))
        http = server.PortalHTTPServer(('127.0.0.1', 0), server.Handler)
        http.portal = self.app
        worker = threading.Thread(target=http.serve_forever, daemon=True)
        worker.start()
        try:
            with urlopen(f'http://127.0.0.1:{http.server_port}/rs-sdk/worlds') as response:
                self.assertEqual(response.status, 200)
                csp = response.headers['Content-Security-Policy']
                html = response.read().decode()
            self.assertTrue(csp.startswith("default-src 'none'"))
            self.assertNotIn('script-src', csp)
            self.assertNotIn('connect-src', csp)
            self.assertNotIn('<script', html)
            self.assertIn('World 100', html)
        finally:
            http.shutdown()
            http.server_close()
            worker.join()


if __name__ == '__main__':
    unittest.main()
