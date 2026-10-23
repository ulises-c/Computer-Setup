from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "rs-sdk/restore-xp.js"
FILES = {
    "server/engine/src/engine/entity/Player.ts": "const delta = Math.floor(level + Math.pow(2.0, level / 10.0) * 300.0);\n",
    "server/webclient/src/client/Client.ts": "const delta = (level + Math.pow(2.0, level / 10.0) * 300.0) | 0;\n",
    "server/webclient/src/lite/LiteClient.ts": "const delta = (level + Math.pow(2.0, level / 10.0) * 300.0) | 0;\n",
    "server/webclient/src/lite/actions.ts": "const delta = (level + Math.pow(2.0, level / 10.0) * 300.0) | 0;\n",
    "sdk/test/utils/save-generator.ts": "xp += Math.floor(i + 300 * Math.pow(2, i / 10));\n",
}


class OriginalXpTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for name, text in FILES.items():
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)

    def run_patch(self):
        return subprocess.run(
            [shutil.which("node") or "node", str(SCRIPT), str(self.root)],
            capture_output=True, text=True,
        )

    def test_restores_engine_browser_lite_and_save_generator_curves(self):
        result = self.run_patch()
        self.assertEqual(result.returncode, 0, result.stderr)
        for name, text in FILES.items():
            with self.subTest(path=name):
                self.assertEqual((self.root / name).read_text(), text.replace("/ 10", "/ 7"))
        result = self.run_patch()
        self.assertEqual(result.returncode, 0, result.stderr)
        formula = (self.root / "server/engine/src/engine/entity/Player.ts").read_text()
        result = subprocess.run([
            shutil.which("node") or "node", "-e",
            "let total=0;const targets=new Set([1,9,98]);for(let level=1;level<99;level++){"
            + formula + "total+=delta;if(targets.has(level))console.log(Math.floor(total/4));}",
        ], capture_output=True, text=True, check=True)
        self.assertEqual(result.stdout.splitlines(), ["83", "1154", "13034431"])

    def test_unknown_upstream_formula_fails_before_any_file_changes(self):
        path = self.root / "server/webclient/src/lite/actions.ts"
        path.write_text("const delta = customCurve(level);\n")
        before = {name: (self.root / name).read_text() for name in FILES}
        result = self.run_patch()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unexpected XP formula", result.stderr)
        self.assertEqual({name: (self.root / name).read_text() for name in FILES}, before)


if __name__ == "__main__":
    unittest.main()
