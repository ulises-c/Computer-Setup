#!/usr/bin/env python3
"""Bounded private resource samples for the Dragonwilds status endpoint."""


import argparse
import fcntl
import json
import math
import os
from pathlib import Path
import sys
import subprocess
import time
import tempfile

WINDOW_SECONDS = 86400
MAX_SAMPLES = 1441  # one-minute buckets covering 24h plus the partial boundary


def update(state, sample):
    previous = state.get('previous')
    row = dict(sample)
    row['cpu_percent'] = None
    row['duration'] = 0
    if (previous and sample['boot'] and sample['invocation']
            and sample['boot'] == previous['boot']
            and sample['invocation'] == previous['invocation']
            and sample['cpu_ns'] is not None and previous['cpu_ns'] is not None):
        elapsed = sample['monotonic'] - previous['monotonic']
        wall_elapsed = sample['epoch'] - previous['epoch']
        if (0 < elapsed <= 180 and wall_elapsed > 0
                and abs(wall_elapsed - elapsed) < 5
                and sample['cpu_ns'] >= previous['cpu_ns']):
            row['duration'] = elapsed
            row['cpu_percent'] = (sample['cpu_ns'] - previous['cpu_ns']) / (elapsed * 1e9) * 100
    cutoff = sample['epoch'] - WINDOW_SECONDS
    samples = [s for s in state.get('samples', [])
               if cutoff <= s['epoch'] < sample['epoch']]
    # Minute buckets retain weighted CPU totals and sampled gauge sums/maxima;
    # five-second ticks never truncate the day to four hours. Keep current CPU
    # separate from the aggregate so it still describes the latest interval.
    current = row['cpu_percent']
    row.update(memory_sum=row['memory_bytes'] or 0,
               memory_count=int(row['memory_bytes'] is not None),
               memory_peak=row['memory_bytes'], cpu_peak=current,
               start_epoch=row['epoch'])
    for old in samples:
        old.setdefault('memory_sum', old['memory_bytes'] or 0)
        old.setdefault('memory_count', int(old['memory_bytes'] is not None))
        old.setdefault('memory_peak', old['memory_bytes'])
        old.setdefault('cpu_peak', old['cpu_percent'])
        old.setdefault('start_epoch', old['epoch'])
    if samples and int(samples[-1]['epoch'] // 60) == int(row['epoch'] // 60):
        old = samples.pop()
        duration = old['duration'] + row['duration']
        row['cpu_percent'] = ((old['cpu_percent'] or 0) * old['duration'] +
                              (current or 0) * row['duration']) / duration if duration else None
        row['duration'] = duration
        row['start_epoch'] = old['start_epoch']
        row['memory_sum'] += old['memory_sum']
        row['memory_count'] += old['memory_count']
        row['memory_peak'] = max((v for v in (old['memory_peak'], row['memory_peak']) if v is not None), default=None)
        row['cpu_peak'] = max((v for v in (old['cpu_peak'], current) if v is not None), default=None)
    samples = (samples + [row])[-MAX_SAMPLES:]
    cpu_rows = [(s, min(s['duration'], max(0, s['epoch'] - cutoff)))
                for s in samples if s['cpu_percent'] is not None]
    coverage = sum(duration for _, duration in cpu_rows)
    memory = [s for s in samples if s['memory_count']]
    memory_count = sum(s['memory_count'] for s in memory)
    result = {
        'cpu_percent': current,
        'cpu_current': 'unknown (warming up)' if current is None else f'{current:.1f}%',
        'cpu_avg_percent': sum(s['cpu_percent'] * duration for s, duration in cpu_rows) / coverage if coverage else None,
        'cpu_max_percent': max((s['cpu_peak'] for s, duration in cpu_rows if duration > 0), default=None),
        'history_span_seconds': sample['epoch'] - samples[0]['start_epoch'],
        'memory_bytes': sample['memory_bytes'],
        'memory_avg_bytes': sum(s['memory_sum'] for s in memory) / memory_count if memory_count else None,
        'memory_max_bytes': max((s['memory_peak'] for s in memory), default=None),
        'memory_samples': memory_count,
        'cpu_coverage_seconds': coverage,
    }
    for key, value in [('cpu_avg', result['cpu_avg_percent']), ('cpu_max', result['cpu_max_percent'])]:
        result[key] = 'unknown (no intervals)' if value is None else f'{value:.1f}%'
    for key in ('current', 'avg', 'max'):
        raw = 'memory_bytes' if key == 'current' else f'memory_{key}_bytes'
        value = result[raw]
        result[f'memory_{key}'] = format_bytes(value)
    result['sample_window'] = (f"{result['history_span_seconds'] / 3600:.2f}h/24h · "
                               f"CPU {coverage / 3600:.2f}h · "
                               f"{memory_count} memory samples")
    return {'schema': 1, 'samples': samples, 'previous': sample}, result


def format_bytes(value):
    if value is None:
        return 'unknown'
    for unit in ('B', 'KiB', 'MiB', 'GiB', 'TiB'):
        if value < 1024 or unit == 'TiB':
            return f'{value:.1f} {unit}'
        value /= 1024


def valid_sample(sample, row=False):
    if not isinstance(sample, dict):
        return False
    for key in ('epoch', 'monotonic', 'cpu_ns', 'memory_bytes'):
        value = sample.get(key)
        if value is None and key in ('cpu_ns', 'memory_bytes'):
            continue
        if type(value) not in (int, float) or not math.isfinite(value) or value < 0:
            return False
    if not all(isinstance(sample.get(key), str) and len(sample[key]) <= 128
               for key in ('invocation', 'boot')):
        return False
    if row:
        duration = sample.get('duration')
        cpu = sample.get('cpu_percent')
        if type(duration) not in (int, float) or not 0 <= duration <= 86400:
            return False
        if cpu is not None and (type(cpu) not in (int, float) or not math.isfinite(cpu) or cpu < 0):
            return False
        # Old schema-1 samples remain readable; aggregate fields, when present,
        # must be a complete, finite set rather than trusting corrupt totals.
        keys = ('memory_sum', 'memory_count', 'memory_peak', 'cpu_peak', 'start_epoch')
        if any(key in sample for key in keys):
            if not all(key in sample for key in keys):
                return False
            count = sample['memory_count']
            if type(count) is not int or not 0 <= count <= 10000:
                return False
            for key in keys:
                value = sample[key]
                if value is None and key in ('memory_peak', 'cpu_peak'):
                    continue
                if type(value) not in (int, float) or not math.isfinite(value) or value < 0:
                    return False
            if not 0 <= sample['epoch'] - sample['start_epoch'] < 60:
                return False
    return True


def load_history(path):
    if not path.exists():
        return {}, False
    try:
        if path.stat().st_size > 2_000_000:
            raise ValueError('oversized history')
        state = json.loads(path.read_text())
        if (not isinstance(state, dict) or state.get('schema') != 1
                or not isinstance(state.get('samples'), list)
                or len(state['samples']) > MAX_SAMPLES
                or not valid_sample(state.get('previous'))
                or not all(valid_sample(row, True) for row in state['samples'])):
            raise ValueError('invalid history schema')
        return state, False
    except (ValueError, TypeError):
        print('warning: resource history reset (invalid or oversized file)', file=sys.stderr)
        return {}, True


def collect_unit(unit):
    properties = ('ActiveState', 'InvocationID', 'CPUUsageNSec', 'MemoryCurrent', 'TasksCurrent', 'NRestarts', 'ActiveEnterTimestampMonotonic', 'ActiveEnterTimestamp')
    command = ['systemctl', 'show', unit]
    for key in properties:
        command += ['-p', key]
    process = subprocess.run(command, capture_output=True, text=True, check=False)
    values = dict(line.split('=', 1) for line in process.stdout.splitlines() if '=' in line)
    active = values.get('ActiveState') == 'active' and process.returncode == 0
    def counter(key):
        value = values.get(key, '')
        # systemd's UINT64_MAX is the unavailable sentinel, not an actual gauge.
        return int(value) if value.isdecimal() and int(value) < 2**64 - 1 else None
    sample = dict(epoch=time.time(), monotonic=time.monotonic(),
                  boot=Path('/proc/sys/kernel/random/boot_id').read_text().strip(),
                  invocation=values.get('InvocationID', '') if active else '',
                  cpu_ns=counter('CPUUsageNSec') if active else None,
                  memory_bytes=counter('MemoryCurrent') if active else None)
    extras = {'tasks_current': counter('TasksCurrent') if active else None,
              'restarts': counter('NRestarts'), 'invocation': sample['invocation']}
    for key in ('tasks_current', 'restarts'):
        if extras[key] is None:
            extras[key] = 'unknown'
    started = counter('ActiveEnterTimestampMonotonic')
    if active and started is not None:
        uptime = max(0, int(time.monotonic() - started / 1e6))
    elif active:
        parsed = subprocess.run(['date', '-d', values.get('ActiveEnterTimestamp', ''), '+%s'],
                                capture_output=True, text=True, check=False)
        uptime = max(0, int(time.time()) - int(parsed.stdout)) if parsed.returncode == 0 else 0
    else:
        uptime = 0
    extras.update(uptime_seconds=uptime, unit_status=values.get('ActiveState', 'unknown'))
    return sample, extras


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--history', type=Path, required=True)
    parser.add_argument('--unit', help='Collect counters from this systemd service instead of stdin')
    args = parser.parse_args()
    sample, extras = collect_unit(args.unit) if args.unit else (json.load(sys.stdin), {})
    if not valid_sample(sample):
        parser.error('invalid resource sample')
    path = args.history
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    # Keep the state separate from the public status directory served by nginx.
    with (path.parent / '.history.lock').open('a') as lock:
        os.chmod(lock.name, 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX)
        state, reset = load_history(path)
        state, result = update(state, sample)
        result.update(extras)
        if args.unit and not sample['invocation']:
            result['cpu_current'] = 'unknown (inactive)'
        result['history_reset'] = reset
        if reset:
            result['sample_window'] += '; history reset'
        fd, temporary = tempfile.mkstemp(prefix='.history.', dir=path.parent)
        try:
            with os.fdopen(fd, 'w') as output:
                json.dump(state, output, allow_nan=False, separators=(',', ':'))
                output.flush()
                os.fsync(output.fileno())
            os.replace(temporary, path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
    print(json.dumps(result, allow_nan=False))


if __name__ == '__main__':
    main()
