#!/usr/bin/env bash
set -euo pipefail

# Routes and compose stacks for this host live in serve.conf.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$SCRIPT_DIR/../server-base/serve.sh" "$SCRIPT_DIR"
