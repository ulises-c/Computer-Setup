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
# Each call is numbered by how often that exact command has run, so a test can
# fail, hang or tamper on one specific call: FAIL_CALL='stop dragonwilds.service#2'.
SYSTEMCTL = r'''#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CALLS"
call="$*#$(grep -cxF -- "$*" "$CALLS")"
[[ "$call" == "${HANG_CALL:-}" ]] && exec /bin/sleep 3600
[[ "$call" == "${SWAP_ASIDE_CALL:-}" ]] && { rm -rf "$ASIDE"; mkdir "$ASIDE"; printf 'foreign\n' >"$ASIDE/Foreign.sav"; }
[[ "$call" == "${FAIL_CALL:-}" ]] && exit 1
case "$*" in
  "show dragonwilds.service -p WorkingDirectory --value") printf '%s\n' "$INSTALL" ;;
  "show dragonwilds.service -p User --value") id -un ;;
  "show dragonwilds.service -p Group --value") printf '\n' ;;
  "show game-backup.service -p Result --value") printf 'success\n' ;;
  show*ActiveState*) printf 'inactive\n' ;;
  "start dragonwilds.service")
    [[ "$call" == *'#1' ]] || exit 0
    case "${FAIL_START:-}" in
      '') exit 0 ;;
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
# The forward move is `mv -T <live> <aside>`, the rollback `mv -T <aside> <live>`.
MV = r'''#!/usr/bin/env bash
src="${*: -2:1}" dst="${*: -1}"
if [[ "${FOREIGN_BEFORE_MOVE:-}" == 1 && "$dst" == "$ASIDE" ]]; then
  mkdir -p "$ASIDE"; printf 'foreign\n' >"$ASIDE/Foreign.sav"
fi
if [[ "${TERM_DURING_ROLLBACK:-}" == 1 && "$src" == "$ASIDE" ]]; then
  # Live is already deleted here; if the drill dies, the rollback never finishes.
  kill -TERM "$PPID"; /bin/sleep 0.5; kill -0 "$PPID" 2>/dev/null || exit 143
fi
/bin/mv "$@" || exit
[[ "${TERM_AFTER_MOVE:-}" == 1 && "$dst" == "$ASIDE" ]] && kill -TERM "$PPID"
exit 0
'''


class RestoreDrillRunTests(unittest.TestCase):
    """Runs the whole drill with systemd, restic and the clock stubbed.

    Only the root guard, the two root-owned paths and the recovery time limits
    are rewritten, so every other line is the real script.
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
            ('RECOVERY_CALL_SECONDS=180', 'RECOVERY_CALL_SECONDS=2'),
            ('RECOVERY_START_SECONDS=900', 'RECOVERY_START_SECONDS=2'),
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
            'mv': MV,
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
                              capture_output=True, text=True, timeout=30)

    def assert_original_live(self, result):
        self.assertEqual(self.tree(self.live), ['Main.sav'], result.stderr)
        self.assertEqual((self.live / 'Main.sav').read_text(), 'original\n')

    def assert_timer_left_stopped(self, result):
        self.assertNotIn('start dragonwilds-auto-update.timer', self.mutations(), result.stderr)

    def test_successful_drill_keeps_the_original_aside(self):
        result = self.run_drill()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('PASSED', result.stdout)
        self.assertEqual(self.tree(self.aside), ['Main.sav'])
        self.assertIn('start dragonwilds-auto-update.timer', self.mutations())

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


    def test_failed_forward_move_never_replaces_live(self):
        result = self.run_drill(FOREIGN_BEFORE_MOVE='1')
        self.assertNotEqual(result.returncode, 0)
        self.assert_original_live(result)
        self.assertEqual(self.tree(self.aside), ['Foreign.sav'])
        # Live never moved, so this is an ordinary failure: the game and timer come back.
        self.assertNotIn('manual recovery', result.stderr)
        self.assertEqual(self.mutations()[-2:], ['start dragonwilds.service', 'start dragonwilds-auto-update.timer'])

    def test_aside_replaced_while_recovery_stops_the_game_is_not_moved_back(self):
        result = self.run_drill(FAIL_START='touch-live', SWAP_ASIDE_CALL='stop dragonwilds.service#2')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('manual recovery required: the original world is not at', result.stderr)
        self.assertEqual(self.tree(self.live), ['Main.sav', 'Played.sav'])
        self.assertEqual(self.tree(self.aside), ['Foreign.sav'])
        self.assert_timer_left_stopped(result)

    def test_term_during_rollback_does_not_stop_it(self):
        result = self.run_drill(FAIL_START='touch-live', TERM_DURING_ROLLBACK='1')
        self.assertNotEqual(result.returncode, -15, result.stderr)
        self.assert_original_live(result)
        self.assertFalse(self.aside.exists())

    def test_hung_recovery_stop_is_bounded_and_touches_nothing(self):
        result = self.run_drill(FAIL_START='touch-live', HANG_CALL='stop dragonwilds.service#2')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('manual recovery required: dragonwilds.service could not be verified stopped', result.stderr)
        self.assertEqual(self.tree(self.live), ['Main.sav', 'Played.sav'])
        self.assertEqual(self.tree(self.aside), ['Main.sav'])
        self.assert_timer_left_stopped(result)

    def test_updater_that_cannot_stop_leaves_everything_and_the_timer_off(self):
        result = self.run_drill(FAIL_START='touch-live', FAIL_CALL='stop dragonwilds-auto-update.service#2')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('manual recovery required: the updater could not be stopped', result.stderr)
        self.assertEqual(self.tree(self.live), ['Main.sav', 'Played.sav'])
        self.assertEqual(self.tree(self.aside), ['Main.sav'])
        self.assert_timer_left_stopped(result)

    def test_game_that_will_not_restart_keeps_the_timer_off(self):
        result = self.run_drill(FAIL_START='touch-live', FAIL_CALL='start dragonwilds.service#2')
        self.assertNotEqual(result.returncode, 0)
        self.assert_original_live(result)
        self.assertIn('dragonwilds-auto-update.timer stays stopped', result.stderr)
        self.assert_timer_left_stopped(result)

if __name__ == '__main__':
    unittest.main()
