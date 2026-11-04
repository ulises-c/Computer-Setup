"""clan-storage.patch wiring: applied first, fails loudly, flags off by default."""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RS = ROOT / "rs-sdk"


class ClanPatchWiring(unittest.TestCase):
    def setUp(self):
        self.dockerfile = (RS / "Dockerfile").read_text()
        self.patch = (RS / "clan-storage.patch").read_text()

    def test_applied_before_the_patch_scripts_and_builds(self):
        d = self.dockerfile
        self.assertIn("COPY clan-storage.patch /usr/local/lib/clan-storage.patch", d)
        apply = d.index("git apply --verbose /usr/local/lib/clan-storage.patch")
        self.assertLess(apply, d.index("bun /usr/local/lib/restore-xp.js /opt"))
        self.assertLess(apply, d.index("bun /usr/local/lib/hiscore-pages.js /opt"))
        engine = d.index("cd /opt/server/engine")
        self.assertLess(d.index("bun /usr/local/lib/hop-timer-utc.js /opt"), engine)
        self.assertIn("BUILD_VERIFY=false bun run build", d[engine:])
        self.assertLess(engine, d.index("cd /opt/server/webclient"))

    def test_never_dropped_silently(self):
        # Only an exact reverse match counts as "already applied"; no --reject, no || true.
        self.assertIn("git apply --reverse --check /usr/local/lib/clan-storage.patch", self.dockerfile)
        self.assertNotIn("--reject", self.dockerfile)
        self.assertNotRegex(self.dockerfile, r"clan-storage\.patch[^\n]*\|\|\s*true")

    def test_patch_is_server_only(self):
        paths = re.findall(r"^diff --git a/(\S+) ", self.patch, re.M)
        self.assertTrue(paths)
        for path in paths:
            self.assertRegex(path, r"^server/(engine|content|webclient|gateway)/")
        self.assertIn("server/engine/src/engine/clan/ClanStore.ts", paths)

    def test_patch_set_hash_covers_the_patch(self):
        world = (ROOT / "2004scape/world.sh").read_text()
        self.assertIn("sha256sum Dockerfile ./*.js ./*.patch", world)

    def test_flags_off_unless_asked(self):
        main = (RS / "docker-compose.yml").read_text()
        self.assertIn("CLAN_STORAGE_ENABLED: ${RS_SDK_CLAN_STORAGE:-false}", main)
        self.assertIn("CLAN_HISCORES_ENABLED: ${RS_SDK_CLAN_HISCORES:-false}", main)
        shared = (RS / "worlds/world-compose.yml").read_text()
        self.assertIn('CLAN_STORAGE_ENABLED: "false"', shared)
        self.assertIn('CLAN_HISCORES_ENABLED: "false"', shared)
        isolated = (RS / "worlds/isolated-compose.yml").read_text()
        self.assertIn("CLAN_STORAGE_ENABLED: ${WORLD_CLAN_STORAGE_ENABLED:-false}", isolated)


if __name__ == "__main__":
    unittest.main()
