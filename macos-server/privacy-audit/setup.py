#!/usr/bin/env python3
import argparse
import json
import os
import plistlib
from pathlib import Path
import subprocess
import sys
import tempfile


def render_agents(runtime, config, python, search_path):
    result = {}
    for cadence, calendar in (
        ('daily', {'Hour': 9, 'Minute': 17}),
        ('monthly', {'Day': 1, 'Hour': 10, 'Minute': 17}),
    ):
        label = f'net.computer-setup.privacy-{cadence}'
        args = [python, '-I', str(runtime / 'privacy-audit.py'), '--config', str(config)]
        if cadence == 'monthly':
            args.append('--full')
        args.append('run')
        result[label] = plistlib.dumps({
            'Label': label,
            'ProgramArguments': args,
            'WorkingDirectory': str(runtime),
            'StartCalendarInterval': calendar,
            'RunAtLoad': False,
            'KeepAlive': False,
            'ProcessType': 'Background',
            'LowPriorityIO': True,
            'Nice': 10,
            'Umask': 0o077,
            'EnvironmentVariables': {'PATH': search_path, 'PYTHONNOUSERSITE': '1'},
            'StandardOutPath': str(config.parent / f'{cadence}.stdout.log'),
            'StandardErrorPath': str(config.parent / f'{cadence}.stderr.log'),
        })
    return result


def install(source, config, agents, python, search_path):
    runtime = config.parent / 'runtime'
    for target in (config, runtime, agents, source):
        if any(part.is_symlink() for part in (target, *target.parents)):
            raise ValueError('symlink installation target refused')
    settings = json.loads(config.read_text())
    if not isinstance(settings, dict) or not isinstance(settings.get('repo_path'), str):
        raise ValueError('audited checkout must be explicit')
    repo = Path(settings['repo_path'])
    if not repo.is_absolute():
        raise ValueError('audited checkout path must be absolute')
    repo = repo.resolve()
    for target in (config, runtime, agents):
        if target.resolve() == repo or repo in target.resolve().parents:
            raise ValueError('private runtime and configuration must be outside audited checkout')
    config.parent.chmod(0o700)
    config.chmod(0o600)
    runtime.mkdir(mode=0o700, exist_ok=True)
    runtime.chmod(0o700)
    agents.mkdir(parents=True, exist_ok=True)
    payloads = {runtime / name: (source / name).read_bytes()
                for name in ('privacy-audit.py', 'check-privacy.py')}
    rendered = render_agents(runtime, config, python, search_path)
    payloads.update({agents / f'{label}.plist': raw for label, raw in rendered.items()})
    for cadence in ('daily', 'monthly'):
        for stream in ('stdout', 'stderr'):
            target = config.parent / f'{cadence}.{stream}.log'
            if target.is_symlink():
                raise ValueError('symlink log target refused')
            fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600)
            os.fchmod(fd, 0o600)
            os.close(fd)
    for target, raw in payloads.items():
        if target.is_symlink():
            raise ValueError('symlink file target refused')
        with tempfile.NamedTemporaryFile(dir=target.parent, delete=False) as handle:
            handle.write(raw)
            os.fchmod(handle.fileno(), 0o600)
            staged = Path(handle.name)
        try:
            os.replace(staged, target)
        finally:
            staged.unlink(missing_ok=True)
    return list(rendered)


def main():
    parser = argparse.ArgumentParser(description='Install private privacy-audit runtime and opt-in LaunchAgents.')
    parser.add_argument('--config', type=Path, required=True)
    parser.add_argument('--enable', action='store_true', help='register schedules without starting an audit')
    args = parser.parse_args()
    if not args.config.is_absolute():
        parser.error('config must be an absolute private path')
    agents = Path.home() / 'Library/LaunchAgents'
    domain = f'gui/{os.getuid()}'
    labels = ['net.computer-setup.privacy-daily', 'net.computer-setup.privacy-monthly']
    for label in labels:
        result = subprocess.run(['launchctl', 'print', f'{domain}/{label}'], capture_output=True, text=True)
        if 'state = running' in result.stdout:
            raise ValueError('an audit is running; defer installation')
    labels = install(Path(__file__).resolve().parents[2] / 'scripts', args.config, agents,
                     sys.executable, '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin')
    if args.enable:
        for label in labels:
            subprocess.run(['launchctl', 'bootout', f'{domain}/{label}'], capture_output=True)
            result = subprocess.run(['launchctl', 'bootstrap', domain, str(agents / f'{label}.plist')], capture_output=True)
            if result.returncode:
                raise ValueError('schedule registration failed; diagnostics suppressed')
            subprocess.run(['launchctl', 'enable', f'{domain}/{label}'], check=True, capture_output=True)
    print('Private runtime installed; schedules ' + ('registered.' if args.enable else 'not enabled.'))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.SubprocessError):
        print('Privacy installer failed; private diagnostics suppressed.', file=sys.stderr)
        sys.exit(1)
