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


if __name__ == "__main__":
    unittest.main()
