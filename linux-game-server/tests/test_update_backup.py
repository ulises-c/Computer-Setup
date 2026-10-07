import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
GAME = ROOT / "linux-game-server" / "dragonwilds"


class UpdateBackupTests(unittest.TestCase):
    def test_game_start_runs_backup_before_steamcmd(self):
        lines = GAME.joinpath("dragonwilds.service.template").read_text().splitlines()
        backup_index = next(i for i, line in enumerate(lines)
                            if "dragonwilds-pre-update-backup.service" in line)
        steam_index = next(i for i, line in enumerate(lines)
                           if "app_update @APPID@" in line)
        self.assertLess(backup_index, steam_index)
        self.assertIn(
            "ExecStartPre=+/usr/bin/systemctl start --wait dragonwilds-pre-update-backup.service",
            lines[backup_index],
        )
        self.assertTrue(any("ExecStopPost=+" in line and "SERVICE_RESULT" in line for line in lines))

    def test_backup_gate_is_fail_closed_once_a_world_exists(self):
        template = GAME.joinpath("dragonwilds-pre-update-backup.service.template").read_text()
        self.assertNotIn("ConditionPathExists=@INSTALL_DIR@/RSDragonwilds/Saved/Config/LinuxServer/DedicatedServer.ini", template)
        self.assertIn(
            "ConditionPathExistsGlob=@INSTALL_DIR@/RSDragonwilds/Saved/SaveGames/*.sav",
            template,
        )
        self.assertNotIn("ConditionPathExists=/etc/systemd/system/", template)
        self.assertIn(
            "ExecStart=/usr/bin/systemctl restart --wait @BACKUP_UNIT@",
            template,
        )
        self.assertTrue(any("stop-failure" in line for line in template.splitlines()))

    def test_start_timeout_covers_long_patch_and_backup(self):
        template = GAME.joinpath("dragonwilds.service.template").read_text()
        self.assertIn("TimeoutStartSec=5h", template)

    def test_backup_units_use_an_installed_executor_bundle(self):
        template = ROOT.joinpath("linux-game-server/backup/game-backup.service.template").read_text()
        failure = ROOT.joinpath("linux-game-server/backup/game-backup-failure.service.template").read_text()
        self.assertIn("ExecStart=/usr/bin/env bash @BACKUP_SCRIPT@", template)
        self.assertIn("Environment=BACKUP_HOST_DIR=@BACKUP_HOST_DIR@", template)
        self.assertIn("Environment=BACKUP_SAVE_SCRIPT=@BACKUP_SAVE_SCRIPT@", template)
        self.assertIn("Environment=BACKUP_SAVE_SCRIPT_SHA256=@BACKUP_SAVE_SCRIPT_SHA256@", template)
        self.assertNotIn("EnvironmentFile=-@BACKUP_ENV@", failure)

        setup = ROOT.joinpath("server-base/backup/setup.sh").read_text()
        self.assertIn("BUNDLE_DIR=\"/usr/local/libexec/computer-setup-backup/$prefix\"", setup)
        self.assertIn('install -o root -g root -m 755 "$SCRIPT_DIR/backup.sh" "$BUNDLE_DIR/backup.sh"', setup)
        self.assertNotIn('@BACKUP_SCRIPT@|$SCRIPT_DIR/backup.sh', setup)

    def test_main_backup_rejects_an_unverified_dragonwilds_world(self):
        sources = ROOT.joinpath("linux-server/backup/sources.sh").read_text()
        self.assertIn("DedicatedServer.ini is missing", sources)
        self.assertIn("DefaultWorldName", sources)
        self.assertIn("refusing an unverified backup", sources)

    def test_game_backup_requires_the_installed_helper(self):
        sources = ROOT.joinpath("linux-game-server/backup/sources.sh").read_text()
        setup = ROOT.joinpath("server-base/backup/setup.sh").read_text()
        self.assertIn('[[ -n "${BACKUP_SAVE_SCRIPT:-}" ]]', sources)
        self.assertNotIn("${BACKUP_SAVE_SCRIPT:-$HOST_DIR/dragonwilds/backup-save.py}", sources)
        self.assertIn('[[ "$unit" == "game-backup.service"', setup)
        self.assertIn("cannot install game backup without", setup)

    def test_backup_path_is_fixed_at_root_owned_unit_install_time(self):
        template = ROOT.joinpath("linux-game-server/backup/game-backup.service.template").read_text()
        sources = ROOT.joinpath("linux-game-server/backup/sources.sh").read_text()
        setup = ROOT.joinpath("server-base/backup/setup.sh").read_text()
        engine = ROOT.joinpath("server-base/backup/backup.sh").read_text()
        self.assertIn("Environment=BACKUP_DRAGONWILDS_INSTALL_DIR=@BACKUP_DRAGONWILDS_INSTALL_DIR@", template)
        self.assertIn('install_dir="${BACKUP_DRAGONWILDS_INSTALL_DIR:-}"', sources)
        self.assertNotIn('env_value "$HOST_DIR/dragonwilds/.env" DRAGONWILDS_INSTALL_DIR', sources)
        self.assertIn("@BACKUP_DRAGONWILDS_INSTALL_DIR@", setup)
        self.assertIn('STATE_DIR="/var/lib/computer-setup-backup/$prefix"', setup)
        self.assertIn('"$unit" == "backup.service"', setup)
        self.assertIn("UNIT_BACKUP_SAVE_SCRIPT", engine)
        self.assertIn("UNIT_BACKUP_SAVE_SCRIPT_SHA256", engine)
        self.assertIn('BACKUP_SAVE_SCRIPT="$UNIT_BACKUP_SAVE_SCRIPT"', engine)
        self.assertIn("BACKUP_SAVE_SCRIPT_SHA256", engine)
        self.assertIn("/var/lib/computer-setup-backup/game-backup", ROOT.joinpath("linux-game-server/backup/docker-compose.yml").read_text())
        self.assertIn("world_exists", sources)
        self.assertIn("BACKUP_FORGEJO_DATA_PATH", ROOT.joinpath("linux-server/backup/sources.sh").read_text())
        self.assertNotIn('env_value "$HOST_DIR/forgejo/.env" FORGEJO_DATA_PATH', ROOT.joinpath("linux-server/backup/sources.sh").read_text())

    def test_backup_units_allow_only_the_host_specific_unit(self):
        game_setup = GAME.joinpath("setup.sh").read_text()
        server_setup = ROOT.joinpath("linux-server/dragonwilds/setup.sh").read_text()
        self.assertIn('"$BACKUP_UNIT" != game-backup.service', game_setup)
        self.assertIn('"$BACKUP_UNIT" != backup.service', server_setup)

    def test_direct_installer_uses_the_same_backup_gate(self):
        installer = ROOT.joinpath("linux-game-server/dragonwilds/install.sh").read_text()
        polkit = ROOT.joinpath("linux-server/dragonwilds/dragonwilds-restart.rules.template").read_text()
        self.assertIn("systemctl show dragonwilds.service", installer)
        self.assertIn("dragonwilds-pre-update-backup.service", installer)
        self.assertIn('action.lookup("unit") == "dragonwilds-pre-update-backup.service"', polkit)
        self.assertIn('action.lookup("verb") == "start"', polkit)

    def test_player_log_is_private_root_owned_and_periodic(self):
        service = GAME.joinpath("dragonwilds-player-log.service.template").read_text()
        timer = GAME.joinpath("dragonwilds-player-log.timer").read_text()
        setup = GAME.joinpath("setup.sh").read_text()
        maintenance = GAME.joinpath("maintenance.sh").read_text()
        backup_engine = ROOT.joinpath("server-base/backup/backup.sh").read_text()
        README = GAME.joinpath("README.md").read_text()
        self.assertIn("ExecStart=/usr/bin/python3 @PLAYER_LOG_SCRIPT@", service)
        self.assertIn("ProtectHome=read-only", service)
        self.assertIn("ReadWritePaths=/var/lib/dragonwilds/player-log", service)
        self.assertIn("ProtectSystem=strict", service)
        self.assertIn("Environment=PYTHONDONTWRITEBYTECODE=1", service)
        self.assertIn("User=root", service)
        self.assertIn("Group=adm", service)
        self.assertIn('player_log_lock="$player_log_dir/.backup.lock"', setup)
        self.assertIn("install -o root -g adm -m 600 /dev/null", setup)
        self.assertIn("player_log_parent=/var/lib/dragonwilds", setup)
        self.assertIn("chown root:adm \"$player_log_lock\"", setup)
        self.assertIn("dragonwilds-player-log.timer", maintenance)
        self.assertIn("dragonwilds-player-log.service", maintenance)
        self.assertIn('readlink -- "/proc/$$/fd/$BACKUP_SHARED_LOCK_FD"', backup_engine)
        self.assertIn("flock -x /var/lib/dragonwilds/player-log/.backup.lock", README)
        self.assertIn("--exclude=.backup.lock", README)
        self.assertIn("OnUnitActiveSec=1min", timer)
        self.assertIn("install -o root -g root -m 755 \"$SCRIPT_DIR/player_log.py\"", setup)
        self.assertIn("enable --now dragonwilds-player-log.timer", setup)
        self.assertIn("verify_units=(", setup)
        self.assertIn("[[ -x \"$PLAYER_LOG_BUNDLE\" ]] && verify_units+=", setup)

    def test_player_log_is_in_encrypted_backup_sources(self):
        game_sources = ROOT.joinpath("linux-game-server/backup/sources.sh").read_text()
        server_sources = ROOT.joinpath("linux-server/backup/sources.sh").read_text()
        backup_engine = ROOT.joinpath("server-base/backup/backup.sh").read_text()
        self.assertIn("/var/lib/dragonwilds/player-log", game_sources)
        self.assertIn("/var/lib/dragonwilds/player-log", server_sources)
        self.assertIn("BACKUP_SHARED_LOCK_PATH", game_sources)
        self.assertIn("BACKUP_SHARED_LOCK_PATH", server_sources)
        self.assertIn('flock -s "$BACKUP_SHARED_LOCK_FD"', backup_engine)


class PlayerLogNotifyTests(unittest.TestCase):
    def _run(self, directory, env_lines):
        bin_dir = Path(directory) / "bin"
        bin_dir.mkdir(exist_ok=True)
        calls = Path(directory) / "curl.calls"
        (bin_dir / "curl").write_text(f'#!/usr/bin/env bash\nprintf "%s\\n" "$*" >>"{calls}"\n')
        (bin_dir / "journalctl").write_text('#!/usr/bin/env bash\nprintf "starting\\nerror: boom\\n"\n')
        for tool in ("curl", "journalctl"):
            (bin_dir / tool).chmod(0o755)
        app = Path(directory) / "app"
        (app / "status").mkdir(parents=True, exist_ok=True)
        shutil.copy(GAME / "dragonwilds-player-log-notify.sh", app / "notify.sh")
        (app / ".env").write_text("".join(f"{line}\n" for line in env_lines))
        env = {"PATH": f"{bin_dir}:{os.environ['PATH']}", "HOME": directory}
        result = subprocess.run(["bash", str(app / "notify.sh")], env=env, capture_output=True, text=True)
        return result, calls.read_text().splitlines() if calls.exists() else [], app

    def test_player_log_service_alerts_on_failure(self):
        template = GAME.joinpath("dragonwilds-player-log.service.template").read_text()
        self.assertIn("OnFailure=dragonwilds-player-log-failure.service", template)
        failure = GAME.joinpath("dragonwilds-player-log-failure.service.template").read_text()
        self.assertIn("User=@USER@", failure)
        self.assertIn("ExecStart=@PLAYER_LOG_NOTIFY_SCRIPT@", failure)

    def test_alert_is_sent_once_per_window_with_last_error(self):
        with tempfile.TemporaryDirectory() as directory:
            env = ["NTFY_URL=https://ntfy.example", "NTFY_TOPIC=dw", "NTFY_TOKEN=tok"]
            result, calls, app = self._run(directory, env)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(len(calls), 1)
            self.assertIn("error: boom", calls[0])
            self.assertIn("https://ntfy.example/dw", calls[0])
            self.assertTrue((app / "status" / ".player-log-alerted").exists())
            result, calls, _ = self._run(directory, env)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(len(calls), 1)

    def test_unconfigured_ntfy_is_a_warning_not_a_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            result, calls, _ = self._run(directory, ["NTFY_URL="])
            self.assertEqual(result.returncode, 0)
            self.assertEqual(calls, [])
            self.assertIn("not alerted", result.stderr)


if __name__ == "__main__":
    unittest.main()
