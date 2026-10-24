#!/usr/bin/env python3
"""Live fleet snapshot: allowlist shaping, the server-side receiver and the portal's view of it.

The bot workstation's publisher (live_publish.py) polls the SDK gateway with
each bot's own credentials and streams one JSON snapshot per line over SSH:

    live_publish.py | ssh game-server python3 live.py receive --target DIR

`receive` re-shapes every line through `shape_snapshot` (an allowlist, so a
publisher bug can never put a credential or raw gateway frame on disk), stamps
it with the server clock and atomically replaces DIR/live.json. The portal
container mounts DIR read-only and serves it from /rs-sdk/api/live.
"""
import argparse
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import time

TICK_MS = 600
DEFAULT_TICKS = 10
MAX_TICKS = 1000
MAX_LINE = 2 * 1024 * 1024
MAX_BOTS = 200
STALE_FLOOR_MS = 20_000
NAME = re.compile(r'^[A-Za-z0-9_ -]{1,12}$')
TOKEN = re.compile(r'^[A-Za-z0-9_.:+-]{1,40}$')
STATUSES = {'active', 'stale', 'dead', 'offline', 'unknown'}
# MapView.ts unified canvas (must match worldmap.py).
ORIGIN_X, ORIGIN_Z, MAP_WIDTH, MAP_HEIGHT = 28 << 6, 41 << 6, 30 << 6, 52 << 6
MAP_BANDS = ((42, 62, 0), (142, 161, -79), (69, 77, 14))


def ticks_param(params):
    """Refresh period in game ticks from ?ticks=N (default 10 = ~6 s); ValueError if invalid."""
    raw = params.get('ticks', [str(DEFAULT_TICKS)])[0]
    if not raw.isdigit():
        raise ValueError('ticks')
    ticks = int(raw)
    if not 1 <= ticks <= MAX_TICKS:
        raise ValueError('ticks')
    return ticks


def map_point(x, z):
    """World tile -> (column, row) on the unified world-map canvas, or None if off the map."""
    for low, high, offset in MAP_BANDS:
        if low <= z >> 6 <= high:
            column = x - ORIGIN_X
            row = ORIGIN_Z + MAP_HEIGHT - 1 - (((z >> 6) + offset) * 64 + (z & 63))
            if 0 <= column < MAP_WIDTH and 0 <= row < MAP_HEIGHT:
                return column, row
            return None
    return None


def _int(value, low=-(1 << 31), high=(1 << 31) - 1):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    value = int(value)
    return value if low <= value <= high else None


def _text(value, limit=80):
    if not isinstance(value, str):
        return None
    value = ''.join(ch for ch in value if ch.isprintable())[:limit].strip()
    return value or None


def _items(values, limit):
    out = []
    for item in values if isinstance(values, list) else []:
        if not isinstance(item, dict):
            continue
        entry = {'slot': _int(item.get('slot'), 0, 255), 'id': _int(item.get('id'), 0, 65535),
                 'name': _text(item.get('name'), 60), 'count': _int(item.get('count'), 0)}
        if entry['id'] is not None:
            out.append(entry)
        if len(out) >= limit:
            break
    return out


def shape_bot(bot):
    """Allowlisted, size-bounded copy of one bot entry, or None if it has no valid username."""
    if not isinstance(bot, dict):
        return None
    username = bot.get('username')
    if not isinstance(username, str) or not NAME.match(username):
        return None
    status = bot.get('status') if bot.get('status') in STATUSES else 'unknown'
    out = {'username': username, 'displayName': _text(bot.get('displayName'), 12), 'status': status,
           'inGame': bot.get('inGame') is True, 'stateAge': _int(bot.get('stateAge'), 0),
           'tick': _int(bot.get('tick'), 0), 'player': None, 'skills': [], 'inventory': [], 'equipment': [],
           'recentXp': {}, 'messages': [], 'activity': {}}
    player = bot.get('player')
    if isinstance(player, dict):
        x, z = _int(player.get('x'), 0, 16383), _int(player.get('z'), 0, 16383)
        shaped = {key: _int(player.get(key), -1, 1 << 20) for key in
                  ('level', 'hp', 'maxHp', 'combatLevel', 'runEnergy', 'animId')}
        shaped.update({'x': x, 'z': z, 'inCombat': player.get('inCombat') is True,
                       'isDead': player.get('isDead') is True, 'target': _text(player.get('target'), 40)})
        point = map_point(x, z) if x is not None and z is not None else None
        shaped['map'] = list(point) if point else None
        out['player'] = shaped
    for skill in bot.get('skills') if isinstance(bot.get('skills'), list) else []:
        if isinstance(skill, dict) and _text(skill.get('name'), 20) and len(out['skills']) < 30:
            out['skills'].append({'name': _text(skill.get('name'), 20), 'level': _int(skill.get('level'), 0, 255),
                                  'baseLevel': _int(skill.get('baseLevel'), 0, 255),
                                  'experience': _int(skill.get('experience'), 0)})
    out['inventory'] = _items(bot.get('inventory'), 28)
    out['equipment'] = _items(bot.get('equipment'), 14)
    recent = bot.get('recentXp')
    if isinstance(recent, dict):
        out['recentXp'] = {name: gained for name, gained in ((_text(k, 20), _int(v, 0)) for k, v in list(recent.items())[:30])
                           if name and gained}
    for message in (bot.get('messages') if isinstance(bot.get('messages'), list) else [])[-5:]:
        if _text(message, 160):
            out['messages'].append(_text(message, 160))
    activity = bot.get('activity') if isinstance(bot.get('activity'), dict) else {}
    args = activity.get('args') if isinstance(activity.get('args'), list) else []
    out['activity'] = {
        'routine': activity.get('routine') if isinstance(activity.get('routine'), str) and TOKEN.match(activity['routine']) else None,
        'args': [a for a in args if isinstance(a, str) and TOKEN.match(a)][:6],
        'client': activity.get('client') is True, 'watcher': activity.get('watcher') is True,
        'dialog': activity.get('dialog') is True, 'modal': activity.get('modal') is True,
        'focus': activity.get('focus') is True,
    }
    out['activity']['label'] = activity_label(out)
    return out


def activity_label(bot):
    """Best human summary of what a bot is doing, from routine, state and XP flow."""
    player = bot.get('player') or {}
    activity = bot.get('activity') or {}
    if bot.get('status') in ('dead', 'offline') or not bot.get('inGame'):
        return 'Offline' if not activity.get('client') else 'Client running, not in game'
    parts = []
    if player.get('isDead'):
        return 'Dead (respawning)'
    if activity.get('focus'):
        parts.append('Fleet focus: random-event investigation')
    if activity.get('routine'):
        parts.append(' '.join([activity['routine']] + activity.get('args', [])[:3]))
    if player.get('inCombat'):
        parts.append('In combat' + (f' with {player["target"]}' if player.get('target') else ''))
    if activity.get('dialog'):
        parts.append('Dialog open')
    elif activity.get('modal'):
        parts.append('Interface open')
    gained = sorted(bot.get('recentXp', {}).items(), key=lambda item: -item[1])
    if gained:
        parts.append('Training ' + ', '.join(name for name, _ in gained[:2]))
    elif not parts and player.get('animId') not in (None, -1):
        parts.append(f'Animating (#{player["animId"]})')
    if not parts:
        parts.append('Gateway frames stalled' if bot.get('status') == 'stale' else 'Idle')
    return ' · '.join(parts)


def shape_snapshot(raw, received_at=None):
    """Allowlisted snapshot; ValueError if it is not a publisher snapshot."""
    if not isinstance(raw, dict) or raw.get('version') != 1 or not isinstance(raw.get('bots'), list):
        raise ValueError('Not a live snapshot')
    bots = [bot for bot in (shape_bot(item) for item in raw['bots'][:MAX_BOTS]) if bot]
    fleet = raw.get('fleet') if isinstance(raw.get('fleet'), dict) else {}
    focus = fleet.get('focus')
    return {
        'version': 1,
        'publishedAt': _int(raw.get('publishedAt'), 0, 1 << 53),
        'receivedAt': received_at if received_at is not None else _int(raw.get('receivedAt'), 0, 1 << 53),
        'intervalMs': _int(raw.get('intervalMs'), TICK_MS, MAX_TICKS * TICK_MS) or DEFAULT_TICKS * TICK_MS,
        'fleet': {'running': fleet.get('running') is True,
                  'focus': focus if isinstance(focus, str) and NAME.match(focus) else None},
        'gatewayOk': raw.get('gatewayOk') is True,
        'bots': sorted(bots, key=lambda bot: (bot['status'] in ('dead', 'offline'), bot['username'])),
    }


def read_live(path, now_ms=None, ticks=DEFAULT_TICKS, accounts=()):
    """The API payload: the last received snapshot plus freshness, or an explicit 'no data' answer.

    `accounts` (usernames from the accounts snapshot) adds offline rows for bots the
    publisher has never reported, so every account is listed."""
    now_ms = int(time.time() * 1000) if now_ms is None else now_ms
    payload = {'version': 1, 'now': now_ms, 'refreshMs': ticks * TICK_MS, 'ticks': ticks,
               'available': False, 'stale': True, 'ageMs': None, 'error': None, 'fleet': None, 'bots': []}
    try:
        if path is None:
            raise FileNotFoundError
        with open(path, 'rb') as stream:
            data = stream.read(MAX_LINE + 1)
        if len(data) > MAX_LINE:
            raise ValueError('Snapshot too large')
        snapshot = shape_snapshot(json.loads(data))
    except FileNotFoundError:
        payload['error'] = 'No live snapshot yet: the workstation publisher has not connected.'
    except (OSError, ValueError) as exc:
        payload['error'] = f'Live snapshot unreadable: {exc.__class__.__name__}'
    else:
        age = max(0, now_ms - (snapshot['receivedAt'] or 0))
        payload.update({'available': True, 'ageMs': age, 'publishedAt': snapshot['publishedAt'],
                        'receivedAt': snapshot['receivedAt'], 'publishIntervalMs': snapshot['intervalMs'],
                        'stale': age > max(3 * snapshot['intervalMs'], STALE_FLOOR_MS),
                        'gatewayOk': snapshot['gatewayOk'], 'fleet': snapshot['fleet'], 'bots': snapshot['bots']})
        if payload['stale']:
            payload['error'] = f'Snapshot is {age // 1000}s old: the workstation publisher may be offline.'
    known = {bot['username'] for bot in payload['bots']}
    for username in accounts:
        if username not in known and NAME.match(username):
            payload['bots'].append(shape_bot({'username': username, 'status': 'offline'}))
    if payload['available'] and payload['stale']:
        for bot in payload['bots']:
            bot['activity']['label'] = 'Unknown (stale snapshot) · last: ' + bot['activity']['label']
    return payload


def write_atomic(target, snapshot):
    target.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix='.live-', dir=target)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(snapshot, stream, separators=(',', ':'))
        os.chmod(tmp, 0o600)
        os.replace(tmp, target / 'live.json')
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def receive(stream, target, clock=time.time):
    """Consume newline-delimited snapshots until EOF; bad lines are reported and skipped."""
    written = 0
    while True:
        line = stream.readline(MAX_LINE + 1)
        if not line:
            return written
        if len(line) > MAX_LINE:
            print('live receive: oversized line dropped', file=sys.stderr, flush=True)
            while line and not line.endswith(b'\n'):
                line = stream.readline(MAX_LINE + 1)
            continue
        if not line.strip():
            continue
        try:
            snapshot = shape_snapshot(json.loads(line), received_at=int(clock() * 1000))
        except ValueError as exc:
            print(f'live receive: rejected line ({exc.__class__.__name__})', file=sys.stderr, flush=True)
            continue
        write_atomic(target, snapshot)
        written += 1


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest='command', required=True)
    receiver = sub.add_parser('receive', help='Read snapshots from stdin into TARGET/live.json')
    receiver.add_argument('--target', type=Path, default=Path.home() / '.local/share/rs-sdk-portal/live')
    args = parser.parse_args()
    if args.command == 'receive':
        receive(sys.stdin.buffer, args.target)


if __name__ == '__main__':
    main()
