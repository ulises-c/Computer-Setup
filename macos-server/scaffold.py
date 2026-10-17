#!/usr/bin/env python3
"""Create or extend this host's private .env files (homepage, status) from the
live tailnet name. Run by serve.sh (PRE_SERVE) and setup.sh; idempotent."""
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess

ROOT = Path(__file__).resolve().parent
APP_CLI = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"


def tailnet_domain():
    cli = shutil.which("tailscale") or (APP_CLI if os.path.exists(APP_CLI) else None)
    if not cli:
        return ""
    status = subprocess.run([cli, "status", "--json"], capture_output=True, text=True)
    if status.returncode != 0:
        return ""
    return (json.loads(status.stdout).get("Self") or {}).get("DNSName", "").rstrip(".")


def write_private(path, content):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as file:
        file.write(content)


def add_missing(path, values):
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists():
        write_private(path, "")
    lines = path.read_text().splitlines()
    keys = {line.partition("=")[0] for line in lines}
    lines += [f"{key}={value}" for key, value in values.items() if value and key not in keys]
    path.write_text("".join(f"{line}\n" for line in lines))
    path.chmod(0o600)


def main():
    domain = tailnet_domain()
    hosts = ["localhost", "localhost:3000", "127.0.0.1", "127.0.0.1:3000", socket.gethostname()]
    if domain:
        hosts.append(domain)
    env = ROOT / "homepage/.env"
    if env.exists():
        lines = env.read_text().splitlines()
        for index, line in enumerate(lines):
            if line.startswith("HOMEPAGE_ALLOWED_HOSTS="):
                existing = line.partition("=")[2].split(",")
                lines[index] = "HOMEPAGE_ALLOWED_HOSTS=" + ",".join(dict.fromkeys(existing + hosts))
                break
        else:
            lines.append("HOMEPAGE_ALLOWED_HOSTS=" + ",".join(hosts))
        env.write_text("\n".join(lines) + "\n")
        env.chmod(0o600)
    else:
        write_private(env, f"HOMEPAGE_ALLOWED_HOSTS={','.join(hosts)}\n")
    add_missing(env, {"HOMEPAGE_VAR_MAC_HOMEPAGE_DOMAIN": domain})
    status_env = ROOT / "status/.env"
    if not status_env.exists():
        shutil.copyfile(ROOT / "status/.env.example", status_env)
        status_env.chmod(0o600)
    (ROOT / "status/www").mkdir(parents=True, exist_ok=True)


if __name__ == "__main__":
    main()
