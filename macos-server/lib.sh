# shellcheck shell=bash
# Sourced by the macos-server scripts: paths plus LaunchAgent rendering and
# control. Agents run in the login user's gui domain, so they need a logged-in
# session (see README.md, "After a power cut").
# shellcheck disable=SC2034  # constants are consumed by the sourcing scripts

MACOS_SERVER_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$MACOS_SERVER_DIR/.." && pwd)"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
LOG_DIR="$HOME/Library/Logs/computer-setup"
BREW_PREFIX="$(brew --prefix 2>/dev/null || printf '/opt/homebrew')"
TAILSCALE_APP_CLI=/Applications/Tailscale.app/Contents/MacOS/Tailscale
DRY_RUN="${DRY_RUN:-false}"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
gui_domain() { printf 'gui/%s' "$(id -u)"; }

tailscale_cli() {
  if command -v tailscale >/dev/null; then
    tailscale "$@"
  else
    "$TAILSCALE_APP_CLI" "$@"
  fi
}

tailnet_domain() {
  tailscale_cli status --json 2>/dev/null | jq -r '.Self.DNSName // "" | rtrimstr(".")' 2>/dev/null || true
}

# render_plist <template> <label> [KEY=VALUE ...]: fills @HOME@, @REPO@, @BREW@,
# @LOG_DIR@ and each @KEY@, lints the result and installs it as <label>.plist.
render_plist() {
  local template="$1" label="$2" dest tmp
  shift 2
  dest="$LAUNCH_AGENTS/$label.plist"
  command -v python3 >/dev/null || die "python3 is required to render LaunchAgents"
  tmp="$(mktemp)"
  if ! python3 - "$template" "HOME=$HOME" "REPO=$REPO_ROOT" "BREW=$BREW_PREFIX" "LOG_DIR=$LOG_DIR" "$@" >"$tmp" <<'PY'
import html
from pathlib import Path
import plistlib
import re
import sys

values = dict(pair.split("=", 1) for pair in sys.argv[2:])
template = Path(sys.argv[1]).read_text(encoding="utf-8")
try:
    rendered = re.sub(r"@([A-Z_]+)@", lambda match: html.escape(values[match[1]], quote=True), template)
    plistlib.loads(rendered.encode("utf-8"))
except (KeyError, ValueError, plistlib.InvalidFileException) as error:
    sys.exit(f"invalid or unfilled plist template: {error}")
sys.stdout.write(rendered)
PY
  then
    rm -f "$tmp"
    die "could not render $template"
  fi
  if command -v plutil >/dev/null && ! plutil -lint -s "$tmp"; then
    rm -f "$tmp"
    die "invalid plist rendered from $template"
  fi
  if [[ "$DRY_RUN" == true ]]; then
    printf '[dry-run] install %s as %s\n' "${template#"$REPO_ROOT"/}" "$dest"
    rm -f "$tmp"
    return
  fi
  mkdir -p "$LAUNCH_AGENTS" "$LOG_DIR"
  install -m 644 "$tmp" "$dest"
  rm -f "$tmp"
}

# (Re)load an installed agent. bootout is asynchronous, so bootstrap retries.
agent_load() {
  local label="$1" plist="$LAUNCH_AGENTS/$1.plist" i state
  if [[ "$DRY_RUN" == true ]]; then
    printf '[dry-run] launchctl bootstrap %s %s\n' "$(gui_domain)" "$plist"
    return
  fi
  if [[ "$label" == net.computer-setup.mac-backup ]]; then
    state="$(agent_state "$label")"
    if [[ -n "$state" && "${state%% *}" != - ]]; then
      printf 'defer mac-backup reload: backup is running; rerun bash macos-server/agents.sh install after it finishes\n'
      return 0
    fi
  fi
  launchctl bootout "$(gui_domain)/$label" 2>/dev/null || true
  for i in 1 2 3 4 5 6 7 8 9 10; do
    launchctl bootstrap "$(gui_domain)" "$plist" 2>/dev/null && return 0
    sleep 1
  done
  launchctl bootstrap "$(gui_domain)" "$plist"
}

agent_unload() {
  local label="$1"
  if [[ "$DRY_RUN" == true ]]; then
    printf '[dry-run] launchctl bootout %s/%s\n' "$(gui_domain)" "$label"
    return
  fi
  launchctl bootout "$(gui_domain)/$label" 2>/dev/null || true
}

# <pid|-> <last exit status>, or nothing when the agent is not loaded.
agent_state() {
  launchctl list | awk -v l="$1" '$3 == l { print $1, $2 }'
}
