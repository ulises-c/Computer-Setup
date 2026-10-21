#!/usr/bin/env python3
"""Write the status JSON behind the Lost City and RS-SDK Homepage cards.

Run by 2004scape-status.timer every 15 seconds; safe to run by hand. Each stack
gets its own document in status/, served by this directory's loopback nginx.
Resource history (24h CPU/memory) reuses the Dragonwilds sampler and lives in
the private .metrics/ directory, outside what nginx serves.
"""
import calendar
import fcntl
import json
import os
from pathlib import Path
import shlex
import sqlite3
import subprocess
import tempfile
import time
import urllib.request

HERE = Path(__file__).resolve().parent
GAME = HERE.parent
SAMPLER = GAME / 'dragonwilds' / 'status_metrics.py'
BACKUP_STATUS = Path('/var/lib/computer-setup-backup/game-backup/backup-status.json')
DAYS = ('Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun')
# maintenance.sh stops the games this long before the backup it waits for.
DOWN_BEFORE_BACKUP_SECONDS = 120


def read_env(path):
    values = {}
    try:
        lines = Path(path).read_text().splitlines()
    except OSError:
        return values
    for line in lines:
        key, sep, value = line.partition('=')
        key = key.strip()
        if not sep or not key or key.startswith('#'):
            continue
        try:
            values[key] = ''.join(shlex.split(value, comments=True))
        except ValueError:
            continue
    return values


def run(command, timeout=5):
    try:
        process = subprocess.run(command, capture_output=True, text=True, timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return process.stdout.strip() if process.returncode == 0 else None


def inspect(name):
    output = run(['docker', 'inspect', name])
    try:
        return json.loads(output)[0] if output else None
    except (ValueError, IndexError):
        return None


def utc_epoch(value, layout):
    try:
        return calendar.timegm(time.strptime(value[:19], layout))
    except (TypeError, ValueError):
        return None


def iso_epoch(value):
    """Docker's UTC timestamps carry nanoseconds, which strptime cannot parse."""
    if not value or value.startswith('0001-') or not value.endswith('Z'):
        return None
    return utc_epoch(value, '%Y-%m-%dT%H:%M:%S')


def utc_iso(epoch):
    return time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(epoch)) if epoch is not None else ''


def server_state(info):
    if info is None:
        return 'not created', 0
    state = info.get('State') or {}
    status = state.get('Status', 'unknown')
    health = (state.get('Health') or {}).get('Status')
    uptime = 0
    if status == 'running':
        started = iso_epoch(state.get('StartedAt'))
        uptime = max(0, int(time.time() - started)) if started else 0
    return (f'{status} · {health}' if health and status == 'running' else status), uptime


def read_int(path):
    try:
        return int(Path(path).read_text().split()[0])
    except (OSError, ValueError, IndexError):
        return None


def cgroup_sample(info, boot):
    running = bool(info) and (info.get('State') or {}).get('Status') == 'running'
    sample = dict(epoch=time.time(), monotonic=time.monotonic(), boot=boot,
                  invocation='', cpu_ns=None, memory_bytes=None)
    tasks = None
    if running:
        base = Path('/sys/fs/cgroup/system.slice') / f"docker-{info['Id']}.scope"
        usage = None
        try:
            for line in (base / 'cpu.stat').read_text().splitlines():
                key, _, value = line.partition(' ')
                if key == 'usage_usec' and value.isdecimal():
                    usage = int(value) * 1000
        except OSError:
            pass
        sample.update(invocation=f"{info['Id'][:12]}@{info['State'].get('StartedAt', '')}"[:128],
                      cpu_ns=usage, memory_bytes=read_int(base / 'memory.current'))
        tasks = read_int(base / 'pids.current')
    return sample, tasks


def resources(sample, history):
    try:
        process = subprocess.run(['python3', str(SAMPLER), '--history', str(history)],
                                 input=json.dumps(sample), capture_output=True, text=True,
                                 timeout=10, check=True)
        metrics = json.loads(process.stdout)
    except (OSError, ValueError, subprocess.SubprocessError):
        return {'cpu_summary': 'unknown', 'memory_summary': 'unknown', 'sample_window': 'unknown'}
    if not sample['invocation']:
        metrics['cpu_current'] = 'unknown (stopped)'
    return {
        'cpu_summary': f"{metrics['cpu_current']} now · {metrics['cpu_avg']} avg · {metrics['cpu_max']} max",
        'memory_summary': f"{metrics['memory_current']} now · {metrics['memory_avg']} avg · {metrics['memory_max']} max",
        'sample_window': metrics['sample_window'],
        'memory_bytes': metrics['memory_bytes'],
        'cpu_percent': metrics['cpu_percent'],
    }


def database(path):
    """Read-only counts; never creates journal or WAL sidecars in live data."""
    if not Path(path).is_file():
        return None
    try:
        connection = sqlite3.connect(f'file:{path}?mode=ro', uri=True, timeout=1)
        try:
            accounts = connection.execute('SELECT count(*) FROM account').fetchone()[0]
            online, seen = connection.execute(
                "SELECT count(CASE WHEN logged_in != 0 THEN 1 END),"
                " max(max(coalesce(login_time, ''), coalesce(logout_time, ''))) FROM account_login").fetchone()
        finally:
            connection.close()
    except sqlite3.Error:
        return None
    # Prisma stores these as UTC 'YYYY-MM-DD HH:MM:SS' text.
    return {'accounts': accounts, 'online': online,
            'last_seen': utc_iso(utc_epoch(seen, '%Y-%m-%d %H:%M:%S')) if seen else ''}


def git_head(path):
    output = run(['git', '--no-optional-locks', '-C', str(path), 'log', '-1', '--format=%h %cs'])
    return tuple(output.split(' ', 1)) if output and ' ' in output else (None, None)


def du_bytes(path):
    output = run(['du', '-s', '-B1', '--', str(path)], timeout=10)
    try:
        return int(output.split()[0]) if output else None
    except ValueError:
        return None


def count_saves(path):
    try:
        return sum(1 for _ in Path(path).rglob('*.sav'))
    except OSError:
        return None


def http_json(url):
    try:
        with urllib.request.urlopen(url, timeout=2) as response:
            return json.loads(response.read(1_000_000))
    except (OSError, ValueError):
        return None


def listening(port):
    output = run(['ss', '-ltnH'])
    return bool(output) and any(len(line.split()) >= 4 and line.split()[3].rsplit(':', 1)[-1] == str(port)
                                for line in output.splitlines())


def lan_ip():
    """The default route's address; the first global one could be a Docker bridge."""
    route = run(['ip', '-4', 'route', 'show', 'default']) or ''
    words = route.split()
    if 'dev' not in words[:-1]:
        return ''
    addresses = run(['ip', '-4', '-o', 'addr', 'show', 'dev', words[words.index('dev') + 1], 'scope', 'global'])
    for line in (addresses or '').splitlines():
        fields = line.split()
        if 'inet' in fields[:-1]:
            return fields[fields.index('inet') + 1].split('/')[0]
    return ''


def format_bytes(value):
    if value is None:
        return 'unknown'
    for unit in ('B', 'KiB', 'MiB', 'GiB', 'TiB'):
        if value < 1024 or unit == 'TiB':
            return f'{value:.1f} {unit}'
        value /= 1024


def plural(count, word):
    return f"{count} {word}{'' if count == 1 else 's'}"


def rules(env, tick_ms):
    members = 'members' if env.get('NODE_MEMBERS', 'true') == 'true' else 'free-to-play'
    return f"{members} · {env.get('NODE_XPRATE', '1')}× XP · {tick_ms} ms ticks"


def systemd(unit, prop):
    return run(['systemctl', 'show', unit, '-p', prop, '--value']) or ''


def maintenance(env, stack, state_dir):
    """Weekly window from maintenance.sh's own rule: the backup on MAINTENANCE_DAY."""
    day = env.get('MAINTENANCE_DAY', 'Mon')
    auto = 'auto-update on' if env.get('AUTO_UPDATE', 'true') == 'true' else 'auto-update off'
    flags = [label for marker, label in (('inprogress', 'interrupted update — run --resume'),
                                         ('failed', 'last update failed'))
             if (state_dir / f'{stack}.{marker}').exists()]
    if systemd('2004scape-maintenance.timer', 'ActiveState') != 'active':
        return ' · '.join(['timer not installed'] + flags), ''
    summary = ' · '.join([f'weekly {day}', auto] + flags)
    backup = run(['date', '-d', systemd('game-backup.timer', 'NextElapseUSecRealtime'), '+%s'])
    if not backup or not backup.isdecimal() or day not in DAYS:
        return summary, ''
    epoch = int(backup)
    for _ in range(7):
        if time.strftime('%a', time.localtime(epoch)) == day:
            break
        epoch += 86400
    countdown = env.get('COUNTDOWN_MINUTES', '10')
    countdown = int(countdown) if countdown.isdecimal() else 10
    return summary, utc_iso(epoch - DOWN_BEFORE_BACKUP_SECONDS - countdown * 60)


def backup_status():
    try:
        data = json.loads(BACKUP_STATUS.read_text())
    except (OSError, ValueError):
        return {'backup_status': 'unknown', 'last_backup': ''}
    return {'backup_status': str(data.get('status') or 'unknown'), 'last_backup': str(data.get('last_run') or '')}


def common(info, history, boot, db, data_dir, saves_dir, window):
    status, uptime = server_state(info)
    sample, tasks = cgroup_sample(info, boot)
    data_bytes = du_bytes(data_dir)
    saves = count_saves(saves_dir)
    result = {
        'status': status,
        'uptime_seconds': uptime,
        'uptime_display': (f'{uptime // 86400}d {uptime // 3600 % 24}h {uptime // 60 % 60}m {uptime % 60}s'
                           if uptime else '—'),
        'restarts': (info or {}).get('RestartCount', 0),
        'tasks': tasks,
        'accounts': db['accounts'] if db else None,
        'last_seen': db['last_seen'] if db else '',
        'data_bytes': data_bytes,
        'storage_summary': (f"{plural(saves, 'player save') if saves is not None else 'saves unknown'} · "
                            f'{format_bytes(data_bytes)} data'),
        'maintenance_summary': window[0],
        'next_maintenance': window[1],
        'updated': utc_iso(time.time()),
    }
    result.update(resources(sample, history))
    result['process_summary'] = (f"{tasks if tasks is not None else 'unknown'} tasks · "
                                 f"{plural(result['restarts'], 'auto restart')}")
    result.update(backup_status())
    return result


def lostcity(runtime, history, boot, window):
    runtime = Path(runtime)
    engine = runtime / 'engine'
    info = inspect('lostcity')
    db = database(engine / 'db.sqlite')
    result = common(info, history, boot, db, engine / 'data', engine / 'data' / 'players', window)
    try:
        revision = json.loads((runtime / 'server.json').read_text()).get('rev', '?')
    except (OSError, ValueError, AttributeError):
        revision = '?'
    engine_sha, engine_date = git_head(engine)
    content_sha, _ = git_head(runtime / 'content')
    result.update(
        revision=str(revision),
        software_summary=(f'rev {revision} · engine {engine_sha or "?"} ({engine_date or "?"})'
                          f' · content {content_sha or "?"}'),
        rules_summary=rules(read_env(engine / '.env'), 600),
        players_summary=(f"{db['online']} online · {plural(db['accounts'], 'account')}" if db else 'unknown'),
        connect_lan=f'http://{address}:8888/rs2.cgi' if (address := lan_ip()) else '—',
    )
    return result


def rs_sdk(source, data, history, boot, window):
    info = inspect('rs-sdk-server')
    db = database(Path(data) / 'db.sqlite')
    result = common(info, history, boot, db, data, Path(data) / 'players', window)
    env = dict(item.partition('=')[::2] for item in ((info or {}).get('Config') or {}).get('Env') or [])
    sha, date = git_head(source)
    branch = run(['git', '--no-optional-locks', '-C', str(source), 'rev-parse', '--abbrev-ref', 'HEAD'])
    built = run(['docker', 'image', 'inspect', '-f', '{{.Created}}', 'computer-setup/rs-sdk:local'])
    running = result['status'].startswith('running')
    live = http_json('http://127.0.0.1:8080/playercount') if running else None
    gateway = http_json('http://127.0.0.1:8080/status') if running else None
    market = http_json('http://127.0.0.1:8080/api/market/status') if running else None
    online = live.get('count') if isinstance(live, dict) else (db['online'] if db else None)
    bots = gateway.get('bots') if isinstance(gateway, dict) and isinstance(gateway.get('bots'), dict) else None
    sdks = gateway.get('sdks') if isinstance(gateway, dict) and isinstance(gateway.get('sdks'), dict) else {}
    bot_count = None
    if bots is None:
        bots_summary = ' · gateway unavailable' if running else ''
    else:
        bot_count = len(bots)
        states = [bot.get('status') for bot in bots.values() if isinstance(bot, dict)]
        bots_summary = (f" · {plural(bot_count, 'bot')} ({states.count('active')} active, "
                        f"{states.count('stale')} stale) · {plural(len(sdks), 'SDK client')}")
    gateway_port = env.get('GATEWAY_PUBLIC_PORT', '7781')
    gateway_state = 'listening' if listening(gateway_port) else 'down'
    exchange = 'on' if isinstance(market, dict) and market.get('enabled') else 'off'
    random_events = 'random events' if env.get('NODE_RANDOM_EVENTS') == 'true' else 'no random events'
    run_energy = 'infinite run' if env.get('NODE_INFINITE_RUN') == 'true' else 'normal run energy'
    result.update(
        software_summary=(f'{branch or "?"}@{sha or "?"} ({date or "?"}) · image {(built or "?")[:10]}'),
        rules_summary=f"{rules(env, env.get('NODE_TICKRATE', '?'))} · {random_events} · {run_energy}",
        # Bots and the gateway share the Players and LAN rows so this card stays
        # the same height as Lost City's.
        players_summary=(f"{online if online is not None else '?'} online · "
                         f"{plural(db['accounts'], 'account') if db else 'accounts unknown'}{bots_summary}"),
        bots=bot_count,
        connect_lan=(f"http://{address}:{env.get('WEB_PORT', '8080')} · "
                     f"ws://{address}:{gateway_port} ({gateway_state}) · GE {exchange}")
        if (address := lan_ip()) else '—',
    )
    return result


def publish(destination, document):
    destination.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix='.status.', dir=destination.parent)
    try:
        with os.fdopen(fd, 'w') as output:
            json.dump(document, output, allow_nan=False)
        os.chmod(temporary, 0o644)
        os.replace(temporary, destination)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main():
    status_dir = Path(os.environ.get('STATUS_DIR', HERE / 'status'))
    metrics = Path(os.environ.get('STATUS_HISTORY_DIR', HERE / '.metrics'))
    metrics.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(metrics, 0o700)
    state_dir = Path(os.environ.get('XDG_STATE_HOME', Path.home() / '.local/state')) \
        / 'computer-setup' / '2004scape-maintenance'
    settings = read_env(HERE / '.env')
    lostcity_env = read_env(GAME / 'lostcity' / '.env')
    rs_sdk_env = read_env(GAME / 'rs-sdk' / '.env')
    boot = Path('/proc/sys/kernel/random/boot_id').read_text().strip()
    with (metrics / '.status.lock').open('a') as lock:
        os.chmod(lock.name, 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX)
        if lostcity_env.get('LOSTCITY_RUNTIME_DIR'):
            publish(status_dir / 'lostcity-status.json',
                    lostcity(lostcity_env['LOSTCITY_RUNTIME_DIR'], metrics / 'lostcity-history.json', boot,
                             maintenance(settings, 'lostcity', state_dir)))
        if rs_sdk_env.get('RS_SDK_SOURCE_DIR') and rs_sdk_env.get('RS_SDK_DATA_DIR'):
            publish(status_dir / 'rs-sdk-status.json',
                    rs_sdk(rs_sdk_env['RS_SDK_SOURCE_DIR'], rs_sdk_env['RS_SDK_DATA_DIR'],
                           metrics / 'rs-sdk-history.json', boot, maintenance(settings, 'rs-sdk', state_dir)))


if __name__ == '__main__':
    main()
