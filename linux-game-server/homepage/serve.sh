#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
[[ "$(tailscale status --json | jq -r .BackendState)" == Running ]] || {
  printf 'error: authenticate this host with sudo tailscale up first\n' >&2
  exit 1
}
python3 "$SCRIPT_DIR/../scaffold.py"
sudo docker compose -f "$SCRIPT_DIR/docker-compose.yml" up -d
curl --fail --silent --show-error --retry 12 --retry-connrefused --retry-delay 2 \
  http://127.0.0.1:3000/ >/dev/null
tailscale serve --bg --https=443 http://127.0.0.1:3000
tailscale serve status
