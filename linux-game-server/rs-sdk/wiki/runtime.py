import argparse
import json
import os
from pathlib import Path
import pwd
import shlex
import shutil
import stat
import subprocess
import sys

HERE = Path(__file__).resolve().parent


def inputs(wiki):
    home = Path.home()
    values = {'RS_SDK_WIKI_DIR': str(home / 'github/rs-sdk/wiki'),
              'BOTTING_DIR': str(home / 'forgejo/2004Scape-Botting')}
    config = wiki / 'data/inputs.json'
    if os.path.lexists(config):
        info = config.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600:
            raise ValueError('inputs.json must be user-owned with mode 600')
        configured = json.loads(config.read_text())
        if not isinstance(configured, dict) or configured.keys() - values.keys():
            raise ValueError('inputs.json accepts only RS_SDK_WIKI_DIR and BOTTING_DIR keys')
        values.update(configured)
    for key, value in values.items():
        if not isinstance(value, str) or not value or any(ord(c) < 32 or 127 <= ord(c) <= 159 for c in value):
            raise ValueError(f'{key} must be a path without control characters')
        if not value.startswith('/') and not value.startswith('~/'):
            raise ValueError(f'{key} must be an absolute path or ~/ path')
        path = Path(value).expanduser().resolve(strict=True)
        if not path.is_dir():
            raise ValueError(f'{key} must be a directory')
        values[key] = str(path)
    return values


def validate(wiki, values):
    for name in ('bun', 'git-lfs'):
        if not shutil.which(name):
            raise ValueError(f'missing prerequisite: {name}')
    cli = wiki / 'bin/wiki'
    if not cli.is_file() or not os.access(cli, os.X_OK):
        raise ValueError('missing executable wiki checkout bin/wiki')
    curated_files = []
    for directory in (Path(values['RS_SDK_WIKI_DIR']), Path(values['BOTTING_DIR']) / 'learnings'):
        files = [p for p in directory.rglob('*.md') if p.is_file() and p.name != 'README.md' and p.stat().st_size]
        if not files:
            raise ValueError(f'missing curated markdown inputs: {directory}')
        curated_files.extend(files)
    for name in ('items', 'locs', 'npcs', 'ground-items', 'shops'):
        file = Path(values['BOTTING_DIR']) / f'observations/{name}.tsv'
        if name == 'shops' and not file.exists():
            continue
        if not file.is_file() or not file.stat().st_size:
            raise ValueError(f'missing curated observations: {file}')
        curated_files.append(file)
    for file in curated_files:
        with file.open('rb') as stream:
            if stream.read(42).startswith(b'version https://git-lfs.github.com/spec/v1'):
                raise ValueError(f'curated input is an unhydrated LFS pointer: {file}')


def unit_quote(value, expand_dollars=False):
    value = str(value)
    if any(c in value for c in '\n\r\x00'):
        raise ValueError('unit paths must not contain control characters')
    if expand_dollars:
        value = value.replace('$', '$$')
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"').replace('%', '%%') + '"'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['install', 'drain', 'publish'])
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--no-start', action='store_true')
    parser.add_argument('--wiki-root', type=Path, default=Path.home() / 'forgejo/2004Scape-Wiki')
    parser.add_argument('--target', type=Path, default=Path.home() / '.local/share/rs-sdk-portal/data')
    args = parser.parse_args()
    home = Path.home()
    path = f'{home}/.bun/bin:{home}/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
    os.environ['PATH'] = path
    if 'WIKI_DB' in os.environ:
        raise ValueError('WIKI_DB override is unsupported; use the canonical wiki store')
    wiki = args.wiki_root.expanduser().resolve()
    values = inputs(wiki)
    os.environ.update(values)
    target = args.target.expanduser().resolve()
    validate(wiki, values)
    publisher = HERE.parent / 'portal/sync.py'
    if args.action == 'install':
        linger = subprocess.run(['loginctl', 'show-user', pwd.getpwuid(os.getuid()).pw_name,
                                 '--property=Linger', '--value'], check=True, text=True, capture_output=True)
        if linger.stdout.strip() != 'yes':
            raise ValueError('Linger=yes is required for reboot persistence; ask the host administrator')
        support = subprocess.run([sys.executable, '-B', str(publisher), '--help'], check=True, text=True, capture_output=True)
        if 'publish-wiki' not in support.stdout:
            raise ValueError('portal sync.py must support publish-wiki before installing timers')
    metadata = [sys.executable, '-B', str(HERE / 'build_metadata.py'), '--wiki-root', str(wiki)]
    if args.dry_run:
        print(shlex.join(metadata))
    else:
        subprocess.run(metadata, check=True, timeout=150)
    if args.action != 'install':
        os.environ['WIKI_AUTO_IMAGES'] = '0'
        command = ([str(wiki / 'bin/wiki'), 'downloads', '--drain'] if args.action == 'drain' else
                   [sys.executable, '-B', str(publisher), 'publish-wiki', '--wiki-root', str(wiki), '--target', str(target), '--curated'])
        if args.dry_run:
            print(shlex.join(command))
        else:
            subprocess.run(command, check=True, cwd=wiki)
        return
    units = home / '.config/systemd/user'
    rendered = {}
    for action, schedule in [('drain', '*-*-* *:0/2:00'), ('publish', '*-*-* *:0/5:00')]:
        command = [sys.executable, '-B', HERE / 'runtime.py', action, '--wiki-root', wiki, '--target', target]
        values = {'ACTION': action, 'SCHEDULE': schedule,
                  'PATH': unit_quote('PATH=' + path),
                  'EXEC': ' '.join(unit_quote(v, expand_dollars=True) for v in command)}
        for kind in ('service', 'timer'):
            text = (HERE / f'wiki.{kind}.template').read_text()
            for key, value in values.items():
                text = text.replace('@' + key + '@', value)
            rendered[units / f'rs-sdk-wiki-{action}.{kind}'] = text
    if not args.dry_run:
        units.mkdir(parents=True, exist_ok=True)
    for filename, text in rendered.items():
        if args.dry_run:
            print(f'write {filename}\n{text}')
        else:
            filename.write_text(text)
    commands = [['systemctl', '--user', 'daemon-reload']]
    if not args.no_start:
        commands.append(['systemctl', '--user', 'enable', '--now', 'rs-sdk-wiki-drain.timer', 'rs-sdk-wiki-publish.timer'])
    for command in commands:
        if args.dry_run:
            print(shlex.join(command))
        else:
            subprocess.run(command, check=True)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(f'error: {error}')
