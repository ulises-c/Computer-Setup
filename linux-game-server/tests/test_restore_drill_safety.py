import fcntl
import json
from datetime import datetime, timezone
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
DRILL = REPO / 'linux-game-server/backup/restore-drill.sh'


class RestoreSafetyTests(unittest.TestCase):
    def test_recovery_does_not_reenable_timer_when_updater_cannot_stop(self):
        text = DRILL.read_text()
        helpers = text[text.index('die()'):text.index('allow_players=false')]
        recover = text[text.index('recover()'):text.index('trap recover EXIT')]
        script = helpers + recover + '''
finished=false; swapping=false; swapped=false
GAME_UNIT=dragonwilds.service; UPDATE_TIMER=dragonwilds-auto-update.timer
UPDATE_SERVICE=dragonwilds-auto-update.service
live="$1/live"; aside="$1/aside"; scratch="$1/scratch"
systemctl() { printf '%s\\n' "$*"; [[ "$*" != *dragonwilds-auto-update.service* ]]; }
recover
'''
        with tempfile.TemporaryDirectory() as root:
            result = subprocess.run(['bash', '-c', script, 'bash', root], capture_output=True, text=True)
            self.assertNotIn('start dragonwilds-auto-update.timer', result.stdout)

    def test_failed_unit_state_is_not_verified_stopped(self):
        text = DRILL.read_text()
        helpers = text[text.index('die()'):text.index('allow_players=false')]
        script = helpers + '''
GAME_UNIT=dragonwilds.service
systemctl() { [[ "$1" != show ]] || printf 'failed\\n'; return 0; }
stop_game
'''
        result = subprocess.run(['bash', '-c', script], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)

    def test_fresh_running_zero_players_allowed(self):
        text = DRILL.read_text()
        guard = text[text.index('if [[ "$allow_players"'):text.index('[[ -f "$SCRIPT_DIR/.env"')]
        with tempfile.TemporaryDirectory() as root:
            status = Path(root) / 'status.json'
            status.write_text(json.dumps({'players': 0, 'updated': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'), 'status': 'running'}))
            result = subprocess.run(['bash', '-c', 'die() { exit 1; }; allow_players=false; status_json="$1"; ' + guard, 'bash', str(status)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_stale_zero_players_rejected_before_disruption(self):
        text = DRILL.read_text()
        guard = text[text.index('if [[ "$allow_players"'):text.index('[[ -f "$SCRIPT_DIR/.env"')]
        with tempfile.TemporaryDirectory() as root:
            status = Path(root) / 'status.json'
            status.write_text(json.dumps({'players': 0, 'updated': '2000-01-01T00:00:00Z', 'status': 'running'}))
            result = subprocess.run(['bash', '-c', 'die() { printf "%s\\n" "$*" >&2; exit 1; }; allow_players=false; status_json="$1"; ' + guard, 'bash', str(status)], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('fresh', result.stderr)

    def test_failed_stop_preserves_both_worlds_and_timer_stays_stopped(self):
        text = DRILL.read_text()
        helpers = text[text.index('die()'):text.index('allow_players=false')]
        recover = text[text.index('recover()'):text.index('trap recover EXIT')]
        with tempfile.TemporaryDirectory() as root:
            base = Path(root)
            for name in ('live', 'aside'):
                (base / name).mkdir()
                (base / name / 'Main.sav').write_text(name)
            script = helpers + recover + '''
finished=false; swapping=true; swapped=true
GAME_UNIT=dragonwilds.service; UPDATE_TIMER=dragonwilds-auto-update.timer
UPDATE_SERVICE=dragonwilds-auto-update.service
live="$1/live"; aside="$1/aside"; scratch="$1/scratch"
mkdir "$scratch"
systemctl() {
  printf '%s\n' "$*" >>"$calls"
  case "$*" in
    *auto-update.timer*) return 0 ;;
    *auto-update.service*ActiveState*) printf 'inactive\n'; return 0 ;;
    *auto-update.service*) return 0 ;;
    *) return 1 ;;
  esac
}
calls="$1/calls"
recover
'''
            result = subprocess.run(['bash', '-c', script, 'bash', root], capture_output=True, text=True)
            self.assertEqual((base / 'live/Main.sav').read_text(), 'live')
            self.assertEqual((base / 'aside/Main.sav').read_text(), 'aside')
            self.assertIn('stop dragonwilds.service', (base / 'calls').read_text())
            self.assertNotIn('start dragonwilds-auto-update.timer', (base / 'calls').read_text())
            self.assertIn('manual recovery', result.stderr)

    def test_updater_stopped_and_verified_before_game_or_snapshot(self):
        text = DRILL.read_text()
        helpers = text[text.index('die()'):text.index('allow_players=false')]
        commands = text[text.index('log "stopping $UPDATE_TIMER'):text.index('log "taking a fresh snapshot')]
        script = helpers + '''
GAME_UNIT=dragonwilds.service; UPDATE_TIMER=dragonwilds-auto-update.timer
UPDATE_SERVICE=dragonwilds-auto-update.service
systemctl() { printf '%s\\n' "$*" >&2; [[ "$*" != *ActiveState* ]] || printf 'inactive\\n'; return 0; }
''' + commands
        result = subprocess.run(['bash', '-c', script], capture_output=True, text=True)
        self.assertIn('show dragonwilds-auto-update.service -p ActiveState', result.stderr)


STAMP = '20260101-120000'
SYSTEMCTL = r'''#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CALLS"
case "$*" in
  "show dragonwilds.service -p WorkingDirectory --value") printf '%s\n' "$INSTALL" ;;
  "show dragonwilds.service -p User --value") id -un ;;
  "show dragonwilds.service -p Group --value") printf '\n' ;;
  "show game-backup.service -p Result --value") printf 'success\n' ;;
  show*ActiveState*) printf 'inactive\n' ;;
  "start dragonwilds.service")
    [[ -e "$CALLS.started" ]] && exit 0
    touch "$CALLS.started"
    case "${FAIL_START:-}" in
      touch-live) printf 'played\n' >"$LIVE/Played.sav" ;;
      drop-aside) rm -rf "$ASIDE" ;;
    esac
    exit 1 ;;
esac
exit 0
'''
RESTIC = r'''#!/usr/bin/env bash
case "$1" in
  snapshots) printf '[{"short_id":"abc12345"}]\n' ;;
  restore)
    target="$4"; shift 4
    while (($#)); do
      [[ "$1" == --include ]] && { mkdir -p "$target$(dirname -- "$2")"; cp -a "$2" "$target$2"; }
      shift 2
    done ;;
esac
'''
# The forward move is the only `mv -T <live> <aside>`; TERM lands right after it.
MV_TERM = r'''#!/usr/bin/env bash
/bin/mv "$@" || exit
[[ "${TERM_AFTER_MOVE:-}" == 1 && "${*: -1}" == "$ASIDE" ]] && kill -TERM "$PPID"
exit 0
'''


class RestoreDrillRunTests(unittest.TestCase):
    """Runs the whole drill with systemd, restic and the clock stubbed.

    Only the root guard and the two root-owned paths are rewritten, so every
    other line is the real script.
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        install = self.root / 'install'
        self.saved = install / 'RSDragonwilds/Saved'
        self.live = self.saved / 'SaveGames'
        self.aside = self.saved / f'SaveGames.drill-{STAMP}'
        self.live.mkdir(parents=True)
        (self.saved / 'Config').mkdir()
        (self.live / 'Main.sav').write_text('original\n')
        (self.saved / 'Config/Game.ini').write_text('[game]\n')
        drill_dir = self.root / 'backup'
        drill_dir.mkdir()
        (drill_dir / '.env').write_text('RESTIC_REPOSITORY=sftp:example:/repo\n')
        self.lock = self.root / 'drill.lock'
        text = DRILL.read_text()
        for old, new in (
            ('[[ "$EUID" -eq 0 ]] ||', '[[ -n "$EUID" ]] ||'),
            ('LOCK_FILE=/run/lock/dragonwilds-restore-drill.lock', f'LOCK_FILE={self.lock}'),
            ('mktemp -d /root/restore-drill.XXXXXX', f'mktemp -d {self.root}/restore-drill.XXXXXX'),
        ):
            self.assertEqual(text.count(old), 1, old)
            text = text.replace(old, new)
        self.drill = drill_dir / 'restore-drill.sh'
        self.drill.write_text(text)
        bin_dir = self.root / 'bin'
        bin_dir.mkdir()
        stubs = {
            'systemctl': SYSTEMCTL,
            'restic': RESTIC,
            'mv': MV_TERM,
            'journalctl': "#!/usr/bin/env bash\nprintf 'World load SUCCEEDED\\n'\n",
            'chown': '#!/usr/bin/env bash\nexit 0\n',
            'sleep': '#!/usr/bin/env bash\nexit 0\n',
            'date': f'#!/usr/bin/env bash\n[[ "$*" == "+%Y%m%d-%H%M%S" ]] && {{ printf "{STAMP}\\n"; exit; }}\nexec /bin/date "$@"\n',
        }
        for name, body in stubs.items():
            (bin_dir / name).write_text(body)
            (bin_dir / name).chmod(0o755)
        self.calls = self.root / 'calls'
        self.env = {**os.environ, 'PATH': f'{bin_dir}:{os.environ["PATH"]}', 'CALLS': str(self.calls),
                    'INSTALL': str(install), 'LIVE': str(self.live), 'ASIDE': str(self.aside)}

    def tearDown(self):
        self.tmp.cleanup()

    def run_drill(self, **env):
        return subprocess.run(['bash', str(self.drill), '--allow-players'], env={**self.env, **env},
                              capture_output=True, text=True, timeout=60)

    def mutations(self):
        calls = self.calls.read_text().splitlines() if self.calls.exists() else []
        return [c for c in calls if not c.startswith('show ')]

    def tree(self, path):
        return sorted(str(p.relative_to(path)) for p in path.rglob('*'))

    def test_failed_start_puts_the_original_world_back(self):
        result = self.run_drill(FAIL_START='touch-live')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.tree(self.live), ['Main.sav'], result.stderr)
        self.assertEqual((self.live / 'Main.sav').read_text(), 'original\n')
        self.assertFalse(self.aside.exists())

    def test_existing_aside_is_rejected_before_anything_stops(self):
        self.aside.mkdir()
        (self.aside / 'Old.sav').write_text('old\n')
        result = self.run_drill(FAIL_START='touch-live')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('already exists', result.stderr)
        self.assertEqual(self.mutations(), [])
        self.assertEqual(self.tree(self.live), ['Main.sav'])
        self.assertEqual(self.tree(self.aside), ['Old.sav'])

    def test_term_right_after_the_move_restores_the_world(self):
        result = self.run_drill(TERM_AFTER_MOVE='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.tree(self.live), ['Main.sav'], result.stderr)
        self.assertEqual((self.live / 'Main.sav').read_text(), 'original\n')
        self.assertFalse(self.aside.exists())

    def test_missing_aside_keeps_live_and_leaves_the_game_stopped(self):
        result = self.run_drill(FAIL_START='drop-aside')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('manual recovery required', result.stderr)
        self.assertEqual(self.tree(self.live), ['Main.sav'])
        self.assertEqual(self.mutations().count('start dragonwilds.service'), 1)
        self.assertNotIn('start dragonwilds-auto-update.timer', self.mutations())
        self.assertEqual(len(list(self.root.glob('restore-drill.*'))), 1, 'scratch copy removed')

    def test_a_second_drill_is_refused_while_one_runs(self):
        with open(self.lock, 'w') as held:
            fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.run_drill()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('another restore drill is running', result.stderr)
        self.assertEqual(self.mutations(), [])
        self.assertEqual(self.tree(self.live), ['Main.sav'])


if __name__ == '__main__':
    unittest.main()
