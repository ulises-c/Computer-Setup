#!/usr/bin/env python3
"""Private identifier inventory and read-only public-content audit (stdlib only)."""
import argparse
import contextlib
import datetime
import fcntl
import hashlib
import importlib.util
import ipaddress
import json
import os
from pathlib import Path
import re
import selectors
import subprocess
import sys
import tempfile
import time


class AuditError(Exception):
    pass


def safe_path(path):
    path = Path(os.path.abspath(os.path.expanduser(str(path))))
    for parent in [path, *path.parents]:
        if parent.is_symlink():
            raise AuditError('symlink refused')
    return path


def atomic_write(path, text):
    path = safe_path(path)
    fd, temporary = tempfile.mkstemp(prefix='.privacy-', dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, 'w', encoding='utf-8') as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        safe_path(path)
        os.replace(temporary, path)
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(temporary)


class State:
    def __init__(self, path):
        self.path = safe_path(path)
        self.lock = None

    def __enter__(self):
        self.path.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(self.path, 0o700)
        lock_path = safe_path(self.path / 'lock')
        fd = os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        self.lock = os.fdopen(fd, 'a+')
        os.fchmod(fd, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            self.lock.close()
            raise AuditError('another audit is running') from None
        return self

    def __exit__(self, *args):
        self.lock.close()

    def read(self, name, default):
        path = safe_path(self.path / name)
        if not path.exists():
            return default
        os.chmod(path, 0o600)
        return json.loads(path.read_text(encoding='utf-8'))

    def write(self, name, data):
        atomic_write(self.path / name, json.dumps(data, ensure_ascii=True, indent=2) + '\n')


def command(argv, input_data=None, timeout=45, limit=32 * 1024 * 1024, cwd=None):
    # Bound both output and wall time without buffering an untrusted Git object in RAM.
    env = dict(os.environ, GIT_TERMINAL_PROMPT='0', GIT_CONFIG_NOSYSTEM='1',
               GIT_CONFIG_GLOBAL=os.devnull, GIT_NO_REPLACE_OBJECTS='1',
               GIT_OPTIONAL_LOCKS='0', GH_PROMPT_DISABLED='1', GH_HOST='github.com')
    for key in list(env):
        if key.startswith(('GIT_CONFIG_KEY_', 'GIT_CONFIG_VALUE_')) or key in (
                'GIT_CONFIG_COUNT', 'GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE',
                'GIT_OBJECT_DIRECTORY', 'GIT_ALTERNATE_OBJECT_DIRECTORIES',
                'PYTHONPATH', 'PYTHONHOME'):
            env.pop(key)
    with tempfile.TemporaryFile() as source:
        if input_data is not None:
            source.write(input_data.encode('utf-8'))
            source.seek(0)
        try:
            process = subprocess.Popen(argv, stdin=source, stdout=subprocess.PIPE,
                                       stderr=subprocess.DEVNULL, cwd=cwd, env=env)
        except OSError:
            raise AuditError('command unavailable') from None
        result = bytearray()
        deadline = time.monotonic() + timeout
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ)
                while selector.get_map():
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        raise AuditError('command timed out')
                    ready = selector.select(min(remaining, 1))
                    for key, _ in ready:
                        block = os.read(key.fd, 65536)
                        if not block:
                            selector.unregister(key.fileobj)
                        else:
                            result.extend(block)
                            if len(result) > limit:
                                raise AuditError('command output limit exceeded')
                process.wait(timeout=max(0.01, deadline - time.monotonic()))
            if process.returncode:
                raise AuditError('command failed')
            return bytes(result)
        except (subprocess.TimeoutExpired, AuditError):
            process.kill()
            process.wait()
            raise AuditError('command failed or exceeded limits') from None
        finally:
            process.stdout.close()


BRIDGES = re.compile(r'^(?:lo\d*$|docker|br-|bridge|virbr|veth|cni|flannel|podman|vmnet|vboxnet|utun)')


def linux_addresses(data):
    values = []
    for interface in data:
        if (BRIDGES.match(interface.get('ifname', ''))
                or interface.get('linkinfo', {}).get('info_kind') in ('bridge', 'veth')):
            continue
        for item in interface.get('addr_info', []):
            value = canonical_ip(item.get('local', ''))
            if value:
                values.append(value)
    return values


def mac_addresses(text):
    values, interface = [], ''
    for line in text.splitlines():
        if line and not line[0].isspace():
            interface = line.split(':', 1)[0]
        match = re.match(r'\s+inet6?\s+(\S+)', line)
        if match and not BRIDGES.match(interface):
            value = canonical_ip(match.group(1))
            if value:
                values.append(value)
    return values


def valid_name(value):
    return (isinstance(value, str) and 4 <= len(value) <= 253
            and bool(re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*', value))
            and value.lower() not in ('localhost', 'localhost.localdomain', 'localhost.local',
                                      'root', 'user', 'username', 'none', '(none)'))


def public_endpoint(value):
    if not isinstance(value, str):
        return None
    match = re.fullmatch(r'(?:\[([0-9A-Fa-f:.]+)\]|([0-9.]+)):([0-9]{1,5})', value)
    if not match or not 1 <= int(match[3]) <= 65535:
        return None
    raw = match[1] or match[2]
    try:
        address = ipaddress.ip_address(raw)
    except ValueError:
        return None
    if (match[1] is not None) != isinstance(address, ipaddress.IPv6Address):
        return None
    canonical = canonical_ip(raw)
    if not canonical:
        return None
    address = ipaddress.ip_address(canonical)
    if (not address.is_global or address.is_reserved
            or getattr(address, 'is_site_local', False)):
        return None
    return canonical


def tailnet_records(data):
    records = []
    for node in [data.get('Self', {}), *data.get('Peer', {}).values()]:
        dns = node.get('DNSName', '').rstrip('.')
        if valid_name(dns):
            records.append(('tailnet_dns', dns))
        if not node.get('Tags') and valid_name(node.get('HostName')):
            records.append(('hostname', node['HostName']))
        for endpoint in [*(node.get('Addrs') or []), node.get('CurAddr')]:
            value = public_endpoint(endpoint)
            if value:
                records.append(('ip', value))
        for raw in node.get('TailscaleIPs', []):
            value = canonical_ip(raw)
            if value:
                records.append(('ip', value))
    return records


COLLECTOR = r'''
import getpass,json,platform,socket,subprocess
result = {'hostname': socket.gethostname(), 'fqdn': socket.getfqdn(), 'login': getpass.getuser()}
if platform.system() == 'Darwin':
    result['ifconfig'] = subprocess.run(['/sbin/ifconfig'], check=True, capture_output=True, text=True, timeout=15).stdout
else:
    result['interfaces'] = json.loads(subprocess.run(['ip','-j','-details','address'], check=True, capture_output=True, text=True, timeout=15).stdout)
print(json.dumps(result))
'''


def host_command(host, argv, input_data=None):
    if host.get('local') is True:
        return command(argv, input_data, timeout=35, limit=4 * 1024 * 1024, cwd='/')
    alias = host.get('ssh', '')
    if not isinstance(alias, str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*', alias):
        raise AuditError('invalid SSH alias')
    # Only fixed command tokens reach SSH's remote shell; identifiers stay on stdin.
    allowed = (['python3', '-I', '-'], ['tailscale', 'status', '--json'])
    if argv not in allowed:
        raise AuditError('remote command refused')
    return command(['ssh', '-T', '-oBatchMode=yes', '-oConnectTimeout=10',
                    '-oConnectionAttempts=1', '-oServerAliveInterval=5',
                    '-oServerAliveCountMax=2', '--', alias, ('cd / && exec env -u PYTHONPATH -u PYTHONHOME ' + ' '.join(argv))],
                   input_data, timeout=40, limit=4 * 1024 * 1024)


def collect_host(host):
    data = json.loads(host_command(host, ['python3', '-I', '-'], COLLECTOR))
    records = [(kind, data[key]) for kind, key in (
        ('hostname', 'hostname'), ('hostname', 'fqdn'), ('login', 'login'))
        if valid_name(data.get(key))]
    addresses = (mac_addresses(data['ifconfig']) if 'ifconfig' in data
                 else linux_addresses(data['interfaces']))
    return records + [('ip', value) for value in addresses]


def collect_tailnet(host):
    try:
        raw = host_command(host, ['tailscale', 'status', '--json'])
    except AuditError:
        if not host.get('local'):
            raise
        raw = command(['/Applications/Tailscale.app/Contents/MacOS/Tailscale',
                       'status', '--json'], limit=4 * 1024 * 1024)
    data = json.loads(raw)
    if data.get('BackendState') != 'Running' or not data.get('Self'):
        raise AuditError('tailnet unavailable')
    return tailnet_records(data)


def merge_inventory(old, discovered, unavailable, manual, timestamp):
    entries = {(r['type'], r['value'].lower()): r for r in old.get('entries', [])}
    sources = old.get('sources', {})
    observations = dict(discovered)
    if manual is not None:
        observations['manual'] = [('manual', value) for value in manual]
    for source, records in observations.items():
        sources[source] = {'status': 'ok', 'last_seen': timestamp}
        for kind, value in records:
            value = value.strip().lower()
            if not value or '\n' in value or '\r' in value or '\x00' in value:
                continue
            key = (kind, value)
            if key not in entries:
                entries[key] = {'type': kind, 'value': value, 'source': [],
                                'first_seen': timestamp}
            item = entries[key]
            item['last_seen'] = timestamp
            if source not in item['source']:
                item['source'].append(source)
    for source in unavailable:
        sources.setdefault(source, {})['status'] = 'unavailable'
        sources[source]['last_attempt'] = timestamp
    return {'version': 1, 'entries': sorted(entries.values(), key=lambda r: (r['value'], r['type'])),
            'sources': sources, 'updated': timestamp}


DOCUMENTATION = tuple(map(ipaddress.ip_network, (
    '192.0.2.0/24', '198.51.100.0/24', '203.0.113.0/24', '2001:db8::/32',
)))


def canonical_ip(value):
    try:
        address = ipaddress.ip_address(value.split('%')[0].split('/')[0])
    except (ValueError, AttributeError):
        return None
    if isinstance(address, ipaddress.IPv6Address) and address.ipv4_mapped:
        address = address.ipv4_mapped
    if (address.is_loopback or address.is_unspecified or address.is_multicast
            or address.is_link_local or any(address in net for net in DOCUMENTATION)):
        return None
    return str(address)


def git(repo, *args, **kwargs):
    return command(['git', '--no-pager', '-c', 'core.hooksPath=/dev/null',
                    '-c', 'core.fsmonitor=false', '-c', 'core.attributesFile=/dev/null',
                    '-c', 'diff.external=', '-c', 'credential.helper=',
                    '-c', 'protocol.allow=never', '-c', 'protocol.https.allow=always',
                    '-c', 'http.followRedirects=false', '-C', str(repo), *args], **kwargs)


def validate_config(config):
    if not isinstance(config, dict):
        raise AuditError('invalid config')
    config = dict(config)
    for key in ('repo_path', 'state_dir', 'denylist_path'):
        value = config.get(key)
        if not isinstance(value, str) or not Path(value).is_absolute():
            raise AuditError('config paths must be absolute')
        config[key] = str(safe_path(value))
    repo, state = Path(config['repo_path']), Path(config['state_dir'])
    if repo == state or repo in state.parents:
        raise AuditError('state directory must be outside checkout')
    hosts = config.get('hosts')
    if not isinstance(hosts, list):
        raise AuditError('explicit hosts list required')
    names = set()
    for host in hosts:
        if not isinstance(host, dict) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,63}', host.get('name', '')):
            raise AuditError('invalid host definition')
        if host['name'] in names or host['name'] == 'manual':
            raise AuditError('duplicate or reserved source name')
        names.add(host['name'])
        if host.get('local') is True:
            if 'ssh' in host:
                raise AuditError('local host cannot have SSH alias')
        elif not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*', host.get('ssh', '')):
            raise AuditError('invalid SSH alias')
    if config.get('tailnet_host') is not None and config['tailnet_host'] not in names:
        raise AuditError('tailnet_host must name an explicit host')
    github_repo = config.get('github_repo')
    if github_repo is not None and (not isinstance(github_repo, str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*', github_repo)):
        raise AuditError('invalid GitHub repository')
    mirror = config.get('mirror_url')
    if mirror is not None and (not isinstance(mirror, str) or not re.fullmatch(r'https://github\.com/[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*\.git', mirror)):
        raise AuditError('mirror requires explicit HTTPS GitHub repository URL ending .git')
    if not isinstance(config.get('sync_secret', False), bool):
        raise AuditError('sync_secret must be boolean')
    if config.get('sync_secret') and not github_repo:
        raise AuditError('sync_secret requires github_repo')
    return config


def load_scanner():
    # The deployed adjacent copy is trusted; no module is loaded from repo_path.
    path = safe_path(Path(__file__).absolute().with_name('check-privacy.py'))
    spec = importlib.util.spec_from_file_location('_trusted_privacy_scanner', path)
    if spec is None or spec.loader is None:
        raise AuditError('trusted scanner unavailable')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def checked_denylist_target(config):
    repo = safe_path(config['repo_path'])
    target = safe_path(repo / '.privacy-denylist')
    if git(repo, 'ls-files', '-z', '--', '.privacy-denylist'):
        raise AuditError('denylist target is tracked')
    git(repo, 'check-ignore', '--quiet', '--', '.privacy-denylist')
    return target


def load_private_denylist(store, scanner):
    # Ambient CI variables must not silently change the private inventory.
    previous = os.environ.pop('PRIVACY_DENYLIST', None)
    try:
        values, found = scanner.load_denylist(str(store.path))
    finally:
        if previous is not None:
            os.environ['PRIVACY_DENYLIST'] = previous
    if not found or not values:
        raise AuditError('private denylist is missing or empty; run refresh first')
    return values


def refresh(config, store):
    target = checked_denylist_target(config)
    seed = safe_path(config['denylist_path'])
    discovered, unavailable = {}, []
    try:
        manual = [line.strip() for line in seed.read_text(encoding='utf-8').splitlines()
                  if len(line.strip()) >= 4 and not line.lstrip().startswith('#')]
    except OSError:
        manual = None
        unavailable.append('manual')
    for host in config['hosts']:
        try:
            discovered[host['name']] = collect_host(host)
        except (AuditError, ValueError, KeyError, TypeError, AttributeError):
            unavailable.append(host['name'])
    if config.get('tailnet_host') is not None:
        host = next(h for h in config['hosts'] if h['name'] == config['tailnet_host'])
        source = 'tailnet:' + host['name']
        try:
            discovered[source] = collect_tailnet(host)
        except (AuditError, ValueError, KeyError, TypeError, AttributeError):
            unavailable.append(source)
    inventory = merge_inventory(store.read('inventory.json', {}), discovered, unavailable, manual, now())
    for source in inventory['sources']:
        if source != 'manual' and source not in discovered and source not in unavailable:
            inventory['sources'][source]['status'] = 'not_configured'
    store.write('inventory.json', inventory)
    values = sorted({r['value'] for r in inventory['entries']})
    if not values:
        raise AuditError('inventory is empty; refusing to replace denylist')
    text = '\n'.join(values) + '\n'
    atomic_write(store.path / '.privacy-denylist', text)
    scanner = load_scanner()
    if set(load_private_denylist(store, scanner)) != set(values):
        raise AuditError('denylist validation failed')
    checked_denylist_target(config)
    atomic_write(target, text)
    synced, sync_failed = False, False
    if config.get('sync_secret', False) and not unavailable:
        try:
            github_repo = config['github_repo']
            command(['gh', 'secret', 'set', 'PRIVACY_DENYLIST', '--repo', github_repo], input_data=text)
            metadata = json.loads(command(['gh', 'api', '--method', 'GET',
                                          f'repos/{github_repo}/actions/secrets/PRIVACY_DENYLIST']))
            if metadata.get('name') != 'PRIVACY_DENYLIST' or not metadata.get('updated_at'):
                raise AuditError('secret metadata verification failed')
            synced = True
        except (AuditError, ValueError, KeyError, TypeError):
            sync_failed = True
    result = {'identifiers': len(values), 'unavailable_sources': len(unavailable),
              'secret_synced': synced, 'secret_sync_failed': sync_failed,
              'degraded': bool(unavailable) or sync_failed}
    store.write('refresh-summary.json', result)
    return result


class Findings:
    def __init__(self, scanner, denylist, previous=()):
        self.scanner, self.denylist = scanner, denylist
        self.items = {}
        self.overflow = False
        for item in previous:
            self.items[(item['surface'], item['locator'], item['category'])] = item

    def categories(self, text):
        # Audit untrusted content even if it contains an allow-marker or test filename.
        text = text.replace(getattr(self.scanner, 'ALLOW_MARKER', 'privacy-check: allow'), '')
        result = set()
        for category in self.scanner.check_line(text, self.denylist, '', ''):
            category = str(category)
            result.add('denylist entry' if category.startswith('denylist') else category)
        return sorted(result)

    def safe_locator(self, locator):
        digest = hashlib.sha256(locator.encode('utf-8', 'surrogatepass')).hexdigest()[:24]
        if (len(locator) > 512 or self.categories(locator)
                or any(ord(c) < 32 or ord(c) > 126 for c in locator)):
            commit, separator, _ = locator.partition(':')
            if separator and re.fullmatch(r'[0-9a-f]{40,64}', commit) and not self.categories(commit):
                return commit + ':[redacted path]:' + digest
            return '[redacted]:' + digest
        return locator

    def scan(self, surface, locator, text):
        location = self.safe_locator(locator)
        for number, line in enumerate(text.splitlines(), 1):
            for category in self.categories(line):
                key = (surface, location, category)
                if key not in self.items:
                    if len(self.items) >= 5000:
                        self.overflow = True
                    else:
                        self.items[key] = {'surface': surface, 'locator': location,
                                           'line': number, 'category': category}

    def result(self):
        counts = {}
        for item in self.items.values():
            counts[item['category']] = counts.get(item['category'], 0) + 1
        return {'findings': list(self.items.values()), 'findings_count': len(self.items),
                'categories': counts, 'findings_truncated': self.overflow}


def mirror_repo(config, store):
    path = safe_path(store.path / 'public-mirror.git')
    url = config['mirror_url']
    if not path.exists():
        git(store.path, 'clone', '--mirror', '--template=', '--', url, str(path), timeout=180)
    else:
        if git(path, 'remote', 'get-url', 'origin').decode().strip() != url:
            raise AuditError('mirror origin differs from configuration')
    git(path, '-c', 'fetch.recurseSubmodules=false', 'fetch', '--prune', '--no-recurse-submodules',
        '--no-write-fetch-head', 'origin', '+refs/*:refs/*', timeout=180)
    return path


def github_scan(config, findings):
    unavailable, scanned = [], []
    repo = config.get('github_repo')
    if not repo:
        return {'unavailable': [], 'scanned': [], 'configured': False}
    endpoints = [('github_issues_prs', 'issues?state=all'),
                 ('github_issue_comments', 'issues/comments?sort=created&direction=asc'),
                 ('github_review_comments', 'pulls/comments?sort=created&direction=asc'),
                 ('github_releases', 'releases?')]
    deadline = time.monotonic() + 600
    for surface, endpoint in endpoints:
        try:
            for page in range(1, 1001):
                if time.monotonic() > deadline:
                    raise AuditError('GitHub audit deadline exceeded')
                separator = '' if endpoint.endswith('?') else '&'
                url = f'repos/{repo}/{endpoint}{separator}per_page=100&page={page}'
                data = json.loads(command(['gh', 'api', '--method', 'GET', url]))
                if not isinstance(data, list):
                    raise AuditError('unexpected GitHub response')
                for item in data:
                    identifier = item.get('number', item.get('id'))
                    if not isinstance(identifier, int):
                        raise AuditError('invalid GitHub item id')
                    locator = f'item:{identifier}'
                    for field in ('title', 'body', 'name', 'tag_name'):
                        value = item.get(field)
                        if isinstance(value, str):
                            findings.scan(surface, locator, value)
                if len(data) < 100:
                    break
            else:
                raise AuditError('GitHub page limit exceeded')
            scanned.append(surface)
        except (AuditError, ValueError, KeyError, TypeError, AttributeError):
            unavailable.append(surface)
    return {'unavailable': unavailable, 'scanned': scanned, 'configured': True}


def git_scan(repo, findings, known=()):
    commits = git(repo, 'rev-list', '--all').decode('ascii').splitlines()
    if len(commits) > 200000 or any(not re.fullmatch(r'[0-9a-f]{40,64}', c) for c in commits):
        raise AuditError('commit inventory limit or format error')
    refs = git(repo, 'for-each-ref', '--format=%(refname)').decode('utf-8', 'replace')
    findings.scan('git_refs', 'refs', refs)
    tags = git(repo, 'for-each-ref', '--format=%(objecttype) %(objectname)').decode('ascii').splitlines()
    seen_tags = set()
    for tag in tags:
        kind, oid = tag.split()
        while kind == 'tag' and oid not in seen_tags:
            if not re.fullmatch(r'[0-9a-f]{40,64}', oid) or len(seen_tags) > 10000:
                raise AuditError('tag limit or format error')
            seen_tags.add(oid)
            text = git(repo, 'cat-file', 'tag', oid).decode('utf-8', 'replace')
            findings.scan('git_tag_metadata', oid, text)
            lines = text.splitlines()
            oid, kind = lines[0].removeprefix('object '), lines[1].removeprefix('type ')
    known, blobs, completed = set(known), set(), []
    deadline = time.monotonic() + 900
    for commit in commits:
        if commit in known:
            continue
        if time.monotonic() > deadline:
            raise AuditError('Git audit deadline exceeded')
        metadata = git(repo, 'cat-file', 'commit', commit).decode('utf-8', 'replace')
        findings.scan('git_metadata', commit, metadata)
        raw = git(repo, 'diff-tree', '--root', '-r', '-m', '--no-commit-id', '--raw',
                  '--no-abbrev', '--no-renames', '--no-ext-diff', '-z', commit)
        fields = raw.split(b'\x00')
        index = 0
        while index < len(fields) and fields[index]:
            header = fields[index].split()
            if len(header) != 5 or not header[0].startswith(b':') or index + 1 >= len(fields):
                raise AuditError('unexpected Git tree response')
            path = fields[index + 1].decode('utf-8', 'surrogateescape')
            index += 2
            locator = f'{commit}:{path}'
            findings.scan('git_paths', locator, path)
            oid = header[3].decode('ascii')
            if header[1] not in (b'100644', b'100755', b'120000') or set(oid) == {'0'} or oid in blobs:
                continue
            if not re.fullmatch(r'[0-9a-f]{40,64}', oid):
                raise AuditError('invalid Git object identifier')
            size = int(git(repo, 'cat-file', '-s', oid))
            if size > 16 * 1024 * 1024:
                raise AuditError('Git object exceeds audit size limit')
            text = git(repo, 'cat-file', 'blob', oid, limit=16 * 1024 * 1024).decode('utf-8', 'replace')
            findings.scan('git_blobs', locator, text)
            blobs.add(oid)
        completed.append(commit)
    return {'reachable': commits, 'completed': completed, 'commits_scanned': len(completed)}


def audit(config, store, full=False):
    scanner = load_scanner()
    denylist = load_private_denylist(store, scanner)
    fingerprint = hashlib.sha256(('\n'.join(denylist)).encode() + Path(scanner.__file__).read_bytes()
                                 + json.dumps({k: config.get(k) for k in ('repo_path', 'mirror_url', 'github_repo')}, sort_keys=True).encode()).hexdigest()
    checkpoint = store.read('checkpoint.json', {})
    previous = store.read('report.json', {})
    full = (full or checkpoint.get('fingerprint') != fingerprint or not previous
            or previous.get('degraded', False) or previous.get('findings_truncated', False))
    findings = Findings(scanner, denylist, () if full else previous.get('findings', ()))
    unavailable, scanned, total = [], [], 0
    new_checkpoint = {'fingerprint': fingerprint, 'repos': {}}
    targets = [('local_git', Path(config['repo_path']))]
    if config.get('mirror_url'):
        try:
            targets.append(('mirror_git', mirror_repo(config, store)))
        except AuditError:
            unavailable.append('mirror_git')
    for surface, repo in targets:
        try:
            result = git_scan(repo, findings, () if full else checkpoint.get('repos', {}).get(surface, []))
            total += result['commits_scanned']
            new_checkpoint['repos'][surface] = result['reachable']
            scanned.append(surface)
        except (AuditError, ValueError, UnicodeError):
            unavailable.append(surface)
    github = github_scan(config, findings)
    unavailable.extend(github['unavailable'])
    scanned.extend(github['scanned'])
    if unavailable or findings.overflow:
        # An incomplete reconciliation cannot retire any previously observed finding.
        retained = Findings(scanner, denylist, previous.get('findings', ()))
        for key, item in findings.items.items():
            if key in retained.items:
                continue
            if len(retained.items) >= 5000:
                findings.overflow = True
                break
            retained.items[key] = item
        findings.items = retained.items
    report = dict(findings.result(), updated=now(), mode='full' if full else 'incremental',
                  commits_scanned=total, scanned=scanned, unavailable=unavailable,
                  not_scanned=['actions_logs', 'actions_artifacts', 'release_assets',
                               'unreachable_git_objects', 'working_tree', 'github_pr_reviews'],
                  github_configured=github['configured'], degraded=bool(unavailable) or findings.overflow)
    store.write('report.json', report)
    if not unavailable and not findings.overflow:
        store.write('checkpoint.json', new_checkpoint)
    summary = {key: report[key] for key in ('updated', 'mode', 'commits_scanned', 'findings_count',
                                           'categories', 'findings_truncated', 'scanned', 'unavailable',
                                           'not_scanned', 'github_configured', 'degraded')}
    store.write('audit-summary.json', summary)
    return summary


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', required=True, help='absolute private JSON configuration path')
    parser.add_argument('--state-dir', help='override private state_dir (outside checkout)')
    parser.add_argument('--full', action='store_true', help='rescan all reachable Git history')
    parser.add_argument('command', choices=('refresh', 'audit', 'run'))
    args = parser.parse_args(argv)
    os.umask(0o077)
    try:
        config_path = safe_path(args.config)
        if not Path(args.config).is_absolute():
            raise AuditError('config path must be absolute')
        if config_path.stat().st_mode & 0o077:
            raise AuditError('config must have mode 600 or stricter')
        config = json.loads(config_path.read_text(encoding='utf-8'))
        if args.state_dir:
            config['state_dir'] = args.state_dir
        config = validate_config(config)
        with State(config['state_dir']) as store:
            result = {}
            if args.command in ('refresh', 'run'):
                result['refresh'] = refresh(config, store)
            if args.command in ('audit', 'run'):
                result['audit'] = audit(config, store, args.full)
            store.write('summary.json', result)
            print(json.dumps(result, sort_keys=True))
            if any(r.get('degraded') or r.get('findings_truncated') for r in result.values()):
                return 2
            return 1 if result.get('audit', {}).get('findings_count') else 0
    except (AuditError, OSError, ValueError, KeyError, TypeError, AttributeError):
        print('{"error":"privacy audit failed; configuration, state, or command unavailable"}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
