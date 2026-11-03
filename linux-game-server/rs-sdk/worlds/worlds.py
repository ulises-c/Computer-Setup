#!/usr/bin/env python3
"""RS-SDK world list and state, shared by world.sh and game_status.py.

  worlds.py list [--json]          configured worlds with role, image, state, players
  worlds.py env ID                 KEY=VALUE lines world.sh exports for world-compose.yml
  worlds.py row ID                 the worlds.conf row (id node role web ...)
  worlds.py logged-in NODE         accounts the login table shows on that node (read-only)
  worlds.py compat BASE CAND [--allow-content-change]
                                   compare two world-compat.js fingerprints (exit 1 = refuse)
  worlds.py allow ID list|add|remove [NAME]
                                   the world's login allowlist (state dir, never committed)

State lives in ~/.local/state/computer-setup/rs-sdk-worlds/ (WORLDS_STATE_DIR):
<id>.role (override), <id>.image (what world.sh started), <id>.allowlist,
<id>.countdown (deadline epoch while a world counts down), <id>.mode (isolated
while a test world runs on its own servers and data copy), <id>.isolated/data
(that copy), candidates.tsv.
"""
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import sys
import time
import urllib.request

HERE = Path(__file__).resolve().parent
CONFIG = Path(os.environ.get('WORLDS_CONFIG', HERE / 'worlds.conf'))
FIELDS = ('id', 'node', 'role', 'web', 'management', 'game', 'gateway', 'gateway_public', 'https_web', 'https_gateway')
ROLES = ('live', 'test')
MAIN_CONTAINER = 'rs-sdk-server'


def state_dir():
    default = Path(os.environ.get('XDG_STATE_HOME', Path.home() / '.local/state')) / 'computer-setup' / 'rs-sdk-worlds'
    return Path(os.environ.get('WORLDS_STATE_DIR', default))


def load_config(path=CONFIG):
    worlds, seen = [], {}
    for number, line in enumerate(Path(path).read_text().splitlines(), 1):
        line = line.split('#', 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) != len(FIELDS):
            raise ValueError(f'{path}:{number}: expected {len(FIELDS)} fields, got {len(parts)}')
        row = dict(zip(FIELDS, parts))
        if row['role'] not in ROLES:
            raise ValueError(f'{path}:{number}: role must be live or test')
        for key in FIELDS:
            if key != 'role':
                if not parts[FIELDS.index(key)].isdecimal():
                    raise ValueError(f'{path}:{number}: {key} must be a number')
                row[key] = int(row[key])
        for key in ('id', 'node'):
            if (key, row[key]) in seen:
                raise ValueError(f'{path}:{number}: {key} {row[key]} is used twice')
            seen[(key, row[key])] = True
        for key in FIELDS[3:]:
            if ('port', row[key]) in seen:
                raise ValueError(f'{path}:{number}: port {row[key]} is used twice')
            seen[('port', row[key])] = True
        worlds.append(row)
    if not worlds or worlds[0]['id'] != 1 or worlds[0]['node'] != 10:
        raise ValueError(f'{path}: the first row must be world 1 (node 10), the main stack')
    if worlds[0]['role'] != 'live':
        raise ValueError(f'{path}: world 1 is always live')
    return worlds


def world(world_id, worlds=None):
    for row in worlds or load_config():
        if row['id'] == int(world_id):
            return row
    raise KeyError(f'world {world_id} is not in {CONFIG}')


def read_text(path, default=''):
    try:
        return Path(path).read_text().strip()
    except OSError:
        return default


def role_of(row, state=None):
    if row['id'] == 1:
        return 'live'
    override = read_text((state or state_dir()) / f"{row['id']}.role")
    return override if override in ROLES else row['role']


def norm_name(name):
    """The login server's safe name: lower case, anything but a-z0-9 as '_'."""
    return re.sub(r'[^a-z0-9]+', '_', name.strip().lower()).strip('_')


def allowlist(world_id, state=None):
    text = read_text((state or state_dir()) / f'{world_id}.allowlist')
    return sorted({norm_name(line.split('#', 1)[0]) for line in text.splitlines() if norm_name(line.split('#', 1)[0])})


def container(row):
    return MAIN_CONTAINER if row['id'] == 1 else f"rs-sdk-world-{row['id']}"


def run(command, timeout=5):
    try:
        process = subprocess.run(command, capture_output=True, text=True, timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return process.stdout.strip() if process.returncode == 0 else None


def inspect(name):
    output = run(['docker', 'inspect', name])
    try:
        return json.loads(output)[0] if output else None
    except (ValueError, IndexError):
        return None


def http_json(url):
    try:
        with urllib.request.urlopen(url, timeout=2) as response:
            return json.loads(response.read(1_000_000))
    except (OSError, ValueError):
        return None


def tailnet_host():
    output = run(['tailscale', 'status', '--json'])
    try:
        name = json.loads(output)['Self']['DNSName'].rstrip('.') if output else ''
    except (ValueError, KeyError, TypeError):
        name = ''
    return name if re.fullmatch(r'[a-z0-9-]+\.[a-z0-9-]+\.ts\.net', name) else ''


def image_tags(image_id):
    if not image_id:
        return []
    output = run(['docker', 'image', 'inspect', '-f', '{{json .RepoTags}}', image_id])
    try:
        return json.loads(output) if output else []
    except ValueError:
        return []


def image_labels(image_id):
    if not image_id:
        return {}
    output = run(['docker', 'image', 'inspect', '-f', '{{json .Config.Labels}}', image_id])
    try:
        labels = json.loads(output) if output else {}
    except ValueError:
        labels = {}
    return {key.rsplit('.', 1)[-1]: value for key, value in (labels or {}).items()
            if key.startswith('computer-setup.rs-sdk.')}


def countdown_until(world_id, state):
    text = read_text(state / f'{world_id}.countdown')
    return int(text) if text.isdecimal() and int(text) > time.time() else None


def logged_in(data_dir, node):
    path = Path(data_dir) / 'db.sqlite'
    connection = sqlite3.connect(f'file:{path}?mode=ro', uri=True, timeout=5)
    try:
        return connection.execute('SELECT count(*) FROM account_login WHERE logged_in = ?', (node,)).fetchone()[0]
    finally:
        connection.close()


def mode_of(row, info, state):
    """'isolated' for a test world on its own login server and data copy, else 'shared'."""
    labels = ((info or {}).get('Config') or {}).get('Labels') or {}
    if labels.get('computer-setup.rs-sdk.world-mode') == 'isolated':
        return 'isolated'
    if not info and read_text(state / f"{row['id']}.mode") == 'isolated':
        return 'isolated'
    return 'shared'


def utc_iso(epoch):
    return time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(epoch)) if epoch else None


def describe(row, state, host):
    info = inspect(container(row))
    status = ((info or {}).get('State') or {}).get('Status', 'not created') if info else 'not created'
    health = (((info or {}).get('State') or {}).get('Health') or {}).get('Status')
    running = status == 'running'
    image = (info or {}).get('Image') if running else (read_text(state / f"{row['id']}.image") or None)
    live = http_json(f"http://127.0.0.1:{row['web']}/playercount") if running else None
    players = live.get('count') if isinstance(live, dict) and isinstance(live.get('count'), int) else None
    role = role_of(row, state)
    online = running and health == 'healthy'
    deadline = countdown_until(row['id'], state)
    labels = image_labels(image)
    mode = mode_of(row, info, state) if row['id'] != 1 else 'shared'
    entry = {
        'id': row['id'],
        'node': row['node'],
        'role': role,
        # isolated: its own accounts copy, login server and saves; nothing there reaches world 1.
        'mode': mode,
        'online': online,
        'state': f'{status} · {health}' if health and running else status,
        'players': players,
        'countdown_until': utc_iso(deadline),
        'image': image,
        'image_tags': image_tags(image),
        'upstream': labels.get('upstream'),
        'patches': labels.get('patches'),
        'allowlist': role == 'test',
        # Bots hop only between live worlds that are up; a test world never.
        'hoppable': role == 'live' and mode == 'shared' and online and deadline is None,
        'web_url': f"https://{host}:{row['https_web']}/" if host else None,
        'gateway_url': f"wss://{host}:{row['https_gateway']}" if host else None,
        # bot.env SERVER / GATEWAY_URL for this world.
        'bot_env': {'SERVER': f"{host}:{row['https_web']}", 'GATEWAY_URL': f"wss://{host}:{row['https_gateway']}"}
        if host else None,
    }
    if role == 'test':
        entry['allowlist_size'] = len(allowlist(row['id'], state))
    if mode == 'isolated':
        entry['note'] = 'isolated test copy of world 1: its own accounts and saves; progress there is thrown away'
    return entry


def world_list(state=None, host=None):
    state = state or state_dir()
    host = tailnet_host() if host is None else host
    return {
        'version': 1,
        'generated': utc_iso(time.time()),
        'profile': 'main',
        'note': ('Worlds share accounts, saves and banks. A client picks a world by its web URL (game) and '
                 'its gateway URL (SDK); the gateway takes no world parameter. Hop only to hoppable worlds; '
                 'leaving a world starts a 45 s hop timer before another world accepts the login.'),
        'worlds': [describe(row, state, host) for row in load_config()],
    }


def compose_env(row, state, data_dir):
    role = role_of(row, state)
    names = allowlist(row['id'], state)
    return {
        'WORLD_ID': row['id'],
        'WORLD_NODE_ID': row['node'],
        'WORLD_ROLE': role,
        'WORLD_RESTART': 'unless-stopped' if role == 'live' else 'no',
        'WORLD_ALLOWLIST_ENABLED': 'true' if role == 'test' else 'false',
        'WORLD_LOGIN_ALLOWLIST': ','.join(names),
        'WORLD_WEB_PORT': row['web'],
        'WORLD_MANAGEMENT_PORT': row['management'],
        'WORLD_GAME_PORT': row['game'],
        'WORLD_GATEWAY_PORT': row['gateway'],
        'WORLD_GATEWAY_PUBLIC_PORT': row['gateway_public'],
        'WORLD_STATE_DIR': str(state / str(row['id'])),
        'RS_SDK_DATA_DIR': data_dir,
    }


def compat(base, candidate, allow_content_change=False):
    """Problems that make a world unsafe to share saves with world 1; [] = compatible."""
    problems, warnings = [], []
    for key, what in (('xp', 'XP curve'), ('save', 'save format'), ('migrations', 'database migrations')):
        if str(base.get(key, '')).startswith('error') or str(candidate.get(key, '')).startswith('error'):
            problems.append(f'{what}: cannot fingerprint ({base.get(key)} / {candidate.get(key)})')
        elif base.get(key) != candidate.get(key):
            problems.append(f'{what} differs from world 1')
    if base.get('content') != candidate.get('content'):
        base_content, cand_content = base.get('content') or {}, candidate.get('content') or {}
        changed = sorted(k for k in set(base_content) | set(cand_content) if base_content.get(k) != cand_content.get(k)) \
            if isinstance(base_content, dict) and isinstance(cand_content, dict) else ['unknown']
        message = f"content packs differ from world 1 ({', '.join(changed)})"
        (warnings if allow_content_change else problems).append(message)
    if base.get('entrypoint') != candidate.get('entrypoint'):
        warnings.append('the image entrypoint changed: check world-entrypoint.sh still mirrors it')
    return problems, warnings


def main(argv):
    if not argv:
        print(__doc__)
        return 2
    command, args = argv[0], argv[1:]
    state = state_dir()
    if command == 'list':
        document = world_list(state)
        if '--json' in args:
            print(json.dumps(document, indent=2))
        else:
            for entry in document['worlds']:
                tags = ','.join(entry['image_tags']) or (entry['image'] or '-')[:19]
                players = '-' if entry['players'] is None else entry['players']
                extra = f" allowlist={entry.get('allowlist_size', 0)}" if entry['role'] == 'test' else ''
                if entry.get('mode') == 'isolated':
                    extra += ' ISOLATED (own data copy; progress is thrown away)'
                print(f"world {entry['id']:<4} node {entry['node']:<4} {entry['role']:<4} {entry['state']:<20} "
                      f"players={players:<4} image={tags}{extra}"
                      f"{' countdown→' + entry['countdown_until'] if entry['countdown_until'] else ''}")
        return 0
    if command == 'row':
        row = world(args[0])
        print(' '.join(str(row[key]) if key != 'role' else role_of(row, state) for key in FIELDS))
        return 0
    if command == 'env':
        row = world(args[0])
        if row['id'] == 1:
            print('world 1 is the main stack; world.sh never starts it', file=sys.stderr)
            return 1
        data_dir = os.environ.get('RS_SDK_DATA_DIR', '')
        if not data_dir:
            print('RS_SDK_DATA_DIR is not set', file=sys.stderr)
            return 1
        for key, value in compose_env(row, state, data_dir).items():
            print(f'{key}={value}')
        return 0
    if command == 'logged-in':
        print(logged_in(os.environ['RS_SDK_DATA_DIR'], int(args[0])))
        return 0
    if command == 'compat':
        base = json.loads(Path(args[0]).read_text())
        candidate = json.loads(Path(args[1]).read_text())
        problems, warnings = compat(base, candidate, '--allow-content-change' in args)
        for line in warnings:
            print(f'warning: {line}')
        for line in problems:
            print(f'refused: {line}')
        if not problems:
            print('compatible: same XP curve, save format and migrations as world 1')
        return 1 if problems else 0
    if command == 'allow':
        world_id, action = int(args[0]), args[1]
        world(world_id)
        path = state / f'{world_id}.allowlist'
        names = allowlist(world_id, state)
        if action == 'list':
            print('\n'.join(names) if names else '(empty: nobody may log in while the allowlist is on)')
            return 0
        name = norm_name(args[2]) if len(args) > 2 else ''
        if not name:
            print('a name is required', file=sys.stderr)
            return 2
        names = sorted(set(names) | {name}) if action == 'add' else [n for n in names if n != name]
        state.mkdir(parents=True, exist_ok=True)
        path.write_text(''.join(f'{n}\n' for n in names))
        os.chmod(path, 0o600)
        print(f"world {world_id} allowlist: {len(names)} name(s); restart the world to apply")
        return 0
    print(f'unknown command: {command}', file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
