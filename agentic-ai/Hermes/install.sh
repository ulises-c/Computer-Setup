#!/usr/bin/env bash
# Idempotent setup for the Hermes pieces of this repo: puts hermes-config on
# PATH and links each TUI widget into $HERMES_HOME/tui-widgets/. Wiring the
# private skill repos is a separate, explicit step (`hermes-config install`)
# because it needs .env and the Forgejo repos to exist.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERMES_HOME_DIR="${HERMES_HOME:-$HOME/.hermes}"
LOCAL_BIN="$HOME/.local/bin"
WIDGETS_DST="$HERMES_HOME_DIR/tui-widgets"

[[ -d "$HERMES_HOME_DIR" ]] || { printf 'error: %s not found; install Hermes first\n' "$HERMES_HOME_DIR" >&2; exit 1; }

link() {
  local src="$1" dst="$2"
  if [[ -e "$dst" && ! -L "$dst" ]]; then
    printf 'warning: %s exists and is not a symlink; skipping\n' "$dst" >&2
    return 0
  fi
  ln -sfn "$src" "$dst"
  printf 'Linked: %s → %s\n' "${src#"$REPO_DIR"/}" "$dst"
}

mkdir -p "$LOCAL_BIN" "$WIDGETS_DST"
link "$REPO_DIR/bin/hermes-config" "$LOCAL_BIN/hermes-config"
for widget in "$REPO_DIR"/tui-widgets/*.mjs; do
  link "$widget" "$WIDGETS_DST/$(basename "$widget")"
done

if [[ -f "$REPO_DIR/.env" ]]; then
  printf '\nNext: hermes-config install && hermes-config migrate\n'
else
  printf '\nNext: cp %s/.env.example %s/.env, fill it in, then: hermes-config install\n' "$REPO_DIR" "$REPO_DIR"
fi
