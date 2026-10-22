#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
DOMAIN="$(tailscale status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))')"
[[ "$DOMAIN" =~ ^[a-zA-Z0-9.-]+$ ]] || { printf 'error: invalid Tailscale domain\n' >&2; exit 1; }
DATA_DIR="$HOME/.local/share/rs-sdk-portal/data"
mkdir -p "$DATA_DIR"
chmod 700 "$DATA_DIR"
mkdir -p "$SCRIPT_DIR/assets"
if [[ ! -f "$SCRIPT_DIR/assets/background2.jpg" ]]; then
  curl --fail --silent --show-error --max-time 10 http://127.0.0.1:8080/img/background2.jpg \
    --output "$SCRIPT_DIR/assets/background2.jpg.part"
  mv "$SCRIPT_DIR/assets/background2.jpg.part" "$SCRIPT_DIR/assets/background2.jpg"
fi
[[ -f "$REPO_ROOT/server-base/timezone.env" ]] || bash "$REPO_ROOT/server-base/timezone.sh"
if [[ -f "$SCRIPT_DIR/.env" ]]; then
  cp -p "$SCRIPT_DIR/.env" "$SCRIPT_DIR/.env.previous"
fi
umask 077
printf 'PORTAL_UID=%s\nPORTAL_GID=%s\nPORTAL_GAME_DOMAIN=%s\nPORTAL_DATA_DIR=%s\n' \
  "$(id -u)" "$(id -g)" "$DOMAIN" "$DATA_DIR" > "$SCRIPT_DIR/.env"
docker compose --project-name rs-sdk-portal --project-directory "$SCRIPT_DIR" -f "$SCRIPT_DIR/docker-compose.yml" up -d --force-recreate
for _ in {1..15}; do
  if curl --fail --silent http://127.0.0.1:8098/rs-sdk/ >/dev/null; then
    tailscale serve --bg --https=443 --set-path=/rs-sdk http://127.0.0.1:8098
    printf 'Portal ready at https://%s/rs-sdk/\n' "$DOMAIN"
    exit 0
  fi
  sleep 1
done
printf 'error: portal failed its loopback health check\n' >&2
exit 1
