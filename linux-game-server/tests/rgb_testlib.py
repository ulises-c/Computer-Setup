"""Shared helpers for the RGB tests: a stub `openrgb` that records its argv.

The stub is a tiny Python script written into a temp dir. A JSON scenario file
next to it decides what `--list-devices` prints and which set-colour calls
fail, and every invocation is appended to calls.jsonl, so a test can assert on
the exact command lines the real code built. Nothing here touches hardware.
"""
import json
import os
import sys
import tempfile
import time
from pathlib import Path

RGB = Path(__file__).resolve().parents[1] / "rgb"
if str(RGB) not in sys.path:
    sys.path.insert(0, str(RGB))

# Format follows `openrgb --list-devices` (cli.cpp): zone/mode names are quoted
# only when they contain a space, the active mode is wrapped in [brackets].
OMEN = """0: HP Omen 30L
  Type:           Motherboard
  Description:    HP Omen 30L Device
  Location:       HID: /dev/hidraw1
  Modes: [Direct] Static Off Breathing 'Color Cycle' Blinking Wave Radial
  Zones: 'Omen Logo' 'Light Bar' 'Front Fan'
  LEDs: 'Logo LED' 'Bar LED' 'Fan LED'

"""
NO_OFF = """1: Strip Controller
  Type:           LEDStrip
  Modes: Direct [Static] Breathing
  Zones: Strip
  LEDs: 'Strip LED'

"""
STATIC_ONLY = """2: Static Only
  Type:           Keyboard
  Modes: [Static] Wave
  Zones: Keys

"""
NO_SAFE_MODE = """3: Rainbow Only
  Type:           Cooler
  Modes: [Rainbow] 'Color Cycle'
  Zones: Ring

"""

STUB = """#!{python}
import json, os, sys, time
here = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(here, "scenario.json")) as fh:
    scn = json.load(fh)
argv = sys.argv[1:]
calls = os.path.join(here, "calls.jsonl")
prior = []
if os.path.exists(calls):
    with open(calls) as fh:
        prior = [json.loads(line) for line in fh if line.strip()]
with open(calls, "a") as fh:
    fh.write(json.dumps({{"argv": argv, "t": time.time()}}) + "\\n")
time.sleep(scn.get("delay", 0))
if scn.get("on_call_dump"):
    with open(scn["on_call_dump"][0]) as src, open(scn["on_call_dump"][1], "a") as dst:
        dst.write(src.read() + "\\n")
if "--list-devices" in argv:
    n = sum(1 for p in prior if "--list-devices" in p["argv"])
    outs = scn.get("list_outputs", [""])
    rcs = scn.get("list_rcs", [0])
    sys.stdout.write(outs[min(n, len(outs) - 1)])
    sys.exit(rcs[min(n, len(rcs) - 1)])
mode = argv[argv.index("--mode") + 1] if "--mode" in argv else ""
n_set = sum(1 for p in prior if "--list-devices" not in p["argv"])
if n_set < scn.get("fail_first_sets", 0) or mode in scn.get("fail_modes", []):
    print("Error: Mode '%s' not available for device 'x'" % mode)
    sys.exit(255)
if mode in scn.get("quiet_error_modes", []):
    print("Wrong number of colors specified for mode " + mode)
    sys.exit(0)
sys.exit(0)
"""


class Stub:
    """A fake `openrgb` on its own PATH directory."""

    def __init__(self, root):
        self.dir = Path(root) / "stubbin"
        self.dir.mkdir(parents=True, exist_ok=True)
        (self.dir / "openrgb").write_text(STUB.format(python=sys.executable))
        (self.dir / "openrgb").chmod(0o755)
        self.configure()

    def configure(self, **scenario):
        (self.dir / "scenario.json").write_text(json.dumps(scenario))
        (self.dir / "calls.jsonl").unlink(missing_ok=True)

    @property
    def bin(self):
        return str(self.dir / "openrgb")

    def calls(self):
        path = self.dir / "calls.jsonl"
        if not path.exists():
            return []
        return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]

    def argvs(self):
        return [c["argv"] for c in self.calls()]

    def list_calls(self):
        return [c for c in self.calls() if "--list-devices" in c["argv"]]

    def set_calls(self):
        return [c["argv"] for c in self.calls() if "--list-devices" not in c["argv"]]


def make_env(root, stub, **extra):
    """A hermetic environment: stub openrgb on PATH, every state path in root."""
    root = Path(root)
    env = {
        "PATH": f"{stub.dir}{os.pathsep}{os.environ.get('PATH', '/usr/bin:/bin')}",
        "HOME": str(root / "home"),
        "TZ": "America/Los_Angeles",
        "RGB_OPENRGB": stub.bin,
        "RGB_LOCK_FILE": str(root / "run" / "openrgb.lock"),
        "RGB_POLICY_FILE": str(root / "host-status" / "rgb-policy.json"),
        "RGB_CACHE_FILE": str(root / "state" / "devices.json"),
        "RGB_BOOT_ID_FILE": str(root / "boot_id"),
        "RGB_OFF_DELAYS": "0,0,0,0,0",
        "PYTHONDONTWRITEBYTECODE": "1",
    }
    (root / "boot_id").write_text("boot-aaaa\n")
    env.update({k: str(v) for k, v in extra.items()})
    return env


def tempdir():
    return tempfile.TemporaryDirectory(prefix="rgb-test-")


def now():
    return int(time.time())
