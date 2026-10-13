import json
from datetime import datetime, timezone
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
finished=false; swapped=false
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
finished=false; swapped=true
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


if __name__ == '__main__':
    unittest.main()
