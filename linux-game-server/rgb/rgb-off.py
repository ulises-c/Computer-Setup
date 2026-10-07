#!/usr/bin/env python3
"""Force every RGB device OpenRGB detects to black (#000000) and record the result.

Run as root by rgb-off.service (boot, or `systemctl start rgb-off.service`) and by
rgb-off-resume.service (after suspend/hibernate). Installed as
/usr/local/libexec/rgb-off, never run from the writable checkout.

Per device it picks, from that device's own `Modes:` line only:
  1. an `Off` mode, if listed:        openrgb --noautoconnect --device N --mode Off
  2. else `Direct`, then `Static`:    ... --mode Direct --color 000000
A mode name the device does not list is never sent. Only lighting is touched:
no profile is loaded or saved, nothing is written to firmware.

Boot-time enumeration can race device readiness, so enumeration is retried with
bounded backoff (6 attempts over ~110 s); "no devices" counts as retryable.
The outcome goes to /var/lib/host-status/rgb-policy.json (read by rgb-status);
the exit code is non-zero, with a `rgb-off: FAILED ...` journal line, if no
device could be turned off.
"""
import argparse
import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import rgb_common as common  # noqa: E402

OFF_COLOR = "000000"
DEFAULT_DELAYS = (5, 10, 20, 30, 45)  # seconds before attempts 2..6 (~110 s)
TRIGGERS = ("auto", "boot", "resume", "manual", "unknown")


def log(message):
    print(f"rgb-off: {message}", file=sys.stderr, flush=True)


def env_float(name, default):
    try:
        return float(os.environ[name])
    except (KeyError, ValueError):
        return default


def delays():
    raw = os.environ.get("RGB_OFF_DELAYS")
    if raw:
        try:
            return tuple(float(part) for part in raw.split(",") if part.strip())
        except ValueError:
            pass
    return DEFAULT_DELAYS


def resolve_trigger(requested):
    """`auto` (rgb-off.service): boot while systemd is still starting, else a manual start."""
    if requested != "auto":
        return requested
    try:
        run = subprocess.run([os.environ.get("RGB_SYSTEMCTL", "systemctl"), "is-system-running"],
                             capture_output=True, text=True, timeout=10, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return "unknown"
    state = run.stdout.strip()
    if state in ("initializing", "starting"):
        return "boot"
    if state in ("running", "degraded", "maintenance", "stopping"):
        return "manual"
    return "unknown"


def plan(modes):
    """Ordered (mode, needs_black_colour) choices, spelled exactly as the device lists them."""
    listed = {mode.lower(): mode for mode in modes}
    steps = []
    if "off" in listed:
        steps.append((listed["off"], False))
    for name in ("direct", "static"):
        if name in listed:
            steps.append((listed[name], True))
    return steps


def set_args(index, mode, with_colour):
    args = ["--noautoconnect", "--device", str(index), "--mode", mode]
    if with_colour:
        args += ["--color", OFF_COLOR]
    return args


class Run:
    def __init__(self):
        self.binary = os.environ.get("RGB_OPENRGB", "openrgb")
        self.lock = os.environ.get("RGB_LOCK_FILE", common.DEFAULT_LOCK)
        self.lock_timeout = env_float("RGB_LOCK_TIMEOUT", 120)
        self.timeout = env_float("RGB_OFF_CMD_TIMEOUT", 45)
        self.deadline = env_float("RGB_OFF_DEADLINE", 480)
        self.delays = delays()
        self.records = {}  # (device name, occurrence) -> per-device result, in enumeration order
        self.applied_at = None
        self.attempts = 0
        self.reason = "no devices detected"

    def openrgb(self, args):
        rc, out, err = common.run_openrgb(args, binary=self.binary, lock=self.lock,
                                          lock_timeout=self.lock_timeout, timeout=self.timeout)
        return rc, out, err

    def command_device(self, device, record):
        for mode, with_colour in plan(device.get("available_modes", [])):
            rc, out, err = self.openrgb(set_args(device["index"], mode, with_colour))
            combined = f"{out}\n{err}"
            if not common.command_failed(rc, combined):
                record.update(mode_used=mode, result="applied")
                self.applied_at = int(time.time())
                log(f"{device['name']}: commanded off with --mode {mode}"
                    + (f" --color {OFF_COLOR}" if with_colour else ""))
                return
            detail = next((ln for ln in combined.splitlines() if ln.strip()), "")
            log(f"{device['name']}: --mode {mode} failed (exit {rc}) {detail}".rstrip())
        record["result"] = "failed"

    def attempt(self):
        rc, out, _ = self.openrgb(["--noautoconnect", "--list-devices"])
        if rc != 0:
            raise common.OpenRGBError(f"openrgb --list-devices exited {rc}")
        devices = common.parse_devices(out)
        if not devices:
            raise common.OpenRGBError("no devices detected")
        seen = {}
        for device in devices:
            seen[device["name"]] = seen.get(device["name"], 0) + 1
            record = self.records.setdefault(
                (device["name"], seen[device["name"]]),
                {"name": device["name"], "mode_used": None, "result": "failed"})
            if record["result"] != "failed":
                continue
            if not plan(device.get("available_modes", [])):
                record["result"] = "skipped"
                log(f"{device['name']}: lists no Off, Direct or Static mode; not commanded")
                continue
            try:
                self.command_device(device, record)
            except common.OpenRGBError as exc:
                self.reason = str(exc)
                log(f"{device['name']}: {exc}")

    def pending(self):
        return any(r["result"] == "failed" for r in self.records.values())

    def enforce(self):
        started = time.monotonic()
        for number in range(1, len(self.delays) + 2):
            if number > 1:
                wait = self.delays[number - 2]
                if time.monotonic() - started + wait > self.deadline:
                    log(f"stopping early: {self.deadline:.0f}s deadline reached")
                    break
                time.sleep(wait)
            self.attempts = number
            try:
                self.attempt()
            except common.OpenRGBError as exc:
                self.reason = str(exc)
                log(f"attempt {number}: {exc}")
                continue
            if not self.pending():
                break
            log(f"attempt {number}: some devices are not off yet")
        devices = list(self.records.values())
        if any(d["result"] == "applied" for d in devices) and not self.pending():
            return "applied", devices
        if self.pending():
            self.reason = "could not turn off: " + ", ".join(
                d["name"] for d in devices if d["result"] == "failed")
        elif devices:
            self.reason = "no device lists an Off, Direct or Static mode"
        return "failed", devices


def status_doc(trigger, result, applied_at, devices, attempts):
    return {"name": "off", "color": OFF_COLOR, "applied_at": applied_at, "trigger": trigger,
            "result": result, "devices": devices, "attempts": attempts,
            "attempted_at": int(time.time()),
            "boot_id": common.boot_id(os.environ.get("RGB_BOOT_ID_FILE"))}


def write_status(path, doc):
    try:
        common.atomic_write_json(path, doc)
    except OSError as exc:
        log(f"could not write {path}: {exc}")


def main(argv=None):
    parser = argparse.ArgumentParser(description="Force RGB lighting off (#000000).")
    parser.add_argument("--trigger", choices=TRIGGERS, default="auto",
                        help="what started this run (auto: boot while systemd is starting, else manual)")
    args = parser.parse_args(argv)
    trigger = resolve_trigger(args.trigger)
    status = os.environ.get("RGB_POLICY_FILE", common.DEFAULT_POLICY)
    # Reset first: last boot's "applied" must not outlive this run if it crashes or retries for a while.
    write_status(status, status_doc(trigger, "never", None, [], 0))
    run = Run()
    result, devices = run.enforce()
    write_status(status, status_doc(trigger, result, run.applied_at, devices, run.attempts))
    if result == "applied":
        log("applied: " + ", ".join(f"{d['name']}={d['mode_used'] or d['result']}" for d in devices)
            + f" (trigger {trigger}, {run.attempts} attempt(s))")
        return 0
    log(f"FAILED after {run.attempts} attempts: {run.reason}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
