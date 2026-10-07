#!/bin/sh
# The pinned Alpine image has no Bash, so this launcher intentionally uses POSIX sh.
set -eu

PYTHON_BIN="/venv/bin/python${PYTHON_VERSION}"

exec "$PYTHON_BIN" -c '
import os
import re
import shlex
import sys
from pathlib import Path

sys.path.insert(0, "/")
import rename_disks
import telemetry

allowed_hosts = os.environ.get("GLANCES_ALLOWED_HOSTS", "").strip()
if not allowed_hosts:
    print(
        "GLANCES_ALLOWED_HOSTS is unset; allowing local proxy names only. Add the host names used by clients to .env.",
        file=sys.stderr,
    )
    allowed_hosts = "localhost,127.0.0.1,host.docker.internal"
hosts = [host.strip() for host in allowed_hosts.split(",") if host.strip()]
if not hosts or any(re.fullmatch(r"[A-Za-z0-9.-]+", host) is None for host in hosts):
    raise SystemExit("GLANCES_ALLOWED_HOSTS must contain only comma-separated hostnames or IPv4 addresses")

config = Path("/tmp/glances.conf")
allowed_hosts_value = ",".join(hosts)
text = f"[outputs]\nallowed_hosts={allowed_hosts_value}\n"
# Per-host filesystem/sensor selection and display names (comma-separated
# regexps / "key:alias" pairs); they trim Glances and the Homepage server cards.
for section in ("fs", "sensors"):
    lines = []
    for key in ("show", "alias"):
        value = os.environ.get(f"GLANCES_{section.upper()}_{key.upper()}", "").strip()
        if any(c in value for c in "\r\n"):
            raise SystemExit(f"GLANCES_{section.upper()}_{key.upper()} must be a single line")
        if value:
            lines.append(f"{key}={value}")
    if lines:
        text += f"[{section}]\n" + "\n".join(lines) + "\n"
config.write_text(text, encoding="utf-8")
rename_disks.patch()
# Fail closed before any plugin construction/update (including sensors startup):
# no broad SMART discovery, no HDD/unknown statvfs, slow backend storage caches.
telemetry.install(gpu=os.environ.get("GLANCES_GPU_MEMORY", "false") == "true")

from glances import main

sys.argv = ["glances", "-C", str(config)]
sys.argv.extend(shlex.split(os.environ.get("GLANCES_OPT", "-w")))
main()
'
