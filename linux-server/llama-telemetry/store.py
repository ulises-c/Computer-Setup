"""SQLite storage for metadata-only llama-swap Activity records."""

import json
import os
import sqlite3
import stat
from hashlib import sha256
from contextlib import closing
from pathlib import Path
from typing import TextIO

INGEST_COLUMNS = (
    'id', 'ts_created', 'model_id', 'resp_status_code',
    'input_tokens', 'output_tokens', 'cache_tokens',
    'prompt_per_second', 'tokens_per_second', 'duration_ms',
)
_SCHEMA = '''
CREATE TABLE IF NOT EXISTS activity (
  source TEXT NOT NULL,
  id INTEGER NOT NULL,
  ts_created INTEGER NOT NULL,
  model_id TEXT NOT NULL,
  resp_status_code INTEGER NOT NULL,
  input_tokens INTEGER NOT NULL,
  output_tokens INTEGER NOT NULL,
  cache_tokens INTEGER NOT NULL,
  prompt_per_second REAL NOT NULL,
  tokens_per_second REAL NOT NULL,
  duration_ms INTEGER NOT NULL,
  PRIMARY KEY (source, id)
);
CREATE INDEX IF NOT EXISTS activity_time_model ON activity (ts_created, model_id);
'''


def _connect(path: Path) -> sqlite3.Connection:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if path.parent.stat().st_mode & 0o077:
        raise PermissionError(f'Telemetry directory is not private: {path.parent}')
    try:
        fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
    except FileExistsError:
        mode = path.lstat().st_mode
        if not stat.S_ISREG(mode) or mode & 0o077:
            raise PermissionError(f'Telemetry database is not private: {path}')
    else:
        os.close(fd)
    db = sqlite3.connect(path, timeout=15)
    db.execute('PRAGMA journal_mode=WAL')
    db.executescript(_SCHEMA)
    return db


def row_digest(row) -> str:
    values = {column: row[column] for column in INGEST_COLUMNS}
    payload = json.dumps(values, sort_keys=True, separators=(',', ':')).encode()
    return sha256(payload).hexdigest()


def cursor_state(path: Path, source: str) -> dict:
    if not path.exists():
        return {'id': 0, 'digest': None, 'first_digest': None}
    with closing(_connect(path)) as db:
        db.row_factory = sqlite3.Row
        last = db.execute(
            f'SELECT {", ".join(INGEST_COLUMNS)} FROM activity WHERE source = ? ORDER BY id DESC LIMIT 1',
            (source,),
        ).fetchone()
        first = db.execute(
            f'SELECT {", ".join(INGEST_COLUMNS)} FROM activity WHERE source = ? ORDER BY id ASC LIMIT 1',
            (source,),
        ).fetchone()
    return {
        'id': last['id'] if last else 0,
        'digest': row_digest(last) if last else None,
        'first_digest': row_digest(first) if first else None,
    }


def cursor(path: Path, source: str) -> int:
    return cursor_state(path, source)['id']


def _validate(row: object) -> tuple:
    if not isinstance(row, dict) or set(row) != set(INGEST_COLUMNS):
        raise ValueError('Activity row has unexpected fields')
    for name in ('id', 'ts_created', 'resp_status_code', 'input_tokens', 'output_tokens', 'cache_tokens', 'duration_ms'):
        if type(row[name]) is not int:
            raise ValueError(f'Invalid {name}')
    if row['id'] <= 0 or row['ts_created'] <= 0 or min(row['input_tokens'], row['output_tokens']) < 0:
        raise ValueError('Invalid activity counters')
    for name in ('model_id',):
        if not isinstance(row[name], str) or len(row[name]) > 512:
            raise ValueError(f'Invalid {name}')
    for name in ('prompt_per_second', 'tokens_per_second'):
        if type(row[name]) not in (int, float) or not (-1 <= row[name] < 1_000_000):
            raise ValueError(f'Invalid {name}')
    return tuple(row[name] for name in INGEST_COLUMNS)


def ingest(path: Path, source: str, stream: TextIO) -> int:
    if not source or len(source) > 160:
        raise ValueError('Invalid source')
    columns = ', '.join(('source', *INGEST_COLUMNS))
    slots = ', '.join('?' for _ in range(len(INGEST_COLUMNS) + 1))
    inserted = 0
    with closing(_connect(path)) as db:
        with db:
            for line in stream:
                if len(line) > 8192:
                    raise ValueError('Activity row too large')
                row = _validate(json.loads(line))
                inserted += db.execute(
                    f'INSERT OR IGNORE INTO activity ({columns}) VALUES ({slots})', (source, *row),
                ).rowcount
    return inserted


def models(path: Path) -> list[str]:
    if not path.exists():
        return []
    with closing(sqlite3.connect(f'file:{path}?mode=ro', uri=True)) as db:
        return [row[0] for row in db.execute('SELECT DISTINCT model_id FROM activity ORDER BY model_id')]


def aggregate(path: Path, start: int, end: int, bucket_seconds: int, model: str | None = None) -> list[dict]:
    if not path.exists():
        return []
    where_model = ' AND model_id = ?' if model else ''
    params = (bucket_seconds, start, end, *((model,) if model else ()))
    with closing(sqlite3.connect(f'file:{path}?mode=ro', uri=True)) as db:
        db.row_factory = sqlite3.Row
        rows = db.execute(f'''
            SELECT (ts_created / ?) * ? AS bucket, model_id AS model,
                   COUNT(*) AS requests,
                   SUM(CASE WHEN resp_status_code >= 400 THEN 1 ELSE 0 END) AS errors,
                   SUM(input_tokens) AS input_tokens, SUM(output_tokens) AS output_tokens,
                   SUM(cache_tokens) AS cache_tokens,
                   AVG(CASE WHEN prompt_per_second > 0 THEN prompt_per_second END) AS pp_tps,
                   AVG(CASE WHEN tokens_per_second > 0 THEN tokens_per_second END) AS tg_tps,
                   SUM(CASE WHEN prompt_per_second > 0 THEN 1 ELSE 0 END) AS pp_samples,
                   SUM(CASE WHEN tokens_per_second > 0 THEN 1 ELSE 0 END) AS tg_samples
            FROM activity WHERE ts_created >= ? AND ts_created < ?{where_model}
            GROUP BY bucket, model_id ORDER BY bucket, model_id
        ''', (bucket_seconds, *params)).fetchall()
    result = []
    for row in rows:
        elapsed = min(end, row['bucket'] + bucket_seconds) - max(start, row['bucket'])
        result.append(dict(row) | {'output_tps': row['output_tokens'] / elapsed})
    return result
