"""World selector page: the game server's published world list, rendered without JavaScript.

The list is the status timer's `rs-sdk-worlds.json` (2004scape/game_status.py via
rs-sdk/worlds/worlds.py), mounted read-only into the portal. This module only reads it.
"""
from datetime import datetime, timezone
from html import escape
import json
import re

# The status timer rewrites the file every 15 s; older than this and the page says so.
STALE_S = 120
MAX_BYTES = 256 * 1024
REFRESH_S = 30


def esc(value):
    return escape(str(value) if value is not None else '—', quote=True)


def parse_time(text):
    """UTC datetime of an ISO time (`...Z` or with an offset), or None."""
    if not isinstance(text, str) or not text:
        return None
    try:
        stamp = datetime.fromisoformat(text.replace('Z', '+00:00'))
    except ValueError:
        return None
    if stamp.tzinfo is None:
        stamp = stamp.replace(tzinfo=timezone.utc)
    return stamp.astimezone(timezone.utc)


def read_worlds(path):
    """(document, None) or (None, reason) for the world list at `path`; never raises."""
    if path is None:
        return None, 'this portal is not configured with a world list'
    try:
        with open(path, 'rb') as stream:
            data = stream.read(MAX_BYTES + 1)
    except FileNotFoundError:
        return None, 'the world list file has not been published yet'
    except OSError:
        return None, 'the world list file cannot be read'
    if len(data) > MAX_BYTES:
        return None, 'the world list file is too large'
    if not data.strip():
        return None, 'the world list file is empty'
    try:
        document = json.loads(data.decode('utf-8'))
    except (UnicodeDecodeError, ValueError):
        return None, 'the world list file is not valid JSON'
    if not isinstance(document, dict) or not isinstance(document.get('worlds'), list):
        return None, 'the world list file has no list of worlds'
    worlds = [w for w in document['worlds'] if isinstance(w, dict) and isinstance(w.get('id'), int) and not isinstance(w.get('id'), bool)]
    if not worlds:
        return None, 'the world list contains no worlds'
    return dict(document, worlds=sorted(worlds, key=lambda w: w['id'])), None


def safe_url(value, schemes):
    """`value` if it is an absolute URL with one of `schemes`, else None (no javascript: links)."""
    if isinstance(value, str) and re.match(r'^(%s)://[^\s<>"\'`]+$' % '|'.join(schemes), value):
        return value
    return None


def short(value, length=12):
    if not isinstance(value, str) or not value:
        return None
    return value.removeprefix('sha256:')[:length]


def ago(seconds):
    seconds = int(abs(seconds))
    if seconds < 90:
        return f'{seconds} s'
    if seconds < 5400:
        return f'{round(seconds / 60)} min'
    return f'{seconds / 3600:.1f} h'


def badge(text, tone):
    return f'<span class="world-badge tone-{tone}">{esc(text)}</span>'


def world_card(world, now):
    wid = world['id']
    role = world.get('role')
    mode = world.get('mode')
    online = world.get('online') is True
    badges = [badge('Live', 'live') if role == 'live' else badge('Test', 'test') if role == 'test' else badge(role or 'unknown role', 'warn'),
              badge('Online' if online else 'Offline', 'ok' if online else 'bad')]
    if mode == 'isolated':
        badges.append(badge('Isolated', 'warn'))
    elif mode == 'shared':
        badges.append(badge('Shared', 'muted'))
    rows = []
    rows.append(('Status', f"{'Online' if online else 'Offline'} · {esc(world.get('state'))}"))
    players = world.get('players')
    rows.append(('Players online', esc(players if isinstance(players, int) and not isinstance(players, bool) else None)))
    if mode == 'isolated':
        rows.append(('Mode', 'isolated: its own copy of the accounts and saves; <b>progress is thrown away</b>'))
    elif mode == 'shared':
        rows.append(('Mode', 'shared: accounts, saves and banks are shared with the other shared worlds'))
    else:
        rows.append(('Mode', esc(mode)))
    rows.append(('Hoppable', 'yes: bots may hop here' if world.get('hoppable') is True else 'no: bots never hop here'))
    if world.get('allowlist') is True:
        size = world.get('allowlist_size')
        count = f' ({size} account{"" if size == 1 else "s"})' if isinstance(size, int) and not isinstance(size, bool) else ''
        rows.append(('Allowlist', f'allowlisted accounts only{esc(count) if count else ""}'))
    else:
        rows.append(('Allowlist', 'none: any account can log in'))
    deadline = parse_time(world.get('countdown_until'))
    if deadline is not None:
        left = (deadline - now).total_seconds()
        when = f'{deadline:%Y-%m-%d %H:%M:%S} UTC'
        rows.append(('Countdown', f'the world <b>goes down</b> at {esc(when)}' + (f' (in {ago(left)})' if left > 0 else ' (due)')))
    elif world.get('countdown_until'):
        rows.append(('Countdown', esc(world.get('countdown_until'))))
    rows.append(('Upstream', f'<code>{esc(short(world.get("upstream")))}</code>'))
    rows.append(('Patches', f'<code>{esc(short(world.get("patches")))}</code>'))
    tags = world.get('image_tags') if isinstance(world.get('image_tags'), list) else []
    title = f' title="{esc(", ".join(str(t) for t in tags))}"' if tags else ''
    rows.append(('Image', f'<code{title}>{esc(short(world.get("image")))}</code>'))
    url = safe_url(world.get('web_url'), ('https', 'http'))
    if online and url:
        play = f'<a class="world-play" href="{esc(url)}" rel="noreferrer">Play world {esc(wid)} ↗</a>'
    else:
        reason = 'offline' if not online else 'no web address'
        play = f'<span class="world-play disabled" aria-disabled="true">Play ({reason})</span>'
    note = f'<p class="world-note">{esc(world.get("note"))}</p>' if isinstance(world.get('note'), str) and world.get('note') else ''
    facts = ''.join(f'<dt>{label}</dt><dd>{value}</dd>' for label, value in rows)
    tone = 'online' if online else 'offline'
    return (f'<section class="world-card {tone}" id="world-{esc(wid)}"><small>WORLD {esc(wid)} · NODE {esc(world.get("node"))}</small>'
            f'<h2>World {esc(wid)}</h2><div class="world-badges">{"".join(badges)}</div>{note}'
            f'<dl class="world-facts">{facts}</dl>{play}</section>')


def sdk_rows(worlds):
    rows = []
    for world in worlds:
        env = world.get('bot_env') if isinstance(world.get('bot_env'), dict) else {}
        rows.append(f'<tr><td>World {esc(world["id"])}</td><td><code>SERVER={esc(env.get("SERVER"))}</code></td>'
                    f'<td><code>GATEWAY_URL={esc(env.get("GATEWAY_URL"))}</code></td></tr>')
    return ''.join(rows)


def page(path, now=None):
    """(body, head) of the world selector for the world list at `path`."""
    now = now or datetime.now(timezone.utc)
    head = f'<meta http-equiv="refresh" content="{REFRESH_S}">'
    intro = ('<div class="eyebrow">RS-SDK / Worlds</div><h1>World selector</h1>'
             '<p>Every world the game server runs, with its status. <b>Live</b> worlds are the real game; '
             '<b>Test</b> worlds come up only while an update is tested, admit allowlisted accounts only, '
             'and fleet bots never hop to them. Pick a world and press Play to open its browser client.</p>')
    document, problem = read_worlds(path)
    if document is None:
        body = intro + f'<p class="note live-warning" role="status"><b>World list unavailable</b>: {esc(problem)}. The game server publishes it every 15 seconds; reload this page in a moment.</p>'
        return body, head
    worlds = document['worlds']
    generated = parse_time(document.get('generated'))
    if generated is None:
        stamp = '<p class="note live-status stale" role="status">World list publication time unknown: the status may be out of date.</p>'
    else:
        age = (now - generated).total_seconds()
        text = f'World list generated {generated:%Y-%m-%d %H:%M:%S} UTC ({ago(age)} ago)'
        if age > STALE_S:
            stamp = f'<p class="note live-status stale" role="status">{esc(text)} · <b>stale</b>: the game server’s status timer may be down, so this status may be out of date.</p>'
        else:
            stamp = f'<p class="note live-status">{esc(text)} · this page reloads every {REFRESH_S} s.</p>'
    online = sum(1 for w in worlds if w.get('online') is True)
    body = intro + stamp
    body += f'<p>{len(worlds)} world{"" if len(worlds) == 1 else "s"} · {online} online.</p>'
    body += '<div class="world-grid">' + ''.join(world_card(w, now) for w in worlds) + '</div>'
    if isinstance(document.get('note'), str) and document['note']:
        body += f'<p class="note">{esc(document["note"])}</p>'
    body += ('<h2>SDK connection</h2><p>A bot picks its world with two values in its <code>bot.env</code>: '
             '<code>SERVER</code> (the game web server) and <code>GATEWAY_URL</code> (that world’s SDK gateway). '
             'They hold no secrets. Never point a bot at a test world.</p>')
    body += ('<div class="scroll"><table><thead><tr><th>World</th><th>SERVER</th><th>GATEWAY_URL</th></tr></thead>'
             f'<tbody>{sdk_rows(worlds)}</tbody></table></div>')
    return body, head
