#!/usr/bin/env python3
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

MODULE_PATH = Path(__file__).resolve().parents[1] / "scaffold.py"
spec = importlib.util.spec_from_file_location("scaffold", MODULE_PATH)
scaffold = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scaffold)


class ScaffoldTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "homepage").mkdir()
        (self.root / "dragonwilds").mkdir()
        self.root_patch = patch.object(scaffold, "ROOT", self.root)
        self.root_patch.start()
        self.addCleanup(self.root_patch.stop)
        self.host_patch = patch.object(scaffold, "allowed_hosts", return_value=["localhost", "game.example.test"])
        self.host_patch.start()
        self.addCleanup(self.host_patch.stop)
        self.domain_patch = patch.object(scaffold, "tailnet_domain", return_value="game.example.test")
        self.domain_patch.start()
        self.addCleanup(self.domain_patch.stop)

    def test_private_files_and_shell_quoting(self):
        with patch.dict(os.environ, USER="game-user"):
            scaffold.main()
        for path in (self.root / "homepage/.env", self.root / "dragonwilds/.env"):
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        result = subprocess.run(["bash", "-c", 'source "$1"; printf "%s\\n" "$SERVICE_USER" "$AUTO_UPDATE_RESTART"',
                                 "bash", str(self.root / "dragonwilds/.env")], capture_output=True, text=True, check=True)
        self.assertEqual(result.stdout.splitlines(), ["game-user", "false"])

    def test_existing_game_env_is_not_overwritten(self):
        env = self.root / "dragonwilds/.env"
        content = "SERVER_PORT=7778\nAUTO_UPDATE_RESTART=false\n"
        env.write_text(content)
        scaffold.main()
        self.assertEqual(env.read_text(), content)

    def test_refresh_preserves_hosts_and_other_settings(self):
        env = self.root / "homepage/.env"
        env.write_text("OTHER=value\nHOMEPAGE_ALLOWED_HOSTS=custom.example.test,localhost\n")
        scaffold.main()
        self.assertIn("OTHER=value\n", env.read_text())
        self.assertIn("HOMEPAGE_ALLOWED_HOSTS=custom.example.test,localhost,game.example.test\n", env.read_text())
        first = env.read_text()
        scaffold.main()
        self.assertEqual(env.read_text(), first)

    def test_adds_missing_allowed_hosts_key(self):
        env = self.root / "homepage/.env"
        env.write_text("OTHER=value\n")
        scaffold.main()
        self.assertIn("HOMEPAGE_ALLOWED_HOSTS=localhost,game.example.test\n", env.read_text())

    def test_service_envs_are_private_and_not_overwritten(self):
        scaffold.main()
        homepage = (self.root / "homepage/.env").read_text()
        glances = self.root / "glances/.env"
        self.assertIn("HOMEPAGE_VAR_GAME_HOMEPAGE_DOMAIN=game.example.test\n", homepage)
        self.assertEqual(glances.read_text(), "GLANCES_ALLOWED_HOSTS=localhost,127.0.0.1,game.example.test\n")
        self.assertEqual(glances.stat().st_mode & 0o777, 0o600)
        glances.write_text("GLANCES_ALLOWED_HOSTS=custom\n")
        scaffold.main()
        self.assertEqual(glances.read_text(), "GLANCES_ALLOWED_HOSTS=custom\n")
        self.assertEqual((self.root / "homepage/.env").read_text().count("HOMEPAGE_VAR_GAME_HOMEPAGE_DOMAIN="), 1)

    def test_tailscale_self_null_keeps_local_hosts(self):
        self.host_patch.stop()
        self.domain_patch.stop()
        with patch.object(scaffold.subprocess, 'run', side_effect=[
            subprocess.CompletedProcess([], 0),
            subprocess.CompletedProcess([], 0, stdout='{"Self": null}'),
        ]):
            hosts = scaffold.allowed_hosts()
        self.assertIn('localhost', hosts)
        self.assertIn('127.0.0.1:3000', hosts)

    def test_adguard_card_values_come_from_the_replica_env_with_quoting_kept(self):
        (self.root / "adguard").mkdir()
        (self.root / "adguard/.env").write_text(
            "# LAN_IP=ignored\nLAN_IP=192.0.2.10\nLAN_CIDR=\nADGUARD_USER=admin\nADGUARD_PASSWORD='p$ss word'\n")
        scaffold.main()
        homepage = (self.root / "homepage/.env").read_text()
        self.assertIn("HOMEPAGE_VAR_ADGUARD_LAN_URL=http://192.0.2.10:3053\n", homepage)
        self.assertIn("HOMEPAGE_VAR_ADGUARD_USER=admin\n", homepage)
        self.assertIn("HOMEPAGE_VAR_ADGUARD_PASS='p$ss word'\n", homepage)
        scaffold.main()
        self.assertEqual((self.root / "homepage/.env").read_text(), homepage)

    def test_no_adguard_env_adds_no_card_values(self):
        scaffold.main()
        self.assertNotIn("ADGUARD", (self.root / "homepage/.env").read_text())


if __name__ == "__main__":
    unittest.main()
