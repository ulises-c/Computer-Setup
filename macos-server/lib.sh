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
  local template="$1" label="$2" dest tmp pair
  shift 2
  dest="$LAUNCH_AGENTS/$label.plist"
  local args=(-e "s|@HOME@|$HOME|g" -e "s|@REPO@|$REPO_ROOT|g" -e "s|@BREW@|$BREW_PREFIX|g" -e "s|@LOG_DIR@|$LOG_DIR|g")
  for pair in "$@"; do
    [[ "${pair#*=}" != *"|"* ]] || die "unsupported character in ${pair%%=*}"
    args+=(-e "s|@${pair%%=*}@|${pair#*=}|g")
  done
  tmp="$(mktemp)"
  sed "${args[@]}" "$template" >"$tmp"
  if grep -qE '@[A-Z_]+@' "$tmp"; then
    rm -f "$tmp"
    die "unfilled placeholder in $template"
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
  local label="$1" plist="$LAUNCH_AGENTS/$1.plist" i
  if [[ "$DRY_RUN" == true ]]; then
    printf '[dry-run] launchctl bootstrap %s %s\n' "$(gui_domain)" "$plist"
    return
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
