#!/usr/bin/env python3
"""Publish the bot fleet's live state to the portal's live map (runs on the bot workstation).

Every N game ticks (default 5 = ~3 s; never faster, to keep the gateway at no
more than one request per bot per 3 s) this:

1. asks the gateway's unauthenticated GET /status which bots are connected, and
   the game web server's unauthenticated GET /playerpositions who is actually in
   the world (one request each per period), and the fleet service which activity
   cards the other bot hosts pushed (read-only token, at most every 5 s);
2. for each connected bot, reads GET /state/<bot> with that bot's own SDK
   credentials from <sdk>/bots/<bot>/bot.env (sent as a Bearer header; a plain
   HTTP read - no WebSocket session, no observer/controller, no actions);
3. reduces each frame to an allowlist (position, HP, skills, inventory,
   equipment, combat, a few system messages), adds activity from local routine
   processes, the routines' own status files (bot_journal/activity/<bot>.json,
   written by routines/lib/activity-status.ts), the fleet supervisor's state, and
   what successive frames show (recent animation, movement, XP rates), and
4. classifies every account's presence: 'controlled' (in the world with an SDK
   client connected), 'ghost' (in the world but no SDK client: the gateway says
   dead/absent - shown with its live world position and the last controlled
   snapshot's stats, marked last-known), 'offline', or 'unknown' (the world list
   was unreachable, so a disconnected bot may or may not be in the world);
   other players in the world (humans) are published by name and position only;
5. writes one JSON line to stdout, or (with --host) streams it over one
   persistent SSH connection into the portal receiver (live.py receive).

Credentials never leave this machine: they are only used in the request
headers to the gateway and are not part of any snapshot.
Python 3.9 compatible (macOS /usr/bin/python3).
"""
import argparse
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

TICK_MS = 600
MIN_TICKS = 5
DEFAULT_TICKS = 5
ROUTINE = re.compile(r'--env-file=\S*/bots/([A-Za-z0-9_-]{1,12})/bot\.env\s+\S*/routines/([A-Za-z0-9_.-]{1,40})\.ts\b(.*)')
RUNNER = re.compile(r'src/lite/runner\.ts\s+([A-Za-z0-9_-]{1,12})\b')
TOKEN = re.compile(r'^[A-Za-z0-9_.:+-]{1,40}$')
OBSERVERS = {'watch', 'listen'}
XP_WINDOW_S = 60.0
XP_RATE_WINDOW_S = 300.0
XP_RATE_MIN_SPAN_S = 30.0
ANIM_MEMORY_S = 15.0
STATUS_MAX_AGE_S = 24 * 3600
STATUS_MAX_BYTES = 65536
STATUS_STATES = {'running', 'finished', 'failed'}
COUNT_KEY = re.compile(r'^[A-Za-z][A-Za-z0-9_]{0,23}$')
WORLD_NAME = re.compile(r'^[A-Za-z0-9_ -]{1,12}$')
MAX_WORLD_PLAYERS = 2000
LAST_GOOD_KEYS = ('displayName', 'tick', 'player', 'skills', 'inventory', 'equipment')
FLEET_URL = 'https://<game-server>.<tailnet>.ts.net:9447'
REMOTE_POLL_S = 5.0
REMOTE_MAX_AGE_S = 60.0
LEVEL_UP = re.compile(r'^(?:@\w{3}@)?Congratulations, you just advanced (?:a|an) ([a-z]+(?: [a-z]+)?) level\.$')


def read_env(path):
    env = {}
    for line in path.read_text().splitlines():
        text = line.strip()
        if text and not text.startswith('#') and '=' in text:
            key, value = text.split('=', 1)
            env[key.strip()] = value.strip()
    return env


def http_base(url):
    return re.sub(r'^ws(s?)://', r'http\1://', url).rstrip('/')


def get_json(url, headers=None, timeout=5.0):
    request = urllib.request.Request(url, headers=headers or {})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, json.loads(response.read(8 * 1024 * 1024))
    except urllib.error.HTTPError as exc:
        try:
            return exc.code, json.loads(exc.read(65536))
        except ValueError:
            return exc.code, None


def norm_name(name):
    """Account/display name key: 'bot_moondrop', 'Bot Moondrop' and 'bot  moondrop' all match."""
    return re.sub(r'[\s_]+', ' ', name).strip().lower() if isinstance(name, str) else ''


def world_url(bots, override=None):
    """The game web server's base URL (SERVER=host:port from the bots' bot.env, served over HTTPS)."""
    if override:
        return override.rstrip('/')
    server = next((env['SERVER'] for env in bots.values() if env.get('SERVER')), None)
    if not server:
        return None
    return server.rstrip('/') if re.match(r'^https?://', server) else 'https://' + server.rstrip('/')


def world_players(base, fetch=None):
    """(players, error): everyone in the game world from GET /playerpositions, or (None, reason)."""
    if not base:
        return None, 'no game web server configured (SERVER= in bot.env or --world)'
    try:
        code, body = (fetch or get_json)(base + '/playerpositions')
    except (OSError, ValueError) as exc:
        return None, f'/playerpositions unreachable ({exc.__class__.__name__})'
    if code != 200 or not isinstance(body, list):
        return None, f'/playerpositions answered HTTP {code}'
    players = []
    for item in body[:MAX_WORLD_PLAYERS]:
        if isinstance(item, dict) and isinstance(item.get('name'), str) and WORLD_NAME.match(item['name']):
            players.append({'name': item['name'], 'x': item.get('x'), 'z': item.get('z'), 'level': item.get('level')})
    return players, None


def processes():
    """Local routine/client processes by bot: {bot: {'routine', 'args', 'client', 'watcher'}}."""
    try:
        out = subprocess.run(['ps', '-axo', 'command='], capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return {}
    return parse_processes(out)


def parse_processes(text):
    found = {}
    for line in text.splitlines():
        match = ROUTINE.search(line)
        if match:
            bot, routine, rest = match.groups()
            entry = found.setdefault(bot, {})
            if routine in OBSERVERS:
                entry['watcher'] = True
                continue
            try:
                words = shlex.split(rest)
            except ValueError:
                words = []
            # eval snippets and anything odd stay private: keep only short plain tokens
            entry['routine'] = routine
            entry['args'] = [] if routine == 'eval' else [w for w in words if TOKEN.match(w)][:6]
            continue
        match = RUNNER.search(line)
        if match:
            found.setdefault(match.group(1), {})['client'] = True
    return found


def fleet_state(botting):
    """Whether the fleet supervisor holds its lock, and which bot an event latch focused on."""
    state_dir = botting / 'bot_journal/fleet-state'
    running = False
    try:
        pid = int((state_dir / 'manager.lock').read_text().strip() or 0)
        if pid > 0:
            os.kill(pid, 0)
            running = True
    except (OSError, ValueError):
        pass
    focus = None
    try:
        data = json.loads((state_dir / 'focus.json').read_text())
        if isinstance(data, dict) and isinstance(data.get('focus'), str):
            focus = data['focus']
    except (OSError, ValueError):
        pass
    return {'running': running, 'focus': focus}


class XpTracker:
    """Per-skill XP gained in the last minute, and XP/hour over the last five minutes."""
    def __init__(self, window=XP_WINDOW_S, rate_window=XP_RATE_WINDOW_S):
        self.window, self.rate_window = window, rate_window
        self.history = {}

    def update(self, bot, skills, now):
        current = {s.get('name'): s.get('experience') for s in skills
                   if isinstance(s, dict) and isinstance(s.get('experience'), (int, float))}
        samples = [entry for entry in self.history.get(bot, []) if now - entry[0] <= self.rate_window]
        samples.append((now, current))
        self.history[bot] = samples
        oldest = next(values for at, values in samples if now - at <= self.window)
        return {name: int(xp - oldest[name]) for name, xp in current.items()
                if name in oldest and xp > oldest[name]}

    def rates(self, bot, now):
        """{skill: XP per hour} over the rate window, once it spans at least 30 s."""
        samples = self.history.get(bot) or []
        if len(samples) < 2 or now - samples[0][0] < XP_RATE_MIN_SPAN_S:
            return {}
        (start, oldest), (_, current) = samples[0], samples[-1]
        span = max(now - start, XP_RATE_MIN_SPAN_S)
        return {name: int(round((xp - oldest[name]) * 3600 / span)) for name, xp in current.items()
                if name in oldest and xp > oldest[name]}


class Motion:
    """Movement between successive frames: still / walking / running / teleported, plus recent animation."""
    def __init__(self):
        self.last = {}
        self.anims = {}

    def update(self, bot, x, z, level, now):
        prev = self.last.get(bot)
        self.last[bot] = (x, z, level, now)
        if prev is None or not all(isinstance(v, int) for v in (x, z, prev[0], prev[1])):
            return None
        ticks = max(1.0, (now - prev[3]) / (TICK_MS / 1000.0))
        tiles = max(abs(x - prev[0]), abs(z - prev[1]))
        if level != prev[2] or tiles > 2 * ticks + 3:
            state = 'teleported'
        elif tiles == 0:
            state = 'still'
        else:
            state = 'running' if tiles / ticks > 1.3 else 'walking'
        return {'state': state, 'tiles': tiles}

    def anim(self, bot, anim_id, now):
        """The current animation, or the last one seen within ANIM_MEMORY_S (with its age)."""
        if isinstance(anim_id, int) and not isinstance(anim_id, bool) and anim_id >= 0:
            self.anims[bot] = (anim_id, now)
        seen = self.anims.get(bot)
        if seen and now - seen[1] <= ANIM_MEMORY_S:
            return {'id': seen[0], 'ageMs': int((now - seen[1]) * 1000)}
        return None


def _clean(value, limit):
    if not isinstance(value, str):
        return None
    text = re.sub(r'\s+', ' ', ''.join(ch if ch.isprintable() else ' ' for ch in value)).strip()[:limit]
    return text or None


def _ms(value):
    return int(value) if isinstance(value, (int, float)) and not isinstance(value, bool) and 0 <= value < 1 << 53 else None


def _pid_alive(pid):
    if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 1:
        return False
    try:
        os.kill(pid, 0)
        return True
    except PermissionError:
        return True
    except OSError:
        return False


def _read_json(path):
    try:
        with open(path, 'rb') as stream:
            data = stream.read(STATUS_MAX_BYTES + 1)
        if len(data) > STATUS_MAX_BYTES:
            return None
        value = json.loads(data)
        return value if isinstance(value, dict) else None
    except (OSError, ValueError):
        return None


def routine_status(botting, username, now, local=None, alive=_pid_alive):
    """Allowlisted copy of the routine's own status file, or None (missing, foreign or too old).

    A 'running' status whose process is gone (or whose bot has no routine process
    left) is reported as state 'ended'."""
    raw = _read_json(botting / 'bot_journal/activity' / f'{username}.json')
    if not raw:
        return None
    return status_from_raw(raw, username, now, lambda: alive(raw.get('pid')) and bool((local or {}).get('routine')))


def status_from_raw(raw, username, now, running_alive):
    """Allowlisted status from a routine status record (local file or a card pushed by another host).

    running_alive() says whether a 'running' routine still runs; if not the state is 'ended'."""
    if not isinstance(raw, dict) or raw.get('version') != 1 or raw.get('bot') != username:
        return None
    updated = _ms(raw.get('updatedAt'))
    if updated is None or now * 1000 - updated > STATUS_MAX_AGE_S * 1000:
        return None
    state = raw.get('state') if raw.get('state') in STATUS_STATES else None
    if state is None:
        return None
    if state == 'running' and not running_alive():
        state = 'ended'
    counts = {}
    if isinstance(raw.get('counts'), dict):
        for key, value in list(raw['counts'].items())[:12]:
            if isinstance(key, str) and COUNT_KEY.match(key) and isinstance(value, (int, float)) and not isinstance(value, bool):
                counts[key] = value
    event = raw.get('lastEvent') if isinstance(raw.get('lastEvent'), dict) else {}
    args = raw.get('args') if isinstance(raw.get('args'), list) else []
    return {
        'routine': raw.get('routine') if isinstance(raw.get('routine'), str) and TOKEN.match(raw['routine']) else None,
        'args': [a for a in args if isinstance(a, str) and TOKEN.match(a)][:6],
        'state': state, 'phase': _clean(raw.get('phase'), 60), 'detail': _clean(raw.get('detail'), 80),
        'phaseSince': _ms(raw.get('phaseSince')), 'startedAt': _ms(raw.get('startedAt')), 'updatedAt': updated,
        'counts': counts, 'stopReason': _clean(raw.get('stopReason'), 80),
        'lastEvent': {'kind': _clean(event.get('kind'), 40), 'at': _ms(event.get('at'))} if _clean(event.get('kind'), 40) else None,
    }


class RemoteCards:
    """Activity cards that the other bot hosts push to the fleet service (cutover step 8).

    The other bot hosts run `bun tools/fleet-service.ts activity-push`, which stores each routine's
    status record as the doc activity/<bot>: {card, host, pushedAt (ms), alive}. Read with the
    portal's read-only token (GET /v1/docs/activity), at most once per poll period; the token is
    only sent in the request header, never published."""

    def __init__(self, url, token, fetch=None, poll_s=REMOTE_POLL_S):
        self.url, self.token, self.fetch, self.poll_s = url.rstrip('/'), token, fetch or get_json, poll_s
        self.cached, self.at = {}, None

    def cards(self, now):
        if self.at is not None and now - self.at < self.poll_s:
            return self.cached
        self.at = now
        try:
            code, body = self.fetch(self.url + '/v1/docs/activity', {'Authorization': 'Bearer ' + self.token})
        except (OSError, ValueError):
            return self.cached   # pushedAt ages out on its own
        if code == 200 and isinstance(body, dict) and isinstance(body.get('docs'), list):
            self.cached = {d['name']: d['body'] for d in body['docs'][:500]
                           if isinstance(d, dict) and isinstance(d.get('name'), str) and isinstance(d.get('body'), dict)}
        return self.cached


def remote_status(pushed, username, now):
    """(status, processes) from a card pushed by another host, or (None, {}).

    The card's routine counts as running only while that host keeps pushing (REMOTE_MAX_AGE_S)
    and says its process is alive."""
    pushed_at = _ms(pushed.get('pushedAt')) if isinstance(pushed, dict) else None
    if pushed_at is None:
        return None, {}
    alive = now * 1000 - pushed_at <= REMOTE_MAX_AGE_S * 1000 and pushed.get('alive') is True
    status = status_from_raw(pushed.get('card'), username, now, lambda: alive)
    if not status:
        return None, {}
    return status, ({'routine': status['routine'], 'args': status['args']} if alive and status['routine'] else {})


def fleet_task(botting, username, now, fleet_running):
    """The fleet supervisor's lifecycle phase for this bot, while a supervisor holds the lock."""
    if not fleet_running:
        return None
    raw = _read_json(botting / 'bot_journal/activity' / f'{username}.fleet.json')
    if not raw or raw.get('version') != 1 or raw.get('bot') != username or raw.get('source') != 'fleet':
        return None
    updated = _ms(raw.get('updatedAt'))
    if updated is None or now * 1000 - updated > STATUS_MAX_AGE_S * 1000 or not _clean(raw.get('phase'), 60):
        return None
    routine = raw.get('routine')
    return {'phase': _clean(raw.get('phase'), 60), 'detail': _clean(raw.get('detail'), 80), 'updatedAt': updated,
            'routine': routine if isinstance(routine, str) and TOKEN.match(routine) else None}


def level_up_skill(state):
    """Skill named by an open level-up dialog ('Mining'), checked against the frame's skills; else None."""
    dialog = state.get('dialog') if isinstance(state.get('dialog'), dict) else {}
    if dialog.get('isOpen') is not True:
        return None
    texts = [c.get('text') for c in dialog.get('allComponents') or [] if isinstance(c, dict)]
    texts += dialog.get('text') if isinstance(dialog.get('text'), list) else [dialog.get('text')]
    names = {s.get('name').lower(): s.get('name') for s in state.get('skills') or []
             if isinstance(s, dict) and isinstance(s.get('name'), str)}
    for text in texts:
        match = LEVEL_UP.match(text.strip()) if isinstance(text, str) else None
        if match and match.group(1) in names:
            return names[match.group(1)]
    return None


def reduce_state(username, state, meta, local, xp, now, focus=None, motion=None, status=None, fleet_task=None):
    """The allowlisted bot entry the portal accepts (see live.shape_bot)."""
    entry = {'username': username, 'status': meta.get('botStatus') or 'unknown',
             'stateAge': meta.get('stateAge'), 'activity': dict(local or {})}
    entry['activity']['focus'] = focus == username
    entry['activity']['status'] = status
    entry['activity']['fleetTask'] = fleet_task
    if not isinstance(state, dict):
        return entry
    player = state.get('player') if isinstance(state.get('player'), dict) else {}
    combat = player.get('combat') if isinstance(player.get('combat'), dict) else {}
    target = None
    if combat.get('targetType') == 'npc':
        for npc in state.get('nearbyNpcs') or []:
            if isinstance(npc, dict) and npc.get('index') == combat.get('targetIndex'):
                target = npc.get('name')
                break
    entry.update({
        'displayName': player.get('name'), 'inGame': state.get('inGame') is True, 'tick': state.get('tick'),
        'player': {'x': player.get('worldX'), 'z': player.get('worldZ'), 'level': player.get('level'),
                   'hp': player.get('hp'), 'maxHp': player.get('maxHp'), 'combatLevel': player.get('combatLevel'),
                   'runEnergy': player.get('runEnergy'), 'animId': player.get('animId'),
                   'inCombat': combat.get('inCombat') is True, 'target': target, 'isDead': player.get('isDead') is True},
        'skills': [{k: s.get(k) for k in ('name', 'level', 'baseLevel', 'experience')}
                   for s in state.get('skills') or [] if isinstance(s, dict)],
        'inventory': [{k: i.get(k) for k in ('slot', 'id', 'name', 'count')} for i in state.get('inventory') or [] if isinstance(i, dict)],
        'equipment': [{k: i.get(k) for k in ('slot', 'id', 'name', 'count')} for i in state.get('equipment') or [] if isinstance(i, dict)],
        'recentXp': xp.update(username, state.get('skills') or [], now),
        'xpRate': xp.rates(username, now),
    })
    motion = motion or Motion()
    entry['activity']['motion'] = motion.update(username, player.get('worldX'), player.get('worldZ'), player.get('level'), now)
    entry['activity']['anim'] = motion.anim(username, player.get('animId'), now)
    tick = state.get('tick') if isinstance(state.get('tick'), int) else 0
    # system messages only (type 0, no sender): never relay other players' chat
    entry['messages'] = [m.get('text') for m in (state.get('gameMessages') or [])
                         if isinstance(m, dict) and m.get('type') == 0 and not m.get('sender')
                         and isinstance(m.get('tick'), int) and tick - m['tick'] <= 100][-3:]
    dialog = state.get('dialog') if isinstance(state.get('dialog'), dict) else {}
    entry['activity']['dialog'] = dialog.get('isOpen') is True
    entry['activity']['modal'] = state.get('modalOpen') is True
    entry['activity']['levelUp'] = level_up_skill(state)
    return entry


class Publisher:
    def __init__(self, sdk, botting, ticks, gateway=None, world=None, cache=None, fetch=None, remote=None):
        self.sdk, self.botting, self.ticks = sdk, botting, ticks
        self.remote = remote
        self.gateway, self.world = gateway, world
        self.fetch = fetch or get_json
        self.xp = XpTracker()
        self.motion = Motion()
        # Last controlled snapshot per bot (allowlisted fields only, never credentials),
        # persisted so a ghost still shows its last-known stats after a publisher restart.
        self.cache = cache
        self.last_good = self._load_cache()
        self.cache_saved = 0.0

    def _load_cache(self):
        if not self.cache:
            return {}
        try:
            data = json.loads(self.cache.read_text()) if self.cache.stat().st_size < 4 * 1024 * 1024 else None
        except (OSError, ValueError):
            data = None
        if not isinstance(data, dict) or data.get('version') != 1 or not isinstance(data.get('bots'), dict):
            return {}
        return {name: entry for name, entry in data['bots'].items()
                if isinstance(entry, dict) and isinstance(entry.get('at'), (int, float))}

    def _save_cache(self, now):
        if not self.cache or now - self.cache_saved < 60:
            return
        self.cache_saved = now
        try:
            self.cache.parent.mkdir(parents=True, exist_ok=True)
            tmp = self.cache.with_suffix('.tmp')
            tmp.write_text(json.dumps({'version': 1, 'bots': self.last_good}, separators=(',', ':')))
            os.chmod(tmp, 0o600)
            os.replace(tmp, self.cache)
        except OSError:
            pass

    def bots(self):
        found = {}
        for env_file in sorted((self.sdk / 'bots').glob('*/bot.env')):
            if env_file.parent.name.startswith('_'):
                continue
            try:
                env = read_env(env_file)
            except OSError:
                continue
            if env.get('BOT_USERNAME') and env.get('PASSWORD'):
                found[env['BOT_USERNAME']] = env
        return found

    def snapshot(self):
        now = time.time()
        bots = self.bots()
        gateway = self.gateway or next((http_base(env['GATEWAY_URL']) for env in bots.values() if env.get('GATEWAY_URL')), None)
        players, world_error = world_players(world_url(bots, self.world), self.fetch)
        in_world = {norm_name(p['name']): p for p in players or []}
        statuses, gateway_ok = {}, False
        if gateway:
            try:
                code, body = self.fetch(gateway + '/status')
                if code == 200 and isinstance(body, dict) and isinstance(body.get('bots'), dict):
                    statuses, gateway_ok = body['bots'], True
            except (OSError, ValueError):
                pass
        local = processes()
        fleet = fleet_state(self.botting)
        remote_cards = self.remote.cards(now) if self.remote else {}
        entries = []
        for username, env in bots.items():
            status = (statuses.get(username) or {}).get('status')
            meta, state = {'botStatus': status or ('offline' if gateway_ok else 'unknown')}, None
            if gateway_ok and status and status != 'dead':
                try:
                    code, body = self.fetch(gateway + '/state/' + urllib.parse.quote(username),
                                          {'Authorization': 'Bearer ' + env['PASSWORD']})
                    if code == 200 and isinstance(body, dict):
                        meta = {'botStatus': body.get('botStatus') or status, 'stateAge': body.get('stateAge')}
                        state = body.get('state')
                except (OSError, ValueError):
                    meta['botStatus'] = 'unknown'
            if meta['botStatus'] == 'dead':
                meta['botStatus'] = 'offline'
            procs = local.get(username)
            status = routine_status(self.botting, username, now, procs)
            pushed = remote_cards.get(username)
            if pushed:
                # A bot run by another host: its card wins when it is newer than this host's file.
                r_status, r_procs = remote_status(pushed, username, now)
                if r_status and (status is None or (r_status['updatedAt'] or 0) > (status['updatedAt'] or 0)):
                    status, procs = r_status, dict(procs or {}, **r_procs)
            entry = reduce_state(username, state, meta, procs, self.xp, now, fleet['focus'], self.motion, status,
                                 fleet_task(self.botting, username, now, fleet['running']))
            entries.append(self.classify(entry, in_world, players is not None, now))
        claimed = {norm_name(name) for entry in entries for name in (entry['username'], entry.get('displayName'))}
        others = [p for p in players or [] if norm_name(p['name']) not in claimed]
        self._save_cache(now)
        return {'version': 1, 'publishedAt': int(now * 1000), 'intervalMs': self.ticks * TICK_MS,
                'gatewayOk': gateway_ok, 'fleet': fleet, 'bots': entries,
                'world': {'ok': players is not None, 'error': world_error,
                          'count': len(players) if players is not None else None, 'others': others}}

    def classify(self, entry, in_world, world_ok, now):
        """Set entry['presence'] from the world list + gateway; ghosts get world position + last-known stats."""
        username = entry['username']
        client = entry['status'] in ('active', 'stale')
        known = self.last_good.get(username)
        names = [username, entry.get('displayName'), (known or {}).get('displayName')]
        seen = next((in_world[norm_name(n)] for n in names if n and norm_name(n) in in_world), None)
        if client and not entry.get('inGame') and not (seen and world_ok):
            entry['presence'] = 'offline'   # client running, not (yet) in game
            return entry
        if client:
            entry['presence'] = 'controlled'
            if entry.get('inGame'):
                self.last_good[username] = dict({k: entry.get(k) for k in LAST_GOOD_KEYS}, at=int(now * 1000))
            if seen and (entry.get('player') or {}).get('x') is None:
                entry['player'] = dict(entry.get('player') or {}, x=seen['x'], z=seen['z'], level=seen['level'])
            return entry
        if not world_ok:
            entry['presence'] = 'unknown'
            return entry
        if not seen:
            entry['presence'] = 'offline'
            return entry
        entry['presence'] = 'ghost'
        entry['inGame'] = True
        if known:
            for key in ('displayName', 'skills', 'inventory', 'equipment'):
                if not entry.get(key):
                    entry[key] = known.get(key)
            entry['lastKnownAt'] = known['at']
        player = dict((known or {}).get('player') or {})
        # Live data for a ghost is only its position; everything else is last-known.
        for key in ('animId', 'inCombat', 'target', 'runEnergy'):
            player.pop(key, None)
        player.update(x=seen['x'], z=seen['z'], level=seen['level'])
        entry['player'] = player
        entry['displayName'] = entry.get('displayName') or seen['name']
        return entry

    def run(self, sink, once=False):
        period = self.ticks * TICK_MS / 1000.0
        while True:
            started = time.monotonic()
            line = json.dumps(self.snapshot(), separators=(',', ':')) + '\n'
            sink(line)
            if once:
                return
            time.sleep(max(0.5, period - (time.monotonic() - started)))


def ssh_sink_factory(host, receiver):
    command = ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8', '-o', 'ServerAliveInterval=15',
               '-o', 'ServerAliveCountMax=3', '--', host, 'python3 ' + shlex.quote(receiver) + ' receive']
    state = {'proc': None}

    def sink(line):
        proc = state['proc']
        if proc is None or proc.poll() is not None:
            proc = state['proc'] = subprocess.Popen(command, stdin=subprocess.PIPE)
        try:
            proc.stdin.write(line.encode())
            proc.stdin.flush()
        except (BrokenPipeError, OSError):
            proc.kill()
            state['proc'] = None
            raise
    return sink


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--ticks', type=int, default=DEFAULT_TICKS,
                        help=f'Publish period in game ticks (600 ms each; default and minimum {MIN_TICKS})')
    parser.add_argument('--sdk', type=Path, default=Path.home() / 'github/rs-sdk-fork')
    parser.add_argument('--botting', type=Path, default=Path.home() / 'forgejo/2004Scape-Botting')
    parser.add_argument('--gateway', help='Gateway HTTP base URL (default: GATEWAY_URL from the bots\' bot.env)')
    parser.add_argument('--world', help='Game web server base URL for /playerpositions (default: https:// + SERVER from the bots\' bot.env)')
    parser.add_argument('--cache', type=Path, default=Path.home() / 'Library/Caches/computer-setup/rs-sdk-portal-live.json',
                        help='Last controlled snapshot per bot (allowlisted, no credentials), so ghosts keep last-known stats')
    parser.add_argument('--host', help='SSH alias of the game server; omit to print snapshots to stdout')
    parser.add_argument('--receiver', default='github/Computer-Setup/linux-game-server/rs-sdk/portal/live.py')
    parser.add_argument('--once', action='store_true', help='Publish one snapshot and exit')
    parser.add_argument('--fleet-url', default=FLEET_URL, help='Fleet service base URL (activity cards pushed by other bot hosts)')
    parser.add_argument('--fleet-token-file', type=Path, default=Path.home() / '.config/rs-fleet/portal-token',
                        help='Read-only fleet service token (portal:ro); missing = no cards from other hosts')
    args = parser.parse_args()
    if args.ticks < MIN_TICKS:
        parser.error(f'--ticks must be at least {MIN_TICKS} (one gateway request per bot per {MIN_TICKS * TICK_MS / 1000:g} s at most)')
    remote = None
    try:
        token = args.fleet_token_file.expanduser().read_text().strip()
        remote = RemoteCards(args.fleet_url, token) if token else None
    except OSError:
        pass
    publisher = Publisher(args.sdk.expanduser(), args.botting.expanduser(), args.ticks,
                          http_base(args.gateway) if args.gateway else None, args.world,
                          args.cache.expanduser() if args.cache else None, remote=remote)
    if not args.host:
        publisher.run(lambda line: (sys.stdout.write(line), sys.stdout.flush()), once=args.once)
        return
    sink = ssh_sink_factory(args.host, args.receiver)
    while True:
        try:
            publisher.run(sink, once=args.once)
            return
        except (BrokenPipeError, OSError) as exc:
            print(f'live publish: receiver connection lost ({exc.__class__.__name__}); retrying in 10 s',
                  file=sys.stderr, flush=True)
            time.sleep(10)


if __name__ == '__main__':
    main()
