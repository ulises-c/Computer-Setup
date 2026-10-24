#!/usr/bin/env python3
"""Publish the bot fleet's live state to the portal's live map (runs on the bot workstation).

Every N game ticks (default 10 = ~6 s; never faster, to keep the gateway at no
more than one request per bot per 6 s) this:

1. asks the gateway's unauthenticated GET /status which bots are connected;
2. for each connected bot, reads GET /state/<bot> with that bot's own SDK
   credentials from <sdk>/bots/<bot>/bot.env (sent as a Bearer header; a plain
   HTTP read - no WebSocket session, no observer/controller, no actions);
3. reduces each frame to an allowlist (position, HP, skills, inventory,
   equipment, combat, a few system messages), adds activity from local routine
   processes and the fleet supervisor's state, and
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
MIN_TICKS = 10
ROUTINE = re.compile(r'--env-file=\S*/bots/([A-Za-z0-9_-]{1,12})/bot\.env\s+\S*/routines/([A-Za-z0-9_.-]{1,40})\.ts\b(.*)')
RUNNER = re.compile(r'src/lite/runner\.ts\s+([A-Za-z0-9_-]{1,12})\b')
TOKEN = re.compile(r'^[A-Za-z0-9_.:+-]{1,40}$')
OBSERVERS = {'watch', 'listen'}
XP_WINDOW_S = 60.0


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
    """XP gained per skill over the last minute, from successive frames."""
    def __init__(self, window=XP_WINDOW_S):
        self.window = window
        self.history = {}

    def update(self, bot, skills, now):
        current = {s.get('name'): s.get('experience') for s in skills
                   if isinstance(s, dict) and isinstance(s.get('experience'), (int, float))}
        samples = [entry for entry in self.history.get(bot, []) if now - entry[0] <= self.window]
        samples.append((now, current))
        self.history[bot] = samples
        oldest = samples[0][1]
        return {name: int(xp - oldest[name]) for name, xp in current.items()
                if name in oldest and xp > oldest[name]}


def reduce_state(username, state, meta, local, xp, now, focus=None):
    """The allowlisted bot entry the portal accepts (see live.shape_bot)."""
    entry = {'username': username, 'status': meta.get('botStatus') or 'unknown',
             'stateAge': meta.get('stateAge'), 'activity': dict(local or {})}
    entry['activity']['focus'] = focus == username
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
    })
    tick = state.get('tick') if isinstance(state.get('tick'), int) else 0
    # system messages only (type 0, no sender): never relay other players' chat
    entry['messages'] = [m.get('text') for m in (state.get('gameMessages') or [])
                         if isinstance(m, dict) and m.get('type') == 0 and not m.get('sender')
                         and isinstance(m.get('tick'), int) and tick - m['tick'] <= 100][-3:]
    dialog = state.get('dialog') if isinstance(state.get('dialog'), dict) else {}
    entry['activity']['dialog'] = dialog.get('isOpen') is True
    entry['activity']['modal'] = state.get('modalOpen') is True
    return entry


class Publisher:
    def __init__(self, sdk, botting, ticks, gateway=None):
        self.sdk, self.botting, self.ticks = sdk, botting, ticks
        self.gateway = gateway
        self.xp = XpTracker()

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
            entries.append(reduce_state(username, state, meta, local.get(username), self.xp, now, fleet['focus']))
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
    parser.add_argument('--ticks', type=int, default=10, help='Publish period in game ticks (600 ms each; minimum 10)')
    parser.add_argument('--sdk', type=Path, default=Path.home() / 'github/rs-sdk-fork')
    parser.add_argument('--botting', type=Path, default=Path.home() / 'forgejo/2004Scape-Botting')
    parser.add_argument('--gateway', help='Gateway HTTP base URL (default: GATEWAY_URL from the bots\' bot.env)')
    parser.add_argument('--host', help='SSH alias of the game server; omit to print snapshots to stdout')
    parser.add_argument('--receiver', default='github/Computer-Setup/linux-game-server/rs-sdk/portal/live.py')
    parser.add_argument('--once', action='store_true', help='Publish one snapshot and exit')
    args = parser.parse_args()
    if args.ticks < MIN_TICKS:
        parser.error(f'--ticks must be at least {MIN_TICKS} (one gateway request per bot per 6 s at most)')
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
