#!/usr/bin/env python3
"""Write the RGB devices OpenRGB detects, plus the keep-off policy state, as JSON.

Run as root by rgb-status.service (the HID devices are root-only). The output
feeds the Homepage OpenRGB card through `tailscale serve` (/host-status/rgb.json).
OpenRGB's CLI does not print colours, and for many controllers the mode is the
one OpenRGB last set rather than one read back from the device, so nothing here
is ever reported as a *current* colour.

Besides `devices` it writes:
  policy  the outcome of the last rgb-off run (rgb-policy.json), contract keys only
  rows    flat {name,label} display rows for a Homepage dynamic-list

Hardware is probed with `openrgb --list-devices` only when the cached inventory
is missing, older than RGB_PROBE_MAX_AGE (24 h), from an earlier boot, or when
--refresh is given, instead of on every 10-minute run.
"""
import argparse
import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import rgb_common as common  # noqa: E402

CACHE_SCHEMA = 1
DEFAULT_CACHE = "/var/lib/rgb-status/devices.json"
DEFAULT_MAX_AGE = 86400
RESULTS = ("applied", "failed", "never")
DEVICE_RESULTS = ("applied", "failed", "skipped")
TRIGGERS = ("boot", "resume", "manual", "unknown")
NEVER = {"name": "off", "color": "000000", "applied_at": None, "trigger": None,
         "result": "never", "devices": []}


def parse(text):
    """Devices as the exporter publishes them (the enumeration index stays internal)."""
    devices = common.parse_devices(text)
    for device in devices:
        device.pop("index", None)
    return devices


def load_policy(path, current_boot):
    """The rgb-off status, reduced to the contract. Anything unusable is 'never'."""
    never = {**NEVER, "devices": []}
    try:
        raw = json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return never
    if not isinstance(raw, dict) or raw.get("result") not in RESULTS or raw["result"] == "never":
        return never
    file_boot = raw.get("boot_id")
    if file_boot and current_boot and file_boot != current_boot:
        return never  # written by an earlier boot; this boot has not applied anything
    applied_at = raw.get("applied_at")
    devices = []
    for item in raw.get("devices") if isinstance(raw.get("devices"), list) else []:
        if not isinstance(item, dict) or not isinstance(item.get("name"), str):
            continue
        mode = item.get("mode_used")
        result = item.get("result")
        devices.append({"name": item["name"],
                        "mode_used": mode if isinstance(mode, str) else None,
                        "result": result if result in DEVICE_RESULTS else "failed"})
    return {"name": "off", "color": "000000",
            "applied_at": applied_at if isinstance(applied_at, int) and not isinstance(applied_at, bool) else None,
            "trigger": raw.get("trigger") if raw.get("trigger") in TRIGGERS else "unknown",
            "result": raw["result"], "devices": devices}


def clock(epoch):
    return time.strftime("%H:%M", time.localtime(epoch))


def zone_label(entry, applied_at):
    result = entry["result"] if entry else None
    if result == "applied":
        return f"commanded off #000000 at {clock(applied_at)}" if applied_at else "commanded off #000000"
    if result == "failed":
        return "off command failed"
    if result == "skipped":
        return "not commanded (no off-capable mode)"
    return "detected"


def policy_label(policy):
    if policy["result"] == "applied":
        when = f" {clock(policy['applied_at'])}" if policy["applied_at"] else ""
        return f"off (#000000) · applied{when} by {policy['trigger'] or 'unknown'}"
    if policy["result"] == "failed":
        return "off (#000000) · last attempt failed"
    return "off (#000000) · never applied"


def build_rows(devices, policy, error):
    """Flat display rows. Zone names and modes come from `--list-devices` only."""
    if error:
        return [{"name": "OpenRGB", "label": f"unavailable: {error}"}]
    by_name = {}
    for entry in policy["devices"]:
        by_name.setdefault(entry["name"], []).append(entry)
    rows = []
    for device in devices:
        kind = device.get("type") or "Device"
        mode = device.get("mode") or "mode unknown"
        rows.append({"name": device["name"], "label": f"{kind} · {mode} (last-set, not readback)"})
        queue = by_name.get(device["name"], [])
        entry = queue.pop(0) if queue else None
        for zone in device.get("zone_details", []):
            rows.append({"name": zone["name"], "label": zone_label(entry, policy["applied_at"])})
    rows.append({"name": "Lighting policy", "label": policy_label(policy)})
    return rows


def env_float(name, default):
    try:
        return float(os.environ[name])
    except (KeyError, ValueError):
        return default


def load_cache(path, current_boot, max_age):
    try:
        cache = json.loads(Path(path).read_text())
        devices = cache["devices"]
        probed_at = cache["probed_at"]
    except (OSError, ValueError, KeyError, TypeError):
        return None
    if (cache.get("schema") != CACHE_SCHEMA or not isinstance(devices, list) or not devices
            or not all(isinstance(d, dict) and isinstance(d.get("name"), str) for d in devices)
            or not isinstance(probed_at, (int, float)) or cache.get("boot_id") != current_boot):
        return None
    age = time.time() - probed_at
    return devices if -60 <= age < max_age else None


def probe():
    """One hardware enumeration under the shared lock -> devices; raises OpenRGBError."""
    rc, out, _ = common.run_openrgb(
        ["--noautoconnect", "--list-devices"], binary=os.environ.get("RGB_OPENRGB", "openrgb"),
        lock=os.environ.get("RGB_LOCK_FILE", common.DEFAULT_LOCK),
        lock_timeout=env_float("RGB_LOCK_TIMEOUT", 120), timeout=180)
    if rc != 0:
        raise common.OpenRGBError(f"openrgb exited {rc}")
    return parse(out)


def get_devices(refresh, current_boot):
    cache_path = os.environ.get("RGB_CACHE_FILE", DEFAULT_CACHE)
    if not refresh:
        cached = load_cache(cache_path, current_boot, env_float("RGB_PROBE_MAX_AGE", DEFAULT_MAX_AGE))
        if cached is not None:
            return cached, None
    try:
        devices = probe()
    except common.OpenRGBError as exc:
        return [], str(exc)
    if devices:  # never cache an empty or failed enumeration (boot-time race)
        try:
            common.atomic_write_json(cache_path, {"schema": CACHE_SCHEMA, "probed_at": int(time.time()),
                                                  "boot_id": current_boot, "devices": devices}, mode=0o600)
        except OSError as exc:
            print(f"rgb-status: could not write cache: {exc}", file=sys.stderr)
    return devices, None


def main(argv=None):
    parser = argparse.ArgumentParser(description="Export OpenRGB device status and keep-off policy.")
    parser.add_argument("--refresh", action="store_true", help="probe the hardware even if the cache is fresh")
    parser.add_argument("out", nargs="?", default="/var/lib/host-status/rgb.json")
    args = parser.parse_args(argv)
    current_boot = common.boot_id(os.environ.get("RGB_BOOT_ID_FILE"))
    devices, error = get_devices(args.refresh, current_boot)
    policy = load_policy(os.environ.get("RGB_POLICY_FILE", common.DEFAULT_POLICY), current_boot)
    doc = {"updated": int(time.time()), "devices": devices}
    if error:
        doc["error"] = error
    doc["policy"] = policy
    doc["rows"] = build_rows(devices, policy, error)
    common.atomic_write_json(args.out, doc)


if __name__ == "__main__":
    main()
