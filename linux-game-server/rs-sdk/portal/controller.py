#!/usr/bin/env python3
"""Bot controller (no LLM): the portal's desired-state store, registry validation, owner
auth for writes, and the host-side exchange with the workstation's controller daemon.

    bot workstation: bun tools/bot-controller.ts daemon         (2004Scape-Botting repo)
      every few seconds:  status JSON | ssh game-server python3 controller.py exchange
                          <- desired JSON on stdout

The owner edits DESIRED state on /rs-sdk/bot-controller/ (run a registry routine, stop,
hold). The portal only ever writes CONTROLLER_DIR/desired.json (+ audit.jsonl), validated
against the routine registry the daemon last pushed. The daemon re-validates everything
against its own registry copy, maps requests to fixed argv, honours latches/stops and
reports per-bot results; `exchange` (run on the host, outside the container) stores that
report allowlisted as LIVE_DIR/controller-status.json, which the container mounts
read-only, so the portal can never forge daemon status. Threat model: README.md.
"""
import argparse
from collections import deque
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import secrets
import sys
import tempfile
import threading
import time
from urllib.parse import quote, urlencode

BOT = re.compile(r'^bot_[a-z][a-z0-9]{0,7}$')
# The owner's regular accounts (2004Scape-Botting scripts/player.sh: bots/player_<slug>/bot.env).
PLAYER = re.compile(r'^player_[a-z0-9]{1,12}$')
# Their in-game name as stored (BOT_USERNAME); the gateway matches it exactly, so the frame uses it verbatim.
DISPLAY = re.compile(r'^[A-Za-z0-9][A-Za-z0-9 _-]{0,11}$')
MODES = ('headless', 'browser')
PRESENCES = ('present', 'absent', 'unknown')
CLIENTS = ('headless', 'frame')
LOG_LINES = 40
LOG_WIDTH = 200
MAX_PASSWORD = 64
VALUE = re.compile(r'^[a-z0-9][a-z0-9-]{0,39}$')
ROUTINE_ID = re.compile(r'^[a-z][a-z0-9-]{0,31}$')
ARG_NAME = re.compile(r'^[a-z][A-Za-z0-9]{0,23}$')
TEXT = re.compile(r'^[\x20-\x7e]*$')
RUNNERS = ('session', 'chickens-247', 'combat-247', 'scavenge-247', 'food-247', 'pioneer', 'onboard')
ACTIONS = ('run', 'stop', 'hold', 'clear')
ALWAYS_EXCLUDED = ('bot_tester',)
# Gathering entries (2004Scape-Botting routines/gather.ts): session routine 'gather', args in this order.
GATHER_SKILLS = ('woodcutting', 'mining', 'fishing')
# Longest duration any `unit: seconds` arg may allow (owner 2026-10-26): 7 days (mirror of bot-controller.ts MAX_DURATION_S).
MAX_DURATION_S = 7 * 86_400
GATHER_ARGS = ('resource', 'location', 'handling', 'seconds')
PIONEER = 'bot_pioneer'
MAX_STATUS = 1024 * 1024
MAX_BODY = 16 * 1024
MAX_BULK = 60
# The daemon pushes every ~5 s; older than this means it is offline.
HEARTBEAT_STALE_MS = 30_000
STATES = {'idle', 'held', 'rejected', 'pending', 'blocked', 'foreign', 'starting', 'running', 'stopping', 'stopped',
          'switching', 'finished', 'failed', 'done', 'expired', 'unknown', 'error', 'reserved'}
# Account reservations (bot repo scripts/reserve.sh): holder ids like 'hermes:<host>:<session>' or 'runner:<host>:<type>'.
HOLDER = re.compile(r'^[A-Za-z0-9_.:@/+-]{1,100}$')
AUTO_ORIGINS = {'run-bot', 'run-routine', 'player-client', 'player-run'}


def account_type(name):
    """'bot' (fleet), 'player' (the owner's regular account) or None."""
    if not isinstance(name, str):
        return None
    return 'bot' if BOT.match(name) else 'player' if PLAYER.match(name) else None


_REDACTIONS = (
    (re.compile(r'\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=%-]+', re.I), r'\1 [redacted]'),
    (re.compile(r'''("?(?:password|passwd|pwd|token|secret|api[_-]?key|authorization)["']?\s*[:=]\s*)("[^"]*"|'[^']*'|[^\s&"',;]+)''', re.I), r'\1[redacted]'),
    (re.compile(r'\b([A-Za-z0-9_]*(?:PASSWORD|TOKEN|SECRET)[A-Za-z0-9_]*=)\S+', re.I), r'\1[redacted]'),
)
_ANSI = re.compile(r'\x1b\[[0-9;?]*[A-Za-z]')


def sanitize_log(lines):
    """Job-log tail as shown on the page: credential-looking values redacted (again: the daemon already
    did), control characters stripped, at most LOG_LINES lines of LOG_WIDTH characters."""
    out = []
    for line in (lines if isinstance(lines, list) else [])[-LOG_LINES:]:
        if not isinstance(line, str):
            continue
        line = _ANSI.sub('', line)
        for pattern, sub in _REDACTIONS:
            line = pattern.sub(sub, line)
        line = ''.join(ch for ch in line if 0x20 <= ord(ch) < 0x7f).rstrip()
        if line:
            out.append(line if len(line) <= LOG_WIDTH else line[:LOG_WIDTH - 3] + '...')
    return out


def _text(value, limit):
    return isinstance(value, str) and len(value) <= limit and bool(TEXT.match(value))


def _clean(value, limit=160):
    if not isinstance(value, str):
        return None
    value = ''.join(ch if 0x20 <= ord(ch) < 0x7f else ' ' for ch in value).strip()[:limit]
    return value or None


def _int(value, low=0, high=1 << 53):
    if isinstance(value, bool) or not isinstance(value, int):
        return None
    return value if low <= value <= high else None


def _bots(value, where):
    if not isinstance(value, list) or len(value) > 200 or not all(isinstance(b, str) and BOT.match(b) for b in value):
        raise ValueError(f'{where}: bot names')
    return list(value)


def parse_registry(raw):
    """Strictly validated routine registry (mirror of tools/lib/bot-controller.ts parseRegistry); ValueError on any problem."""
    if not isinstance(raw, dict) or raw.get('version') != 1 or not isinstance(raw.get('routines'), list):
        raise ValueError('registry: version 1 with routines[]')
    excluded = _bots(raw.get('excludedBots', []), 'excludedBots')
    for bot in ALWAYS_EXCLUDED:
        if bot not in excluded:
            raise ValueError(f'registry: {bot} must be excluded')
    if len(raw['routines']) > 50:
        raise ValueError('registry: too many routines')
    routines, seen = [], set()
    for index, r in enumerate(raw['routines']):
        if not isinstance(r, dict) or not isinstance(r.get('id'), str) or not ROUTINE_ID.match(r['id']) or r['id'] in seen:
            raise ValueError(f'routines[{index}]: id')
        rid = r['id']
        seen.add(rid)
        if not _text(r.get('label'), 60) or not r['label']:
            raise ValueError(f'{rid}: label')
        if r.get('description') is not None and not _text(r.get('description'), 400):
            raise ValueError(f'{rid}: description')
        if r.get('runner') not in RUNNERS:
            raise ValueError(f'{rid}: runner')
        if r['runner'] == 'session' and not (isinstance(r.get('routine'), str) and ROUTINE_ID.match(r['routine'])):
            raise ValueError(f'{rid}: routine')
        allow = None if r.get('allowBots') is None else _bots(r['allowBots'], f'{rid}.allowBots')
        deny = _bots(r.get('denyBots', []), f'{rid}.denyBots')
        if r['runner'] == 'pioneer' and allow != [PIONEER]:
            raise ValueError(f'{rid}: pioneer runner must allow exactly {PIONEER}')
        if r['runner'] != 'pioneer' and PIONEER not in deny:
            raise ValueError(f'{rid}: must deny {PIONEER}')
        danger = r.get('danger')
        if danger is not None and (not _text(danger, 400) or not danger.strip()):
            raise ValueError(f'{rid}: danger')
        players = r.get('allowPlayers', False)
        if not isinstance(players, bool):
            raise ValueError(f'{rid}: allowPlayers must be true or false')
        if players and (r['runner'] != 'session' or allow is not None):
            raise ValueError(f'{rid}: allowPlayers only for session routines without allowBots')
        hidden = r.get('hidden', False)
        if not isinstance(hidden, bool):
            raise ValueError(f'{rid}: hidden must be true or false')
        fixed = r.get('fixedArgs', [])
        if not isinstance(fixed, list) or len(fixed) > 4 or not all(isinstance(a, str) and VALUE.match(a) for a in fixed):
            raise ValueError(f'{rid}: fixedArgs')
        if not isinstance(r.get('args'), list) or len(r['args']) > 6:
            raise ValueError(f'{rid}: args')
        args, names = [], set()
        for a in r['args']:
            if not isinstance(a, dict) or not isinstance(a.get('name'), str) or not ARG_NAME.match(a['name']) or a['name'] in names:
                raise ValueError(f'{rid}: arg name')
            names.add(a['name'])
            label = a['label'] if _text(a.get('label'), 40) and a.get('label') else a['name']
            if a.get('type') != 'int' and (a.get('unit') is not None or a.get('maxNote') is not None):
                raise ValueError(f'{rid}.{a["name"]}: unit/maxNote only on int args')
            if a.get('type') == 'enum':
                values = a.get('values')
                if not isinstance(values, list) or not values or len(values) > 30 or len(set(values)) != len(values) \
                        or not all(isinstance(v, str) and VALUE.match(v) for v in values):
                    raise ValueError(f'{rid}.{a["name"]}: enum values')
                if a.get('default') is not None and a['default'] not in values:
                    raise ValueError(f'{rid}.{a["name"]}: default')
                arg = {'name': a['name'], 'label': label, 'type': 'enum', 'values': list(values), 'default': a.get('default')}
                if a.get('valuesBy') is not None:
                    # Dependent enum: one list per value of an EARLIER enum arg, each a non-empty subset holding the default.
                    by = a['valuesBy']
                    ref = next((p for p in args if isinstance(by, dict) and p['name'] == by.get('arg') and p['type'] == 'enum'), None)
                    if ref is None or not isinstance(by.get('map'), dict):
                        raise ValueError(f'{rid}.{a["name"]}: valuesBy.arg must name an earlier enum arg')
                    if set(by['map']) != set(ref['values']) or len(by['map']) != len(ref['values']):
                        raise ValueError(f'{rid}.{a["name"]}: valuesBy.map keys must be exactly the values of {ref["name"]}')
                    shaped = {}
                    for key in ref['values']:
                        lst = by['map'][key]
                        if not isinstance(lst, list) or not lst or len(set(lst)) != len(lst) or not all(isinstance(v, str) and v in values for v in lst):
                            raise ValueError(f'{rid}.{a["name"]}: valuesBy.map.{key} must be a non-empty subset of values')
                        if a.get('default') is not None and a['default'] not in lst:
                            raise ValueError(f'{rid}.{a["name"]}: valuesBy.map.{key} must include the default')
                        shaped[key] = list(lst)
                    arg['valuesBy'] = {'arg': ref['name'], 'map': shaped}
                if a.get('valueLabels') is not None:
                    labels = a['valueLabels']
                    if not isinstance(labels, dict) or not all(k in values and _text(v, 80) and v for k, v in labels.items()):
                        raise ValueError(f'{rid}.{a["name"]}: valueLabels')
                    arg['valueLabels'] = dict(labels)
                if a.get('playersOnly') is not None:
                    only = a['playersOnly']
                    if not isinstance(only, list) or not all(isinstance(v, str) and v in values for v in only) or a.get('default') in only or not players:
                        raise ValueError(f'{rid}.{a["name"]}: playersOnly (values other than the default, on allowPlayers routines)')
                    arg['playersOnly'] = list(only)
                args.append(arg)
            elif a.get('type') == 'int':
                low, high = _int(a.get('min'), 0, 1_000_000), _int(a.get('max'), 0, 1_000_000)
                if low is None or high is None or low > high:
                    raise ValueError(f'{rid}.{a["name"]}: int bounds')
                default = a.get('default')
                if default is not None and (_int(default, low, high) is None):
                    raise ValueError(f'{rid}.{a["name"]}: default')
                arg = {'name': a['name'], 'label': label, 'type': 'int', 'min': low, 'max': high, 'default': default}
                # Duration in seconds (the page shows days/hours/minutes/seconds boxes; the value stays whole seconds).
                if a.get('unit') is not None:
                    if a['unit'] != 'seconds':
                        raise ValueError(f'{rid}.{a["name"]}: unit (only seconds)')
                    if high > MAX_DURATION_S:
                        raise ValueError(f'{rid}.{a["name"]}: a duration (unit seconds) is at most {MAX_DURATION_S} s (7 days)')
                    arg['unit'] = 'seconds'
                if a.get('maxNote') is not None:
                    note = a['maxNote']
                    if arg.get('unit') != 'seconds' or not _text(note, 200) or not note.strip() or high >= MAX_DURATION_S:
                        raise ValueError(f'{rid}.{a["name"]}: maxNote (printable text, max 200, only on a duration arg whose max is below 7 days)')
                    arg['maxNote'] = note
                args.append(arg)
            else:
                raise ValueError(f'{rid}.{a.get("name")}: type')
        gather = r.get('gather')
        if gather is not None and (gather not in GATHER_SKILLS or r['runner'] != 'session' or r.get('routine') != 'gather'
                                   or tuple(a['name'] for a in args) != GATHER_ARGS or any(a['type'] != 'enum' for a in args[:3]) or args[3]['type'] != 'int'):
            raise ValueError(f'{rid}: gather (session routine gather with args {", ".join(GATHER_ARGS)})')
        category = r.get('category', 'misc')
        if category not in ('skills', 'quests', 'misc'):
            raise ValueError(f'{rid}: category')
        for key in ('group', 'method'):
            if key in r and (not _text(r[key], 60) or not r[key].strip()):
                raise ValueError(f'{rid}: {key}')
        entry = {'id': rid, 'label': r['label'], 'description': r.get('description') or '', 'runner': r['runner'],
                 'category': category, 'group': r.get('group', 'Misc'), 'method': r.get('method', r['label']),
                 'safeStart': r.get('safeStart') is True, 'enabled': r.get('enabled') is not False, 'allowBots': allow,
                 'denyBots': deny, 'allowPlayers': players, 'danger': danger, 'fixedArgs': list(fixed), 'args': args,
                 'hidden': hidden, 'gather': gather}
        if r['runner'] == 'session':
            entry['routine'] = r['routine']
        routines.append(entry)
    return {'version': 1, 'excludedBots': excluded, 'routines': routines}


def bot_denied(registry, routine, bot):
    """Why `bot` may not run `routine` (registry policy), or None."""
    if isinstance(bot, str) and PLAYER.match(bot):
        return None if routine.get('allowPlayers') else f'{routine["id"]} is a fleet routine (not for regular accounts)'
    if not isinstance(bot, str) or not BOT.match(bot):
        return 'bad bot name'
    if bot in ALWAYS_EXCLUDED or bot in registry['excludedBots']:
        return f'{bot} is not launchable from the controller'
    if routine['allowBots'] is not None and bot not in routine['allowBots']:
        return f'{routine["id"]} is only for {", ".join(routine["allowBots"])}'
    if bot in routine['denyBots']:
        return f'{routine["id"]} is not allowed for {bot}'
    return None


def allowed_values(spec, chosen):
    """Values an enum arg accepts given the args before it (mirror of bot-controller.ts allowedValues): its valuesBy
    list for the chosen value of the referenced earlier arg, else its fixed values. The page's L.allowedValues too."""
    by = spec.get('valuesBy')
    if by:
        return by['map'].get(chosen.get(by['arg']), [])
    return spec['values']


def validate_run(registry, bot, routine_id, args, mode='headless'):
    """Normalised {name: value} args for a run request; ValueError with a user-facing reason."""
    routine = next((r for r in registry['routines'] if r['id'] == routine_id), None)
    if routine is None:
        raise ValueError('unknown routine')
    if not routine['enabled']:
        raise ValueError(f'{routine["id"]} is disabled in the registry')
    denied = bot_denied(registry, routine, bot)
    if denied:
        raise ValueError(denied)
    if mode not in MODES:
        raise ValueError('mode: headless or browser')
    if mode == 'browser' and routine['runner'] != 'session':
        raise ValueError(f'{routine["id"]}: the browser view only for session routines (24/7 runners start their own client)')
    if args is None:
        args = {}
    if not isinstance(args, dict):
        raise ValueError('args must be an object')
    extra = [k for k in args if not any(a['name'] == k for a in routine['args'])]
    if extra:
        raise ValueError('unknown args: ' + ', '.join(str(k)[:24] for k in extra[:3]))
    out = {}
    for spec in routine['args']:
        value = args.get(spec['name'], spec['default'])
        if spec['type'] == 'enum':
            allowed = allowed_values(spec, out)
            if not isinstance(value, str) or value not in allowed:
                raise ValueError(f'{spec["name"]}: one of {", ".join(allowed)}')
            # Fleet bots never drop or consume produce (owner rule: produce is banked): regular accounts only.
            if value in (spec.get('playersOnly') or []) and not (isinstance(bot, str) and PLAYER.match(bot)):
                raise ValueError(f'{spec["name"]} {value}: regular accounts only (fleet bots bank their produce)')
        elif _int(value, spec['min'], spec['max']) is None:
            raise ValueError(f'{spec["name"]}: integer {spec["min"]}..{spec["max"]}')
        out[spec['name']] = value
    return out


def empty_desired():
    return {'version': 1, 'seq': 0, 'updatedAt': 0, 'bots': {}}


def parse_desired(raw):
    """Shape check of desired.json (the daemon re-validates every entry against its registry)."""
    if not isinstance(raw, dict) or raw.get('version') != 1 or not isinstance(raw.get('bots'), dict):
        raise ValueError('not a desired-state document')
    bots = {}
    for bot, entry in list(raw['bots'].items())[:500]:
        if account_type(bot) is None or not isinstance(entry, dict) or entry.get('action') not in ('run', 'stop', 'hold') \
                or _int(entry.get('rev'), 1) is None or _int(entry.get('at')) is None or entry.get('mode', 'headless') not in MODES:
            continue
        shaped = {'action': entry['action'], 'rev': entry['rev'], 'at': entry['at'], 'by': entry.get('by') if _text(entry.get('by'), 80) else None}
        if entry['action'] == 'run':
            if not (isinstance(entry.get('routine'), str) and ROUTINE_ID.match(entry['routine'])) or not isinstance(entry.get('args'), dict):
                continue
            shaped['routine'] = entry['routine']
            shaped['mode'] = entry.get('mode', 'headless')
            shaped['args'] = {k: v for k, v in list(entry['args'].items())[:6]
                              if isinstance(k, str) and ARG_NAME.match(k) and (isinstance(v, str) and VALUE.match(v) or _int(v, 0, 1_000_000) is not None)}
        bots[bot] = shaped
    return {'version': 1, 'seq': _int(raw.get('seq')) or 0, 'updatedAt': _int(raw.get('updatedAt')) or 0, 'bots': bots}


def _shape_result(raw):
    if not isinstance(raw, dict) or raw.get('kind') not in ('run', 'stop'):
        return None
    rc = raw.get('rc')
    return {'rev': _int(raw.get('rev')), 'kind': raw['kind'], 'rc': rc if rc is None else _int(rc, 0, 255),
            'endedAt': _int(raw.get('endedAt')), 'note': _clean(raw.get('note'), 40)}


def _shape_list(value, limit=8, width=160):
    return [t for t in (_clean(v, width) for v in (value if isinstance(value, list) else [])[:limit]) if t]


MAINT_PHASES = {'window', 'down', 'settling', 'outage-down', 'outage-settling'}


def shape_maintenance(value):
    """Server maintenance banner from the daemon (2004Scape-Botting routines/lib/server-maintenance.ts), allowlisted."""
    if not isinstance(value, dict):
        return None
    phase = value.get('phase') if value.get('phase') in MAINT_PHASES else None
    return {'active': value.get('active') is True, 'hold': value.get('hold') is True, 'phase': phase,
            'reason': _clean(value.get('reason'), 300), 'since': _int(value.get('since')), 'resumeAt': _int(value.get('resumeAt')),
            'lastResumeAt': _int(value.get('lastResumeAt')), 'staggerMs': _int(value.get('staggerMs'), 0, 3_600_000),
            'reachable': value.get('reachable') if isinstance(value.get('reachable'), bool) else None,
            'nextWeekly': _int(value.get('nextWeekly')), 'tz': _clean(value.get('tz'), 40)}


def shape_reservation(value):
    """Who holds the account (bot repo routines/lib/reservations.ts), allowlisted; None = free or malformed."""
    if not isinstance(value, dict) or not (isinstance(value.get('holder'), str) and HOLDER.match(value['holder'])):
        return None
    times = {k: value.get(k) for k in ('since', 'expires')}
    if not all(isinstance(t, str) and re.match(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,3})?Z$', t) for t in times.values()):
        return None
    return {'holder': value['holder'], 'label': _clean(value.get('label'), 160), 'host': _clean(value.get('host'), 40),
            'purpose': _clean(value.get('purpose'), 200), **times,
            'auto': value.get('auto') if value.get('auto') in AUTO_ORIGINS else None}


def shape_status(raw, received_at):
    """Allowlisted daemon report; ValueError if it is not one."""
    if not isinstance(raw, dict) or raw.get('version') != 1 or not isinstance(raw.get('bots'), dict):
        raise ValueError('not a controller status')
    daemon = raw.get('daemon') if isinstance(raw.get('daemon'), dict) else {}
    try:
        registry = parse_registry(raw.get('registry'))
        registry_error = None
    except ValueError as exc:
        registry, registry_error = None, str(exc)[:120]
    bots = {}
    for bot, entry in list(raw['bots'].items())[:300]:
        kind = account_type(bot)
        if kind is None or not isinstance(entry, dict):
            continue
        job = entry.get('job') if isinstance(entry.get('job'), dict) else None
        display = entry.get('displayName')
        bots[bot] = {
            'type': kind, 'displayName': display if kind == 'player' and isinstance(display, str) and DISPLAY.match(display) else None,
            'presence': entry.get('presence') if entry.get('presence') in PRESENCES else 'unknown',
            'client': entry.get('client') if entry.get('client') in CLIENTS else None,
            'mode': entry.get('mode') if entry.get('mode') in MODES else None,
            'log': sanitize_log(entry.get('log')),
            'state': entry.get('state') if entry.get('state') in STATES else 'unknown',
            'message': _clean(entry.get('message'), 240), 'rev': _int(entry.get('rev')),
            'action': entry.get('action') if entry.get('action') in ('run', 'stop', 'hold') else None,
            'job': None if job is None else {
                'kind': job.get('kind') if job.get('kind') in ('run', 'stop') else None,
                'routine': job.get('routine') if isinstance(job.get('routine'), str) and ROUTINE_ID.match(job['routine']) else None,
                'args': [a for a in (job.get('args') if isinstance(job.get('args'), list) else [])[:6] if isinstance(a, str) and VALUE.match(a)],
                'mode': job.get('mode') if job.get('mode') in MODES else 'headless',
                'pid': _int(job.get('pid'), 1, 1 << 31), 'startedAt': _int(job.get('startedAt')), 'stopping': job.get('stopping') is True,
                'note': _clean(job.get('note'), 240)},
            'gather': {rid: cid for rid, cid in list((entry.get('gather') if isinstance(entry.get('gather'), dict) else {}).items())[:6]
                       if isinstance(rid, str) and ROUTINE_ID.match(rid) and isinstance(cid, str) and CHOICE_ID.match(cid)},
            'gates': _shape_list(entry.get('gates')), 'foreign': _shape_list(entry.get('foreign')),
            'reservation': shape_reservation(entry.get('reservation')),
            'lastResult': _shape_result(entry.get('lastResult')), 'updatedAt': _int(entry.get('updatedAt')),
        }
    commit = daemon.get('commit')
    return {
        'version': 1, 'receivedAt': received_at, 'updatedAt': _int(raw.get('updatedAt')),
        'daemon': {'pid': _int(daemon.get('pid'), 1, 1 << 31), 'host': _clean(daemon.get('host'), 40),
                   'startedAt': _int(daemon.get('startedAt')), 'intervalMs': _int(daemon.get('intervalMs'), 1000, 600_000),
                   'dryRun': daemon.get('dryRun') is True, 'portalOk': daemon.get('portalOk') is True,
                   'commit': commit if isinstance(commit, str) and re.match(r'^[0-9a-f]{4,40}$', commit) else None,
                   'error': _clean(daemon.get('error'), 200)},
        'registry': registry, 'registryError': registry_error,
        'gatherChoices': shape_choices(raw.get('gatherChoices')),
        'fleet': {'pause': (raw.get('fleet') or {}).get('pause') is True if isinstance(raw.get('fleet'), dict) else False},
        'maintenance': shape_maintenance(raw.get('maintenance')),
        'bots': bots,
    }


CHOICE_ID = re.compile(r'^c[0-9]{1,4}$')
CHOICE_ARGS = ('resource', 'location', 'handling')


def shape_choices(raw):
    """Per-account gathering choices (daemon gatherChoices): id -> {off: {arg: {by, map: {key: {value: reason}}}}, notes}.
    Tokens and short reasons only (levels, tools, hazards, full spots); everything else is dropped."""
    out = {}
    for cid, table in list((raw if isinstance(raw, dict) else {}).items())[:200]:
        if not (isinstance(cid, str) and CHOICE_ID.match(cid) and isinstance(table, dict) and isinstance(table.get('off'), dict)):
            continue
        off = {}
        for arg in CHOICE_ARGS:
            spec = table['off'].get(arg)
            if not isinstance(spec, dict) or not isinstance(spec.get('map'), dict):
                continue
            by = spec.get('by') if spec.get('by') in CHOICE_ARGS else None
            shaped = {}
            for key, reasons in list(spec['map'].items())[:40]:
                if not (key == '' or isinstance(key, str) and VALUE.match(key)) or not isinstance(reasons, dict):
                    continue
                shaped[key] = {v: _clean(why, 160) for v, why in list(reasons.items())[:40]
                               if isinstance(v, str) and VALUE.match(v) and _clean(why, 160)}
            off[arg] = {'by': by, 'map': shaped}
        out[cid] = {'off': off, 'notes': _shape_list(table.get('notes'), 4, 240)}
    return out


def shape_frames(raw):
    """Validated daemon logins, bound to the revision it validated. Legacy strings fail closed."""
    if not isinstance(raw, dict):
        return {}
    return {bot: {'rev': entry['rev'], 'username': entry['username'], 'password': entry['password']} for bot, entry in list(raw.items())[:300]
            if isinstance(bot, str) and (BOT.fullmatch(bot) or PLAYER.fullmatch(bot)) and isinstance(entry, dict)
            and _int(entry.get('rev'), 1, (1 << 53) - 1) is not None
            and isinstance(entry.get('username'), str)
            and (entry['username'] == bot if BOT.fullmatch(bot) else DISPLAY.fullmatch(entry['username']))
            and isinstance(entry.get('password'), str)
            and 0 < len(entry['password']) <= MAX_PASSWORD and TEXT.fullmatch(entry['password'])}


def read_frames(path):
    try:
        return shape_frames(read_json(path, 64 * 1024))
    except (OSError, ValueError, TypeError):
        return {}


def frame_url(game_url, name, password=None):
    """The real game client for one account (`/bot?bot=NAME[&password=...]` on the game web server)."""
    query = {'bot': name}
    if password is not None:
        query['password'] = password
    return game_url.rstrip('/') + '/bot?' + urlencode(query, quote_via=quote)


def write_atomic(path, data, mode=0o600):
    path = Path(path)
    fd, tmp = tempfile.mkstemp(prefix=f'.{path.name}-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(data, stream, separators=(',', ':'))
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def read_json(path, limit=MAX_STATUS):
    with open(path, 'rb') as stream:
        data = stream.read(limit + 1)
    if len(data) > limit:
        raise ValueError('too large')
    return json.loads(data)


def read_status(path, now_ms=None):
    """Last daemon report (re-shaped) plus heartbeat age, or a 'never connected' placeholder."""
    now_ms = int(time.time() * 1000) if now_ms is None else now_ms
    try:
        if path is None:
            raise FileNotFoundError
        raw = read_json(path)
        status = shape_status(raw, _int(raw.get('receivedAt')) or 0)
    except FileNotFoundError:
        return {'available': False, 'error': 'The controller daemon has not connected yet.', 'registry': None, 'bots': {},
                'daemon': None, 'fleet': {'pause': False}, 'maintenance': None, 'ageMs': None, 'online': False}
    except (OSError, ValueError) as exc:
        return {'available': False, 'error': f'Controller status unreadable: {exc.__class__.__name__}', 'registry': None, 'bots': {},
                'daemon': None, 'fleet': {'pause': False}, 'maintenance': None, 'ageMs': None, 'online': False}
    age = max(0, now_ms - (status['receivedAt'] or 0))
    status.update({'available': True, 'ageMs': age, 'online': age <= HEARTBEAT_STALE_MS,
                   'error': None if age <= HEARTBEAT_STALE_MS else f'No controller heartbeat for {age // 1000} s: the daemon on the workstation may be stopped.'})
    return status


class RateLimit:
    def __init__(self, limit=30, window_s=60, clock=time.monotonic):
        self.limit, self.window, self.clock, self.hits = limit, window_s, clock, deque()

    def allow(self):
        now = self.clock()
        while self.hits and now - self.hits[0] > self.window:
            self.hits.popleft()
        if len(self.hits) >= self.limit:
            return False
        self.hits.append(now)
        return True


class Store:
    """desired.json (+ audit.jsonl) in the portal's controller directory, the only state it writes here."""
    AUDIT_LIMIT = 1024 * 1024

    def __init__(self, directory, clock=time.time):
        self.dir = Path(directory) if directory else None
        self.clock = clock
        self.lock = threading.Lock()
        self.rate = RateLimit()
        self.frame_rate = RateLimit(limit=60)

    def read(self):
        if self.dir is None:
            return empty_desired()
        try:
            return parse_desired(read_json(self.dir / 'desired.json'))
        except FileNotFoundError:
            return empty_desired()
        except (OSError, ValueError):
            return empty_desired()

    def audit_frame(self, account, login):
        if self.dir is not None:
            self.dir.mkdir(parents=True, exist_ok=True)
            self.audit({'at': int(self.clock() * 1000), 'by': login, 'action': 'frame', 'bots': [account]})

    def apply(self, request, registry, accounts, login):
        """Validate a UI request and record it. Returns (status, body)."""
        if self.dir is None:
            return 503, {'error': 'Controller writes are not configured on this portal.'}
        if not isinstance(request, dict):
            return 400, {'error': 'Expected a JSON object.'}
        action, bots = request.get('action'), request.get('bots')
        if action not in ACTIONS:
            return 400, {'error': 'action must be run, stop, hold or clear'}
        if not isinstance(bots, list) or not 1 <= len(bots) <= MAX_BULK or not all(isinstance(b, str) for b in bots) or len(set(bots)) != len(bots):
            return 400, {'error': f'bots: 1..{MAX_BULK} distinct account names'}
        if registry is None:
            return 409, {'error': 'No routine registry yet: the controller daemon has not reported.'}
        known = set(accounts)
        errors = {}
        args_by_bot = {}
        mode = request.get('mode', 'headless') if action == 'run' else None
        if action == 'run' and mode == 'browser' and len(bots) > 1:
            return 400, {'error': 'The browser view opens one account at a time.'}
        for bot in bots:
            if account_type(bot) is None or bot not in known:
                errors[bot[:20]] = 'not a known account'
            elif bot in ALWAYS_EXCLUDED or bot in registry['excludedBots']:
                errors[bot] = f'{bot} is not launchable from the controller'
            elif action == 'run':
                try:
                    args_by_bot[bot] = validate_run(registry, bot, request.get('routine'), request.get('args'), mode)
                except ValueError as exc:
                    errors[bot] = str(exc)
        if action == 'run' and not errors:
            spec = next((r for r in registry['routines'] if r['id'] == request.get('routine')), None)
            # Retired entries stay valid in the daemon for requests already recorded; new requests use the new entry.
            if spec and spec.get('hidden'):
                return 400, {'error': f'{spec["id"]} is retired; use the {"Mining" if spec["id"] == "mining" else "Woodcutting"} entry.'}
            # A dangerous routine starts only with the page's explicit confirmation (danger shown, OK pressed).
            if spec and spec.get('danger') and request.get('confirmDanger') is not True:
                return 400, {'error': f'{spec["id"]} is marked dangerous ({spec["danger"]}); confirm on the page to start it.'}
        if errors:
            return 400, {'error': 'Request rejected; nothing was changed.', 'bots': errors}
        if not self.rate.allow():
            return 429, {'error': 'Too many changes; wait a minute.'}
        with self.lock:
            desired = self.read()
            now = int(self.clock() * 1000)
            changed = {}
            for bot in bots:
                if action == 'clear':
                    desired['bots'].pop(bot, None)
                    changed[bot] = None
                    continue
                desired['seq'] += 1
                entry = {'action': action, 'rev': desired['seq'], 'at': now, 'by': login}
                if action == 'run':
                    entry.update(routine=request['routine'], args=args_by_bot[bot], mode=mode)
                desired['bots'][bot] = entry
                changed[bot] = entry
            desired['updatedAt'] = now
            self.dir.mkdir(parents=True, exist_ok=True)
            write_atomic(self.dir / 'desired.json', desired)
            self.audit({'at': now, 'by': login, 'action': action, 'routine': request.get('routine') if action == 'run' else None,
                        'args': request.get('args') if action == 'run' else None, 'mode': mode, 'bots': bots,
                        **({'confirmedDanger': True} if action == 'run' and request.get('confirmDanger') is True else {})})
        return 200, {'ok': True, 'changed': changed}

    def audit(self, row):
        path = self.dir / 'audit.jsonl'
        try:
            if path.exists() and path.stat().st_size > self.AUDIT_LIMIT:
                os.replace(path, self.dir / 'audit.1.jsonl')
            with open(path, 'a') as stream:
                stream.write(json.dumps(row, separators=(',', ':')) + '\n')
        except OSError:
            pass


class Auth:
    """Writes need: the owner's Tailscale identity (Tailscale-User-Login, set by `tailscale serve`
    for requests from the owner's untagged devices), the portal's own origin, a JSON body
    (cross-site forms can't send one without a CORS preflight, which is never granted) and a
    CSRF token bound to the login. GETs stay open to the tailnet as before."""

    def __init__(self, owner, origin, secret=None):
        self.owner = (owner or '').strip().lower() or None
        self.origin = (origin or '').rstrip('/') or None
        self.secret = secret or secrets.token_bytes(32)

    @staticmethod
    def login(headers):
        value = headers.get('Tailscale-User-Login')
        return value.strip().lower() if isinstance(value, str) and _text(value.strip(), 120) and value.strip() else None

    def can_write(self, headers):
        """(allowed, reason) for this identity, before CSRF/origin checks."""
        login = self.login(headers)
        if not self.owner:
            return False, 'Writes are disabled: no owner login is configured on the portal.'
        if not login:
            return False, 'Read-only: no Tailscale identity on this request (tagged device or direct access).'
        if not hmac.compare_digest(login, self.owner):
            return False, f'Read-only: signed in as {login}, not the owner.'
        return True, None

    def token(self, login):
        return hmac.new(self.secret, b'csrf:' + login.encode(), hashlib.sha256).hexdigest()

    def check_write(self, headers):
        """None if this request may write, else an error message."""
        allowed, reason = self.can_write(headers)
        if not allowed:
            return reason
        login = self.login(headers)
        if not self.origin or headers.get('Origin', '').rstrip('/') != self.origin:
            return 'Cross-origin request refused.'
        site = headers.get('Sec-Fetch-Site')
        if site is not None and site != 'same-origin':
            return 'Cross-site request refused.'
        if not (headers.get('Content-Type') or '').split(';')[0].strip().lower() == 'application/json':
            return 'Expected application/json.'
        token = headers.get('X-CSRF-Token') or ''
        if not hmac.compare_digest(token, self.token(login)):
            return 'Missing or stale CSRF token; reload the page.'
        return None


def frame_offer(name, kind, launchable, desired_entry, report):
    """Whether the page may open the browser view (the real game client) for this account, and why not."""
    if not launchable:
        return {'offered': False, 'login': False, 'reason': 'Not launchable from the controller.'}
    if report and report.get('client') == 'headless':
        return {'offered': False, 'login': False, 'reason': 'A headless client runs for this account on the workstation: stop it to use the browser view (one client per account).'}
    if kind == 'player':
        if not (report and report.get('displayName')):
            return {'offered': False, 'login': False, 'reason': 'The daemon has not reported this account yet.'}
        return {'offered': True, 'login': bool(desired_entry and desired_entry.get('action') == 'run' and desired_entry.get('mode') == 'browser'), 'reason': None}
    if desired_entry and desired_entry.get('action') == 'run' and desired_entry.get('mode') == 'browser':
        return {'offered': True, 'login': True, 'reason': None}
    return {'offered': False, 'login': False, 'reason': 'Start a routine in Browser view mode to open the game for this bot.'}


def view(accounts, live, status, desired, auth_info):
    """The page's JSON: one row per account (fleet bots and the owner's regular accounts) plus daemon/registry/auth context."""
    registry = status.get('registry')
    live_bots = {b['username']: b for b in (live.get('bots') or []) if isinstance(b, dict) and isinstance(b.get('username'), str)}
    reports = status.get('bots', {})
    # Regular accounts exist only while the daemon reports their player.sh profile.
    players = {n for n, r in reports.items() if PLAYER.match(n) and r.get('displayName')}
    names = sorted({*(a for a in accounts if BOT.match(a)), *(n for n in live_bots if BOT.match(n)),
                    *(n for n in reports if BOT.match(n)), *(n for n in desired['bots'] if BOT.match(n)), *players})
    excluded = set(ALWAYS_EXCLUDED) | set((registry or {}).get('excludedBots', []))
    rows = []
    for name in names:
        kind = account_type(name)
        report = reports.get(name)
        if kind == 'player':
            presence = {'present': 'online', 'absent': 'offline'}.get((report or {}).get('presence'), 'unknown')
            rows.append({
                'username': name, 'type': 'player', 'displayName': report['displayName'], 'presence': presence,
                'activity': None, 'routine': None, 'phase': None, 'routineState': None,
                'desired': desired['bots'].get(name), 'controller': report, 'launchable': True,
                'eligible': [] if registry is None else [r['id'] for r in registry['routines'] if r['enabled'] and not r.get('hidden') and bot_denied(registry, r, name) is None],
                'frame': frame_offer(name, kind, True, desired['bots'].get(name), report),
            })
            continue
        lb = live_bots.get(name) or {}
        activity = lb.get('activity') or {}
        routine_status = activity.get('status') or {}
        eligible = [] if registry is None or name in excluded else [
            r['id'] for r in registry['routines'] if r['enabled'] and not r.get('hidden') and bot_denied(registry, r, name) is None]
        rows.append({
            'username': name, 'type': 'bot', 'displayName': None, 'presence': lb.get('presence') or 'unknown', 'activity': activity.get('label'),
            'routine': routine_status.get('routine') or activity.get('routine'),
            'phase': routine_status.get('phase') if routine_status.get('state') == 'running' else None,
            'routineState': routine_status.get('state'),
            'desired': desired['bots'].get(name), 'controller': report,
            'launchable': name not in excluded, 'eligible': eligible,
            'frame': frame_offer(name, kind, name not in excluded, desired['bots'].get(name), report),
        })
    daemon = status.get('daemon')
    return {'version': 1, 'now': int(time.time() * 1000), 'auth': auth_info,
            'daemon': daemon, 'online': status.get('online', False), 'ageMs': status.get('ageMs'), 'error': status.get('error'),
            'registry': registry, 'registryError': status.get('registryError'), 'fleet': status.get('fleet') or {'pause': False},
            'maintenance': status.get('maintenance'),
            'gatherChoices': status.get('gatherChoices') or {},
            'liveAvailable': bool(live.get('available')), 'liveStale': bool(live.get('stale')), 'bots': rows}


def exchange(stream_in, stream_out, desired_dir, status_dir, clock=time.time):
    """Host side of the daemon's ssh call: store its status, answer with the desired state."""
    data = stream_in.read(MAX_STATUS + 1)
    if data.strip():
        if len(data) > MAX_STATUS:
            print('controller exchange: oversized status dropped', file=sys.stderr)
        else:
            try:
                raw = json.loads(data)
                status = shape_status(raw, int(clock() * 1000))
            except ValueError as exc:
                print(f'controller exchange: rejected status ({exc.__class__.__name__})', file=sys.stderr)
            else:
                Path(status_dir).mkdir(parents=True, exist_ok=True)
                write_atomic(Path(status_dir) / 'controller-status.json', status)
                # Browser-view logins go to their own file (mode 600), read only by the portal's
                # owner-only frame endpoint; shape_status never copies them into the public status.
                write_atomic(Path(status_dir) / 'controller-frames.json', shape_frames(raw.get('frames')))
    try:
        desired = parse_desired(read_json(Path(desired_dir) / 'desired.json'))
    except FileNotFoundError:
        desired = empty_desired()
    stream_out.write(json.dumps(desired, separators=(',', ':')) + '\n')
    stream_out.flush()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest='command', required=True)
    ex = sub.add_parser('exchange', help='Store the daemon status from stdin; print the desired state')
    base = Path.home() / '.local/share/rs-sdk-portal'
    ex.add_argument('--desired-dir', type=Path, default=base / 'controller')
    ex.add_argument('--status-dir', type=Path, default=base / 'live')
    args = parser.parse_args()
    if args.command == 'exchange':
        exchange(sys.stdin.buffer, sys.stdout, args.desired_dir, args.status_dir)


if __name__ == '__main__':
    main()
