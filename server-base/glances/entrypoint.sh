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
config.write_text(f"[outputs]\nallowed_hosts={allowed_hosts_value}\n", encoding="utf-8")
rename_disks.patch()

from glances import main

sys.argv = ["glances", "-C", str(config)]
sys.argv.extend(shlex.split(os.environ.get("GLANCES_OPT", "-w")))
main()
'
