#!/usr/bin/env bash
# Idempotent setup for the Hermes pieces of this repo: puts hermes-config on
# PATH and links each TUI widget into $HERMES_HOME/tui-widgets/. Then links
# the portable files (worker profiles, the default SOUL.md, hooks) from the
# private config repo into the Hermes root. Wiring the private skill repos is
# a separate, explicit step (`hermes-config install`) because it needs .env
# and the Forgejo repos to exist.
set -euo pipefail

usage() {
  cat <<'EOF'
usage: install.sh [--adopt [--dry-run]] [--take-live]

Links hermes-config into ~/.local/bin and the TUI widgets into
$HERMES_HOME/tui-widgets/, then links the portable files from the portable
dir into the Hermes root (~/.hermes):

  <portable>/profiles/<name>/{config.yaml,profile.yaml,SOUL.md}
                              → profiles/<name>/ (scripts/ is copied, not linked:
                                a differing live script is backed up first)
  <portable>/default/SOUL.md  → SOUL.md
  <portable>/hooks/           → agent-hooks (directory link; a real dir with the
                                same content is moved to agent-hooks.bak-<stamp>,
                                a differing one is left alone and reported)

The portable dir is $HERMES_PORTABLE_DIR, else HERMES_PORTABLE_DIR in .env,
else the work repo dir, else the personal repo dir from .env (a repo counts
when its REMOTE is set). With none configured, or before it is cloned, only
the first two steps run. A portable dir that overlaps the Hermes root is
refused before anything changes. .env is sourced as shell code.

A regular file where a link belongs (for example after `sed -i`) means the
live copy was edited. By default the portable copy wins: the live file is
backed up to <file>.bak-<stamp> (plus -1, -2, ... if taken) and replaced by
the link.

  --adopt      first copy what the portable dir lacks from the live install:
               profiles that have a profile.yaml (config.yaml, profile.yaml,
               SOUL.md, all of scripts/), SOUL.md and agent-hooks/. Never
               overwrites a portable file; skips the names in
               lib/never-copy.sh (__pycache__, *.pyc, *.bak*, *.lock, .env*,
               auth.json, *.db*, mcp-tokens, on any part of the path). Stages
               and commits nothing.
  --dry-run    with --adopt: print what would be adopted and change nothing
  --take-live  the live copy wins: keep the old portable file as
               <file>.bak-<stamp> (git-ignored via .git/info/exclude), put
               the live content in its place, then link it
  -h, --help   show this help
EOF
}

ADOPT=0 DRY_RUN=0 TAKE_LIVE=0
for arg in "$@"; do
  case "$arg" in
    --adopt) ADOPT=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --take-live) TAKE_LIVE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
if (( DRY_RUN && ! ADOPT )); then printf 'error: --dry-run only applies to --adopt\n' >&2; exit 2; fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERMES_HOME_DIR="${HERMES_HOME:-$HOME/.hermes}"
# A trailing slash would make the -L check below follow a symlinked profile.
while [[ "$HERMES_HOME_DIR" == ?*/ ]]; do HERMES_HOME_DIR="${HERMES_HOME_DIR%/}"; done
LOCAL_BIN="$HOME/.local/bin"
WIDGETS_DST="$HERMES_HOME_DIR/tui-widgets"
# shellcheck source=lib/hermes-root.sh
source "$REPO_DIR/lib/hermes-root.sh"
# shellcheck source=lib/never-copy.sh
source "$REPO_DIR/lib/never-copy.sh"
# The default SOUL.md and agent-hooks belong to the root, not to a named
# profile that HERMES_HOME may point at.
HERMES_ROOT_DIR="$(hermes_root)"
PROFILES_DST="$HERMES_ROOT_DIR/profiles"
PORTABLE="$(hermes_portable_dir "$REPO_DIR")"
STAMP="$(date +%Y%m%d-%H%M%S)"
FAILS=0

[[ -d "$HERMES_HOME_DIR" ]] || { printf 'error: %s not found; install Hermes first\n' "$HERMES_HOME_DIR" >&2; exit 1; }
if [[ -n "$PORTABLE" ]] && hermes_paths_overlap "$PORTABLE" "$HERMES_ROOT_DIR"; then
  printf 'error: portable dir %s overlaps the Hermes root %s (the same dir, or one inside the other); nothing changed\n' "$PORTABLE" "$HERMES_ROOT_DIR" >&2
  exit 1
fi
# HERMES_HOME may be a named profile, and the widgets go into it before
# link_profiles runs: refuse a symlinked profile or scripts/ dir now, as
# link_profiles would, before anything is written through it.
if [[ "$(dirname "$HERMES_HOME_DIR")" -ef "$PROFILES_DST" ]]; then
  for dir in "$HERMES_HOME_DIR" "$HERMES_HOME_DIR/scripts"; do
    if [[ -L "$dir" ]]; then
      printf 'error: %s is a symlink; active profile %s (HERMES_HOME) left untouched; nothing changed\n' "$dir" "$(basename "$HERMES_HOME_DIR")" >&2
      exit 1
    fi
  done
fi

SKIP_REASON=""
if [[ -z "$PORTABLE" ]]; then
  SKIP_REASON="no portable dir configured (set HERMES_PORTABLE_DIR, or the repo dirs in .env)"
elif [[ ! -d "$PORTABLE" ]]; then
  SKIP_REASON="portable dir $PORTABLE not found (clone the config repo first)"
fi

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
# as real files, and tools like `sed -i` turn a link back into one. Either
# back the live file up (portable wins) or, with --take-live, copy it over the
# portable copy (live wins); then link it.
link_replacing() {
  local src="$1" dst="$2" bak
  if [[ -L "$dst" && "$(readlink "$dst")" == "$src" ]]; then
    return 0
  fi
  # A portable file that is the live file under another name (a symlink to
  # it, a hard link) would become a link to itself.
  if [[ ! -L "$dst" && "$src" -ef "$dst" ]]; then
    printf 'error: %s and %s are the same file; left untouched\n' "$src" "$dst" >&2
    FAILS=$(( FAILS + 1 ))
    return 0
  fi
  if [[ -d "$dst" && ! -L "$dst" ]]; then
    printf 'error: %s is a directory; left untouched\n' "$dst" >&2
    FAILS=$(( FAILS + 1 ))
    return 0
  fi
  if [[ -e "$dst" && ! -L "$dst" ]]; then
    if ! cmp -s "$src" "$dst"; then
      if (( TAKE_LIVE )); then
        take_live "$src" "$dst" || return 0
      else
        bak="$(backup_name "$dst")"
        cp -p "$dst" "$bak"
        printf 'Backed up: %s → %s\n' "$dst" "$bak"
      fi
    fi
    rm "$dst"
  fi
  ln -sfn "$src" "$dst"
  printf 'Linked: %s → %s\n' "${src#"$PORTABLE"/}" "$dst"
}

# take_live <portable file> <live file>: the live content replaces the
# portable file, by a temp file beside it renamed into place, after the old
# portable content is kept as a .bak- sibling that git ignores. 1 when it
# cannot (reported), so the live file stays.
take_live() {
  local src="$1" dst="$2" bak tmp
  if [[ -e "$src" ]]; then
    bak="$(backup_name "$src")"
    cp -p "$src" "$bak" || { printf 'error: cannot keep the old %s; left untouched\n' "$src" >&2; FAILS=$(( FAILS + 1 )); return 1; }
    printf 'Kept the old portable copy: %s (%s)\n' "$bak" "$(ignore_backups_in_git)"
  fi
  tmp="$(mktemp "$(dirname "$src")/.take-live.XXXXXX")"
  if ! { cp "$dst" "$tmp" && chmod --reference="$src" "$tmp" && mv -f "$tmp" "$src"; }; then
    rm -f "$tmp"
    printf 'error: cannot copy %s over %s; left untouched\n' "$dst" "$src" >&2; FAILS=$(( FAILS + 1 )); return 1
  fi
  printf 'Took live: %s → %s\n' "$dst" "$src"
}

# Adds *.bak-* to the portable repo's local .git/info/exclude (not a tracked
# file), so the nightly `git add -A` never commits a kept copy. Prints what
# keeps the copy out of git. Only when the portable dir is the repo's top.
ignore_backups_in_git() {
  local top exclude
  top="$(git -C "$PORTABLE" rev-parse --show-toplevel 2>/dev/null)" || { printf 'not in a git repo'; return 0; }
  if [[ "$(realpath -- "$top")" != "$(realpath -- "$PORTABLE")" ]]; then printf 'not at the top of a git repo; keep it out of git by hand'; return 0; fi
  exclude="$(git -C "$PORTABLE" rev-parse --path-format=absolute --git-path info/exclude)"
  if ! grep -qxF '*.bak-*' "$exclude" 2>/dev/null; then
    mkdir -p "$(dirname "$exclude")" && printf '*.bak-*\n' >> "$exclude"
  fi
  printf 'ignored by git via %s' "$exclude"
}

# A real hooks dir is moved aside only when nothing in it would be lost.
link_hooks() {
  local src="$PORTABLE/hooks" dst="$HERMES_ROOT_DIR/agent-hooks" diffs bak
  [[ -d "$src" ]] || return 0
  if [[ -L "$dst" && "$(readlink "$dst")" == "$src" ]]; then
    return 0
  fi
  if [[ ! -L "$dst" && "$src" -ef "$dst" ]]; then
    printf 'error: %s and %s are the same directory; left untouched\n' "$src" "$dst" >&2
    FAILS=$(( FAILS + 1 ))
    return 0
  fi
  if [[ -d "$dst" && ! -L "$dst" ]]; then
    if ! diffs="$(diff -rq --exclude=__pycache__ "$dst" "$src" 2>&1)"; then
      printf 'error: %s differs from %s; left untouched:\n' "$dst" "$src" >&2
      printf '%s\n' "$diffs" | sed 's/^/  /' >&2
      printf '  resolve: make them match (copy the live changes you want into %s; install.sh --adopt adds files only the live dir has), then rerun install.sh\n' "$src" >&2
      FAILS=$(( FAILS + 1 ))
      return 0
    fi
    bak="$(backup_name "$dst")"
    mv -T "$dst" "$bak"
    printf 'Moved aside: %s → %s\n' "$dst" "$bak"
  elif [[ -e "$dst" && ! -L "$dst" ]]; then
    printf 'error: %s is not a directory; left untouched\n' "$dst" >&2
    FAILS=$(( FAILS + 1 ))
    return 0
  fi
  ln -sfn "$src" "$dst"
  printf 'Linked: hooks → %s\n' "$dst"
}

# -f follows links, so a file still linked into an old checkout is adopted
# too. Caches, backups, locks and secrets (lib/never-copy.sh, checked on the
# path inside the portable dir) never belong in the config repo.
adopt_file() {
  local live="$1" port="$2"
  [[ -f "$live" ]] || return 0
  [[ -e "$port" || -L "$port" ]] && return 0
  hermes_never_copy "${port#"$PORTABLE"/}" && return 0
  if (( DRY_RUN )); then
    printf 'Would adopt: %s → %s\n' "$live" "$port"
    return 0
  fi
  mkdir -p "$(dirname "$port")"
  cp -p "$live" "$port"
  printf 'Adopted: %s → %s\n' "$live" "$port"
}

adopt_all() {
  local profile_live profile file script hook hooks="$HERMES_ROOT_DIR/agent-hooks"
  for profile_live in "$PROFILES_DST"/*/; do
    [[ -f "${profile_live}profile.yaml" ]] || continue
    profile="$(basename "$profile_live")"
    for file in config.yaml profile.yaml SOUL.md; do
      adopt_file "$profile_live$file" "$PORTABLE/profiles/$profile/$file"
    done
    if [[ -d "${profile_live}scripts" ]]; then
      while IFS= read -r -d '' script; do
        adopt_file "$script" "$PORTABLE/profiles/$profile/scripts/${script#"${profile_live}scripts/"}"
      done < <(portable_scripts "${profile_live}scripts")
    fi
  done
  adopt_file "$HERMES_ROOT_DIR/SOUL.md" "$PORTABLE/default/SOUL.md"
  if [[ -d "$hooks" && ! -L "$hooks" ]]; then
    while IFS= read -r -d '' hook; do
      adopt_file "$hook" "$PORTABLE/hooks/${hook#"$hooks"/}"
    done < <(find "$hooks" -mindepth 1 \( -false "${HERMES_NEVER_COPY_FIND[@]}" \) -prune -o -type f -print0)
  fi
}

# A backup name nothing uses yet: <path>.bak-<stamp>, then -1, -2, ... if
# that exists (two heals in the same second must not overwrite each other).
backup_name() {
  local base="$1.bak-$STAMP" name="$1.bak-$STAMP" n=0
  while [[ -e "$name" || -L "$name" ]]; do n=$(( n + 1 )); name="$base-$n"; done
  printf '%s\n' "$name"
}

# Every file under a portable scripts/ dir, NUL-delimited, never-copy names
# pruned. Symlinks are listed too, so copy_script copies what they point at.
portable_scripts() {
  find "$1" -mindepth 1 \( -false "${HERMES_NEVER_COPY_FIND[@]}" \) -prune -o \( -type f -o -type l \) -print0
}

# copy_script <portable file> <live scripts dir> <path under it>: makes the
# live copy a real file with the portable content. A differing live file is
# backed up first; a live symlink is replaced, never written through (the new
# file is renamed over it), and a symlinked dir on the way is refused.
copy_script() {
  local src="$1" sub="$3" dst="$2/$3" d="$2" rest="$3" tmp bak
  [[ -f "$src" ]] || return 0
  while :; do
    if [[ -L "$d" ]]; then printf 'error: %s is a symlink; not copying %s through it\n' "$d" "$sub" >&2; FAILS=$(( FAILS + 1 )); return 0; fi
    [[ "$rest" == */* ]] || break
    d="$d/${rest%%/*}" rest="${rest#*/}"
  done
  if [[ -f "$dst" && ! -L "$dst" ]] && cmp -s "$src" "$dst"; then return 0; fi
  if [[ -d "$dst" && ! -L "$dst" ]]; then printf 'error: %s is a directory; left untouched\n' "$dst" >&2; FAILS=$(( FAILS + 1 )); return 0; fi
  mkdir -p "$(dirname "$dst")"
  if [[ -f "$dst" && ! -L "$dst" ]]; then
    bak="$(backup_name "$dst")"
    cp -p "$dst" "$bak"
    printf 'Backed up: %s → %s\n' "$dst" "$bak"
  fi
  # mv -T: a live symlink to a directory is replaced, not moved into.
  tmp="$(mktemp "$(dirname "$dst")/.install.XXXXXX")"
  if ! { cp "$src" "$tmp" && chmod --reference="$src" "$tmp" && mv -fT "$tmp" "$dst"; }; then
    rm -f "$tmp"
    printf 'error: cannot copy %s to %s\n' "$src" "$dst" >&2; FAILS=$(( FAILS + 1 )); return 0
  fi
  printf 'Copied: %s → %s\n' "${src#"$PORTABLE"/}" "$dst"
}

link_profiles() {
  local profile_src profile profile_dst file script dir
  for profile_src in "$PORTABLE"/profiles/*/; do
    [[ -d "$profile_src" ]] || continue
    profile="$(basename "$profile_src")"
    profile_dst="$PROFILES_DST/$profile"
    # Links and copies would land wherever a symlinked profile or scripts/
    # dir points, outside the Hermes root.
    for dir in "$profile_dst" "$profile_dst/scripts"; do
      if [[ -L "$dir" ]]; then
        printf 'error: %s is a symlink; profile %s left untouched\n' "$dir" "$profile" >&2
        FAILS=$(( FAILS + 1 )); continue 2
      fi
    done
    if [[ ! -d "$profile_dst" ]]; then
      hermes profile create --no-alias "$profile" >/dev/null
      [[ -d "$profile_dst" ]] || { printf 'error: hermes created %s outside %s\n' "$profile" "$PROFILES_DST" >&2; exit 1; }
      printf 'Created profile: %s\n' "$profile"
    fi
    for file in config.yaml profile.yaml SOUL.md; do
      [[ -f "$profile_src$file" ]] || continue
      link_replacing "$profile_src$file" "$profile_dst/$file"
    done
    # Hermes cron runs only real files inside the profile's scripts/ dir (a
    # symlink out of it is rejected), so scripts are copied, not linked.
    if [[ -d "${profile_src}scripts" ]]; then
      while IFS= read -r -d '' script; do
        copy_script "$script" "$profile_dst/scripts" "${script#"${profile_src}scripts/"}"
      done < <(portable_scripts "${profile_src}scripts")
      wait "$!" || { printf 'error: cannot list %sscripts\n' "$profile_src" >&2; FAILS=$(( FAILS + 1 )); }
    fi
  done
}

if (( DRY_RUN )); then
  if [[ -n "$SKIP_REASON" ]]; then printf 'Skipped portable files: %s\n' "$SKIP_REASON"; exit 0; fi
  adopt_all
  printf 'Dry run: nothing changed\n'
  exit 0
fi

mkdir -p "$LOCAL_BIN" "$WIDGETS_DST"
link "$REPO_DIR/bin/hermes-config" "$LOCAL_BIN/hermes-config"
for widget in "$REPO_DIR"/tui-widgets/*.mjs; do
  link "$widget" "$WIDGETS_DST/$(basename "$widget")"
done

if [[ -n "$SKIP_REASON" ]]; then
  printf 'Skipped portable files: %s\n' "$SKIP_REASON"
else
  if (( ADOPT )); then adopt_all; fi
  link_profiles
  if [[ -f "$PORTABLE/default/SOUL.md" ]]; then
    link_replacing "$PORTABLE/default/SOUL.md" "$HERMES_ROOT_DIR/SOUL.md"
  fi
  link_hooks
fi

if [[ -f "$REPO_DIR/.env" ]]; then
  printf '\nNext: hermes-config install && hermes-config migrate\n'
else
  printf '\nNext: cp %s/.env.example %s/.env, fill it in, then: hermes-config install\n' "$REPO_DIR" "$REPO_DIR"
fi

if (( FAILS )); then printf '\ninstall: %d problem(s); see the errors above\n' "$FAILS" >&2; exit 1; fi
