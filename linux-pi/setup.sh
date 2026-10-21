#!/usr/bin/env bash
set -euo pipefail

# Base layer for the Raspberry Pi (Debian/Raspberry Pi OS, arm64): the shared
# server-base tool set and dotfiles, Tailscale, Docker, and the base containers
# (Glances, Portainer, Watchtower) published on the Pi's own tailnet node. The
# Pi's own service stacks (AdGuard, MotionEye, CUPS, Homepage, backups) keep
# their per-service setup in README.md.
#
#   bash linux-pi/setup.sh --dry-run
#   bash linux-pi/setup.sh

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
  [[ "$ID" == debian || "${ID_LIKE:-}" == *debian* ]] && [[ "$ID" != ubuntu ]] || {
    printf 'error: this bootstrap targets Debian / Raspberry Pi OS\n' >&2
    exit 1
  }
  # The shared apt bootstrap only knows Ubuntu PPAs for these; Debian 13+ ships them.
  for pkg in fastfetch eza; do
    apt-cache show "$pkg" &>/dev/null || {
      printf 'error: %s is not in this release'"'"'s archive; upgrade to Debian 13 (trixie) or later\n' "$pkg" >&2
      exit 1
    }
  done
fi

# shellcheck disable=SC2034  # consumed by the sourced lib/core.sh and platforms/server.sh
PLATFORM=server
# shellcheck disable=SC2034  # consumed by the sourced lib/core.sh and platforms/server.sh
CONFIG_SRC_DIR="$SCRIPT_DIR"
TAG_FILTER_ACTIVE=true
SELECTED_TAGS="$(core_csv_to_json server-base)"
export TAG_FILTER_ACTIVE SELECTED_TAGS

core_prime_sudo
apt_bootstrap
# Without recommends, matching the other servers' minimal Cockpit.
run sudo apt-get install -y --no-install-recommends cockpit
# apt only: Raspberry Pi OS has no snapd, so snap-only base tools (micro) are skipped.
apt_install_tier high
apt_install_tier medium
setup_bat_fd_symlinks
claude_code_step
opencode_step
set_default_shell
deploy_dotfiles
server_preclone_antidote
platform_tailscale_step
command -v docker &>/dev/null || platform_docker_optional
# Not server_docker_daemon_step: restarting Docker here drops the Pi's backup
# DNS resolver; pin the address pools by hand in a maintenance window instead.

run bash "$SETUP_ROOT/server-base/homepage/fetch-assets.sh" "$SCRIPT_DIR"
run bash "$SETUP_ROOT/server-base/timezone.sh"
for dir in glances portainer watchtower; do
  run sudo docker compose -f "$SCRIPT_DIR/$dir/docker-compose.yml" config --quiet
done

if [[ "$DRY_RUN" == true ]]; then
  printf '[dry-run] publish Glances, Cockpit and Portainer on the Pi node with server-base/serve.sh\n'
  exit 0
fi

if [[ "$(tailscale status --json | jq -r .BackendState)" == Running ]]; then
  sudo tailscale set --operator="$(id -un)"
  bash "$SCRIPT_DIR/serve.sh"
else
  printf '\nAuthenticate Tailscale, then publish the base services:\n'
  printf '  sudo tailscale up --operator=%s\n' "$(id -un)"
  printf '  bash %s/serve.sh\n' "$SCRIPT_DIR"
fi
