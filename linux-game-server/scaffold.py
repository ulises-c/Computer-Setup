#!/usr/bin/env python3
import json
import os
from pathlib import Path
import shlex
import socket
import subprocess

ROOT = Path(__file__).resolve().parent


def tailnet_domain():
    if subprocess.run(["sh", "-c", "command -v tailscale"], capture_output=True).returncode != 0:
        return ""
    status = subprocess.run(["tailscale", "status", "--json"], capture_output=True, text=True)
    if status.returncode != 0:
        return ""
    return (json.loads(status.stdout).get("Self") or {}).get("DNSName", "").rstrip(".")


def allowed_hosts():
    hosts = ["localhost", "localhost:3000", "127.0.0.1", "127.0.0.1:3000", socket.gethostname()]
    domain = tailnet_domain()
    if domain:
        hosts.append(domain)
    return hosts


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


def adguard_card_values():
    """The Homepage AdGuard card's URL and login, from the replica's own .env."""
    env = ROOT / "adguard/.env"
    if not env.exists():
        return {}
    raw = {}
    for line in env.read_text().splitlines():
        key, sep, value = line.partition("=")
        if sep and not key.startswith("#"):
            raw[key.strip()] = value.strip()
    lan_ip = "".join(shlex.split(raw.get("LAN_IP", "")))
    # Both files are read by the same compose dotenv parser, so the credentials
    # are copied with their original quoting rather than re-quoted.
    return {
        "HOMEPAGE_VAR_ADGUARD_LAN_URL": f"http://{lan_ip}:3053" if lan_ip else "",
        "HOMEPAGE_VAR_ADGUARD_USER": raw.get("ADGUARD_USER", ""),
        "HOMEPAGE_VAR_ADGUARD_PASS": raw.get("ADGUARD_PASSWORD", ""),
    }


def main():
    homepage_env = ROOT / "homepage/.env"
    hosts = allowed_hosts()
    domain = tailnet_domain()
    if not homepage_env.exists():
        write_private(homepage_env, f"HOMEPAGE_ALLOWED_HOSTS={','.join(hosts)}\n")
    else:
        lines = homepage_env.read_text().splitlines()
        for index, line in enumerate(lines):
            if line.startswith("HOMEPAGE_ALLOWED_HOSTS="):
                existing = line.partition("=")[2].split(",")
                lines[index] = "HOMEPAGE_ALLOWED_HOSTS=" + ",".join(dict.fromkeys(existing + hosts))
                break
        else:
            lines.append("HOMEPAGE_ALLOWED_HOSTS=" + ",".join(hosts))
        homepage_env.write_text("\n".join(lines) + "\n")
        homepage_env.chmod(0o600)

    add_missing(homepage_env, {"HOMEPAGE_VAR_GAME_HOMEPAGE_DOMAIN": domain})
    add_missing(homepage_env, adguard_card_values())
    add_missing(ROOT / "glances/.env",
                {"GLANCES_ALLOWED_HOSTS": ",".join(["localhost", "127.0.0.1"] + ([domain] if domain else []))})

    dragonwilds_env = ROOT / "dragonwilds/.env"
    if not dragonwilds_env.exists():
        values = {
            "DRAGONWILDS_INSTALL_DIR": str(Path.home() / "games/dragonwilds"),
            "SERVICE_USER": os.environ.get("USER") or subprocess.check_output(["id", "-un"], text=True).strip(),
            "STEAMCMD": str(Path.home() / ".local/share/steamcmd/steamcmd.sh"),
            "SERVER_PORT": "7777",
            "LAN_CIDR": "",
            "AUTO_UPDATE_RESTART": "false",
            "NTFY_URL": "",
            "NTFY_TOPIC": "",
            "NTFY_TOKEN": "",
        }
        write_private(dragonwilds_env, "".join(f"{key}={shlex.quote(value)}\n" for key, value in values.items()))


if __name__ == "__main__":
    main()
