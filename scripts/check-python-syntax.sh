#!/usr/bin/env bash
set -euo pipefail

cache="$(mktemp -d)"
trap 'rm -rf "$cache"' EXIT
PYTHONPYCACHEPREFIX="$cache" python3 -m py_compile "$@"
