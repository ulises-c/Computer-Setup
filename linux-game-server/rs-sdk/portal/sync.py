#!/usr/bin/env python3
"""Publish allowlisted read-only database views to the game-server portal."""
import argparse
from contextlib import closing
import fcntl
import hashlib
import gzip
import json
import math
import os
from pathlib import Path
import shlex
import shutil
import sqlite3
import subprocess
import sys
import tarfile
import tempfile
from urllib.parse import unquote, urlsplit
import zlib

MAX_ASSET = 8 * 1024 * 1024
MAX_CSS = 2 * 1024 * 1024
MAX_SNAPSHOT = 512 * 1024 * 1024
MAX_TOTAL = 1024 * 1024 * 1024
MAX_ENTRIES = 100000
ORIGINS = {'osrs': 'oldschool.runescape.wiki', 'rs3': 'runescape.wiki'}


def valid_hash(value):
    return isinstance(value, str) and len(value) == 64 and all(c in '0123456789abcdef' for c in value)


def safe_relative(value):
    return isinstance(value, str) and bool(value) and not any(c in value for c in ('\\', '\x00')) and all(p not in ('', '.', '..') for p in value.split('/'))


def valid_url(source, url, mime):
    if source not in ORIGINS or not isinstance(url, str) or len(url) > 8192:
        return False
    if mime == 'text/css':
        parsed = urlsplit(url)
        return parsed.scheme == 'https' and parsed.netloc == ORIGINS[source] and parsed.path.startswith('/') and not parsed.fragment
    return url.startswith('/images/') and safe_relative(unquote(url[len('/images/'):]))


def validate_asset(data, mime):
    if not data or len(data) > (MAX_CSS if mime == 'text/css' else MAX_ASSET):
        raise ValueError('Asset size limit')
    if mime == 'text/css':
        text = data.decode('utf-8')
        if '\x00' in text or text.lstrip().startswith('<'):
            raise ValueError('Invalid CSS')
        return
    if mime == 'image/png' and data.startswith(b'\x89PNG\r\n\x1a\n'):
        pos = 8
        have_header = have_pixels = False
        while pos + 12 <= len(data):
            size = int.from_bytes(data[pos:pos + 4], 'big')
            kind = data[pos + 4:pos + 8]
            end = pos + size + 12
            if end > len(data) or zlib.crc32(data[pos + 4:end - 4]) != int.from_bytes(data[end - 4:end], 'big'):
                break
            if not have_header:
                if kind != b'IHDR' or size != 13:
                    break
                width = int.from_bytes(data[pos + 8:pos + 12], 'big')
                height = int.from_bytes(data[pos + 12:pos + 16], 'big')
                if not 0 < width * height <= 40000000 or not width or not height:
                    break
                have_header = True
            if kind == b'IDAT':
                have_pixels = True
            if kind == b'IEND' and size == 0 and have_pixels and end == len(data):
                return
            pos = end
    if mime == 'image/gif' and len(data) >= 14 and data[:6] in (b'GIF87a', b'GIF89a'):
        width = int.from_bytes(data[6:8], 'little')
        height = int.from_bytes(data[8:10], 'little')
        if not width or not height or width * height > 40000000:
            raise ValueError('Raster dimensions limit')
        pos = 13 + (3 * (2 ** ((data[10] & 7) + 1)) if data[10] & 128 else 0)
        frames = 0
        while pos < len(data):
            kind = data[pos]
            pos += 1
            if kind == 0x3b and pos == len(data) and frames:
                return
            if kind == 0x21:
                pos += 1
            elif kind == 0x2c and pos + 9 < len(data):
                frame_width = int.from_bytes(data[pos + 4:pos + 6], 'little')
                frame_height = int.from_bytes(data[pos + 6:pos + 8], 'little')
                if not frame_width or not frame_height or frame_width * frame_height > 40000000:
                    break
                flags = data[pos + 8]
                pos += 9 + (3 * (2 ** ((flags & 7) + 1)) if flags & 128 else 0)
                if pos >= len(data) or not 2 <= data[pos] <= 8:
                    break
                pos += 1
                frames += 1
                if frames * width * height > 40000000:
                    break
            else:
                break
            while pos < len(data):
                size = data[pos]
                pos += 1
                if not size:
                    break
                pos += size
    if mime == 'image/jpeg' and data.startswith(b'\xff\xd8'):
        pos = 2
        dimensions = scanned = False
        while pos + 1 < len(data):
            if data[pos] != 255:
                break
            while pos < len(data) and data[pos] == 255:
                pos += 1
            if pos >= len(data):
                break
            marker = data[pos]
            pos += 1
            if marker == 0xd9 and pos == len(data) and dimensions and scanned:
                return
            if pos + 2 > len(data):
                break
            size = int.from_bytes(data[pos:pos + 2], 'big')
            if size < 2 or pos + size > len(data):
                break
            if marker in (0xc0, 0xc1, 0xc2):
                if size < 8:
                    break
                height = int.from_bytes(data[pos + 3:pos + 5], 'big')
                width = int.from_bytes(data[pos + 5:pos + 7], 'big')
                if not width or not height or width * height > 40000000:
                    break
                dimensions = True
            pos += size
            if marker == 0xda:
                scanned = True
                while pos + 1 < len(data):
                    if data[pos] != 255:
                        pos += 1
                    elif data[pos + 1] == 0 or 0xd0 <= data[pos + 1] <= 0xd7:
                        pos += 2
                    else:
                        break
    if mime == 'image/webp' and len(data) >= 30 and data[:4] == b'RIFF' and data[8:12] == b'WEBP' and int.from_bytes(data[4:8], 'little') + 8 == len(data):
        pos = 12
        pixels = False
        while pos + 8 <= len(data):
            kind = data[pos:pos + 4]
            size = int.from_bytes(data[pos + 4:pos + 8], 'little')
            start = pos + 8
            pos = start + size + (size % 2)
            if pos > len(data):
                break
            if kind == b'VP8 ' and size >= 10 and data[start + 3:start + 6] == b'\x9d\x01\x2a':
                width = int.from_bytes(data[start + 6:start + 8], 'little') & 0x3fff
                height = int.from_bytes(data[start + 8:start + 10], 'little') & 0x3fff
                pixels = True
            elif kind == b'VP8L' and size >= 5 and data[start] == 0x2f:
                bits = int.from_bytes(data[start + 1:start + 5], 'little')
                width = (bits & 0x3fff) + 1
                height = ((bits >> 14) & 0x3fff) + 1
                pixels = True
            else:
                if kind not in (b'VP8X', b'ALPH', b'ICCP', b'EXIF', b'XMP '):
                    break
                continue
            if not width or not height or width * height > 40000000:
                break
        else:
            if pos == len(data) and pixels:
                return
    raise ValueError('Unsupported or invalid raster image')


def cached_bytes(root, relative, limit):
    if not safe_relative(relative):
        raise ValueError('Unsafe cached path')
    parts = relative.split('/')
    directory = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for part in parts[:-1]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
            os.close(directory)
            directory = child
        fd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
    finally:
        os.close(directory)
    with os.fdopen(fd, 'rb') as file:
        import stat
        if not stat.S_ISREG(os.fstat(file.fileno()).st_mode):
            raise ValueError('Nonregular cache entry')
        data = file.read(limit + 1)
    if len(data) > limit:
        raise ValueError('Asset size limit')
    return data


def export_assets(wiki, snapshot, blobs):
    source = wiki / 'data/images.sqlite'
    if not source.exists():
        return
    blobs.mkdir(mode=0o700, parents=True, exist_ok=True)
    with closing(sqlite3.connect(source.resolve().as_uri() + '?mode=ro', uri=True, timeout=0.25)) as src, closing(sqlite3.connect(snapshot)) as dst:
        src.execute('PRAGMA query_only=ON')
        src.execute('BEGIN')
        total = count = 0
        for table in ('images', 'assets'):
            exists = src.execute('SELECT 1 FROM sqlite_master WHERE type=\'table\' AND name=?', (table,)).fetchone()
            if not exists:
                continue
            query = "SELECT source,path,mime,bytes,sha256 FROM images WHERE status='ok'" if table == 'images' else 'SELECT source,url,file FROM assets'
            for row in src.execute(query):
                try:
                    source_id = row[0]
                    if source_id not in ORIGINS:
                        continue
                    if table == 'images':
                        _, path, mime, size, digest = row
                        url = '/images/' + path
                        data = cached_bytes(wiki / 'images', source_id + '/' + path, MAX_ASSET)
                        if size != len(data) or digest != hashlib.sha256(data).hexdigest():
                            continue
                    else:
                        _, url, file = row
                        if not isinstance(file, str) or not file.startswith(source_id + '/') or not file.endswith('.css'):
                            continue
                        mime = 'text/css'
                        data = cached_bytes(wiki / 'assets', file, MAX_CSS)
                        digest = hashlib.sha256(data).hexdigest()
                    if not valid_url(source_id, url, mime):
                        continue
                    validate_asset(data, mime)
                except (OSError, ValueError, TypeError):
                    continue
                total += len(data)
                count += 1
                if total > MAX_TOTAL or count > MAX_ENTRIES:
                    raise ValueError('Cache manifest limit')
                (blobs / digest).write_bytes(data)
                dst.execute('INSERT INTO assets VALUES (?,?,?,?,?)', (source_id, url, digest, mime, len(data)))
        dst.commit()

TABLES = {
    'accounts.sqlite': {
        'accounts': ('username', 'status', 'purpose', 'created_at', 'first_login_at', 'last_login_at', 'login_count'),
        'deaths': ('username',),
    },
    'benchmarks.sqlite': {
        'runs': ('id', 'benchmark', 'username', 'routine_sha', 'started_at', 'finished_at', 'success', 'total_ms', 'routine_ms', 'ticks', 'steps', 'mode'),
    },
    '2004scape-wiki.sqlite': {'pages': ('id', 'source', 'title', 'text', 'brief', 'categories', 'fetched_at', 'revid')},
    'rs-sdk-wiki.sqlite': {'pages': ('id', 'source', 'title', 'text', 'fetched_at', 'revid')},
    'scraped-wiki.sqlite': {
        'pages': ('id', 'source', 'title', 'text', 'fetched_at', 'revid', 'raw_html', 'styles'),
        'assets': ('source', 'url', 'sha256', 'mime', 'size'),
        'redirects': ('source', 'from_title', 'to_title'),
    },
}
# Accepted from a sender that predates them.
OPTIONAL_TABLES = {'scraped-wiki.sqlite': {'redirects'}}
OPTIONAL_SNAPSHOTS = {'2004scape-wiki.sqlite'}
PAGE_SOURCES = {'2004scape-wiki.sqlite': ('2004scape',), 'rs-sdk-wiki.sqlite': ('rs-sdk',), 'scraped-wiki.sqlite': ('osrs', 'rs3')}
DEFAULT_TARGET = Path.home() / '.local/share/rs-sdk-portal/data'
DEFAULT_WANTED = Path.home() / '.local/share/rs-sdk-portal/wanted/wanted.sqlite'
MAX_WANTED = 100


def valid_wanted(entry):
    if not isinstance(entry, dict) or set(entry) != {'source', 'kind', 'key'} or entry['source'] not in ORIGINS:
        return False
    key = entry['key']
    if not isinstance(key, str) or not 0 < len(key) <= 1024 or any(ord(c) < 32 or ord(c) == 127 for c in key):
        return False
    if entry['kind'] == 'image':
        return safe_relative(key)
    return entry['kind'] == 'page' and len(key.encode('utf-8')) <= 255 and not any(c in key for c in '#<>[]|{}\\')


def take_wanted(path):
    """Remove and return the oldest requests the portal recorded (server side)."""
    if path.is_symlink() or not path.is_file():
        return []
    with closing(sqlite3.connect(path, timeout=5)) as db:
        db.execute('BEGIN IMMEDIATE')
        rows = db.execute('SELECT rowid,source,kind,key FROM wanted ORDER BY requested_at LIMIT ?', (MAX_WANTED,)).fetchall()
        db.executemany('DELETE FROM wanted WHERE rowid=?', [(r[0],) for r in rows])
        db.commit()
    entries = [{'source': r[1], 'kind': r[2], 'key': r[3]} for r in rows]
    return [e for e in entries if valid_wanted(e)]


def queue_wanted(root, entries):
    """Hand requested pages and images to the wiki's own fetch queues (source side)."""
    entries = [e for e in entries if valid_wanted(e)][:MAX_WANTED]
    if not entries:
        return
    bun = shutil.which('bun')
    wiki = root / '2004Scape-Wiki'
    if bun is None or not (wiki / 'src/cli.ts').is_file():
        print('Cannot queue wanted pages: bun or the wiki checkout is missing.', file=sys.stderr, flush=True)
        return
    payload = ''.join(json.dumps(e, ensure_ascii=False) + '\n' for e in entries)
    result = subprocess.run([bun, 'src/cli.ts', 'want'], cwd=wiki, input=payload, capture_output=True, text=True, timeout=60)
    print((result.stdout + result.stderr).strip() or f'wiki want exited {result.returncode}', flush=True)


def public_steps(raw):
    try:
        steps = json.loads(raw or '[]')
    except (ValueError, TypeError):
        return '[]'
    if not isinstance(steps, list):
        return '[]'
    result = []
    for step in steps:
        if not isinstance(step, dict) or not isinstance(step.get('step'), str):
            continue
        entry = {'step': step['step']}
        for key in ('ms', 'ticks'):
            value = step.get(key)
            entry[key] = value if isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) and value >= 0 else None
        result.append(entry)
    return json.dumps(result, ensure_ascii=False)


def export_db(source, destination, tables, sources=()):
    with closing(sqlite3.connect(source.resolve().as_uri() + '?mode=ro', uri=True, timeout=0.25)) as src:
        src.execute('PRAGMA query_only=ON')
        src.execute('BEGIN')
        with closing(sqlite3.connect(destination)) as dst:
            for table, columns in tables.items():
                names = ','.join(columns)
                dst.execute(f'CREATE TABLE {table} ({names})')
                if table == 'assets':
                    continue
                available = {r[1] for r in src.execute(f'PRAGMA table_info({table})')}
                if not available and any(table in optional for optional in OPTIONAL_TABLES.values()):
                    continue
                selection = ','.join('wikitext' if destination.name == '2004scape-wiki.sqlite' and c == 'text' else 'text' if destination.name == '2004scape-wiki.sqlite' and c == 'brief' else c if c in available else "'[]'" if c == 'styles' else 'NULL' if c == 'raw_html' else c for c in columns)
                where = f' WHERE source IN ({",".join("?" for _ in sources)})' if sources else ''
                rows = src.execute(f'SELECT {selection} FROM {table}' + where, sources)
                def projected_rows():
                    for row in rows:
                        yield tuple(public_steps(value) if column == 'steps' else value for column, value in zip(columns, row))
                dst.executemany(f'INSERT INTO {table} VALUES ({",".join("?" for _ in columns)})', projected_rows())
            dst.commit()
    destination.chmod(0o600)


def inventory(target):
    if target.is_symlink():
        raise ValueError('Symlink inventory target')
    assets = target / 'assets'
    if not assets.exists():
        return []
    if assets.is_symlink():
        raise ValueError('Symlink assets directory')
    result = []
    for path in assets.iterdir():
        if valid_hash(path.name):
            try:
                data = cached_bytes(assets, path.name, MAX_ASSET)
                if hashlib.sha256(data).hexdigest() == path.name:
                    result.append(path.name)
            except (OSError, ValueError):
                continue
        if len(result) > MAX_ENTRIES:
            raise ValueError('Inventory limit')
    return sorted(result)


def check_snapshot(dest, name):
    with closing(sqlite3.connect(dest.as_uri() + '?mode=ro', uri=True)) as db:
        db.execute('PRAGMA trusted_schema=OFF')
        if db.execute('PRAGMA quick_check').fetchone()[0] != 'ok':
            raise ValueError('Snapshot integrity failure')
        objects = list(db.execute("SELECT type,name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'"))
        actual_tables = {name for kind, name in objects if kind == 'table'}
        expected = TABLES[name]
        legacy = name == 'scraped-wiki.sqlite' and actual_tables == {'pages'}
        if not (set(expected) - OPTIONAL_TABLES.get(name, set()) <= actual_tables <= set(expected)) and not legacy:
            raise ValueError('Unexpected tables')
        if any(kind != 'table' for kind, _ in objects):
            raise ValueError('Unexpected database objects')
        for table in actual_tables:
            if any(r[6] for r in db.execute(f'PRAGMA table_xinfo({table})')):
                raise ValueError('Unexpected generated column')
            columns = tuple(r[1] for r in db.execute(f'PRAGMA table_info({table})'))
            allowed = expected[table][:6] if legacy else expected[table]
            if columns != allowed:
                raise ValueError('Unexpected columns')
        if name in PAGE_SOURCES:
            allowed = PAGE_SOURCES[name]
            wrong = db.execute(f'SELECT 1 FROM pages WHERE source IS NULL OR source NOT IN ({",".join("?" for _ in allowed)}) LIMIT 1', allowed).fetchone()
            if wrong:
                raise ValueError('Unexpected wiki collection')
        if 'redirects' in actual_tables:
            for row in db.execute('SELECT source,from_title,to_title FROM redirects'):
                if row[0] not in ORIGINS or not all(isinstance(v, str) and 0 < len(v) <= 512 for v in row[1:]):
                    raise ValueError('Invalid redirect')
        result = []
        if name == 'scraped-wiki.sqlite' and not legacy:
            seen = set()
            for source, url, digest, mime, size in db.execute('SELECT source,url,sha256,mime,size FROM assets'):
                if not valid_hash(digest) or mime not in ('image/png', 'image/jpeg', 'image/gif', 'image/webp', 'text/css') or not valid_url(source, url, mime) or type(size) is not int or not 0 < size <= (MAX_CSS if mime == 'text/css' else MAX_ASSET) or (source, url) in seen:
                    raise ValueError('Invalid asset metadata')
                seen.add((source, url))
                result.append((digest, mime, size))
                if len(result) > MAX_ENTRIES:
                    raise ValueError('Asset manifest limit')
        return result


class BoundedArchive:
    def __init__(self, stream):
        self.stream = stream
        self.total = 0

    def read(self, size):
        data = self.stream.read(min(size, MAX_TOTAL - self.total + 1))
        self.total += len(data)
        if self.total > MAX_TOTAL:
            raise ValueError('Decompressed archive limit')
        return data


def receive(stream, target):
    target.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd = os.open(target, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        with tempfile.TemporaryDirectory(prefix='.incoming-', dir=target) as tmp:
            stage = Path(tmp)
            (stage / 'assets').mkdir()
            seen = set()
            metadata = []
            total = 0
            try:
                decoded = BoundedArchive(gzip.GzipFile(fileobj=stream, mode='rb'))
                with closing(decoded.stream), tarfile.open(fileobj=decoded, mode='r|') as archive:
                    for entry in archive:
                        blob = entry.name.startswith('assets/') and valid_hash(entry.name[7:])
                        if entry.name in seen or not entry.isfile() or entry.size < 0 or (entry.name not in TABLES and not blob) or entry.size > (MAX_ASSET if blob else MAX_SNAPSHOT):
                            raise ValueError('Invalid snapshot archive')
                        seen.add(entry.name)
                        total += entry.size
                        if total > MAX_TOTAL or len(seen) > MAX_ENTRIES:
                            raise ValueError('Snapshot archive limit')
                        source = archive.extractfile(entry)
                        if source is None:
                            raise ValueError('Missing snapshot')
                        dest = stage / entry.name
                        with dest.open('wb') as out:
                            shutil.copyfileobj(source, out, length=65536)
                        if dest.stat().st_size != entry.size:
                            raise ValueError('Truncated snapshot')
                        dest.chmod(0o600)
                        if blob:
                            if hashlib.sha256(dest.read_bytes()).hexdigest() != entry.name[7:]:
                                raise ValueError('Asset hash mismatch')
                        else:
                            metadata.extend(check_snapshot(dest, entry.name))
                    while decoded.read(65536):
                        pass
            except (tarfile.TarError, EOFError, gzip.BadGzipFile, zlib.error, sqlite3.DatabaseError) as exc:
                raise ValueError('Invalid snapshot archive') from exc
            if not (set(TABLES) - OPTIONAL_SNAPSHOTS).issubset(seen):
                raise ValueError('Incomplete snapshot set')
            referenced = {digest for digest, _, _ in metadata}
            if any(name[7:] not in referenced for name in seen if name.startswith('assets/')):
                raise ValueError('Unreferenced asset')
            assets = target / 'assets'
            if assets.is_symlink():
                raise ValueError('Symlink assets directory')
            total = 0
            for digest, mime, size in metadata:
                base = stage / 'assets' if 'assets/' + digest in seen else assets
                try:
                    data = cached_bytes(base, digest, MAX_ASSET)
                except OSError as exc:
                    raise ValueError('Missing cached asset') from exc
                if len(data) != size or hashlib.sha256(data).hexdigest() != digest:
                    raise ValueError('Asset metadata mismatch')
                validate_asset(data, mime)
                total += size
                if total > MAX_TOTAL:
                    raise ValueError('Asset manifest limit')
            if referenced:
                assets.mkdir(mode=0o700, exist_ok=True)
                for digest in referenced:
                    if 'assets/' + digest in seen:
                        os.replace(stage / 'assets' / digest, assets / digest)
            for name in TABLES:
                if (target / name).is_symlink():
                    raise ValueError('Symlink snapshot target')
            for name in TABLES:
                if name in seen:
                    os.replace(stage / name, target / name)
    finally:
        os.close(fd)
    print(f'Published {len(set(TABLES) & seen)} sanitized database snapshots.', flush=True)


def push(root, host, receiver, curated=False):
    sources = {
        'accounts.sqlite': root / '2004Scape-Botting/data/accounts.sqlite',
        'benchmarks.sqlite': root / '2004Scape-Botting/data/benchmarks.sqlite',
        'rs-sdk-wiki.sqlite': root / '2004Scape-Wiki/data/wiki.sqlite',
        'scraped-wiki.sqlite': root / '2004Scape-Wiki/data/wiki.sqlite',
    }
    if curated:
        # Build generated pages before the read-only export. Explicitly enabled only
        # after the receiver is upgraded to accept the optional fifth snapshot.
        wiki = root / '2004Scape-Wiki'
        subprocess.run(['bun', 'src/cli.ts', 'curate'], cwd=wiki, check=True, timeout=90)
        sources['2004scape-wiki.sqlite'] = wiki / 'data/wiki.sqlite'
    with tempfile.TemporaryDirectory(prefix='rs-sdk-portal-') as tmp:
        stage = Path(tmp)
        for name, source in sources.items():
            export_db(source, stage / name, TABLES[name], sources=PAGE_SOURCES.get(name, ()))
        export_assets(root / '2004Scape-Wiki', stage / 'scraped-wiki.sqlite', stage / 'assets')
        ssh = ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8', '--', host]
        command = 'python3 ' + shlex.quote(receiver)
        result = subprocess.run(ssh + [command + ' inventory'], capture_output=True, text=True, check=True, timeout=90)
        if len(result.stdout) > MAX_ENTRIES * 70:
            raise ValueError('Remote inventory limit')
        have = json.loads(result.stdout)
        if not isinstance(have, list) or len(have) > MAX_ENTRIES or any(not valid_hash(value) for value in have):
            raise ValueError('Invalid remote inventory')
        have = set(have)
        wanted = []
        try:
            result = subprocess.run(ssh + [command + ' take-wanted'], capture_output=True, text=True, check=True, timeout=90)
            if len(result.stdout) > MAX_WANTED * 2200:
                raise ValueError('Wanted list limit')
            wanted = json.loads(result.stdout)
            if not isinstance(wanted, list):
                raise ValueError('Invalid wanted list')
        except subprocess.CalledProcessError:
            # A receiver without take-wanted predates redirects too: send what it accepts.
            for name, optional in OPTIONAL_TABLES.items():
                with closing(sqlite3.connect(stage / name)) as db:
                    for table in optional:
                        db.execute(f'DROP TABLE IF EXISTS {table}')
                    db.commit()
        except (subprocess.SubprocessError, OSError, ValueError) as exc:
            print(f'Could not take wanted pages: {exc}', file=sys.stderr, flush=True)
        with tempfile.TemporaryFile() as payload:
            with tarfile.open(fileobj=payload, mode='w:gz') as archive:
                assets = stage / 'assets'
                if assets.exists():
                    for path in sorted(assets.iterdir()):
                        if path.name not in have:
                            archive.add(path, arcname='assets/' + path.name)
                for name in sources:
                    archive.add(stage / name, arcname=name)
            payload.seek(0)
            subprocess.run(ssh + [command + ' receive'], stdin=payload, check=True, timeout=300)
        try:
            queue_wanted(root, wanted)
        except (subprocess.SubprocessError, OSError) as exc:
            print(f'Could not queue wanted pages: {exc}', file=sys.stderr, flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    sender = sub.add_parser('push')
    sender.add_argument('--root', type=Path, default=Path.home() / 'forgejo')
    sender.add_argument('--host', required=True, help='Existing SSH alias for the game server')
    sender.add_argument('--curated', action='store_true', help='Build and publish the fifth, generated 2004Scape collection (upgrade receiver first)')
    sender.add_argument('--receiver', default='github/Computer-Setup/linux-game-server/rs-sdk/portal/sync.py')
    receiver = sub.add_parser('receive')
    receiver.add_argument('--target', type=Path, default=DEFAULT_TARGET)
    inventory_parser = sub.add_parser('inventory')
    inventory_parser.add_argument('--target', type=Path, default=DEFAULT_TARGET)
    wanted_parser = sub.add_parser('take-wanted')
    wanted_parser.add_argument('--wanted', type=Path, default=DEFAULT_WANTED)
    args = parser.parse_args()
    os.umask(0o077)
    if args.command == 'push':
        push(args.root.expanduser().resolve(), args.host, args.receiver, args.curated)
    elif args.command == 'take-wanted':
        print(json.dumps(take_wanted(args.wanted.expanduser().absolute()), ensure_ascii=False))
    elif args.command == 'inventory':
        print(json.dumps(inventory(args.target.expanduser().absolute())))
    else:
        receive(sys.stdin.buffer, args.target.expanduser().absolute())


if __name__ == '__main__':
    main()
