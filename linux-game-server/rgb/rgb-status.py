#!/usr/bin/env python3
"""Write the RGB devices OpenRGB detects, with their active mode, as JSON.

Run as root by rgb-status.service (the HID devices are root-only). The output
feeds the Homepage top bar through `tailscale serve` (/host-status/rgb.json).
OpenRGB's CLI does not print colours, and for many controllers the mode is the
one OpenRGB last set rather than one read back from the device.
"""
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

OUT = Path(sys.argv[1] if len(sys.argv) > 1 else "/var/lib/host-status/rgb.json")


def parse(text):
    devices = []
    for line in text.splitlines():
        head = re.fullmatch(r"(\d+): (.+)", line)
        if head:
            devices.append({"name": head.group(2).strip(),
                            "mode_source": "last-set / device-wide; not hardware readback"})
            continue
        if not devices or not line.startswith("  "):
            continue
        key, _, value = line.strip().partition(":")
        value = value.strip()
        if key == "Type":
            devices[-1]["type"] = value
        elif key == "Modes":
            current = re.search(r"\[([^\]]+)\]", value)
            devices[-1]["mode"] = current.group(1).strip("'\"") if current else None
            modes = value.replace("[", "").replace("]", "")
            devices[-1]["available_modes"] = [
                token.strip("'\"") for token in re.findall(r"'[^']*'|\"[^\"]*\"|\S+", modes)
            ]
        elif key in ("Zones", "LEDs"):
            names = [token.strip("'\"") for token in re.findall(r"'[^']*'|\"[^\"]*\"|\S+", value)]
            if key == "LEDs":
                devices[-1]["led_names"] = names
            else:
                devices[-1]["zones"] = len(names)  # Existing API/card compatibility.
                devices[-1]["zone_details"] = [
                    {"name": name, "status": "detected", "color": None, "readback": False}
                    for name in names
                ]
    return devices


def main():
    try:
        run = subprocess.run(["openrgb", "--noautoconnect", "--list-devices"],
                             capture_output=True, text=True, timeout=180, check=False)
        devices = parse(run.stdout)
        error = None if run.returncode == 0 else f"openrgb exited {run.returncode}"
    except (OSError, subprocess.TimeoutExpired) as exc:
        devices, error = [], str(exc)
    doc = {"updated": int(time.time()), "devices": devices}
    if error:
        doc["error"] = error
    OUT.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", dir=OUT.parent, delete=False) as tmp:
        json.dump(doc, tmp)
    os.chmod(tmp.name, 0o644)
    os.replace(tmp.name, OUT)


if __name__ == "__main__":
    main()
