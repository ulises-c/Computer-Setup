#!/usr/bin/env python3
"""Live fleet snapshot: allowlist shaping, the server-side receiver and the portal's view of it.

The bot workstation's publisher (live_publish.py) polls the SDK gateway with
each bot's own credentials and streams one JSON snapshot per line over SSH:

    live_publish.py | ssh game-server python3 live.py receive --target DIR

Presence comes from two sources: the gateway (is an SDK client connected?) and
the game web server's /playerpositions (who is in the world). A bot in the world
without a connected client is a 'ghost' and is flagged as a warning; other
players in the world are listed by name and position only.

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

from player_anims import anim_info

TICK_MS = 600
DEFAULT_TICKS = 5
MAX_TICKS = 1000
MAX_LINE = 2 * 1024 * 1024
MAX_BOTS = 200
# Stale after 3 publish periods, but never sooner than 12 s (4 default periods) to ride out SSH hiccups.
STALE_FLOOR_MS = 12_000
NAME = re.compile(r'^[A-Za-z0-9_ -]{1,12}$')
TOKEN = re.compile(r'^[A-Za-z0-9_.:+-]{1,40}$')
STATUSES = {'active', 'stale', 'dead', 'offline', 'unknown'}
# controlled: in the world with an SDK client; ghost: in the world, no client; unknown: world list unreachable.
PRESENCES = {'controlled', 'ghost', 'offline', 'unknown'}
PRESENCE_ORDER = {'ghost': 0, 'controlled': 1, 'unknown': 2, 'offline': 3}
MAX_WORLD_PLAYERS = 2000
ROUTINE_STATES = {'running', 'finished', 'failed', 'ended'}
MOTIONS = {'still', 'walking', 'running', 'teleported'}
COUNT_KEY = re.compile(r'^[A-Za-z][A-Za-z0-9_]{0,23}$')
EPOCH_MS = (0, 1 << 53)
# Anim actions that say nothing on their own (the routine phase or motion is better).
QUIET_ACTIONS = {'Standing', 'Walking', 'Running'}
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


def _token(value):
    return value if isinstance(value, str) and TOKEN.match(value) else None


def _counts(value):
    out = {}
    for key, count in (list(value.items())[:12] if isinstance(value, dict) else []):
        if isinstance(key, str) and COUNT_KEY.match(key) and isinstance(count, (int, float)) and not isinstance(count, bool) \
                and abs(count) < 1 << 40:
            out[key] = round(count, 2) if isinstance(count, float) and not count.is_integer() else int(count)
    return out


def _shape_status(raw):
    """A routine's own published status (routines/lib/activity-status.ts), allowlisted."""
    if not isinstance(raw, dict) or raw.get('state') not in ROUTINE_STATES or not _text(raw.get('phase'), 60):
        return None
    args = raw.get('args') if isinstance(raw.get('args'), list) else []
    event = raw.get('lastEvent') if isinstance(raw.get('lastEvent'), dict) else None
    return {
        'routine': _token(raw.get('routine')), 'args': [a for a in args if _token(a)][:6], 'state': raw['state'],
        'phase': _text(raw.get('phase'), 60), 'detail': _text(raw.get('detail'), 80),
        'phaseSince': _int(raw.get('phaseSince'), *EPOCH_MS), 'startedAt': _int(raw.get('startedAt'), *EPOCH_MS),
        'updatedAt': _int(raw.get('updatedAt'), *EPOCH_MS), 'counts': _counts(raw.get('counts')),
        'stopReason': _text(raw.get('stopReason'), 80),
        'lastEvent': ({'kind': _text(event.get('kind'), 40), 'at': _int(event.get('at'), *EPOCH_MS)}
                      if event and _text(event.get('kind'), 40) else None),
    }


def _shape_fleet_task(raw):
    if not isinstance(raw, dict) or not _text(raw.get('phase'), 60):
        return None
    return {'phase': _text(raw.get('phase'), 60), 'detail': _text(raw.get('detail'), 80),
            'routine': _token(raw.get('routine')), 'updatedAt': _int(raw.get('updatedAt'), *EPOCH_MS)}


def _shape_anim(raw, current):
    """Named action for the current (or recently seen) player animation."""
    seen = raw if isinstance(raw, dict) else {}
    anim_id = _int(seen.get('id'), 0, 65535)
    age = _int(seen.get('ageMs'), 0, 3_600_000)
    if anim_id is None and current is not None and current >= 0:
        anim_id, age = current, 0
    info = anim_info(anim_id) if anim_id is not None else None
    if not info:
        return None
    return dict(info, ageMs=age or 0)


def norm_name(name):
    """Account/display name key: 'bot_moondrop' and 'Bot Moondrop' match."""
    return re.sub(r'[\s_]+', ' ', name).strip().lower() if isinstance(name, str) else ''


def _shape_position(raw):
    x, z = _int(raw.get('x'), 0, 16383), _int(raw.get('z'), 0, 16383)
    point = map_point(x, z) if x is not None and z is not None else None
    return {'x': x, 'z': z, 'level': _int(raw.get('level'), 0, 3), 'map': list(point) if point else None}


def _presence(bot, status):
    if bot.get('presence') in PRESENCES:
        return bot['presence']
    # Snapshots from before presence existed: only the gateway's view is known.
    return 'controlled' if status in ('active', 'stale') and bot.get('inGame') is True else 'offline'


def shape_world(raw):
    """The world player list summary: reachable?, count, and non-fleet players (name + position only)."""
    if not isinstance(raw, dict):
        return {'ok': False, 'error': 'World player list not published', 'count': None, 'others': []}
    others = []
    for item in raw.get('others') if isinstance(raw.get('others'), list) else []:
        if isinstance(item, dict) and isinstance(item.get('name'), str) and NAME.match(item['name']):
            others.append(dict(_shape_position(item), name=item['name']))
        if len(others) >= MAX_WORLD_PLAYERS:
            break
    ok = raw.get('ok') is True
    return {'ok': ok, 'error': None if ok else (_text(raw.get('error'), 120) or 'World player list unavailable'),
            'count': _int(raw.get('count'), 0, 100_000) if ok else None, 'others': others}


def shape_bot(bot):
    """Allowlisted, size-bounded copy of one bot entry, or None if it has no valid username."""
    if not isinstance(bot, dict):
        return None
    username = bot.get('username')
    if not isinstance(username, str) or not NAME.match(username):
        return None
    status = bot.get('status') if bot.get('status') in STATUSES else 'unknown'
    out = {'username': username, 'displayName': _text(bot.get('displayName'), 12), 'status': status,
           'presence': _presence(bot, status), 'lastKnownAt': _int(bot.get('lastKnownAt'), *EPOCH_MS),
           'inGame': bot.get('inGame') is True, 'stateAge': _int(bot.get('stateAge'), 0),
           'tick': _int(bot.get('tick'), 0), 'player': None, 'skills': [], 'inventory': [], 'equipment': [],
           'recentXp': {}, 'xpRate': {}, 'messages': [], 'activity': {}}
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
    rate = bot.get('xpRate')
    if isinstance(rate, dict):
        out['xpRate'] = {name: per_hour for name, per_hour in ((_text(k, 20), _int(v, 0, 10_000_000)) for k, v in list(rate.items())[:30])
                         if name and per_hour}
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
        'levelUp': _text(activity.get('levelUp'), 20),
        'status': _shape_status(activity.get('status')),
        'fleetTask': _shape_fleet_task(activity.get('fleetTask')),
        'anim': _shape_anim(activity.get('anim'), (out['player'] or {}).get('animId')),
        'motion': None,
    }
    motion = activity.get('motion')
    if isinstance(motion, dict) and motion.get('state') in MOTIONS:
        out['activity']['motion'] = {'state': motion['state'], 'tiles': _int(motion.get('tiles'), 0, 16383)}
    out['activity']['label'] = activity_label(out)
    return out


def _rate_text(per_hour):
    return f'{per_hour / 1000:.1f}k' if per_hour >= 10_000 else f'{per_hour:,}'


def observed_action(bot):
    """What the frames themselves show: combat, a named animation, or movement (None if nothing)."""
    player = bot.get('player') or {}
    activity = bot.get('activity') or {}
    if player.get('inCombat'):
        return 'Fighting' + (f' {player["target"]}' if player.get('target') else '')
    anim = activity.get('anim')
    if anim and anim.get('action') not in QUIET_ACTIONS and (anim.get('ageMs') or 0) <= 10_000:
        return anim['action']
    motion = (activity.get('motion') or {}).get('state')
    if motion in ('walking', 'running'):
        return motion.capitalize()
    if motion == 'teleported':
        return 'Teleported'
    return None


def activity_label(bot):
    """One-line summary: routine phase (published by the routine) + what the frames show + XP flow."""
    player = bot.get('player') or {}
    activity = bot.get('activity') or {}
    if bot.get('presence') == 'ghost':
        return 'In world with NO controller (SDK client disconnected)'
    if bot.get('presence') == 'unknown' and bot.get('status') in ('dead', 'offline', 'unknown'):
        return 'No controller · world presence unknown (player list unreachable)'
    if bot.get('status') in ('dead', 'offline') or not bot.get('inGame'):
        return 'Offline' if not activity.get('client') else 'Client running, not in game'
    if player.get('isDead'):
        return 'Dead (respawning)'
    parts = []
    if activity.get('focus'):
        parts.append('Fleet focus: random-event investigation')
    if activity.get('levelUp'):
        parts.append(f'Dismissing level-up ({activity["levelUp"]})')
    elif activity.get('dialog'):
        parts.append('Dialog open')
    elif activity.get('modal'):
        parts.append('Interface open')
    status = activity.get('status') or {}
    phase = None
    if status.get('state') == 'running':
        phase = status.get('phase')
        parts.append(f'{status.get("routine") or activity.get("routine") or "routine"}: {phase}')
    elif activity.get('routine'):
        parts.append(' '.join([activity['routine']] + activity.get('args', [])[:2]))
    elif activity.get('fleetTask'):
        parts.append(f'Fleet: {activity["fleetTask"]["phase"]}')
    observed = observed_action(bot)
    # Skip the observation when the phase already says it ("mining tin" + "Mining", "walking to bank" + "Walking").
    if observed and not (phase and observed.split()[0].lower() in phase.lower()):
        parts.append(observed)
    rates = sorted((bot.get('xpRate') or {}).items(), key=lambda item: -item[1])
    gained = sorted((bot.get('recentXp') or {}).items(), key=lambda item: -item[1])
    if rates and gained:
        parts.append(' · '.join(f'{name} {_rate_text(rate)} XP/h' for name, rate in rates[:2]))
    elif gained:
        parts.append('Training ' + ', '.join(name for name, _ in gained[:2]))
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
        'world': shape_world(raw.get('world')),
        'bots': sorted(bots, key=lambda bot: (PRESENCE_ORDER[bot['presence']], bot['username'])),
    }


def read_live(path, now_ms=None, ticks=DEFAULT_TICKS, accounts=()):
    """The API payload: the last received snapshot plus freshness, or an explicit 'no data' answer.

    `accounts` (usernames from the accounts snapshot) adds offline rows for bots the
    publisher has never reported, so every account is listed."""
    now_ms = int(time.time() * 1000) if now_ms is None else now_ms
    payload = {'version': 1, 'now': now_ms, 'refreshMs': ticks * TICK_MS, 'ticks': ticks,
               'available': False, 'stale': True, 'ageMs': None, 'error': None, 'fleet': None,
               'world': shape_world(None), 'bots': []}
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
                        'gatewayOk': snapshot['gatewayOk'], 'fleet': snapshot['fleet'], 'world': snapshot['world'],
                        'bots': snapshot['bots']})
        if payload['stale']:
            payload['error'] = f'Snapshot is {age // 1000}s old: the workstation publisher may be offline.'
    known = {bot['username'] for bot in payload['bots']}
    world = payload['world']
    for username in accounts:
        if username not in known and NAME.match(username):
            # An account the publisher has no credentials for, yet in the world: a ghost too.
            seen = next((p for p in world['others'] if norm_name(p['name']) == norm_name(username)), None)
            if seen:
                world['others'].remove(seen)
                payload['bots'].append(shape_bot({'username': username, 'status': 'offline', 'presence': 'ghost',
                                                  'displayName': seen['name'], 'inGame': True, 'player': seen}))
            else:
                presence = 'offline' if world['ok'] else 'unknown'
                payload['bots'].append(shape_bot({'username': username, 'status': 'offline', 'presence': presence}))
    payload['bots'].sort(key=lambda bot: (PRESENCE_ORDER[bot['presence']], bot['username']))
    payload['ghosts'] = [bot['username'] for bot in payload['bots'] if bot['presence'] == 'ghost']
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
