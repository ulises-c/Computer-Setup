import argparse
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import tempfile


CONTAINER = 'rs-sdk-server'
INSPECT = ('{"id":{{json .Id}},"image":{{json .Image}},'
           '"running":{{json .State.Running}},"startedAt":{{json .State.StartedAt}},'
           '"restartCount":{{json .RestartCount}},"workdir":{{json .Config.WorkingDir}}}')
READ = '''const fs = require('node:fs');
console.log(JSON.stringify({
    readme: fs.readFileSync('content/README.md', 'utf8'),
    client: fs.readFileSync('webclient/src/client/Client.ts', 'utf8')
}));'''


def docker(*arguments):
    result = subprocess.run(['docker', *arguments], check=True, text=True,
                            capture_output=True, timeout=20)
    return json.loads(result.stdout)


def refresh(wiki):
    data = wiki / 'data'
    data.mkdir(mode=0o700, exist_ok=True)
    info = data.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022:
        raise ValueError('metadata data directory must be user-owned and not writable by others')
    try:
        lock_fd = os.open(data / '.game-build.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    except OSError:
        (data / 'game-build.json').unlink(missing_ok=True)
        raise
    with os.fdopen(lock_fd, 'r+') as lock:
        info = os.fstat(lock.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600:
            (data / 'game-build.json').unlink(missing_ok=True)
            raise ValueError('metadata lock must be user-owned with mode 600')
        fcntl.flock(lock, fcntl.LOCK_EX)
        refresh_locked(data)


def refresh_locked(data):
    target = data / 'game-build.json'
    if os.path.lexists(target):
        info = target.lstat()
        target.unlink()
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
            raise ValueError('metadata must be a user-owned regular file, not a symlink')
    before = docker('inspect', '--format', INSPECT, CONTAINER)
    if (not isinstance(before, dict) or before.get('running') is not True
            or not re.fullmatch(r'[a-f0-9]{64}', before.get('id', ''))
            or not re.fullmatch(r'sha256:[a-f0-9]{64}', before.get('image', ''))
            or not before.get('startedAt')
            or type(before.get('restartCount')) is not int or before['restartCount'] < 0
            or before.get('workdir') != '/opt/server'):
        raise ValueError('unexpected running game container identity or working directory')
    content = docker('exec', '--workdir', before['workdir'], before['id'], 'bun', '-e', READ)
    after = docker('inspect', '--format', INSPECT, CONTAINER)
    if before != after:
        raise ValueError('game container changed during metadata probe')
    heading = re.findall(r'<h1>Lost City - ([A-Za-z]+ \d{1,2}, \d{4})</h1>', content['readme'])
    if len(heading) != 1:
        raise ValueError('content README must declare exactly one historical target')
    historical_date = datetime.strptime(heading[0], '%B %d, %Y').date().isoformat()
    revisions = re.findall(r'^\s*const CLIENT_VERSION\s*=\s*(\d+)\s*;', content['client'], re.MULTILINE)
    if len(revisions) != 1 or int(revisions[0]) <= 0:
        raise ValueError('client must declare exactly one positive protocol revision')
    identity = json.dumps([before, hashlib.sha256(content['readme'].encode()).hexdigest()], sort_keys=True)
    value = {'version': 1, 'protocolRevision': int(revisions[0]),
             'historicalContentDate': historical_date, 'historicalContentDateSource': 'content-readme',
             'contentIdentity': 'sha256:' + hashlib.sha256(identity.encode()).hexdigest(),
             'observedAt': datetime.now(timezone.utc).isoformat(), 'confidence': 'declared-target'}
    fd, name = tempfile.mkstemp(prefix='.game-build-', dir=data)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(value, stream)
            stream.write('\n')
        os.replace(name, target)
    finally:
        Path(name).unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--wiki-root', type=Path, default=Path.home() / 'forgejo/2004Scape-Wiki')
    args = parser.parse_args()
    try:
        refresh(args.wiki_root.expanduser())
    except (OSError, ValueError, subprocess.SubprocessError, KeyError, IndexError, TypeError):
        parser.exit(1, 'error: running game metadata unavailable; historical cutoff invalidated when safely accessible\n')


if __name__ == '__main__':
    main()
