#!/usr/bin/env python3
"""Central bank page (/rs-sdk/central-bank/): the owner marks each item the fleet's central bank account
holds as Sell, Keep or Alch ('alch' is a placeholder the bots treat as Keep until an alcher exists). No LLM; same trust model as the bot controller (controller.py, README.md).

    workstation: bun tools/central-bank.ts bridge          (2004Scape-Botting repo, launchd agent)
      every ~10 s:  page status JSON | ssh game-server python3 central_bank.py exchange
                    <- the owner's pending Sell/Keep edits on stdout

The bridge applies the edits to the fleet service's designations doc (compare-and-swap) and reports the
applied revision back in the next status, which retires them here. The portal only ever writes
CONTROLLER_DIR/central-bank-wanted.json (+ central-bank-audit.jsonl); `exchange` (run on the host, outside
the container) stores the status allowlisted as LIVE_DIR/central-bank-status.json, which the container
mounts read-only, so the page can never forge what the bank holds.

Item icons: `exchange` also copies each listed item's inventory icon from the wiki's own image cache
(WIKI_ROOT/images/osrs/<Name>.png, already fetched there; validated PNG, size-capped) into
LIVE_DIR/item-icons/, which the portal serves at /rs-sdk/central-bank/icons/<Name>.png. An icon the cache
lacks is recorded as a wanted wiki image by the portal (the same lazy queue the scraped wiki uses).
"""
import argparse
import json
import os
from pathlib import Path
import re
from urllib.parse import quote
import sys
import threading
import time

import controller

ITEM = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 '()+-]{0,39}$")
BOT = controller.BOT
POLICIES = ('sell', 'keep', 'alch')
CLASSES = ('surplus', 'material', 'consumable')
STATES = ('collecting', 'away', 'absent')
MAX_ITEMS = 400
MAX_STATUS = 512 * 1024
# The bridge pushes every ~10 s; older than this means it (or the workstation) is offline.
STALE_MS = 60_000
BY = re.compile(r'^[A-Za-z0-9._%+@:-]{1,120}$')
STORE_ID = re.compile(r'^[a-z0-9-]{1,40}$')
SHOP_NAME = re.compile(r"^[A-Za-z0-9 '()+.,-]{1,60}$")
SHOP_KINDS = ('general', 'specialty')
ICON = re.compile(r"^[A-Z0-9][A-Za-z0-9_'()+-]{0,44}\.png$")
ICON_MAX = 64 * 1024
PNG_MAGIC = b'\x89PNG\r\n\x1a\n'
WIKI_BASE = '/rs-sdk/wiki/2004scape/w/'
ICON_BASE = '/rs-sdk/central-bank/icons/'


def icon_file(name):
    """The wiki's inventory icon file for an item name ('Steel 2h sword' -> 'Steel_2h_sword.png'; arrows use the
    5-arrow stack picture), or None for a name that can't be one."""
    if not isinstance(name, str) or not ITEM.match(name):
        return None
    title = name[0].upper() + name[1:]
    if re.search(r' arrows?$', title):
        title = re.sub(r' arrows?$', ' arrow', title) + ' 5'
    file = title.replace(' ', '_') + '.png'
    return file if ICON.match(file) else None


def wiki_href(name):
    """The item's page on the portal's own 2004Scape wiki (this game's items; same origin)."""
    return WIKI_BASE + quote(name.replace(' ', '_'), safe="/:(),'!*@$;-._~")


def valid_png(data):
    return isinstance(data, (bytes, bytearray)) and 8 < len(data) <= ICON_MAX and data[:8] == PNG_MAGIC


def _int(value, low=0, high=1 << 53):
    return value if isinstance(value, int) and not isinstance(value, bool) and low <= value <= high else None


def _counts(value, limit=60):
    """{item: count} with valid names and non-negative counts only."""
    if not isinstance(value, dict):
        return {}
    out = {}
    for name, count in list(value.items())[:limit]:
        if isinstance(name, str) and ITEM.match(name) and _int(count) is not None:
            out[name] = count
    return out


def _quote(q):
    """One shop offer {shop, shopName, price, stock, routed, hubTiles}, or None."""
    if not isinstance(q, dict) or not isinstance(q.get('shop'), str) or not STORE_ID.match(q['shop']) or _int(q.get('price')) is None:
        return None
    return {'shop': q['shop'], 'shopName': q['shopName'] if isinstance(q.get('shopName'), str) and SHOP_NAME.match(q['shopName']) else q['shop'],
            'price': q['price'], 'stock': _int(q.get('stock')), 'routed': q.get('routed') is True, 'hubTiles': _int(q.get('hubTiles'))}


def shape_status(raw, received_at):
    """Allowlist the bridge's status: known keys, bounded strings and numbers, nothing else."""
    if not isinstance(raw, dict):
        raise ValueError('status is not an object')
    bank = raw.get('bank') if isinstance(raw.get('bank'), dict) else {}
    items = []
    for row in (raw.get('items') if isinstance(raw.get('items'), list) else [])[:MAX_ITEMS]:
        if not isinstance(row, dict) or not isinstance(row.get('name'), str) or not ITEM.match(row['name']):
            continue
        items.append({
            'name': row['name'],
            'count': _int(row.get('count')) or 0,
            'value': _int(row.get('value')),
            'policy': row.get('policy') if row.get('policy') in POLICIES else 'keep',
            'policyAt': _int(row.get('policyAt')) or 0,
            'policyBy': row['policyBy'] if isinstance(row.get('policyBy'), str) and BY.match(row['policyBy']) else None,
            'class': row.get('class') if row.get('class') in CLASSES else None,
            'buy': _int(row.get('buy')),
            'sell': _quote(row.get('sell')),
            'bestAnywhere': _quote(row.get('bestAnywhere')),
            'lowAlch': _int(row.get('lowAlch')),
            'highAlch': _int(row.get('highAlch')),
        })
    des = raw.get('designations') if isinstance(raw.get('designations'), dict) else {}

    def moves(key, who):
        out = []
        for row in (raw.get(key) if isinstance(raw.get(key), list) else [])[:20]:
            if isinstance(row, dict) and isinstance(row.get(who), str) and BOT.match(row[who]):
                out.append({who: row[who], 'at': _int(row.get('at')) or 0, 'items': _counts(row.get('items'))})
        return out

    traders = []
    for row in (raw.get('traders') if isinstance(raw.get('traders'), list) else [])[:8]:
        if isinstance(row, dict) and isinstance(row.get('bot'), str) and BOT.match(row['bot']):
            traders.append({'bot': row['bot'], 'state': row.get('state') if row.get('state') in STATES else 'absent',
                            'at': _int(row.get('at')) or 0, 'stock': _counts(row.get('stock')), 'coins': _int(row.get('coins')) or 0})
    sales = []
    for row in (raw.get('sales') if isinstance(raw.get('sales'), list) else [])[:30]:
        if isinstance(row, dict) and isinstance(row.get('item'), str) and ITEM.match(row['item']):
            sales.append({'at': _int(row.get('at')) or 0, 'bot': row['bot'] if isinstance(row.get('bot'), str) and BOT.match(row['bot']) else None,
                          'item': row['item'], 'price': _int(row.get('price')) or 0,
                          'store': row['store'] if isinstance(row.get('store'), str) and STORE_ID.match(row['store']) else None})
    totals = []
    for row in (raw.get('soldTotals') if isinstance(raw.get('soldTotals'), list) else [])[:60]:
        if isinstance(row, dict) and isinstance(row.get('item'), str) and ITEM.match(row['item']):
            totals.append({'item': row['item'], 'count': _int(row.get('count')) or 0, 'coins': _int(row.get('coins')) or 0})
    results = []
    for row in (raw.get('results') if isinstance(raw.get('results'), list) else [])[-20:]:
        if isinstance(row, dict) and _int(row.get('rev'), 1) is not None and isinstance(row.get('item'), str) and ITEM.match(row['item']):
            results.append({'rev': row['rev'], 'item': row['item'], 'ok': row.get('ok') is True, 'at': _int(row.get('at')) or 0,
                            'error': controller._clean(row.get('error'), 160) if row.get('ok') is not True else None})
    alch = raw.get('alch') if isinstance(raw.get('alch'), dict) else {}
    cost = alch.get('castCost') if isinstance(alch.get('castCost'), dict) else {}
    shops = []
    for row in (raw.get('shops') if isinstance(raw.get('shops'), list) else [])[:30]:
        if isinstance(row, dict) and isinstance(row.get('id'), str) and STORE_ID.match(row['id']) and isinstance(row.get('name'), str) and SHOP_NAME.match(row['name']):
            shops.append({'id': row['id'], 'name': row['name'], 'kind': row.get('kind') if row.get('kind') in SHOP_KINDS else None,
                          'routed': row.get('routed') is True, 'hubTiles': _int(row.get('hubTiles')),
                          'measured': controller._clean(row.get('measured'), 120) if isinstance(row.get('measured'), str) else ''})
    return {
        'receivedAt': received_at,
        'generatedAt': _int(raw.get('generatedAt')) or 0,
        'bank': {'bot': bank['bot'] if isinstance(bank.get('bot'), str) and BOT.match(bank['bot']) else None,
                 'state': bank.get('state') if bank.get('state') in STATES else 'absent',
                 'at': _int(bank.get('at')) or 0,
                 'hub': controller._clean(bank.get('hub'), 40) if isinstance(bank.get('hub'), str) else None,
                 'holdingsAt': _int(bank.get('holdingsAt')) or 0,
                 'coins': _int(bank.get('coins')) or 0},
        'items': items,
        'designations': {'version': _int(des.get('version'), -1) if _int(des.get('version'), -1) is not None else -1,
                         'appliedRev': _int(des.get('appliedRev')) or 0},
        'received': moves('received', 'from'),
        'handedOut': moves('handedOut', 'to'),
        'traders': traders,
        'sales': sales,
        'soldTotals': totals,
        'results': results,
        'alch': {'castCost': {'low': _int(cost.get('low')), 'high': _int(cost.get('high'))}, 'natureBuyable': alch.get('natureBuyable') is True},
        'shops': shops,
    }


def read_status(path, now_ms=None):
    """The last stored status plus its age; {'available': False} when there is none."""
    now_ms = now_ms if now_ms is not None else int(time.time() * 1000)
    try:
        status = controller.read_json(path, MAX_STATUS) if path else None
    except (OSError, ValueError):
        status = None
    if not isinstance(status, dict):
        return {'available': False, 'stale': True, 'ageMs': None, 'items': [], 'bank': None, 'designations': {'version': -1, 'appliedRev': 0}}
    age = max(0, now_ms - (status.get('receivedAt') or 0))
    return {**status, 'available': True, 'ageMs': age, 'stale': age > STALE_MS}


def empty_wanted():
    return {'version': 1, 'seq': 0, 'edits': {}}


def parse_wanted(raw):
    if not isinstance(raw, dict) or raw.get('version') != 1:
        return empty_wanted()
    edits = {}
    for key, e in (raw.get('edits') if isinstance(raw.get('edits'), dict) else {}).items():
        if (isinstance(e, dict) and isinstance(e.get('item'), str) and ITEM.match(e['item']) and e['item'].lower() == key
                and e.get('policy') in POLICIES and _int(e.get('rev'), 1) is not None and _int(e.get('expectAt')) is not None
                and isinstance(e.get('by'), str) and BY.match(e['by'])):
            edits[key] = {'rev': e['rev'], 'item': e['item'], 'policy': e['policy'], 'expectAt': e['expectAt'], 'by': e['by'], 'at': _int(e.get('at')) or 0}
    return {'version': 1, 'seq': _int(raw.get('seq')) or 0, 'edits': edits}


def pending(wanted, applied_rev):
    """Edits the bridge has not applied yet, oldest first."""
    return sorted((e for e in wanted['edits'].values() if e['rev'] > applied_rev), key=lambda e: e['rev'])


class Store:
    """central-bank-wanted.json (+ central-bank-audit.jsonl) in the portal's controller directory."""
    AUDIT_LIMIT = 1024 * 1024

    def __init__(self, directory, clock=time.time):
        self.dir = Path(directory) if directory else None
        self.clock = clock
        self.lock = threading.Lock()
        self.rate = controller.RateLimit(limit=60)

    def read(self):
        if self.dir is None:
            return empty_wanted()
        try:
            return parse_wanted(controller.read_json(self.dir / 'central-bank-wanted.json', 256 * 1024))
        except (OSError, ValueError):
            return empty_wanted()

    def apply(self, request, status, login):
        """Validate one Sell/Keep/Alch change from the page and record it. Returns (http status, body)."""
        if self.dir is None:
            return 503, {'error': 'Central bank writes are not configured on this portal.'}
        if not isinstance(request, dict) or set(request) - {'item', 'policy', 'expectAt'}:
            return 400, {'error': 'Expected {item, policy, expectAt}.'}
        item, policy, expect_at = request.get('item'), request.get('policy'), request.get('expectAt')
        if policy not in POLICIES:
            return 400, {'error': 'policy must be sell, keep or alch'}
        if not isinstance(item, str) or not ITEM.match(item):
            return 400, {'error': 'not an item name'}
        if _int(expect_at) is None:
            return 400, {'error': 'expectAt: the mark time the page showed (0 = never marked)'}
        if not status.get('available'):
            return 409, {'error': 'No central bank status yet: the workstation bridge has not reported.'}
        known = {i['name'].lower(): i for i in status.get('items', [])}
        row = known.get(item.lower())
        if row is None:
            return 400, {'error': f'{item} is not in the central bank list.'}
        if not self.rate.allow():
            return 429, {'error': 'Too many changes; wait a minute.'}
        applied = (status.get('designations') or {}).get('appliedRev', 0)
        with self.lock:
            wanted = self.read()
            # Edits the bridge already applied are retired here (the host side never rewrites this file).
            wanted['edits'] = {k: e for k, e in wanted['edits'].items() if e['rev'] > applied}
            now = int(self.clock() * 1000)
            wanted['seq'] = max(wanted['seq'], applied) + 1
            entry = {'rev': wanted['seq'], 'item': row['name'], 'policy': policy, 'expectAt': expect_at, 'by': login, 'at': now}
            wanted['edits'][row['name'].lower()] = entry
            self.dir.mkdir(parents=True, exist_ok=True)
            controller.write_atomic(self.dir / 'central-bank-wanted.json', wanted)
            self.audit({'at': now, 'by': login, 'item': row['name'], 'policy': policy, 'rev': entry['rev'], 'from': row.get('policy')})
        return 200, {'ok': True, 'edit': entry}

    def audit(self, row):
        path = self.dir / 'central-bank-audit.jsonl'
        try:
            if path.exists() and path.stat().st_size > self.AUDIT_LIMIT:
                path.replace(self.dir / 'central-bank-audit.1.jsonl')
            with open(path, 'a') as stream:
                stream.write(json.dumps(row, separators=(',', ':')) + '\n')
        except OSError:
            pass


def view(status, wanted, auth):
    """The page's JSON: the bank's items with their mark and any pending change, the traders, sales, auth."""
    applied = (status.get('designations') or {}).get('appliedRev', 0)
    waiting = {e['item'].lower(): e for e in pending(wanted, applied)}
    items = []
    for i in status.get('items', []):
        p = waiting.get(i['name'].lower())
        icon = icon_file(i['name'])
        items.append({**i, 'total': i['count'] * i['value'] if i.get('value') is not None else None,
                      'pending': p['policy'] if p else None, 'pendingRev': p['rev'] if p else None,
                      'icon': ICON_BASE + quote(icon) if icon else None, 'wiki': wiki_href(i['name'])})
    return {
        'available': bool(status.get('available')), 'stale': bool(status.get('stale')), 'ageMs': status.get('ageMs'),
        'bank': status.get('bank'), 'items': items, 'designations': status.get('designations'),
        'received': status.get('received', []), 'handedOut': status.get('handedOut', []),
        'traders': status.get('traders', []), 'sales': status.get('sales', []), 'soldTotals': status.get('soldTotals', []),
        'results': status.get('results', []), 'auth': auth,
        'alch': status.get('alch') or {'castCost': {'low': None, 'high': None}, 'natureBuyable': False}, 'shops': status.get('shops', []),
    }


def read_icon(directory, file):
    """Bytes of a stored item icon, or None (unknown name, missing, or not a small PNG)."""
    if directory is None or not isinstance(file, str) or not ICON.match(file):
        return None
    try:
        dir_fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            fd = os.open(file, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dir_fd)
        finally:
            os.close(dir_fd)
        with os.fdopen(fd, 'rb') as stream:
            data = stream.read(ICON_MAX + 1)
    except OSError:
        return None
    return bytes(data) if valid_png(data) else None


def sync_icons(names, wiki_images, icon_dir):
    """Copy each item's icon from the wiki image cache into icon_dir when it is missing there or changed (host
    side, every exchange). Returns the files copied."""
    copied = []
    if not wiki_images or not Path(wiki_images).is_dir():
        return copied
    target = Path(icon_dir)
    for name in names:
        file = icon_file(name)
        if file is None:
            continue
        src = Path(wiki_images) / file
        try:
            if not src.is_file() or src.is_symlink() or src.stat().st_size > ICON_MAX:
                continue
            dst = target / file
            if dst.is_file() and dst.stat().st_size == src.stat().st_size:
                continue
            data = src.read_bytes()
        except OSError:
            continue
        if not valid_png(data):
            continue
        target.mkdir(parents=True, exist_ok=True)
        tmp = target / (file + '.tmp')
        tmp.write_bytes(data)
        tmp.replace(dst)
        copied.append(file)
    return copied


def exchange(stream_in, stream_out, wanted_dir, status_dir, clock=time.time, wiki_images=None):
    """Host side of the bridge's ssh call: store its status, copy the listed items' icons, answer with the pending edits."""
    data = stream_in.read(MAX_STATUS + 1)
    applied = None
    if data.strip():
        if len(data) > MAX_STATUS:
            print('central bank exchange: oversized status dropped', file=sys.stderr)
        else:
            try:
                status = shape_status(json.loads(data), int(clock() * 1000))
            except ValueError as exc:
                print(f'central bank exchange: rejected status ({exc.__class__.__name__})', file=sys.stderr)
            else:
                Path(status_dir).mkdir(parents=True, exist_ok=True)
                controller.write_atomic(Path(status_dir) / 'central-bank-status.json', status)
                applied = status['designations']['appliedRev']
                try:
                    sync_icons([i['name'] for i in status['items']], wiki_images, Path(status_dir) / 'item-icons')
                except OSError as exc:
                    print(f'central bank exchange: icons not copied ({exc.__class__.__name__})', file=sys.stderr)
    try:
        wanted = parse_wanted(controller.read_json(Path(wanted_dir) / 'central-bank-wanted.json', 256 * 1024))
    except (OSError, ValueError):
        wanted = empty_wanted()
    stream_out.write(json.dumps({'edits': pending(wanted, applied or 0)}, separators=(',', ':')) + '\n')
    stream_out.flush()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest='command', required=True)
    ex = sub.add_parser('exchange', help='Store the bridge status from stdin; print the pending edits')
    base = Path.home() / '.local/share/rs-sdk-portal'
    ex.add_argument('--wanted-dir', type=Path, default=base / 'controller')
    ex.add_argument('--status-dir', type=Path, default=base / 'live')
    ex.add_argument('--wiki-images', type=Path, default=Path.home() / 'forgejo/2004Scape-Wiki/images/osrs',
                    help="The wiki's image cache to copy item icons from (missing = no icons)")
    args = parser.parse_args()
    if args.command == 'exchange':
        exchange(sys.stdin.buffer, sys.stdout, args.wanted_dir, args.status_dir, wiki_images=args.wiki_images)


if __name__ == '__main__':
    main()
