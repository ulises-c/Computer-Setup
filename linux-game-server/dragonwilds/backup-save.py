#!/usr/bin/env python3
import argparse
import configparser
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import struct
import time


def save_world(data):
    header = data[:4096]
    values, index = [], 0
    while index < len(header) - 4:
        length = struct.unpack_from("<i", header, index)[0]
        if 2 <= length <= 128 and index + 4 + length <= len(header):
            value = header[index + 4:index + 4 + length]
            if value.endswith(b"\0") and all(32 <= char < 127 for char in value[:-1]):
                values.append(value[:-1].decode())
                index += 4 + length
                continue
        index += 1
    if "L_World" not in values or values.index("L_World") == 0:
        raise ValueError("Save header does not contain a recognized world")
    return values[values.index("L_World") - 1]


def backup_save(install_dir, output_dir):
    saved = Path(install_dir) / "RSDragonwilds/Saved"
    config = configparser.ConfigParser(interpolation=None)
    config.read(saved / "Config/LinuxServer/DedicatedServer.ini")
    world = config["/Script/Dominion.DedicatedServerSettings"]["DefaultWorldName"]
    if not world or world in (".", "..") or any(char in world for char in "/\\\n\r"):
        raise ValueError("Invalid world name; refusing an ambiguous backup")
    source = saved / "SaveGames" / f"{world}.sav"
    for _ in range(5):
        before = source.stat()
        data = source.read_bytes()
        after = source.stat()
        digest = hashlib.sha256(data).hexdigest()
        if (before.st_size, before.st_mtime_ns) == (after.st_size, after.st_mtime_ns) and len(data) == after.st_size:
            time.sleep(1)
            if hashlib.sha256(source.read_bytes()).hexdigest() == digest:
                break
    else:
        raise ValueError("Save kept changing; no stable backup was created")
    if save_world(data) != world:
        raise ValueError("Save header does not match the configured world")

    output = Path(output_dir)
    output.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    backup = output / f"dragonwilds-save-backup-{stamp}.sav"
    checksum = backup.with_suffix(".sav.sha256")
    fd = os.open(backup, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    try:
        with os.fdopen(fd, "wb") as file:
            file.write(data)
            file.flush()
            os.fsync(file.fileno())
        if hashlib.sha256(backup.read_bytes()).hexdigest() != digest:
            raise ValueError("Written backup hash did not match")
        fd = os.open(checksum, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        with os.fdopen(fd, "w") as file:
            file.write(f"{digest}  {backup.name}\n")
            file.flush()
            os.fsync(file.fileno())
    except Exception:
        backup.unlink(missing_ok=True)
        raise
    return {"backup": str(backup), "checksum": str(checksum), "bytes": len(data),
            "sha256": digest, "world_header_matches": True, "source_stable_during_copy": True,
            "mode": oct(backup.stat().st_mode & 0o777), "consistency": "live-copy; not a stopped-server snapshot"}


def main():
    parser = argparse.ArgumentParser(description="Copy the configured Dragonwilds save without stopping the game.")
    parser.add_argument("--install-dir", type=Path, default=Path.home() / "games/dragonwilds")
    parser.add_argument("--output-dir", type=Path, default=Path.home() / "Downloads")
    args = parser.parse_args()
    try:
        result = backup_save(args.install_dir, args.output_dir)
    except (KeyError, configparser.Error):
        parser.exit(1, "error: server config is missing or malformed; no config values were printed\n")
    except (OSError, ValueError) as error:
        parser.exit(1, f"error: {error}\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
