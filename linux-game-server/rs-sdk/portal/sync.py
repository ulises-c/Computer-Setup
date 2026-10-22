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

from snapshot_policy import POLICY_COLUMNS, POLICY_SCHEMA, POLICY_TABLE, read_policy, validate_policy

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


def export_assets(wiki, snapshot, blobs, strict=False):
    source = wiki / 'data/images.sqlite'
    if not source.exists():
        return
    blobs.mkdir(mode=0o700, parents=True, exist_ok=True)
    metadata = []
    with closing(sqlite3.connect(source.resolve().as_uri() + '?mode=ro', uri=True, timeout=0.25)) as src:
        src.execute('PRAGMA query_only=ON')
        src.execute('BEGIN')
        row_count = 0
        for table in ('images', 'assets'):
            exists = src.execute('SELECT 1 FROM sqlite_master WHERE type=\'table\' AND name=?', (table,)).fetchone()
            if not exists:
                continue
            query = "SELECT source,path,mime,bytes,sha256 FROM images WHERE status='ok'" if table == 'images' else 'SELECT source,url,file FROM assets'
            rows = src.execute(query).fetchmany(MAX_ENTRIES + 1)
            row_count += len(rows)
            if row_count > MAX_ENTRIES:
                raise ValueError('Cache manifest limit')
            metadata.append((table, rows))
    with closing(sqlite3.connect(snapshot)) as dst:
        total = count = 0
        for table, rows in metadata:
            for row in rows:
                try:
                    source_id = row[0]
                    if source_id not in ORIGINS:
                        continue
                    if table == 'images':
                        _, path, mime, size, digest = row
                        url = '/images/' + path
                        data = cached_bytes(wiki / 'images', source_id + '/' + path, MAX_ASSET)
                        if size != len(data) or digest != hashlib.sha256(data).hexdigest():
                            if strict:
                                raise ValueError('Cached image metadata mismatch')
                            continue
                    else:
                        _, url, file = row
                        if not isinstance(file, str) or not file.startswith(source_id + '/') or not file.endswith('.css'):
                            if strict:
                                raise ValueError('Invalid cached stylesheet path')
                            continue
                        mime = 'text/css'
                        data = cached_bytes(wiki / 'assets', file, MAX_CSS)
                        digest = hashlib.sha256(data).hexdigest()
                    if not valid_url(source_id, url, mime):
                        if strict:
                            raise ValueError('Invalid cached asset URL')
                        continue
                    validate_asset(data, mime)
                except (OSError, ValueError, TypeError):
                    if strict and table == 'assets':
                        raise
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
ACCOUNT_SNAPSHOTS = {'accounts.sqlite', 'benchmarks.sqlite'}
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


def take_wanted(path, consumer=None):
    """Remove and return the oldest requests the portal recorded (server side)."""
    if path.is_symlink() or not path.is_file():
        return []
    with closing(sqlite3.connect(path, timeout=5)) as db:
        rows = db.execute('SELECT rowid,source,kind,key,requested_at FROM wanted ORDER BY requested_at LIMIT ?', (MAX_WANTED,)).fetchall()
    entries = [{'source': r[1], 'kind': r[2], 'key': r[3]} for r in rows]
    entries = [e for e in entries if valid_wanted(e)]
    if consumer is not None:
        consumer(entries)
    with closing(sqlite3.connect(path, timeout=5)) as db, db:
        db.executemany('DELETE FROM wanted WHERE rowid=? AND source=? AND kind=? AND key=? AND requested_at=?', rows)
    return entries


def queue_wanted(root, entries, *, wiki_root=None):
    """Hand requested pages and images to the wiki's own fetch queues (source side)."""
    entries = [e for e in entries if valid_wanted(e)][:MAX_WANTED]
    if not entries:
        return
    payload = ''.join(json.dumps(e, ensure_ascii=False) + '\n' for e in entries)
    if wiki_root is not None:
        result = subprocess.run([str(wiki_root / 'bin/wiki'), 'want'], cwd=wiki_root, input=payload,
                                capture_output=True, text=True, check=True, timeout=60)
        print((result.stdout + result.stderr).strip() or 'Queued wanted pages.', flush=True)
        return
    bun = shutil.which('bun')
    wiki = root / '2004Scape-Wiki'
    if bun is None or not (wiki / 'src/cli.ts').is_file():
        print('Cannot queue wanted pages: bun or the wiki checkout is missing.', file=sys.stderr, flush=True)
        return
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
        expected = dict(TABLES[name])
        optional = OPTIONAL_TABLES.get(name, set())
        if name in PAGE_SOURCES:
            expected[POLICY_TABLE] = POLICY_COLUMNS
            optional = optional | {POLICY_TABLE}
        legacy = name == 'scraped-wiki.sqlite' and actual_tables - {POLICY_TABLE} == {'pages'}
        if not (set(expected) - optional <= actual_tables <= set(expected)) and not legacy:
            raise ValueError('Unexpected tables')
        if any(kind != 'table' for kind, _ in objects):
            raise ValueError('Unexpected database objects')
        for table in actual_tables:
            if any(r[6] for r in db.execute(f'PRAGMA table_xinfo({table})')):
                raise ValueError('Unexpected generated column')
            columns = tuple(r[1] for r in db.execute(f'PRAGMA table_info({table})'))
            allowed = expected[table][:6] if legacy and table == 'pages' else expected[table]
            if columns != allowed:
                raise ValueError('Unexpected columns')
        if POLICY_TABLE in actual_tables:
            read_policy(db)
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


def receive(stream, target, accounts_only=False, *, wiki_only=False):
    allowed = set(TABLES)
    if accounts_only:
        allowed = ACCOUNT_SNAPSHOTS
    elif wiki_only:
        allowed -= ACCOUNT_SNAPSHOTS
    required = allowed if accounts_only else allowed - OPTIONAL_SNAPSHOTS
    target.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd = os.open(target, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        authority = target / '.wiki-authority'
        if not (accounts_only or wiki_only) and (authority.exists() or authority.is_symlink()):
            raise ValueError('Server-authoritative wiki rejects full uploads; use --accounts-only')
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
                        blob = not accounts_only and entry.name.startswith('assets/') and valid_hash(entry.name[7:])
                        if entry.name in seen or not entry.isfile() or entry.size < 0 or (entry.name not in allowed and not blob) or entry.size > (MAX_ASSET if blob else MAX_SNAPSHOT):
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
            if not required.issubset(seen):
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
            for name in allowed:
                if (target / name).is_symlink():
                    raise ValueError('Symlink snapshot target')
            if wiki_only:
                if authority.is_symlink():
                    raise ValueError('Symlink wiki authority marker')
                authority.touch(mode=0o600, exist_ok=True)
            if referenced:
                assets.mkdir(mode=0o700, exist_ok=True)
                for digest in referenced:
                    if 'assets/' + digest in seen:
                        os.replace(stage / 'assets' / digest, assets / digest)
            for name in allowed:
                if name in seen:
                    os.replace(stage / name, target / name)
            if not accounts_only:
                for name in OPTIONAL_SNAPSHOTS - seen:
                    (target / name).unlink(missing_ok=True)
    finally:
        os.close(fd)
    print(f'Published {len(set(TABLES) & seen)} sanitized database snapshots.', flush=True)


def write_archive(payload, stage, names, have=()):
    with tarfile.open(fileobj=payload, mode='w:gz') as archive:
        assets = stage / 'assets'
        if assets.exists():
            for path in sorted(assets.iterdir()):
                if path.name not in have:
                    archive.add(path, arcname='assets/' + path.name)
        for name in names:
            archive.add(stage / name, arcname=name)
    payload.seek(0)


def export_visible(wiki, stage, names, as_of=None):
    with tempfile.TemporaryFile() as output:
        command = [str(wiki / 'bin/wiki'), 'export-visible']
        if as_of is not None:
            command += ['--as-of', as_of]
        subprocess.run(command, cwd=wiki,
                       stdout=output, check=True, timeout=90)
        if output.tell() > MAX_SNAPSHOT:
            raise ValueError('Visible projection size limit')
        output.seek(0)
        projection = json.load(output)
    if not isinstance(projection, dict) or not isinstance(projection.get('policy'), dict) or not isinstance(projection.get('pages'), list):
        raise ValueError('Invalid visible projection')
    policy = validate_policy(projection['policy'])
    if policy['mode'] != ('automatic' if as_of is None else 'override') or policy['asOf'] != as_of:
        raise ValueError('Visible projection override does not match requested cutoff')
    if len(projection['pages']) > MAX_ENTRIES:
        raise ValueError('Visible projection page limit')
    required = {'id', 'source', 'title', 'text', 'html', 'wikitext', 'categories', 'fetched_at', 'revid'}
    seen = set()
    for page in projection['pages']:
        if not isinstance(page, dict) or not required <= page.keys():
            raise ValueError('Invalid visible page fields')
        if not isinstance(page['source'], str) or page['source'] not in ('2004scape', 'rs-sdk', 'osrs', 'rs3'):
            raise ValueError('Invalid visible page source')
        if type(page['id']) is not int or not 0 <= page['id'] < 2**63:
            raise ValueError('Invalid visible page id')
        if not isinstance(page['title'], str) or not page['title'] or not isinstance(page['text'], str):
            raise ValueError('Invalid visible page text')
        if any(page[key] is not None and not isinstance(page[key], str) for key in ('html', 'wikitext', 'categories')):
            raise ValueError('Invalid visible page content')
        if page['source'] == '2004scape' and not isinstance(page['wikitext'], str):
            raise ValueError('Invalid visible curated page')
        if type(page['fetched_at']) not in (int, float) or not math.isfinite(page['fetched_at']) or not 0 <= page['fetched_at'] < 2**63:
            raise ValueError('Invalid visible page timestamp')
        if page['revid'] is not None and (type(page['revid']) is not int or not 0 <= page['revid'] < 2**63):
            raise ValueError('Invalid visible page revision')
        if page['source'] in ORIGINS and (page.get('raw_html', '') is not None or page.get('styles') != '[]'):
            raise ValueError('Invalid visible page originals')
        identity = (page['source'], page['id'])
        if identity in seen:
            raise ValueError('Duplicate visible page')
        seen.add(identity)
    for name in names:
        with closing(sqlite3.connect(stage / name)) as db, db:
            db.execute('BEGIN')
            db.execute(POLICY_SCHEMA)
            db.execute('INSERT INTO wiki_policy VALUES (?)', (json.dumps(projection['policy']),))
            for table, columns in TABLES[name].items():
                db.execute(f'CREATE TABLE {table} ({",".join(columns)})')
            columns = TABLES[name]['pages']
            for page in projection['pages']:
                if page['source'] not in PAGE_SOURCES[name]:
                    continue
                row = dict(page, raw_html=None, styles='[]')
                if name == '2004scape-wiki.sqlite':
                    row.update(text=page['wikitext'], brief=page['text'])
                db.execute(f'INSERT INTO pages VALUES ({",".join("?" for _ in columns)})',
                           tuple(row[column] for column in columns))
        (stage / name).chmod(0o600)


def publish_wiki(wiki, target, curated=False, wanted=None, as_of=None):
    names = set(TABLES) - ACCOUNT_SNAPSHOTS - OPTIONAL_SNAPSHOTS
    if curated:
        names |= OPTIONAL_SNAPSHOTS
    with tempfile.TemporaryDirectory(prefix='rs-sdk-portal-') as tmp:
        stage = Path(tmp)
        export_visible(wiki, stage, names, as_of=as_of)
        with tempfile.TemporaryFile() as payload:
            write_archive(payload, stage, names)
            receive(payload, target, wiki_only=True)
    wanted = wanted if wanted is not None else target.parent / 'wanted/wanted.sqlite'
    take_wanted(wanted, consumer=lambda entries: queue_wanted(wiki.parent, entries, wiki_root=wiki))


def push(root, host, receiver, curated=False, accounts_only=False, as_of=None):
    if accounts_only and (curated or as_of is not None):
        raise ValueError('Accounts-only push cannot curate wiki or override --as-of')
    sources = {
        'accounts.sqlite': root / '2004Scape-Botting/data/accounts.sqlite',
        'benchmarks.sqlite': root / '2004Scape-Botting/data/benchmarks.sqlite',
    }
    wiki_names = set()
    if not accounts_only:
        wiki_names = set(PAGE_SOURCES) - OPTIONAL_SNAPSHOTS
        if curated:
            wiki_names |= OPTIONAL_SNAPSHOTS
    with tempfile.TemporaryDirectory(prefix='rs-sdk-portal-') as tmp:
        stage = Path(tmp)
        for name, source in sources.items():
            export_db(source, stage / name, TABLES[name])
        if wiki_names:
            export_visible(root / '2004Scape-Wiki', stage, wiki_names, as_of=as_of)
        names = set(sources) | wiki_names
        ssh = ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8', '--', host]
        command = 'python3 ' + shlex.quote(receiver)
        have = set()
        if not accounts_only:
            result = subprocess.run(ssh + [command + ' inventory'], capture_output=True, text=True, check=True, timeout=90)
            if len(result.stdout) > MAX_ENTRIES * 70:
                raise ValueError('Remote inventory limit')
            have = json.loads(result.stdout)
            if not isinstance(have, list) or len(have) > MAX_ENTRIES or any(not valid_hash(value) for value in have):
                raise ValueError('Invalid remote inventory')
            have = set(have)
        wanted = []
        try:
            if not accounts_only:
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
            write_archive(payload, stage, names, have)
            mode = ' --accounts-only' if accounts_only else ''
            subprocess.run(ssh + [command + ' receive' + mode], stdin=payload, check=True, timeout=300)
        try:
            if not accounts_only:
                queue_wanted(root, wanted)
        except (subprocess.SubprocessError, OSError) as exc:
            print(f'Could not queue wanted pages: {exc}', file=sys.stderr, flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    sender = sub.add_parser('push')
    sender.add_argument('--root', type=Path, default=Path.home() / 'forgejo')
    sender.add_argument('--host', required=True, help='Existing SSH alias for the game server')
    mode = sender.add_mutually_exclusive_group()
    mode.add_argument('--curated', action=argparse.BooleanOptionalAction, help='Include the fifth, generated 2004Scape snapshot (upgrade receiver first)')
    mode.add_argument('--accounts-only', action='store_true', help='Publish only accounts and benchmarks; never access wiki or wanted queues')
    sender.add_argument('--as-of', help='Explicit publication date override; validated by canonical wiki policy')
    sender.add_argument('--receiver', default='github/Computer-Setup/linux-game-server/rs-sdk/portal/sync.py')
    sender.add_argument('--bot-inputs', action=argparse.BooleanOptionalAction, default=False,
                        help='With --accounts-only, also upload allowlisted bot observations and guides')
    receiver = sub.add_parser('receive')
    receiver.add_argument('--target', type=Path, default=DEFAULT_TARGET)
    receiver.add_argument('--accounts-only', action='store_true', help='Require exactly accounts and benchmarks; preserve wiki')
    publisher = sub.add_parser('publish-wiki', help='Publish authoritative server-local wiki projections and consume local wanted requests')
    publisher.add_argument('--wiki-root', type=Path, required=True)
    publisher.add_argument('--target', type=Path, default=DEFAULT_TARGET)
    publisher.add_argument('--wanted', type=Path, help='Defaults to TARGET/../wanted/wanted.sqlite')
    publisher.add_argument('--curated', action=argparse.BooleanOptionalAction, default=False)
    publisher.add_argument('--as-of', help='Explicit publication date override; requires republishing to change')
    inventory_parser = sub.add_parser('inventory')
    inventory_parser.add_argument('--target', type=Path, default=DEFAULT_TARGET)
    wanted_parser = sub.add_parser('take-wanted')
    wanted_parser.add_argument('--wanted', type=Path, default=DEFAULT_WANTED)
    wanted_parser.add_argument('--target', type=Path, default=DEFAULT_TARGET)
    args = parser.parse_args()
    os.umask(0o077)
    if args.command == 'push':
        if args.bot_inputs and not args.accounts_only:
            parser.error('--bot-inputs requires --accounts-only')
        if args.accounts_only and args.as_of is not None:
            parser.error('--as-of cannot be used with --accounts-only')
        push(args.root.expanduser().resolve(), args.host, args.receiver, args.curated,
             accounts_only=args.accounts_only, as_of=args.as_of)
        if args.bot_inputs:
            helper = Path(__file__).resolve().parent.parent / 'wiki/inputs.py'
            subprocess.run([sys.executable, '-B', str(helper), 'push', '--host', args.host,
                            '--botting-root', str(args.root.expanduser().resolve() / '2004Scape-Botting')],
                           check=True, timeout=120)
    elif args.command == 'publish-wiki':
        publish_wiki(args.wiki_root.expanduser().resolve(), args.target.expanduser().absolute(), args.curated,
                     args.wanted.expanduser().absolute() if args.wanted is not None else None, as_of=args.as_of)
    elif args.command == 'take-wanted':
        authority = args.target.expanduser().absolute() / '.wiki-authority'
        if authority.exists() or authority.is_symlink():
            raise ValueError('Server-authoritative wiki consumes wanted locally through publish-wiki')
        print(json.dumps(take_wanted(args.wanted.expanduser().absolute()), ensure_ascii=False))
    elif args.command == 'inventory':
        print(json.dumps(inventory(args.target.expanduser().absolute())))
    else:
        receive(sys.stdin.buffer, args.target.expanduser().absolute(), accounts_only=args.accounts_only)


if __name__ == '__main__':
    main()
