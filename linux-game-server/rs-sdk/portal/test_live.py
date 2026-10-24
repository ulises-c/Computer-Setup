import io
import json
from pathlib import Path
import tempfile
import threading
import unittest
from urllib.error import HTTPError
from urllib.request import urlopen

import live
import live_publish
import player_anims
import worldmap

SECRET = 'hunter2-SECRET'


def frame(**player):
    base = {'name': 'Bot Hoofs', 'worldX': 3222, 'worldZ': 3218, 'level': 0, 'hp': 9, 'maxHp': 11,
            'combatLevel': 3, 'runEnergy': 80, 'animId': 625, 'isDead': False,
            'combat': {'inCombat': True, 'targetIndex': 7, 'targetType': 'npc'}}
    base.update(player)
    return {
        'tick': 500, 'inGame': True, 'player': base, 'modalOpen': False,
        'skills': [{'name': 'Mining', 'level': 5, 'baseLevel': 5, 'experience': 400, 'extra': SECRET}],
        'inventory': [{'slot': 0, 'id': 1265, 'name': 'Bronze pickaxe', 'count': 1, 'optionsWithIndex': [{'text': SECRET}]}],
        'equipment': [],
        'nearbyNpcs': [{'index': 7, 'name': 'Goblin'}],
        'gameMessages': [{'type': 0, 'text': 'You swing your pick at the rock.', 'sender': '', 'tick': 490},
                         {'type': 2, 'text': SECRET, 'sender': 'someone', 'tick': 495},
                         {'type': 0, 'text': 'ancient', 'sender': '', 'tick': 10}],
        'dialog': {'isOpen': False}, 'bank': {'items': [SECRET]},
    }


class LiveShapingTests(unittest.TestCase):
    def test_map_point_matches_world_map_and_folds_underground(self):
        self.assertEqual(live.map_point(3222, 3218), (3222 - 1792, 2624 + 3328 - 1 - 3218))
        # Underground band 142-161 folds onto unified rows 63-82, as in MapView.
        self.assertEqual(live.map_point(3100, 9600), (3100 - 1792, 2624 + 3328 - 1 - ((150 - 79) * 64)))
        self.assertIsNone(live.map_point(3222, 100))
        self.assertIsNone(live.map_point(100, 3218))
        self.assertEqual(worldmap.unified_square_z(150), 71)
        self.assertEqual((worldmap.ORIGIN_X, worldmap.ORIGIN_Z, worldmap.WIDTH, worldmap.HEIGHT),
                         (live.ORIGIN_X, live.ORIGIN_Z, live.MAP_WIDTH, live.MAP_HEIGHT))

    def test_ticks_param(self):
        self.assertEqual(live.ticks_param({}), 10)
        self.assertEqual(live.ticks_param({'ticks': ['25']}), 25)
        for bad in ('0', '-1', 'x', '1001', '1e3'):
            with self.assertRaises(ValueError):
                live.ticks_param({'ticks': [bad]})

    def test_publisher_reduction_is_allowlisted_and_never_carries_credentials(self):
        xp, motion = live_publish.XpTracker(), live_publish.Motion()
        entry = live_publish.reduce_state('bot_hoofs', frame(), {'botStatus': 'active', 'stateAge': 120},
                                          {'routine': 'mining', 'args': ['copper-tin-sw-varrock', '180'], 'client': True}, xp, 0.0,
                                          motion=motion)
        later = frame()
        later['skills'][0]['experience'] = 435
        entry = live_publish.reduce_state('bot_hoofs', later, {'botStatus': 'active', 'stateAge': 120},
                                          {'routine': 'mining', 'args': ['copper-tin-sw-varrock'], 'client': True}, xp, 30.0,
                                          motion=motion)
        self.assertEqual(entry['recentXp'], {'Mining': 35})
        self.assertEqual(entry['xpRate'], {'Mining': 4200})
        self.assertEqual(entry['player']['target'], 'Goblin')
        self.assertEqual(entry['messages'], ['You swing your pick at the rock.'])
        shaped = live.shape_snapshot({'version': 1, 'publishedAt': 1, 'intervalMs': 6000, 'bots': [entry]}, received_at=5)
        text = json.dumps(shaped)
        self.assertNotIn(SECRET, text)
        self.assertNotIn('optionsWithIndex', text)
        bot = shaped['bots'][0]
        self.assertEqual(bot['player']['map'], list(live.map_point(3222, 3218)))
        self.assertEqual(bot['activity']['label'], 'mining copper-tin-sw-varrock · Fighting Goblin · Mining 4,200 XP/h')
        self.assertEqual(bot['activity']['anim']['action'], 'Mining')
        self.assertEqual(bot['activity']['motion'], {'state': 'still', 'tiles': 0})

    def test_shape_rejects_foreign_fields_names_and_tokens(self):
        raw = {'version': 1, 'password': SECRET, 'bots': [
            {'username': 'bot_ok', 'password': SECRET, 'status': 'active', 'inGame': True,
             'activity': {'routine': 'eval', 'args': ['$(rm -rf /)', 'ok-arg', SECRET + ' x']},
             'messages': ['fine', 7], 'player': {'x': 3222, 'z': 3218, 'hp': 'NaN'}},
            {'username': '<script>', 'status': 'active'},
            {'username': 'bot_two', 'status': 'hacked'},
        ]}
        shaped = live.shape_snapshot(raw, received_at=1)
        self.assertNotIn(SECRET, json.dumps(shaped))
        self.assertEqual([b['username'] for b in shaped['bots']], ['bot_ok', 'bot_two'])
        self.assertEqual(shaped['bots'][0]['activity']['args'], ['ok-arg'])
        self.assertIsNone(shaped['bots'][0]['player']['hp'])
        self.assertEqual(shaped['bots'][1]['status'], 'unknown')
        for bad in ({}, {'version': 2, 'bots': []}, [], {'version': 1, 'bots': {}}):
            with self.assertRaises(ValueError):
                live.shape_snapshot(bad)

    def test_activity_labels(self):
        offline = live.shape_bot({'username': 'bot_a', 'status': 'offline'})
        self.assertEqual(offline['activity']['label'], 'Offline')
        dead = live.shape_bot({'username': 'bot_a', 'status': 'active', 'inGame': True, 'player': {'x': 1, 'z': 1, 'isDead': True}})
        self.assertEqual(dead['activity']['label'], 'Dead (respawning)')
        anim = live.shape_bot({'username': 'bot_a', 'status': 'active', 'inGame': True, 'player': {'x': 1, 'z': 1, 'animId': 879},
                               'activity': {'dialog': True, 'focus': True}})
        self.assertEqual(anim['activity']['label'], 'Fleet focus: random-event investigation · Dialog open · Woodcutting')
        idle = live.shape_bot({'username': 'bot_a', 'status': 'active', 'inGame': True, 'player': {'x': 1, 'z': 1, 'animId': -1}})
        self.assertEqual(idle['activity']['label'], 'Idle')

    def test_routine_status_drives_the_label_and_detail(self):
        status = {'routine': 'mining', 'args': ['copper-tin-sw-varrock'], 'state': 'running', 'phase': 'mining tin',
                  'detail': '12 ore carried', 'phaseSince': 1, 'startedAt': 1, 'updatedAt': 2, 'password': SECRET,
                  'counts': {'trips': 3, 'oresBanked': 84, 'bad key': 1, 'x': SECRET}, 'lastEvent': {'kind': 'genie', 'at': 2}}
        bot = live.shape_bot({'username': 'bot_a', 'status': 'active', 'inGame': True, 'recentXp': {'Mining': 17},
                              'xpRate': {'Mining': 3100}, 'player': {'x': 1, 'z': 1, 'animId': -1},
                              'activity': {'routine': 'mining', 'status': status, 'anim': {'id': 625, 'ageMs': 2400},
                                           'motion': {'state': 'still', 'tiles': 0}}})
        self.assertNotIn(SECRET, json.dumps(bot))
        self.assertEqual(bot['activity']['status']['counts'], {'trips': 3, 'oresBanked': 84})
        self.assertEqual(bot['activity']['label'], 'mining: mining tin · Mining 3,100 XP/h')
        walking = live.shape_bot({'username': 'bot_a', 'status': 'active', 'inGame': True, 'player': {'x': 1, 'z': 1},
                                  'activity': {'status': dict(status, phase='walking to bank'), 'motion': {'state': 'running', 'tiles': 9},
                                               'levelUp': 'Mining', 'dialog': True}})
        self.assertEqual(walking['activity']['label'], 'Dismissing level-up (Mining) · mining: walking to bank · Running')
        ended = live.shape_bot({'username': 'bot_a', 'status': 'active', 'inGame': True, 'player': {'x': 1, 'z': 1},
                                'activity': {'status': dict(status, state='ended'), 'fleetTask': {'phase': 'starting client'}}})
        self.assertEqual(ended['activity']['label'], 'Fleet: starting client')
        bogus = live.shape_bot({'username': 'bot_a', 'status': 'active', 'inGame': True,
                                'activity': {'status': dict(status, state='hacked'), 'motion': {'state': 'flying'}}})
        self.assertIsNone(bogus['activity']['status'])
        self.assertIsNone(bogus['activity']['motion'])

    def test_publisher_reads_status_files_allowlisted_and_detects_dead_routines(self):
        with tempfile.TemporaryDirectory() as tmp:
            botting = Path(tmp)
            folder = botting / 'bot_journal/activity'
            folder.mkdir(parents=True)
            record = {'version': 1, 'source': 'routine', 'bot': 'bot_a', 'routine': 'mining', 'args': ['spot', '$(x)'],
                      'pid': 4242, 'state': 'running', 'phase': 'banking\n', 'detail': 'x' * 300, 'phaseSince': 999_000,
                      'startedAt': 900_000, 'updatedAt': 999_000, 'counts': {'trips': 2, 'nested': {'a': 1}},
                      'lastEvent': None, 'stopReason': None, 'token': SECRET}
            (folder / 'bot_a.json').write_text(json.dumps(record))
            local = {'routine': 'mining'}
            got = live_publish.routine_status(botting, 'bot_a', 1000.0, local, alive=lambda pid: pid == 4242)
            self.assertEqual((got['state'], got['phase'], got['args'], got['counts']), ('running', 'banking', ['spot'], {'trips': 2}))
            self.assertEqual(len(got['detail']), 80)
            self.assertNotIn(SECRET, json.dumps(got))
            self.assertEqual(live_publish.routine_status(botting, 'bot_a', 1000.0, local, alive=lambda pid: False)['state'], 'ended')
            self.assertEqual(live_publish.routine_status(botting, 'bot_a', 1000.0, {}, alive=lambda pid: True)['state'], 'ended')
            self.assertIsNone(live_publish.routine_status(botting, 'bot_b', 1000.0))
            self.assertIsNone(live_publish.routine_status(botting, 'bot_a', 1000.0 + 2 * 86400))
            (folder / 'bot_c.json').write_text(json.dumps(dict(record, bot='bot_a')))
            self.assertIsNone(live_publish.routine_status(botting, 'bot_c', 1000.0))
            (folder / 'bot_a.fleet.json').write_text(json.dumps({'version': 1, 'source': 'fleet', 'bot': 'bot_a',
                                                                 'phase': 'routine running', 'routine': 'mining', 'updatedAt': 999_000}))
            self.assertEqual(live_publish.fleet_task(botting, 'bot_a', 1000.0, True)['phase'], 'routine running')
            self.assertIsNone(live_publish.fleet_task(botting, 'bot_a', 1000.0, False))

    def test_motion_anim_memory_level_up_and_xp_rates(self):
        motion = live_publish.Motion()
        self.assertIsNone(motion.update('b', 3200, 3200, 0, 0.0))
        self.assertEqual(motion.update('b', 3203, 3201, 0, 3.0), {'state': 'walking', 'tiles': 3})
        self.assertEqual(motion.update('b', 3213, 3201, 0, 6.0), {'state': 'running', 'tiles': 10})
        self.assertEqual(motion.update('b', 3213, 3201, 0, 9.0)['state'], 'still')
        self.assertEqual(motion.update('b', 2964, 3378, 0, 12.0)['state'], 'teleported')
        self.assertEqual(motion.anim('b', 625, 0.0), {'id': 625, 'ageMs': 0})
        self.assertEqual(motion.anim('b', -1, 3.0), {'id': 625, 'ageMs': 3000})
        self.assertIsNone(motion.anim('b', -1, 20.0))
        state = {'skills': [{'name': 'Mining', 'baseLevel': 21}], 'dialog': {'isOpen': True, 'text': [], 'allComponents': [
            {'text': ''}, {'text': '@dbl@Congratulations, you just advanced a mining level.'}, {'text': 'Your mining level is now 21.'}]}}
        self.assertEqual(live_publish.level_up_skill(state), 'Mining')
        state['dialog']['allComponents'][1]['text'] = 'Congratulations, you just advanced a cheating level.'
        self.assertIsNone(live_publish.level_up_skill(state))
        xp = live_publish.XpTracker()
        skills = lambda n: [{'name': 'Mining', 'experience': n}]
        xp.update('b', skills(100), 0.0)
        xp.update('b', skills(110), 10.0)
        self.assertEqual(xp.rates('b', 10.0), {})          # under 30 s of history: no rate yet
        xp.update('b', skills(110), 70.0)
        self.assertEqual(xp.update('b', skills(160), 120.0), {'Mining': 50})
        self.assertEqual(xp.rates('b', 120.0), {'Mining': 1800})

    def test_player_animation_names(self):
        info = player_anims.anim_info
        self.assertEqual(info(625)['action'], 'Mining')
        self.assertEqual(info(879)['action'], 'Woodcutting')
        self.assertEqual(info(621)['action'], 'Fishing')
        self.assertEqual(info(897)['action'], 'Cooking')
        self.assertEqual(info(898)['action'], 'Smithing')
        self.assertEqual(info(733)['action'], 'Firemaking')
        self.assertEqual(info(422)['action'], 'Attacking')
        self.assertEqual(info(424)['action'], 'Blocking')
        self.assertEqual(info(714)['action'], 'Teleporting')
        self.assertEqual(info(824)['action'], 'Running')
        self.assertEqual(info(4000), {'id': 4000, 'name': None, 'action': 'Animation #4000', 'skill': None})
        self.assertIsNone(info(-1))
        self.assertIsNone(info(True))

    def test_receive_writes_shaped_snapshots_and_read_live_reports_staleness(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp)
            lines = b'not json\n' + json.dumps({'version': 1, 'intervalMs': 6000, 'password': SECRET,
                                                'bots': [{'username': 'bot_a', 'status': 'active'}]}).encode() + b'\n'
            self.assertEqual(live.receive(io.BytesIO(lines), target, clock=lambda: 1000.0), 1)
            data = (target / 'live.json').read_text()
            self.assertNotIn(SECRET, data)
            fresh = live.read_live(target / 'live.json', now_ms=1_005_000, accounts=['bot_a', 'bot_b'])
            self.assertTrue(fresh['available'])
            self.assertFalse(fresh['stale'])
            self.assertEqual(fresh['ageMs'], 5000)
            self.assertEqual([b['username'] for b in fresh['bots']], ['bot_a', 'bot_b'])
            self.assertEqual(fresh['bots'][1]['status'], 'offline')
            old = live.read_live(target / 'live.json', now_ms=1_060_000, ticks=20)
            self.assertTrue(old['stale'])
            self.assertEqual(old['refreshMs'], 12000)
            self.assertIn('publisher may be offline', old['error'])
            self.assertTrue(old['bots'][0]['activity']['label'].startswith('Unknown (stale snapshot)'))
            missing = live.read_live(target / 'nothing.json', accounts=['bot_a'])
            self.assertFalse(missing['available'])
            self.assertEqual(missing['bots'][0]['activity']['label'], 'Offline')

    def test_process_parsing_keeps_routines_and_drops_private_args(self):
        ps = '\n'.join([
            'bun --env-file=/u/rs-sdk-fork/bots/bot_hoofs/bot.env /u/2004Scape-Botting/routines/mining.ts copper-tin-sw-varrock 180',
            'bun --env-file=/u/rs-sdk-fork/bots/bot_hoofs/bot.env /u/2004Scape-Botting/routines/watch.ts',
            'bun --env-file=/u/rs-sdk-fork/bots/bot_reface/bot.env /u/2004Scape-Botting/routines/eval.ts "await bot.secret()"',
            'bun src/lite/runner.ts bot_hoofs',
        ])
        found = live_publish.parse_processes(ps)
        self.assertEqual(found['bot_hoofs'], {'routine': 'mining', 'args': ['copper-tin-sw-varrock', '180'], 'watcher': True, 'client': True})
        self.assertEqual(found['bot_reface'], {'routine': 'eval', 'args': []})


class LiveHTTPTests(unittest.TestCase):
    def test_live_routes_and_csp(self):
        import server
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        snapshot = Path(tmp.name) / 'live.json'
        live.write_atomic(Path(tmp.name), live.shape_snapshot({'version': 1, 'bots': [{'username': 'bot_a', 'status': 'active'}]}, received_at=1))
        http = server.PortalHTTPServer(('127.0.0.1', 0), server.Handler)
        self.addCleanup(http.server_close)
        http.portal = server.Portal(Path('/nonexistent'), 'https://game.example', 'https://home.example', live_path=snapshot)
        http.assets_dir = Path(tmp.name)
        (http.assets_dir / 'worldmap.json').write_text('{"width":1}')
        threading.Thread(target=http.serve_forever, daemon=True).start()
        self.addCleanup(http.shutdown)
        base = f'http://127.0.0.1:{http.server_port}'
        with urlopen(base + '/rs-sdk/live-map?ticks=20') as response:
            body = response.read().decode()
            csp = response.headers['Content-Security-Policy']
        self.assertIn("script-src 'self'", csp)
        self.assertIn("connect-src 'self'", csp)
        self.assertIn('data-refresh-ms="12000"', body)
        self.assertIn('src="/rs-sdk/live-map.js"', body)
        self.assertNotIn('<script>', body)
        for path in ('/rs-sdk/', '/rs-sdk/benchmarks'):
            try:
                response = urlopen(base + path)
            except HTTPError as error:
                response = error
            with response:
                self.assertNotIn('script-src', response.headers['Content-Security-Policy'])
        with urlopen(base + '/rs-sdk/', timeout=5) as response:
            self.assertIn('href="/rs-sdk/live-map"', response.read().decode())
        with urlopen(base + '/rs-sdk/api/live') as response:
            payload = json.loads(response.read())
            self.assertEqual(response.headers['Content-Type'], 'application/json')
        self.assertEqual(payload['ticks'], 10)
        self.assertEqual(payload['bots'][0]['username'], 'bot_a')
        with urlopen(base + '/rs-sdk/live-map.js') as response:
            self.assertIn('text/javascript', response.headers['Content-Type'])
        with urlopen(base + '/rs-sdk/assets/worldmap.json') as response:
            self.assertEqual(json.loads(response.read()), {'width': 1})
        for path in ('/rs-sdk/api/live?ticks=0', '/rs-sdk/live-map?ticks=abc'):
            with self.assertRaises(HTTPError) as caught:
                urlopen(base + path)
            self.assertEqual(caught.exception.code, 400)
            caught.exception.close()
        with self.assertRaises(HTTPError) as caught:
            urlopen(base + '/rs-sdk/assets/worldmap.png')
        self.assertEqual(caught.exception.code, 404)
        caught.exception.close()


class WorldmapTests(unittest.TestCase):
    def test_jag_hash_and_png_container(self):
        self.assertEqual(worldmap.jag_hash('floorcol.dat'), worldmap.jag_hash('FLOORCOL.DAT'))
        data = worldmap.png(2, 1, [bytearray(b'\x00\x00\x00\xff\xff\xff')])
        self.assertTrue(data.startswith(b'\x89PNG\r\n\x1a\n'))
        self.assertTrue(data.endswith(b'IEND\xaeB`\x82'))


if __name__ == '__main__':
    unittest.main()
