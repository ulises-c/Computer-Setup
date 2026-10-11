import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
GAME = ROOT / "linux-game-server" / "dragonwilds"


class UpdateMetadataCliTests(unittest.TestCase):
    def run_helper(self, *arguments, input_text=None):
        return subprocess.run(
            ["python3", str(GAME / "dragonwilds_update_metadata.py"), *arguments],
            input=input_text,
            capture_output=True,
            text=True,
            timeout=10,
        )

    def test_latest_public_linux_manifest_and_installed_manifest_match_despite_buildid_drift(self):
        steam_info = '''Steam Console Client output
"4019830"
{
    "depots"
    {
        "4019831" { "config" { "oslist" "windows" }
            "manifests" { "public" { "gid" "8785703735728836370" } } }
        "3501791" { "config" { "oslist" "linux" }
            "manifests" {
                "beta" { "gid" "1111111111111111111" }
                "public" { "gid" "5736699466634593401" }
            }
        }
    }
    "branches"
    {
        "beta" { "buildid" "25809000" }
        "public" { "buildid" "25808123" }
    }
}
Unloading Steam API...
'''
        installed = '''"AppState"
{
    "appid" "4019830"
    "buildid" "25805654"
    "InstalledDepots"
    {
        "3501791" { "manifest" "5736699466634593401" }
    }
}
'''
        with tempfile.TemporaryDirectory() as directory:
            manifest = Path(directory) / "appmanifest_4019830.acf"
            manifest.write_text(installed)
            latest = self.run_helper("steam", input_text=steam_info)
            on_disk = self.run_helper("installed", str(manifest))

        self.assertEqual(latest.returncode, 0, latest.stderr)
        self.assertEqual(latest.stdout.strip(), "25808123 5736699466634593401")
        self.assertEqual(on_disk.returncode, 0, on_disk.stderr)
        self.assertEqual(on_disk.stdout.strip(), "25805654 5736699466634593401")
        status = self.run_helper(
            "status", "5736699466634593401", "5736699466634593401", "25808123"
        )
        self.assertEqual(status.returncode, 0, status.stderr)
        self.assertEqual(status.stdout.strip(), "up to date")

    def test_inline_comments_and_quoted_slashes_parse_as_vdf_data(self):
        steam_info = '''"4019830" { "common" { "url" "https://example.test/a//b" } // app note
  "depots" { "3501791" { "manifests" { "public" { "gid" "5736699466634593401" } } } } // depot note
  "branches" { "public" { "buildid" "25808123" } }
}'''
        result = self.run_helper("steam", input_text=steam_info)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "25808123 5736699466634593401")

    def test_unterminated_block_comment_fails_closed(self):
        steam_info = '''"4019830" { "depots" { "3501791" { "manifests" { "public" { "gid" "5736699466634593401" } } } } "branches" { "public" { "buildid" "25808123" } } /* missing close'''
        result = self.run_helper("steam", input_text=steam_info)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unterminated VDF comment", result.stderr)

    def test_game_host_helper_link_resolves_with_full_repository_checkout(self):
        helper = GAME / "dragonwilds_update_metadata.py"
        self.assertTrue(helper.is_symlink())
        self.assertEqual(
            helper.resolve(),
            ROOT / "linux-server" / "dragonwilds" / "dragonwilds_update_metadata.py",
        )
        self.assertTrue(helper.is_file())

    def test_changed_linux_depot_manifest_reports_update_available(self):
        result = self.run_helper(
            "status", "5736699466634593401", "6000000000000000000", "25808123"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "update available (25808123)")

    def test_missing_manifest_metadata_is_unknown_not_update(self):
        result = self.run_helper("status", "5736699466634593401", "", "25808123")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "unknown")


class UpdateCheckIntegrationTests(unittest.TestCase):
    def test_check_persists_app_build_timestamp_and_linux_manifest(self):
        steam_info = '''"4019830"
{
  // comment note
  "common" { "installdir" "RuneScape\\Dragonwilds" }
  /* manifest comment */
  "depots" { "3501791" { "manifests" { "public" { "gid" "5736699466634593401" } } } }
  "branches" { "public" { "buildid" "25808123" } }
}
'''
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            script_dir = root / "scripts"
            script_dir.mkdir()
            shutil.copy(GAME / "dragonwilds-update-check.sh", script_dir)
            shutil.copy(GAME / "dragonwilds_update_metadata.py", script_dir)
            fixture = root / "steam-info.vdf"
            fixture.write_text(steam_info)
            install = root / "install"
            install.mkdir()
            output = root / "latest-build"
            bin_dir = root / "bin"
            bin_dir.mkdir()
            timeout = bin_dir / "timeout"
            timeout.write_text(chr(10).join(["#!/usr/bin/env bash", "shift", 'exec "$@"', ""]))
            timeout.chmod(0o755)
            flock = bin_dir / "flock"
            flock.write_text(chr(10).join(["#!/usr/bin/env bash", "exit 0", ""]))
            flock.chmod(0o755)
            steamcmd = bin_dir / "steamcmd"
            steamcmd.write_text(
                chr(10).join([
                    "#!/usr/bin/env python3",
                    "import os, pathlib",
                    "print(pathlib.Path(os.environ['STEAM_INFO_FIXTURE']).read_text(), end='')",
                    "",
                ])
            )
            steamcmd.chmod(0o755)
            env = dict(os.environ)
            env.update(
                PATH=f"{bin_dir}:{env['PATH']}",
                HOME=str(root),
                DRAGONWILDS_INSTALL_DIR=str(install),
                STEAMCMD=str(steamcmd),
                STEAM_INFO_FIXTURE=str(fixture),
                LATEST_BUILD_FILE=str(output),
            )
            result = subprocess.run(
                ["bash", str(script_dir / "dragonwilds-update-check.sh")],
                env=env,
                capture_output=True,
                text=True,
                timeout=15,
            )

            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            fields = output.read_text().split()
            self.assertEqual(fields[0], "25808123")
            self.assertRegex(fields[1], r"^\d{4}-\d{2}-\d{2}T")
            self.assertEqual(fields[2], "5736699466634593401")


class DepotUpdateIntegrationTests(unittest.TestCase):
    def test_app_buildid_drift_with_current_linux_depot_does_not_restart(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            script_dir = root / "scripts"
            script_dir.mkdir()
            shutil.copy(GAME / "dragonwilds-auto-update.sh", script_dir)
            shutil.copy(GAME / "dragonwilds-players.sh", script_dir)
            shutil.copy(GAME / "dragonwilds_update_metadata.py", script_dir)

            install = root / "install"
            steamapps = install / "steamapps"
            steamapps.mkdir(parents=True)
            (steamapps / "appmanifest_4019830.acf").write_text(
                '"AppState"\n{\n'
                '\t"appid" "4019830"\n'
                '\t"buildid" "25805654"\n'
                '\t"InstalledDepots"\n\t{\n'
                '\t\t"3501791"\n\t\t{\n'
                '\t\t\t"manifest" "5736699466634593401"\n'
                '\t\t}\n\t}\n}\n'
            )
            latest = root / "latest-build"
            latest.write_text(
                "25808123 2026-10-11T18:01:40Z 5736699466634593401\n"
            )
            notified = root / "notified-build"
            notified.write_text("25808123\n")
            failed = root / "failed-build"
            calls = root / "systemctl.calls"

            bin_dir = root / "bin"
            bin_dir.mkdir()
            fake_systemctl = bin_dir / "systemctl"
            fake_systemctl.write_text(
                "#!/usr/bin/env bash\n"
                f"printf '%s\n' \"$*\" >> {str(calls)!r}\n"
                "exit 1\n"
            )
            fake_systemctl.chmod(0o755)
            (script_dir / "dragonwilds-players.sh").write_text(
                "#!/usr/bin/env bash\nprintf '0\\t\n'\n"
            )
            (script_dir / "dragonwilds-players.sh").chmod(0o755)

            env = dict(os.environ)
            env.update(
                PATH=f"{bin_dir}:{env['PATH']}",
                HOME=str(root),
                DRAGONWILDS_INSTALL_DIR=str(install),
                LATEST_BUILD_FILE=str(latest),
                NOTIFIED_BUILD_FILE=str(notified),
                FAILED_BUILD_FILE=str(failed),
                AUTO_UPDATE_RESTART="true",
            )
            result = subprocess.run(
                ["bash", str(script_dir / "dragonwilds-auto-update.sh")],
                env=env,
                capture_output=True,
                text=True,
                timeout=10,
            )

            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(calls.exists(), "the updater restarted for app BuildID drift")
            self.assertFalse(failed.exists(), "a current Linux depot was marked failed")

            latest.write_text("25808123 2026-10-11T18:01:40Z" + chr(10))
            legacy_metadata = subprocess.run(
                ["bash", str(script_dir / "dragonwilds-auto-update.sh")],
                env=env,
                capture_output=True,
                text=True,
                timeout=10,
            )
            self.assertEqual(legacy_metadata.returncode, 0, legacy_metadata.stdout + legacy_metadata.stderr)
            self.assertIn("no usable app build and Linux depot manifest", legacy_metadata.stdout)
            self.assertFalse(calls.exists(), "old two-field metadata must fail closed")

    def test_legacy_failed_app_build_id_does_not_block_a_real_depot_update(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            script_dir = root / "scripts"
            script_dir.mkdir()
            for name in ("dragonwilds-auto-update.sh", "dragonwilds-players.sh", "dragonwilds_update_metadata.py"):
                shutil.copy(GAME / name, script_dir)
            install = root / "install"
            steamapps = install / "steamapps"
            steamapps.mkdir(parents=True)
            (steamapps / "appmanifest_4019830.acf").write_text(
                '"AppState"\n{\n"buildid" "25805654"\n'
                '"InstalledDepots" { "3501791" { "manifest" "5736699466634593401" } }\n}\n'
            )
            latest = root / "latest-build"
            latest.write_text("25808123 2026-10-11T18:01:40Z 6000000000000000000\n")
            notified = root / "notified-build"
            notified.write_text("25808123\n")
            failed = root / "failed-build"
            failed.write_text("25808123\n")
            calls = root / "systemctl.calls"
            bin_dir = root / "bin"
            bin_dir.mkdir()
            systemctl = bin_dir / "systemctl"
            systemctl.write_text(chr(10).join([
                "#!/usr/bin/env bash",
                f"printf '%s\n' \"$*\" >> {str(calls)!r}",
                "exit 1",
                "",
            ]))
            systemctl.chmod(0o755)
            players = script_dir / "dragonwilds-players.sh"
            players.write_text(chr(10).join(["#!/usr/bin/env bash", "printf 0", ""]))
            players.chmod(0o755)
            env = dict(os.environ)
            env.update(
                PATH=f"{bin_dir}:{env['PATH']}",
                HOME=str(root),
                DRAGONWILDS_INSTALL_DIR=str(install),
                LATEST_BUILD_FILE=str(latest),
                NOTIFIED_BUILD_FILE=str(notified),
                FAILED_BUILD_FILE=str(failed),
                AUTO_UPDATE_RESTART="true",
            )
            result = subprocess.run(
                ["bash", str(script_dir / "dragonwilds-auto-update.sh")],
                env=env,
                capture_output=True,
                text=True,
                timeout=10,
            )

            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertTrue(calls.exists(), "a differing Linux depot should attempt rollout")
            self.assertIn("restart dragonwilds.service", calls.read_text())
            self.assertEqual(failed.read_text().strip(), "linux-depot:6000000000000000000")
            self.assertEqual(notified.read_text().strip(), "linux-depot:6000000000000000000")


if __name__ == "__main__":
    unittest.main()
