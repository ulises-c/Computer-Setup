#!/usr/bin/env python3
"""Assert every service in every tracked compose file gets TZ from server-base/timezone.env.

Resolves each file with `docker compose config` in a scratch copy of the repo
that has a sentinel timezone.env and each .env.example copied to .env.
Override the compose command with COMPOSE (default: "docker compose").
"""
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

SENTINEL = "Europe/Berlin"
COMPOSE_RE = re.compile(r"compose\.ya?ml$")
REQUIRED_VAR_RE = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*):?\?")


def tracked_files(repo):
    out = subprocess.run(
        ["git", "-C", str(repo), "ls-files", "-z"], check=True, capture_output=True
    ).stdout
    return [p for p in out.decode().split("\0") if p]


def build_scratch(repo, files, scratch):
    for rel in files:
        src = repo / rel
        if not os.path.lexists(src):
            continue
        dst = scratch / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst, follow_symlinks=False)
    (scratch / "server-base" / "timezone.env").write_text(f"TZ={SENTINEL}\n")


def main():
    repo = Path(__file__).resolve().parent.parent
    compose = shlex.split(os.environ.get("COMPOSE", "docker compose"))
    files = tracked_files(repo)
    compose_files = sorted(f for f in files if COMPOSE_RE.search(f))

    env = dict(os.environ)
    for rel in compose_files:
        for name in REQUIRED_VAR_RE.findall((repo / rel).read_text()):
            env[name] = "/dummy"

    failures = []
    with tempfile.TemporaryDirectory() as tmp:
        scratch = Path(tmp)
        build_scratch(repo, files, scratch)
        for rel in compose_files:
            directory = (scratch / rel).parent
            example, dotenv = directory / ".env.example", directory / ".env"
            if example.exists() and not dotenv.exists():
                shutil.copy2(example, dotenv)

        for rel in compose_files:
            path = scratch / rel
            result = subprocess.run(
                [*compose, "-f", str(path), "config", "--no-consistency", "--format", "json"],
                cwd=path.parent, env=env, capture_output=True, text=True,
            )
            if result.returncode != 0:
                failures.append(f"{rel}: compose config failed: {result.stderr.strip()}")
                continue
            services = json.loads(result.stdout).get("services", {})
            if not services:
                failures.append(f"{rel}: no services resolved")
            for name, service in sorted(services.items()):
                tz = (service.get("environment") or {}).get("TZ")
                if tz != SENTINEL:
                    failures.append(f"{rel}: service {name}: TZ={tz!r}, expected {SENTINEL} from timezone.env")

    if failures:
        for line in failures:
            print(f"error: {line}", file=sys.stderr)
        sys.exit(1)
    print(f"check-compose-timezone: {len(compose_files)} compose files, every service has TZ from timezone.env")


if __name__ == "__main__":
    main()
