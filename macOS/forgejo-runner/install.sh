#!/usr/bin/env bash
# Build + install the Forgejo Actions runner on macOS, then register it and
# install the LaunchAgent so it starts at login and stays up.
#
# Forgejo ships no macOS binaries (Linux-only releases), so the runner is built
# from source with Go — matching the git-describe version already on the Mac
# mini (e.g. v12.10.2+...).
#
# Usage:
#   bash install.sh                 # build, register (prompts for token), load
#   bash install.sh --skip-build    # reuse an existing binary
#   bash install.sh --skip-register # don't touch server.connections
#   RUNNER_VERSION=v12.12.0 bash install.sh
#   FORGEJO_INSTANCE_URL=https://forgejo.<tailnet>.ts.net bash install.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=macOS/forgejo-runner/lib.sh
source "$HERE/lib.sh"

RUNNER_VERSION="${RUNNER_VERSION:-v12.12.0}"
RUNNER_REPO="https://code.forgejo.org/forgejo/runner"
RUNNER_NAME="${RUNNER_NAME:-$(scutil --get LocalHostName 2>/dev/null || hostname -s)}"
RUNNER_LABELS="${RUNNER_LABELS:-macos-latest:host}"

skip_build=false
skip_register=false
for arg in "$@"; do
  case "$arg" in
    --skip-build)    skip_build=true ;;
    --skip-register) skip_register=true ;;
    *) warn "ignoring unknown flag: $arg" ;;
  esac
done

[[ "$(uname -s)" == "Darwin" ]] || die "this installer is macOS-only"
[[ "$(uname -m)" == "arm64" ]] || warn "expected arm64 (Apple Silicon); continuing anyway"

build_runner() {
  command -v go >/dev/null 2>&1 || die "Go is required to build the runner. Install with: brew install go"
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  info "cloning $RUNNER_REPO @ $RUNNER_VERSION"
  git clone --depth 1 --branch "$RUNNER_VERSION" "$RUNNER_REPO" "$tmp/runner"
  info "building (this takes a minute)"
  if ! make -C "$tmp/runner" build 2>/dev/null; then
    ( cd "$tmp/runner" && go build -o forgejo-runner . )
  fi
  mkdir -p "$(dirname "$RUNNER_BIN")"
  install -m 0755 "$tmp/runner/forgejo-runner" "$RUNNER_BIN"
  ok "installed $RUNNER_BIN ($("$RUNNER_BIN" --version 2>&1 | head -1))"
}

ensure_config() {
  if [[ -f "$CONFIG" ]]; then
    info "config already present: $CONFIG"
    return
  fi
  info "generating base config: $CONFIG"
  "$RUNNER_BIN" generate-config >"$CONFIG"
  ok "wrote default config"
}

register_runner() {
  if grep -q 'server:' "$CONFIG" && grep -q 'connections:' "$CONFIG" && grep -q 'token:' "$CONFIG"; then
    info "a server.connections entry already exists in $CONFIG — skipping registration"
    info "(delete that block and re-run to re-register)"
    return
  fi

  local url token
  url="$DEFAULT_INSTANCE_URL"
  printf 'Forgejo instance URL [%s]: ' "$url"
  read -r reply || true
  [[ -n "${reply:-}" ]] && url="$reply"

  printf 'Registration token (Forgejo → Settings → Actions → Runners → Create new runner): '
  read -rs token || true
  printf '\n'
  [[ -n "${token:-}" ]] || die "a registration token is required"

  info "registering '$RUNNER_NAME' (labels: $RUNNER_LABELS) against $url"
  "$RUNNER_BIN" register --no-interactive \
    --config "$CONFIG" \
    --instance "$url" \
    --token "$token" \
    --name "$RUNNER_NAME" \
    --labels "$RUNNER_LABELS"
  ok "registered"
}

install_agent() {
  local node_bin tmpl
  node_bin="$(command -v node >/dev/null 2>&1 && dirname "$(command -v node)" || true)"
  tmpl="$HERE/net.forgejo.runner.plist.template"
  mkdir -p "$(dirname "$PLIST")" "$(dirname "$LOG")"

  # PATH for jobs: node (if found) + Homebrew + system. Workflows often need node.
  local path_value="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  [[ -n "$node_bin" ]] && path_value="$node_bin:$path_value"

  sed -e "s|__RUNNER_BIN__|$RUNNER_BIN|g" \
      -e "s|__CONFIG__|$CONFIG|g" \
      -e "s|__LOG__|$LOG|g" \
      -e "s|__WORKDIR__|$HOME|g" \
      -e "s|__PATH__|$path_value|g" \
      "$tmpl" >"$PLIST"
  ok "wrote $PLIST"
}

load_agent() {
  local domain
  domain="$(launchd_domain)"
  launchctl bootout "$domain/$LABEL" 2>/dev/null || true
  launchctl bootstrap "$domain" "$PLIST"
  launchctl kickstart -k "$domain/$LABEL" 2>/dev/null || true
  ok "loaded LaunchAgent ($LABEL)"
}

"$skip_build" || build_runner
[[ -x "$RUNNER_BIN" ]] || die "runner binary missing at $RUNNER_BIN (run without --skip-build)"
ensure_config
"$skip_register" || register_runner
install_agent
load_agent

printf '\nDone. Verify with:\n  bash %s/verify.sh\n' "$HERE"
printf 'Tail logs with:\n  bash %s/run.sh tail\n' "$HERE"
