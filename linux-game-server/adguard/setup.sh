#!/usr/bin/env bash
set -euo pipefail

# Brings up the AdGuard replica, completes its first-run install through the
# install API (DNS and UI on the LAN address only), opens DNS and the UI to the
# LAN in ufw, and checks that it resolves. Run as the login user; steps use sudo.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
readonly WEB_PORT=3053
DRY_RUN=false

case "${1:-}" in
  "") ;;
  --dry-run) DRY_RUN=true ;;
  *) printf 'usage: bash %s [--dry-run]\n' "$0" >&2; exit 1 ;;
esac
[[ $# -le 1 ]] || { printf 'error: too many arguments\n' >&2; exit 1; }
if [[ $EUID -eq 0 ]]; then
  printf 'error: run as your login user, not with sudo; individual steps use sudo\n' >&2
  exit 1
fi

if [[ -f "$SCRIPT_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/.env"
  set +a
elif [[ "$DRY_RUN" == false ]]; then
  printf 'error: missing %s/.env — copy .env.example and fill it in\n' "$SCRIPT_DIR" >&2
  exit 1
fi
: "${LAN_IP:=}" "${LAN_CIDR:=}" "${ADGUARD_USER:=}" "${ADGUARD_PASSWORD:=}"

run() {
  if [[ "$DRY_RUN" == true ]]; then printf '[dry-run] %s\n' "$*"; else "$@"; fi
}

die_or_warn() {
  if [[ "$DRY_RUN" == true ]]; then
    printf 'warning: %s\n' "$1" >&2
  else
    printf 'error: %s\n' "$1" >&2
    exit 1
  fi
}

default_iface=""
if command -v ip >/dev/null; then
  default_iface="$(ip -4 route show default | awk '{print $5; exit}')"
fi
if [[ -z "$LAN_CIDR" && -n "$default_iface" ]]; then
  LAN_CIDR="$(ip -4 route show dev "$default_iface" proto kernel scope link | awk '{print $1; exit}')"
fi

ipv4_re='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
if ! [[ "$LAN_IP" =~ $ipv4_re ]]; then
  detected=""
  [[ -n "$default_iface" ]] && \
    detected="$(ip -4 -o addr show dev "$default_iface" scope global | awk '{sub(/\/.*/, "", $4); print $4; exit}')"
  die_or_warn "LAN_IP in .env must be this host's LAN IPv4 address${detected:+ (detected: $detected)}"
  LAN_IP="${detected:-<lan-ip>}"
fi
if ! [[ "$LAN_CIDR" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
  die_or_warn 'could not detect the LAN subnet — set LAN_CIDR in .env'
  LAN_CIDR='<lan-cidr>'
fi
if ! [[ "$ADGUARD_USER" =~ ^[A-Za-z0-9._-]+$ ]]; then
  die_or_warn 'ADGUARD_USER in .env must be set (letters, digits, . _ -)'
fi
# The install API rejects shorter passwords with a 422 after the wizard is up.
if (( ${#ADGUARD_PASSWORD} < 8 )); then
  die_or_warn 'ADGUARD_PASSWORD in .env must be at least 8 characters'
fi
for tool in curl jq dig; do
  command -v "$tool" >/dev/null || die_or_warn "$tool not found (dig: sudo apt-get install bind9-dnsutils)"
done

[[ "$DRY_RUN" == true ]] || chmod 600 "$SCRIPT_DIR/.env"

base="http://$LAN_IP:$WEB_PORT"
run sudo docker compose -f "$COMPOSE_FILE" config --quiet
run sudo docker compose -f "$COMPOSE_FILE" up -d

# Configure before the ufw rules below: until then the wizard is unauthenticated,
# and ufw keeps it reachable from this host only.
if [[ "$DRY_RUN" == true ]]; then
  printf '[dry-run] if %s/conf/AdGuardHome.yaml is missing: POST %s/control/install/configure (web %s:%s, dns %s:53, user %s)\n' \
    "$SCRIPT_DIR" "$base" "$LAN_IP" "$WEB_PORT" "$LAN_IP" "${ADGUARD_USER:-<admin-user>}"
elif sudo test -f "$SCRIPT_DIR/conf/AdGuardHome.yaml"; then
  printf 'AdGuard already configured; leaving conf/AdGuardHome.yaml as is\n'
else
  for _ in {1..30}; do
    curl -fsS -o /dev/null "$base/control/install/get_addresses" 2>/dev/null && break
    sleep 1
  done
  # Credentials come from the exported environment, not argv, so ps never shows them.
  jq -n --arg ip "$LAN_IP" --argjson web_port "$WEB_PORT" \
      '{web: {ip: $ip, port: $web_port}, dns: {ip: $ip, port: 53},
        username: $ENV.ADGUARD_USER, password: $ENV.ADGUARD_PASSWORD}' |
    curl -sS --fail-with-body -X POST -H 'Content-Type: application/json' \
      --data-binary @- "$base/control/install/configure"
  printf '\nAdGuard configured: UI %s, DNS %s:53\n' "$base" "$LAN_IP"
fi

run sudo ufw allow proto udp from "$LAN_CIDR" to "$LAN_IP" port 53 comment 'adguard dns (LAN)'
run sudo ufw allow proto tcp from "$LAN_CIDR" to "$LAN_IP" port 53 comment 'adguard dns (LAN)'
run sudo ufw allow proto tcp from "$LAN_CIDR" to "$LAN_IP" port "$WEB_PORT" comment 'adguard ui (LAN)'
if [[ "$DRY_RUN" == false ]] && sudo ufw status | grep -qx 'Status: inactive'; then
  printf 'warning: ufw is inactive — the rules above are saved but NOT enforced\n' >&2
fi

if [[ "$DRY_RUN" == true ]]; then
  printf '[dry-run] dig @%s example.com +short\n' "$LAN_IP"
  exit 0
fi
answer=""
for _ in {1..10}; do
  answer="$(dig @"$LAN_IP" example.com +short +time=2 +tries=1 || true)"
  [[ -n "$answer" && "$answer" != *';;'* ]] && break
  answer=""
  sleep 2
done
if [[ -z "$answer" ]]; then
  printf 'error: AdGuard at %s:53 did not resolve example.com\n' "$LAN_IP" >&2
  exit 1
fi
printf 'dig @%s example.com -> %s\n' "$LAN_IP" "$(tr '\n' ' ' <<< "$answer")"
printf 'Next: add REPLICA2 (%s) to the Pi syncer and this host as a DNS server in the router (README.md).\n' "$base"
