#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SETUP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/core.sh
source "$SETUP_ROOT/lib/core.sh"
# shellcheck source=platforms/server.sh
source "$SETUP_ROOT/platforms/server.sh"

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
if [[ "$DRY_RUN" == false ]]; then
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "$ID" == ubuntu && "$(uname -m)" == x86_64 ]] || {
    printf 'error: this bootstrap requires Ubuntu Server on x86_64\n' >&2
    exit 1
  }
fi

run bash "$SCRIPT_DIR/dragonwilds/maintenance.sh" prepare

PLATFORM=server
CONFIG_SRC_DIR="$SCRIPT_DIR"
TAG_FILTER_ACTIVE=true
SELECTED_TAGS="$(core_csv_to_json terminal)"
export TAG_FILTER_ACTIVE SELECTED_TAGS

core_prime_sudo
run sudo apt-get update
run sudo apt-get install -y ca-certificates curl jq git rsync python3 ufw polkitd \
  docker.io docker-compose-v2 lib32gcc-s1 lib32stdc++6
apt_install_tier high
apt_install_tier medium
setup_bat_fd_symlinks
set_default_shell
deploy_dotfiles
server_preclone_antidote
run sudo systemctl enable --now docker
# Docker group membership is root-equivalent; this bootstrap deliberately uses sudo instead.
CONFIG_SRC_DIR="$SETUP_ROOT/linux-server"
server_docker_daemon_step
CONFIG_SRC_DIR="$SCRIPT_DIR"
TAG_FILTER_ACTIVE=false
platform_tailscale_step
run sudo systemctl enable --now tailscaled

if [[ "$DRY_RUN" == true ]]; then
  printf '[dry-run] scaffold private homepage and dragonwilds .env files (mode 600)\n'
else
  python3 "$SCRIPT_DIR/scaffold.py"
fi
run sudo docker compose -f "$SCRIPT_DIR/homepage/docker-compose.yml" config --quiet
run sudo docker compose -f "$SCRIPT_DIR/homepage/docker-compose.yml" up -d
run bash "$SCRIPT_DIR/dragonwilds/install.sh"

if [[ "$DRY_RUN" == true ]]; then
  printf '[dry-run] once a migrated world is verified, install Dragonwilds units and LAN/tailnet firewall rules\n'
  printf '[dry-run] publish homepage with tailscale serve after authentication\n'
  exit 0
fi

if [[ "$(tailscale status --json | jq -r .BackendState)" == Running ]]; then
  sudo tailscale set --operator="$(id -un)"
  bash "$SCRIPT_DIR/homepage/serve.sh"
else
  printf '\nAuthenticate Tailscale, then publish Homepage:\n'
  printf '  sudo tailscale up --operator=%s\n' "$(id -un)"
  printf '  bash %s/homepage/serve.sh\n' "$SCRIPT_DIR"
fi
printf '\nBase installed. Dragonwilds has NOT been started.\n'
printf 'Complete the stopped-server migration in linux-game-server/README.md first.\n'
