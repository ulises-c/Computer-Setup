from pathlib import Path
import os
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
ENGINE = REPO / 'server-base/backup/backup.sh'
SETUP = REPO / 'server-base/backup/setup.sh'
SOURCES = REPO / 'linux-server/backup/sources.sh'


class BackupBoundaryTests(unittest.TestCase):
    def test_native_engine_snapshots_volume_with_no_bind_sources(self):
        with tempfile.TemporaryDirectory() as root:
            base = Path(root)
            (base / 'backup').mkdir()
            (base / 'bin').mkdir()
            (base / 'backup/backup.sh').write_text(ENGINE.read_text())
            (base / 'backup/sources.sh').write_text('BACKUP_NAME=fixture\nBACKUP_LABEL=Fixture\nBACKUP_UNIT=fixture.service\nresolve_sources() { :; }\n')
            (base / 'bin/docker').write_text('''#!/usr/bin/env bash
case "$1" in
  inspect) printf 'true\\n' ;;
  run) printf 'volume archive\\n' ;;
  stop|start|ps) exit 0 ;;
esac
''')
            (base / 'bin/restic').write_text('''#!/usr/bin/env bash
case "$1" in
  backup) cp "$STAGING_DIR/portainer.tar" "$ARCHIVE" ;;
  snapshots) printf '[{"short_id":"fixture"}]\\n' ;;
  stats) printf '{"total_size":100}' ;;
esac
''')
            for tool in (base / 'bin').iterdir():
                tool.chmod(0o755)
            env = dict(os.environ, PATH=str(base / 'bin') + ':' + os.environ['PATH'], RESTIC_REPOSITORY='sftp:fixture:/primary', RESTIC_PASSWORD='fixture', STAGING_DIR=str(base / 'staging'), STATUS_JSON=str(base / 'status.json'), ARCHIVE=str(base / 'archive.tar'), NTFY_URL='', KUMA_PUSH_URL='')
            result = subprocess.run(['bash', str(base / 'backup/backup.sh')], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue((base / 'archive.tar').is_file(), result.stdout + result.stderr)
            self.assertEqual((base / 'archive.tar').read_text(), 'volume archive\n')

    def test_empty_cleanup_works_on_native_bash(self):
        text = ENGINE.read_text()
        cleanup = text[text.index('finish()'):text.index('# --- guards')]
        result = subprocess.run(['bash', '-c', 'set -euo pipefail; STATUS=success; STAGING_READY=false; ' + cleanup], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_unpinned_configured_or_present_game_fails_closed(self):
        with tempfile.TemporaryDirectory() as root:
            for state in ('configured', 'saved', 'loaded'):
                with self.subTest(state=state):
                    base = Path(root) / state
                    (base / 'dragonwilds').mkdir(parents=True)
                    if state == 'configured':
                        (base / 'dragonwilds/.env').touch()
                    if state == 'saved':
                        (base / 'dragonwilds/games/dragonwilds/RSDragonwilds/Saved').mkdir(parents=True)
                    script = '''set -euo pipefail
HOST_DIR="$1"; BACKUP_FORGEJO_DATA_PATH="$1/forgejo/data"
CANDIDATES=(); log() { :; }; die() { printf '%s\\n' "$*" >&2; exit 1; }
systemctl() { printf '%s\\n' "$load_state"; }
load_state="$3"
source "$2"; resolve_sources
'''
                    result = subprocess.run(['bash', '-c', script, 'bash', str(base), str(SOURCES), 'loaded' if state == 'loaded' else 'not-found'], capture_output=True, text=True)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn('configured/present Dragonwilds state', result.stderr)

    def test_primary_local_init_requires_verified_mount_containment(self):
        text = ENGINE.read_text()
        block = text[text.index('if ! restic cat config'):text.index('log "backing up')]
        with tempfile.TemporaryDirectory() as root:
            Path(root, '.backup-target-ok').touch()
            for repository, mount, allowed in [(root + '/restic', root, True), ('/outside/restic', root, False), (root + '/restic', '', False)]:
                with self.subTest(repository=repository, mount=mount):
                    script = '''set -euo pipefail
RESTIC_REPOSITORY="$1"; BACKUP_MOUNT="$2"
mountpoint() { return 0; }; log() { :; }
die() { printf '%s\\n' "$*" >&2; exit 1; }
restic() { printf '%s\\n' "$*"; [[ "$*" != 'cat config' ]]; }
''' + block
                    result = subprocess.run(['bash', '-c', script, 'bash', repository, mount], capture_output=True, text=True)
                    self.assertEqual('init\n' in result.stdout, allowed, result.stdout)

    def test_missing_portainer_container_with_existing_volume_is_failure(self):
        text = ENGINE.read_text()
        block = text[text.index('# Portainer stores'):text.index('if declare -F stage_extra')]
        script = '''set -euo pipefail
HOST_DIR=/fixture; STAGING_DIR=/unused; QUIESCED_CONTAINERS=()
die() { printf '%s\\n' "$*" >&2; exit 1; }; log() { :; }
docker() { case "$1" in inspect) return 1;; info) return 0;; volume) printf 'portainer_portainer_data\\n';; esac; }
''' + block
        result = subprocess.run(['bash', '-c', script], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Portainer', result.stderr)

    def test_orbstack_volume_snapshot_is_docker_mediated_and_restarts_on_failure(self):
        text = ENGINE.read_text()
        block = text[text.index('# Portainer stores'):text.index('if declare -F stage_extra')]
        with tempfile.TemporaryDirectory() as root:
            for fail_copy in ('false', 'true'):
                with self.subTest(fail_copy=fail_copy):
                    script = '''set -euo pipefail
STAGING_DIR="$1"; HOST_DIR="$1"; QUIESCED_CONTAINERS=()
log() { :; }; die() { printf '%s\\n' "$*" >&2; exit 1; }
docker() {
  printf '%s\\n' "$*" >>"$STAGING_DIR/calls"
  case "$1" in
    inspect) if [[ "$*" == *State.Running* ]]; then printf 'true\\n'; else printf '/var/lib/docker/volumes/portainer/_data\\n'; fi ;;
    run) [[ "$fail_copy" == false ]] || return 1; printf 'volume archive\\n' ;;
    stop|start) return 0 ;;
  esac
}
fail_copy="$2"
''' + block
                    Path(root, 'calls').unlink(missing_ok=True)
                    result = subprocess.run(['bash', '-c', script, 'bash', root, fail_copy], capture_output=True, text=True)
                    calls = Path(root, 'calls').read_text()
                    self.assertIn('run --rm', calls)
                    self.assertIn('--volumes-from portainer:ro', calls)
                    self.assertIn('start portainer', calls)
                    self.assertEqual(result.returncode == 0, fail_copy == 'false', result.stderr)
                    if fail_copy == 'false':
                        self.assertTrue(Path(root, 'portainer.tar').stat().st_size)

    def test_second_repo_init_requires_local_path_inside_verified_mount(self):
        text = ENGINE.read_text()
        function = text[text.index('  sync_second_repo()'):text.index('  if ! sync_second_repo;')]
        with tempfile.TemporaryDirectory() as root:
            Path(root, '.backup-target-ok').touch()
            for repository, allowed in [('sftp:target:/copy', False), ('/outside/restic', False), (root + '/../escape/restic', False), (root + '/restic', True)]:
                with self.subTest(repository=repository):
                    script = '''SECOND_BACKUP_MOUNT="$1"; SECOND_RESTIC_REPOSITORY="$2"
RESTIC_REPOSITORY=/primary; HOSTTAG=test
RETENTION_KEEP_DAILY=7; RETENTION_KEEP_WEEKLY=4; RETENTION_KEEP_MONTHLY=6
mountpoint() { return 0; }; log() { :; }
restic() { printf '%s\\n' "$*"; [[ "$*" != *'cat config'* ]]; }
''' + function + '\nsync_second_repo\n'
                    result = subprocess.run(['bash', '-c', script, 'bash', root, repository], capture_output=True, text=True)
                    self.assertEqual(' init ' in result.stdout, allowed, result.stdout)

    def test_generic_sources_allow_absent_game(self):
        with tempfile.TemporaryDirectory() as root:
            script = '''set -euo pipefail
HOST_DIR="$1"; BACKUP_FORGEJO_DATA_PATH="$1/forgejo/data"
CANDIDATES=(); log() { :; }; die() { printf '%s\\n' "$*" >&2; exit 1; }
systemctl() { printf 'not-found\\n'; }
source "$2"; resolve_sources
printf '%s\\n' "${CANDIDATES[@]}"
'''
            result = subprocess.run(['bash', '-c', script, 'bash', root, str(SOURCES)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('/forgejo/data', result.stdout)

    def test_generic_install_allows_absent_game(self):
        text = SETUP.read_text()
        start = text.index('  if [[ ("$unit"')
        guard = text[start:text.index('  if [[ "$unit" == "game-backup.service" && -z "$BUNDLE_SAVE_SCRIPT_SHA256"', start)]
        result = subprocess.run(['bash', '-c', 'unit=backup.service; BACKUP_DRAGONWILDS_INSTALL_DIR=""; HOST_DIR=/fixture; ' + guard], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main()
