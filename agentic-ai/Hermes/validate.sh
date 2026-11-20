#!/usr/bin/env bash
# Post-install health check for install.sh, plus the skill-sync checks from
# `hermes-config verify` once .env exists. Exit 0 = all checks passed.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERMES_HOME_DIR="${HERMES_HOME:-$HOME/.hermes}"
# shellcheck source=lib/hermes-root.sh
source "$REPO_DIR/lib/hermes-root.sh"
# shellcheck source=lib/never-copy.sh
source "$REPO_DIR/lib/never-copy.sh"
HERMES_ROOT_DIR="$(hermes_root)"
PROFILES_DIR="$HERMES_ROOT_DIR/profiles"
PORTABLE="$(hermes_portable_dir "$REPO_DIR")"
ERRORS=0

pass() { printf '  [ OK ] %s\n' "$1"; }
fail() { printf '  [FAIL] %s\n' "$1" >&2; ERRORS=$(( ERRORS + 1 )); }
warn() { printf '  [WARN] %s\n' "$1"; }

check_link() {
  if [[ -L "$1" && "$(readlink "$1")" == "$2" ]]; then pass "$1 → $2"; else fail "$1 is not a symlink to $2"; fi
}

# A regular file where a link belongs is a live edit (e.g. `sed -i`), so name
# both ways to resolve it.
check_portable_link() {
  if [[ -f "$1" && ! -L "$1" ]]; then
    if cmp -s "$1" "$2"; then
      fail "$1 is a regular file, not a link to $2 (same content); run install.sh"
    else
      fail "$1 is a regular file, not a link to $2; run install.sh (keep portable, back up live) or install.sh --take-live (keep live)"
    fi
  else
    check_link "$1" "$2"
  fi
}

printf '=== links ===\n'
check_link "$HOME/.local/bin/hermes-config" "$REPO_DIR/bin/hermes-config"
for widget in "$REPO_DIR"/tui-widgets/*.mjs; do
  check_link "$HERMES_HOME_DIR/tui-widgets/$(basename "$widget")" "$widget"
done

printf '\n=== portable files ===\n'
if [[ -z "$PORTABLE" ]]; then
  warn "no portable dir configured; profiles, SOUL.md and hooks not checked (set HERMES_PORTABLE_DIR or the repo dirs in .env)"
elif [[ ! -d "$PORTABLE" ]]; then
  warn "portable dir $PORTABLE not found; profiles, SOUL.md and hooks not checked (clone the config repo, then run install.sh)"
elif hermes_paths_overlap "$PORTABLE" "$HERMES_ROOT_DIR"; then
  fail "portable dir $PORTABLE overlaps the Hermes root $HERMES_ROOT_DIR (the same dir, or one inside the other); set HERMES_PORTABLE_DIR to the config repo"
else
  for profile_src in "$PORTABLE"/profiles/*/; do
    [[ -d "$profile_src" ]] || continue
    profile="$(basename "$profile_src")"
    for file in "$PROFILES_DIR/$profile" "$PROFILES_DIR/$profile/scripts"; do
      if [[ -L "$file" ]]; then fail "$file is a symlink; install.sh refuses to work through it (make it a real dir)"; continue 2; fi
    done
    for file in config.yaml profile.yaml SOUL.md; do
      [[ -f "$profile_src$file" ]] || continue
      check_portable_link "$PROFILES_DIR/$profile/$file" "$profile_src$file"
    done
    if [[ -d "${profile_src}scripts" ]]; then
      while IFS= read -r -d '' script; do
        [[ -f "$script" ]] || continue
        sub="${script#"${profile_src}scripts/"}" live="$PROFILES_DIR/$profile/scripts/$sub"
        if [[ -f "$live" && ! -L "$live" ]] && cmp -s "$script" "$live"; then pass "$profile/scripts/$sub matches"; else fail "$profile/scripts/$sub missing or differs, or is a symlink; run install.sh"; fi
      done < <(find "${profile_src}scripts" -mindepth 1 \( -false "${HERMES_NEVER_COPY_FIND[@]}" \) -prune -o \( -type f -o -type l \) -print0)
    fi
  done
  if [[ -f "$PORTABLE/default/SOUL.md" ]]; then
    check_portable_link "$HERMES_ROOT_DIR/SOUL.md" "$PORTABLE/default/SOUL.md"
  fi
  if [[ -d "$PORTABLE/hooks" ]]; then
    hooks_dst="$HERMES_ROOT_DIR/agent-hooks"
    if [[ -d "$hooks_dst" && ! -L "$hooks_dst" ]]; then
      fail "$hooks_dst is a real directory, not a link to $PORTABLE/hooks; run install.sh (moves it aside if identical, else lists the differences)"
    else
      check_link "$hooks_dst" "$PORTABLE/hooks"
    fi
  fi
  if compgen -G "$PORTABLE/profiles/*/" >/dev/null; then
    if assignees="$(hermes kanban assignees 2>/dev/null)"; then
      for profile_src in "$PORTABLE"/profiles/*/; do
        profile="$(basename "$profile_src")"
        if grep -qE "^$profile +yes" <<< "$assignees"; then pass "kanban assignee $profile"; else fail "kanban assignee $profile not on disk"; fi
      done
    else
      fail "hermes kanban assignees failed"
    fi
  fi
fi

printf '\n=== tools ===\n'
for tool in hermes jq git; do
  if command -v "$tool" >/dev/null; then pass "$tool"; else fail "$tool not on PATH"; fi
done
if command -v codeburn >/dev/null; then pass "codeburn (widget data source)"; else warn "codeburn not on PATH; the codeburn widget will show an error"; fi

if [[ -f "$REPO_DIR/.env" ]]; then
  printf '\n=== skill sync ===\n'
  "$REPO_DIR/bin/hermes-config" verify || ERRORS=$(( ERRORS + 1 ))
  printf '\n=== nightly sync ===\n'
  cron_script="$HERMES_HOME_DIR/scripts/hermes-config-sync.sh"
  if grep -qF "$REPO_DIR/bin/hermes-config sync" "$cron_script" 2>/dev/null; then pass "cron script $cron_script"; else fail "cron script missing or stale; run: hermes-config install"; fi
  if hermes cron list 2>/dev/null | grep -q 'Script: *hermes-config-sync.sh'; then pass "cron job scheduled"; else warn "no cron job runs hermes-config-sync.sh (see README: Nightly commit + push)"; fi
else
  warn "no .env; skill sync not configured (see .env.example)"
fi

printf '\n'
if (( ERRORS )); then printf 'validate: %d failure(s)\n' "$ERRORS" >&2; exit 1; fi
printf 'validate: all checks passed\n'
