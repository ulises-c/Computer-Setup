#!/usr/bin/env bash
# Install or update the fleet service (rs-fleet-service) on this host.
#   bash linux-game-server/rs-sdk/fleet-service/install.sh
# Data:   ~/.local/share/rs-fleet-service/data/fleet.sqlite (WAL; nightly game backup, see README)
# Tokens: ~/.config/rs-fleet-service/service.env (FLEET_TOKENS, mode 600, never in git). Missing
#         hosts get a fresh token; existing tokens are kept.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
DOMAIN="$(tailscale status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))')"
[[ "$DOMAIN" =~ ^[a-zA-Z0-9.-]+$ ]] || { printf 'error: invalid Tailscale domain\n' >&2; exit 1; }
[[ -f "$SCRIPT_DIR/fleet-service.js" ]] || { printf 'error: fleet-service.js missing; build it in the bot repo with scripts/fleet-service-bundle.sh\n' >&2; exit 1; }
DATA_DIR="$HOME/.local/share/rs-fleet-service/data"
ENV_DIR="$HOME/.config/rs-fleet-service"
ENV_FILE="$ENV_DIR/service.env"
mkdir -p "$DATA_DIR" "$ENV_DIR"
chmod 700 "$DATA_DIR" "$ENV_DIR"
umask 077
# One token per bot host, plus a read-only one for the portal.
HOSTS=(bot-workstation bot-host-2 bot-host-3 portal:ro)
python3 - "$ENV_FILE" "${HOSTS[@]}" <<'PY'
import os, re, secrets, sys
path, hosts = sys.argv[1], sys.argv[2:]
tokens = {}
if os.path.exists(path):
    for line in open(path):
        m = re.match(r'^FLEET_TOKENS=(.*)$', line.strip())
        if m:
            for part in m.group(1).split(','):
                if '=' in part:
                    name, tok = part.split('=', 1)
                    tokens[name] = tok
for h in hosts:
    tokens.setdefault(h, secrets.token_hex(24))
with open(path + '.part', 'w') as f:
    f.write('FLEET_TOKENS=' + ','.join(f'{k}={v}' for k, v in tokens.items()) + '\n')
os.chmod(path + '.part', 0o600)
os.replace(path + '.part', path)
PY
[[ -f "$REPO_ROOT/server-base/timezone.env" ]] || bash "$REPO_ROOT/server-base/timezone.sh"
printf 'FLEET_UID=%s\nFLEET_GID=%s\nFLEET_DATA_DIR=%s\nFLEET_ENV_FILE=%s\n' "$(id -u)" "$(id -g)" "$DATA_DIR" "$ENV_FILE" > "$SCRIPT_DIR/.env"
docker compose --project-name rs-fleet-service --project-directory "$SCRIPT_DIR" -f "$SCRIPT_DIR/docker-compose.yml" up -d --build --force-recreate
for _ in {1..20}; do
  if curl --fail --silent http://127.0.0.1:8100/healthz >/dev/null; then
    tailscale serve --bg --https=9447 http://127.0.0.1:8100 >/dev/null
    printf 'Fleet service ready at https://%s:9447/ (tailnet only)\n' "$DOMAIN"
    exit 0
  fi
  sleep 1
done
printf 'error: fleet service failed its loopback health check\n' >&2
exit 1
