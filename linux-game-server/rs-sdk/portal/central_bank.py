#!/usr/bin/env python3
"""Central bank page (/rs-sdk/central-bank/): the owner marks each item the fleet's central bank account
holds as Sell or Keep. No LLM; same trust model as the bot controller (controller.py, README.md).

    workstation: bun tools/central-bank.ts bridge          (2004Scape-Botting repo, launchd agent)
      every ~10 s:  page status JSON | ssh game-server python3 central_bank.py exchange
                    <- the owner's pending Sell/Keep edits on stdout

The bridge applies the edits to the fleet service's designations doc (compare-and-swap) and reports the
applied revision back in the next status, which retires them here. The portal only ever writes
CONTROLLER_DIR/central-bank-wanted.json (+ central-bank-audit.jsonl); `exchange` (run on the host, outside
the container) stores the status allowlisted as LIVE_DIR/central-bank-status.json, which the container
mounts read-only, so the page can never forge what the bank holds.
"""
import argparse
import json
from pathlib import Path
import re
import sys
import threading
import time

import controller

ITEM = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 '()+-]{0,39}$")
BOT = controller.BOT
POLICIES = ('sell', 'keep')
CLASSES = ('surplus', 'material', 'consumable')
STATES = ('collecting', 'away', 'absent')
MAX_ITEMS = 400
MAX_STATUS = 512 * 1024
# The bridge pushes every ~10 s; older than this means it (or the workstation) is offline.
STALE_MS = 60_000
BY = re.compile(r'^[A-Za-z0-9._%+@:-]{1,120}$')
STORE_ID = re.compile(r'^[a-z0-9-]{1,40}$')


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
        """Validate one Sell/Keep change from the page and record it. Returns (http status, body)."""
        if self.dir is None:
            return 503, {'error': 'Central bank writes are not configured on this portal.'}
        if not isinstance(request, dict) or set(request) - {'item', 'policy', 'expectAt'}:
            return 400, {'error': 'Expected {item, policy, expectAt}.'}
        item, policy, expect_at = request.get('item'), request.get('policy'), request.get('expectAt')
        if policy not in POLICIES:
            return 400, {'error': 'policy must be sell or keep'}
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
        items.append({**i, 'total': i['count'] * i['value'] if i.get('value') is not None else None,
                      'pending': p['policy'] if p else None, 'pendingRev': p['rev'] if p else None})
    return {
        'available': bool(status.get('available')), 'stale': bool(status.get('stale')), 'ageMs': status.get('ageMs'),
        'bank': status.get('bank'), 'items': items, 'designations': status.get('designations'),
        'received': status.get('received', []), 'handedOut': status.get('handedOut', []),
        'traders': status.get('traders', []), 'sales': status.get('sales', []), 'soldTotals': status.get('soldTotals', []),
        'results': status.get('results', []), 'auth': auth,
    }


def exchange(stream_in, stream_out, wanted_dir, status_dir, clock=time.time):
    """Host side of the bridge's ssh call: store its status, answer with the pending edits."""
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
    args = parser.parse_args()
    if args.command == 'exchange':
        exchange(sys.stdin.buffer, sys.stdout, args.wanted_dir, args.status_dir)


if __name__ == '__main__':
    main()
