#!/usr/bin/env bash
set -euo pipefail

# Bootstrap for the always-on Mac mini (macos-server): the host packages, the
# repo-managed LaunchAgents (native Glances, status exporter, backup, local
# inference), the base containers in OrbStack, and the Homepage published on
# the Mac's own tailnet name. Power settings and backups have their own steps
# (power/power.sh, backup/connect.sh); see README.md.
#
#   bash macos-server/setup.sh --dry-run
#   bash macos-server/setup.sh

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=macos-server/lib.sh
source "$SCRIPT_DIR/lib.sh"

case "${1:-}" in
  "") ;;
  --dry-run) DRY_RUN=true ;;
  *) printf 'usage: bash %s [--dry-run]\n' "$0" >&2; exit 1 ;;
esac
[[ $# -le 1 ]] || die "too many arguments"
[[ $EUID -ne 0 ]] || die "run as your login user, not with sudo"
export DRY_RUN

run() {
  if [[ "$DRY_RUN" == true ]]; then
    printf '[dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

if [[ "$DRY_RUN" == false ]]; then
  [[ "$(uname -s)" == Darwin ]] || die "this bootstrap targets macOS"
  command -v brew >/dev/null || die "install Homebrew first (root setup.sh --platform macos)"
fi

# bash: the shared backup engine needs bash 4+ (macOS ships 3.2).
for formula in bash jq restic glances mlx-lm; do
  if [[ "$DRY_RUN" == true ]] || ! brew list --formula "$formula" &>/dev/null; then
    run brew install "$formula"
  fi
done
if [[ "$DRY_RUN" == true || ! -d /Applications/OrbStack.app ]]; then
  run brew install --cask orbstack
fi

run bash "$REPO_ROOT/server-base/timezone.sh"
run python3 "$SCRIPT_DIR/scaffold.py"
bash "$SCRIPT_DIR/agents.sh" install

export PATH="$HOME/.orbstack/bin:$PATH"
for dir in homepage portainer watchtower status; do
  run docker compose -f "$SCRIPT_DIR/$dir/docker-compose.yml" config --quiet
done

if [[ "$DRY_RUN" == true ]]; then
  printf '[dry-run] bash %s/power/power.sh --check\n' "$SCRIPT_DIR"
  printf '[dry-run] publish Homepage, Glances, Portainer and Hermes WebUI with server-base/serve.sh\n'
  exit 0
fi

bash "$SCRIPT_DIR/power/power.sh" --check || printf 'power settings drift: run bash %s/power/power.sh\n' "$SCRIPT_DIR"
if [[ "$(tailscale_cli status --json | jq -r .BackendState)" == Running ]]; then
  bash "$SCRIPT_DIR/serve.sh"
else
  printf '\nSign in to Tailscale, then publish the services:\n  bash %s/serve.sh\n' "$SCRIPT_DIR"
fi
