#!/usr/bin/env python3
"""Publish the bot fleet's live state to the portal's live map (runs on the bot workstation).

Every N game ticks (default 5 = ~3 s; never faster, to keep the gateway at no
more than one request per bot per 3 s) this:

1. asks the gateway's unauthenticated GET /status which bots are connected;
2. for each connected bot, reads GET /state/<bot> with that bot's own SDK
   credentials from <sdk>/bots/<bot>/bot.env (sent as a Bearer header; a plain
   HTTP read - no WebSocket session, no observer/controller, no actions);
3. reduces each frame to an allowlist (position, HP, skills, inventory,
   equipment, combat, a few system messages), adds activity from local routine
   processes, the routines' own status files (bot_journal/activity/<bot>.json,
   written by routines/lib/activity-status.ts), the fleet supervisor's state, and
   what successive frames show (recent animation, movement, XP rates), and
4. writes one JSON line to stdout, or (with --host) streams it over one
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
    if not raw or raw.get('version') != 1 or raw.get('bot') != username:
        return None
    updated = _ms(raw.get('updatedAt'))
    if updated is None or now * 1000 - updated > STATUS_MAX_AGE_S * 1000:
        return None
    state = raw.get('state') if raw.get('state') in STATUS_STATES else None
    if state is None:
        return None
    if state == 'running' and (not alive(raw.get('pid')) or not (local or {}).get('routine')):
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
    def __init__(self, sdk, botting, ticks, gateway=None):
        self.sdk, self.botting, self.ticks = sdk, botting, ticks
        self.gateway = gateway
        self.xp = XpTracker()
        self.motion = Motion()

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
        statuses, gateway_ok = {}, False
        if gateway:
            try:
                code, body = get_json(gateway + '/status')
                if code == 200 and isinstance(body, dict) and isinstance(body.get('bots'), dict):
                    statuses, gateway_ok = body['bots'], True
            except (OSError, ValueError):
                pass
        local = processes()
        fleet = fleet_state(self.botting)
        entries = []
        for username, env in bots.items():
            status = (statuses.get(username) or {}).get('status')
            meta, state = {'botStatus': status or ('offline' if gateway_ok else 'unknown')}, None
            if gateway_ok and status and status != 'dead':
                try:
                    code, body = get_json(gateway + '/state/' + urllib.parse.quote(username),
                                          {'Authorization': 'Bearer ' + env['PASSWORD']})
                    if code == 200 and isinstance(body, dict):
                        meta = {'botStatus': body.get('botStatus') or status, 'stateAge': body.get('stateAge')}
                        state = body.get('state')
                except (OSError, ValueError):
                    meta['botStatus'] = 'unknown'
            if meta['botStatus'] == 'dead':
                meta['botStatus'] = 'offline'
            entries.append(reduce_state(username, state, meta, local.get(username), self.xp, now, fleet['focus'], self.motion,
                                        routine_status(self.botting, username, now, local.get(username)),
                                        fleet_task(self.botting, username, now, fleet['running'])))
        return {'version': 1, 'publishedAt': int(now * 1000), 'intervalMs': self.ticks * TICK_MS,
                'gatewayOk': gateway_ok, 'fleet': fleet, 'bots': entries}

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
    parser.add_argument('--host', help='SSH alias of the game server; omit to print snapshots to stdout')
    parser.add_argument('--receiver', default='github/Computer-Setup/linux-game-server/rs-sdk/portal/live.py')
    parser.add_argument('--once', action='store_true', help='Publish one snapshot and exit')
    args = parser.parse_args()
    if args.ticks < MIN_TICKS:
        parser.error(f'--ticks must be at least {MIN_TICKS} (one gateway request per bot per {MIN_TICKS * TICK_MS / 1000:g} s at most)')
    publisher = Publisher(args.sdk.expanduser(), args.botting.expanduser(), args.ticks,
                          http_base(args.gateway) if args.gateway else None)
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
