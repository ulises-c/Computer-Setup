#!/usr/bin/env bash
# Idempotent setup for the Hermes pieces of this repo: puts hermes-config on
# PATH, links each TUI widget into $HERMES_HOME/tui-widgets/, and links the
# Kanban role profiles into <hermes root>/profiles/. Wiring the
# private skill repos is a separate, explicit step (`hermes-config install`)
# because it needs .env and the Forgejo repos to exist.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERMES_HOME_DIR="${HERMES_HOME:-$HOME/.hermes}"
LOCAL_BIN="$HOME/.local/bin"
WIDGETS_DST="$HERMES_HOME_DIR/tui-widgets"
# shellcheck source=lib/hermes-root.sh
source "$REPO_DIR/lib/hermes-root.sh"
PROFILES_DST="$(hermes_root)/profiles"
STAMP="$(date +%Y%m%d-%H%M%S)"

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

# A profile is a live directory Hermes created, so its config files start out
# as real files: back each one up once, then link it.
link_replacing() {
  local src="$1" dst="$2"
  if [[ -L "$dst" && "$(readlink "$dst")" == "$src" ]]; then
    return 0
  fi
  if [[ -e "$dst" && ! -L "$dst" ]]; then
    if ! cmp -s "$src" "$dst"; then
      cp -p "$dst" "$dst.bak-$STAMP"
      printf 'Backed up: %s → %s.bak-%s\n' "$dst" "$dst" "$STAMP"
    fi
    rm "$dst"
  fi
  ln -sfn "$src" "$dst"
  printf 'Linked: %s → %s\n' "${src#"$REPO_DIR"/}" "$dst"
}

mkdir -p "$LOCAL_BIN" "$WIDGETS_DST"
link "$REPO_DIR/bin/hermes-config" "$LOCAL_BIN/hermes-config"
for widget in "$REPO_DIR"/tui-widgets/*.mjs; do
  link "$widget" "$WIDGETS_DST/$(basename "$widget")"
done

for profile_src in "$REPO_DIR"/profiles/*/; do
  profile="$(basename "$profile_src")"
  profile_dst="$PROFILES_DST/$profile"
  if [[ ! -d "$profile_dst" ]]; then
    hermes profile create --no-alias "$profile" >/dev/null
    [[ -d "$profile_dst" ]] || { printf 'error: hermes created %s outside %s\n' "$profile" "$PROFILES_DST" >&2; exit 1; }
    printf 'Created profile: %s\n' "$profile"
  fi
  for file in config.yaml profile.yaml SOUL.md; do
    link_replacing "$profile_src$file" "$profile_dst/$file"
  done
  # Hermes cron runs only real files inside the profile's scripts/ dir (a
  # symlink out of it is rejected), so scripts are copied, not linked.
  if [[ -d "${profile_src}scripts" ]]; then
    mkdir -p "$profile_dst/scripts"
    for script in "${profile_src}scripts"/*; do
      if ! cmp -s "$script" "$profile_dst/scripts/$(basename "$script")"; then
        cp "$script" "$profile_dst/scripts/"
        printf 'Copied: %s → %s/scripts/\n' "${script#"$REPO_DIR"/}" "$profile_dst"
      fi
    done
  fi
done

if [[ -f "$REPO_DIR/.env" ]]; then
  printf '\nNext: hermes-config install && hermes-config migrate\n'
else
  printf '\nNext: cp %s/.env.example %s/.env, fill it in, then: hermes-config install\n' "$REPO_DIR" "$REPO_DIR"
fi
