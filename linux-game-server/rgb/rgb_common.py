"""Shared helpers for the RGB exporter (rgb-status) and the keep-off service (rgb-off).

Installed next to both scripts in /usr/local/libexec. It only wraps the OpenRGB
CLI (list/enumerate and set-colour calls), a lock that serialises those calls,
and an atomic JSON writer. It never touches firmware or saved profiles.
"""
import contextlib
import fcntl
import json
import os
import re
import subprocess
import tempfile
import time
from pathlib import Path

DEFAULT_LOCK = "/run/rgb-lock/openrgb.lock"
DEFAULT_POLICY = "/var/lib/host-status/rgb-policy.json"
BOOT_ID_FILE = "/proc/sys/kernel/random/boot_id"
MODE_SOURCE = "last-set / device-wide; not hardware readback"


class OpenRGBError(Exception):
    """A short, human-readable reason (it ends up on the dashboard card)."""


def tokens(value):
    """Split an OpenRGB list value; names containing spaces come quoted."""
    return [t.strip("'\"") for t in re.findall(r"'[^']*'|\"[^\"]*\"|\S+", value)]


def parse_devices(text):
    """Parse `openrgb --list-devices`. Names come only from that output."""
    devices = []
    for line in text.splitlines():
        head = re.fullmatch(r"(\d+): (.+)", line)
        if head:
            devices.append({"index": int(head.group(1)), "name": head.group(2).strip(),
                            "mode_source": MODE_SOURCE})
            continue
        if not devices or not line.startswith("  "):
            continue
        key, _, value = line.strip().partition(":")
        value = value.strip()
        device = devices[-1]
        if key == "Type":
            device["type"] = value
        elif key == "Modes":
            current = re.search(r"\[([^\]]+)\]", value)
            device["mode"] = current.group(1).strip("'\"") if current else None
            device["available_modes"] = tokens(value.replace("[", "").replace("]", ""))
        elif key == "LEDs":
            device["led_names"] = tokens(value)
        elif key == "Zones":
            names = tokens(value)
            device["zones"] = len(names)  # Existing API/card compatibility.
            device["zone_details"] = [
                {"name": name, "status": "detected", "color": None, "readback": False}
                for name in names
            ]
    return devices


@contextlib.contextmanager
def locked(path, timeout):
    """Exclusive flock on `path`; waits up to `timeout` seconds."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        end = time.monotonic() + timeout
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= end:
                    raise OpenRGBError("lock busy: another openrgb call is running") from None
                time.sleep(0.05)
        yield
    finally:
        os.close(fd)  # closing the descriptor drops the flock


def run_openrgb(args, *, binary, lock, lock_timeout, timeout):
    """Run one openrgb invocation under the shared lock -> (returncode, stdout, stderr)."""
    with locked(lock, lock_timeout):
        try:
            run = subprocess.run([binary, *args], capture_output=True, text=True,
                                 timeout=timeout, check=False)
        except FileNotFoundError:
            raise OpenRGBError("openrgb not installed") from None
        except subprocess.TimeoutExpired:
            raise OpenRGBError("openrgb timed out") from None
        except OSError as exc:
            raise OpenRGBError(str(exc)) from None
    return run.returncode, run.stdout, run.stderr


def command_failed(returncode, output):
    """OpenRGB's CLI prints `Error: ...` (exit 255), but a wrong colour count exits 0."""
    return returncode != 0 or bool(
        re.search(r"^(Error:|Wrong number of colors)", output, re.MULTILINE))


def atomic_write_json(path, doc, mode=0o644):
    """Write JSON next to `path`, fsync, chmod and rename over it."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    try:
        with os.fdopen(fd, "w") as handle:
            json.dump(doc, handle)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(tmp)
        raise


def boot_id(path=None):
    try:
        return Path(path or BOOT_ID_FILE).read_text().strip() or None
    except OSError:
        return None
