from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "rs-sdk/restore-client.js"
SHELL = "server/webclient/src/client/GameShell.ts"
CLIENT = "server/webclient/src/client/Client.ts"


class OriginalClientTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / SHELL).parent.mkdir(parents=True)
        (self.root / SHELL).write_text("protected deltime: number = 14; // 30% faster than original 20ms\n")
        (self.root / CLIENT).write_text(
            "// Always run (previously: this.keyHeld[5] === 1)\n"
            "this.out.p1(1);\n"
        )

    def run_patch(self):
        return subprocess.run(
            [shutil.which("node") or "node", str(SCRIPT), str(self.root)],
            capture_output=True, text=True,
        )

    def test_restores_twenty_millisecond_logic_cycles(self):
        result = self.run_patch()
        self.assertEqual(result.returncode, 0, result.stderr)
        text = (self.root / SHELL).read_text()
        self.assertIn("protected deltime: number = 20;", text)
        self.assertNotIn("30% faster", text)
        self.assertEqual(self.run_patch().returncode, 0)

    def test_movement_packet_uses_the_requested_ctrl_run_bit(self):
        result = self.run_patch()
        self.assertEqual(result.returncode, 0, result.stderr)
        text = (self.root / CLIENT).read_text()
        self.assertNotIn("Always run", text)
        expression = text.split("this.out.p1(", 1)[1].split(");", 1)[0]
        result = subprocess.run([
            shutil.which("node") or "node", "-e",
            "const out=[];const encode=new Function('return " + expression + "');"
            "for(const held of [0,1])out.push(encode.call({keyHeld:{5:held}}));"
            "console.log(JSON.stringify(out));",
        ], capture_output=True, text=True, check=True)
        self.assertEqual(result.stdout.strip(), "[0,1]")

    def test_unknown_packet_encoding_fails_before_changing_either_file(self):
        (self.root / CLIENT).write_text("this.out.p1(customRunBit());\n")
        before = {name: (self.root / name).read_text() for name in (SHELL, CLIENT)}
        result = self.run_patch()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unexpected movement", result.stderr)
        self.assertEqual({name: (self.root / name).read_text() for name in before}, before)


if __name__ == "__main__":
    unittest.main()
