"""Push llama-swap Activity metadata to the always-on server over SSH."""

import argparse
import json
import os
import shlex
import socket
import sqlite3
import stat
import subprocess
import sys
import uuid
from contextlib import closing
from pathlib import Path

# Both platform folders travel together in the Computer-Setup checkout.
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'linux-server' / 'llama-telemetry'))
from store import INGEST_COLUMNS, row_digest


def source_id(path: Path) -> str:
    stat = path.stat()
    return f'{socket.gethostname()}:{stat.st_dev:x}:{stat.st_ino:x}'


class SSHTransport:
    def __init__(self, host: str, remote_script: str):
        self.host = host
        self.remote_script = remote_script

    def _run(self, action: str, source: str, payload: str | None = None) -> str:
        command = ' '.join(shlex.quote(word) for word in ('python3', self.remote_script, action, source))
        result = subprocess.run(
            ['ssh', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes',
             '-o', 'ConnectTimeout=10', self.host, command],
            input=payload, text=True, capture_output=True, timeout=60, check=True,
        )
        return result.stdout.strip()

    def cursor(self, source: str) -> dict:
        state = json.loads(self._run('cursor', source))
        if type(state.get('id')) is not int or state['id'] < 0 or any(
            state.get(name) is not None and not isinstance(state[name], str)
            for name in ('digest', 'first_digest')
        ) or (state['id'] > 0 and not state.get('first_digest')):
            raise ValueError('Invalid remote cursor')
        return state

    def ingest(self, source: str, payload: str) -> int:
        return int(self._run('ingest', source, payload))


def _saved_identity(source: Path, base: str) -> str:
    path = source.parent / '.llama-telemetry-source.json'
    if not path.exists() and not path.is_symlink():
        return base
    mode = path.lstat().st_mode
    if not stat.S_ISREG(mode) or mode & 0o077:
        raise PermissionError(f'Unsafe telemetry source state: {path}')
    saved = json.loads(path.read_text())
    return saved['identity'] if saved['base'] == base else base


def _rotate_identity(source: Path, base: str) -> str:
    path = source.parent / '.llama-telemetry-source.json'
    identity = f'{base}:{uuid.uuid4().hex}'
    temp = source.parent / f'.llama-telemetry-{uuid.uuid4().hex}.tmp'
    fd = os.open(temp, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump({'base': base, 'identity': identity}, stream)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp, path)
    finally:
        temp.unlink(missing_ok=True)
    return identity


def _matches_remote(db: sqlite3.Connection, remote: dict, columns: str) -> bool:
    if not remote['id']:
        return True
    last = db.execute(f'SELECT {columns} FROM activity WHERE id = ?', (remote['id'],)).fetchone()
    first = db.execute(f'SELECT {columns} FROM activity ORDER BY id LIMIT 1').fetchone()
    return bool(last and first and row_digest(last) == remote['digest'] and
                row_digest(first) == remote['first_digest'])


def push_once(source: Path, transport, batch_size: int = 500) -> int:
    if batch_size <= 0 or batch_size > 5000:
        raise ValueError('Invalid batch size')
    base = source_id(source)
    identity = _saved_identity(source, base)
    total = 0
    columns = ', '.join(INGEST_COLUMNS)
    with closing(sqlite3.connect(f'file:{source}?mode=ro', uri=True, timeout=15)) as db:
        db.row_factory = sqlite3.Row
        remote = transport.cursor(identity)
        after = remote['id']
        if not _matches_remote(db, remote, columns):
            identity = _rotate_identity(source, base)
            remote = transport.cursor(identity)
            after = remote['id']
            if not _matches_remote(db, remote, columns):
                raise ValueError('Remote cursor mismatch after source generation reset')
        while True:
            batch = db.execute(
                f'SELECT {columns} FROM activity WHERE id > ? ORDER BY id LIMIT ?',
                (after, batch_size),
            ).fetchall()
            if not batch:
                break
            payload = ''.join(json.dumps(dict(row), separators=(',', ':')) + '\n' for row in batch)
            transport.ingest(identity, payload)
            after = batch[-1]['id']
            total += len(batch)
            if len(batch) < batch_size:
                break
    return total


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--ssh-host', required=True)
    parser.add_argument('--remote-script', required=True)
    args = parser.parse_args()
    print(f'Synced {push_once(args.source, SSHTransport(args.ssh_host, args.remote_script))} activity rows')


if __name__ == '__main__':
    main()
