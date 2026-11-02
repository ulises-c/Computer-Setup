#!/usr/bin/env bash
# Opens the Darkan lobby and world ports to the LAN and tailnet only, checks
# they are free, and starts the stack built by setup.sh.
# Usage: bash linux-game-server/darkan/activate.sh
set -euo pipefail

if [[ "$(id -u)" == 0 ]]; then
  printf 'error: run as the normal user; sudo is used only for UFW\n' >&2
  exit 2
fi

darkan_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
env_file="$darkan_dir/.env"
compose=(docker compose --project-directory "$darkan_dir" -f "$darkan_dir/docker-compose.yml")
[[ -f "$env_file" ]] || { printf 'error: missing %s; run setup.sh first\n' "$env_file" >&2; exit 2; }

env_get() {
  local line
  line="$(grep -E "^$1=" "$env_file" | tail -n1 || true)"
  printf '%s' "${line#*=}"
}

lan_iface="$(env_get LAN_IFACE)"
lan_cidr="$(env_get LAN_CIDR)"
lobby_port="$(env_get DARKAN_LOBBY_PORT)"
world_port="$(env_get DARKAN_WORLD_PORT)"
api_port="$(env_get DARKAN_LOBBY_API_PORT)"
mongo_port="$(env_get DARKAN_MONGO_PORT)"
public_host="$(env_get DARKAN_PUBLIC_HOST)"
[[ -n "$lan_iface" && -n "$lan_cidr" ]] || { printf 'error: set LAN_IFACE and LAN_CIDR in %s\n' "$env_file" >&2; exit 2; }
docker image inspect computer-setup/darkan:local >/dev/null 2>&1 || { printf 'error: image not built; run setup.sh\n' >&2; exit 2; }

ufw_status="$(sudo ufw status verbose)"
[[ "$ufw_status" == *'Status: active'* ]] || { printf 'error: UFW is not active; refusing to start\n' >&2; exit 2; }
[[ "$ufw_status" == *'deny (incoming)'* || "$ufw_status" == *'reject (incoming)'* ]] || {
  printf 'error: UFW default incoming policy is not deny/reject; refusing to start\n' >&2
  exit 2
}
ufw_rules="$(sudo ufw status)"
for port in "$api_port" "$mongo_port"; do
  if grep -E "^$port(/tcp)?[[:space:]].*ALLOW" <<<"$ufw_rules" >/dev/null; then
    printf 'error: internal port %s has a UFW allow rule; remove it first\n' "$port" >&2
    exit 2
  fi
done

running="$("${compose[@]}" ps --status running --services 2>/dev/null || true)"
listeners="$(ss -H -ltn | awk '{print $4}')"
for port in "$lobby_port" "$world_port" "$api_port" "$mongo_port"; do
  if grep -Eq "[:.]$port\$" <<<"$listeners" && [[ -z "$running" ]]; then
    printf 'error: port %s is already in use by another service\n' "$port" >&2
    exit 2
  fi
done

for port in "$lobby_port" "$world_port"; do
  sudo ufw allow in on "$lan_iface" from "$lan_cidr" to any port "$port" proto tcp comment 'Darkan LAN'
  sudo ufw allow in on tailscale0 to any port "$port" proto tcp comment 'Darkan tailnet'
done

"${compose[@]}" up -d --wait --wait-timeout 1200

printf 'Darkan is up. Launcher: Custom lobby %s, port %s; then pick world %s.\n' \
  "$public_host" "$lobby_port" "$(env_get DARKAN_WORLD_ID)"
