#!/usr/bin/env python3
"""Five-second process metrics with private sixty-second metadata cache."""
import fcntl
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

from status_metrics import collect_unit


def main():
    script = Path(__file__).resolve().parent
    history = Path(os.environ.get('STATUS_HISTORY_FILE', script / '.metrics/history.json'))
    directory = history.parent
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(directory, 0o700)
    with (directory / '.fast.lock').open('a') as lock:
        os.chmod(lock.name, 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX)
        sample, extras = collect_unit('dragonwilds.service')
        cache = directory / 'metadata.json'
        try:
            metadata = json.loads(cache.read_text())
        except (OSError, ValueError):
            metadata = {}
        age = time.time() - metadata.get('_cached_at', 0)
        if not 0 <= age < 60 or metadata.get('_invocation') != sample['invocation']:
            env = dict(os.environ, STATUS_JSON=str(cache))
            subprocess.run(['bash', str(script / 'dragonwilds-status.sh'), '--slow'], env=env, check=True)
            metadata = json.loads(cache.read_text())
            metadata.update(_cached_at=time.time(), _invocation=sample['invocation'])
            cache.write_text(json.dumps(metadata))
            os.chmod(cache, 0o600)
        process = subprocess.run(['python3', str(script / 'status_metrics.py'), '--history', str(history)],
                                 input=json.dumps(sample), capture_output=True, text=True, check=True)
        metrics = json.loads(process.stdout)
        metrics.update(extras)
        result = {k: v for k, v in metadata.items() if not k.startswith('_')}
        result.update(metrics)
        seconds = result['uptime_seconds']
        result.update(
            uptime_display=f'{seconds // 86400}d {seconds // 3600 % 24}h {seconds // 60 % 60}m {seconds % 60}s',
            cpu_summary=f"{metrics['cpu_current']} now · {metrics['cpu_avg']} avg · {metrics['cpu_max']} max",
            memory_summary=f"{metrics['memory_current']} now · {metrics['memory_avg']} avg · {metrics['memory_max']} max",
            software_summary=f"v{result['game_version']} · build {result['build'] or 'unknown'}",
            process_summary=f"{result['tasks_current']} tasks/threads · {result['restarts']} auto restarts",
            worlds_summary=f"{result['world_count']} saves · {result['worlds_on_disk'] or '—'}",
            update_summary=f"{result['update_status']} · auto {result['auto_update']}",
            metadata_refresh_seconds=60,
            metadata_age_seconds=round(time.time()-metadata['_cached_at'], 1),
            updated=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()))
        socket = subprocess.run(['ss', '-uln'], capture_output=True, text=True, check=False)
        port = os.environ.get('SERVER_PORT', '7777')
        listening = socket.returncode == 0 and any(
            len(line.split()) >= 5 and line.split()[3].rsplit(':', 1)[-1] == port
            for line in socket.stdout.splitlines()[1:])
        result['listening'] = listening
        if sample['invocation']:
            result['status'] = 'running' if listening else 'starting'
        else:
            state = extras['unit_status']
            result.update(status={'inactive': 'stopped', 'activating': 'starting'}.get(state, state),
                          game_version='unknown', cpu_current='unknown (inactive)')
        destination = Path(os.environ.get('STATUS_JSON', script / 'status/dragonwilds-status.json'))
        destination.parent.mkdir(parents=True, exist_ok=True)
        fd, temporary = tempfile.mkstemp(prefix='.status.', dir=destination.parent)
        try:
            with os.fdopen(fd, 'w') as output:
                json.dump(result, output, allow_nan=False)
            os.chmod(temporary, 0o644)
            os.replace(temporary, destination)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)


if __name__ == '__main__':
    main()
