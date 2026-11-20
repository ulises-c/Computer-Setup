# shellcheck shell=bash
# Profiles are siblings under the Hermes root, not children of the active
# HERMES_HOME. This mirrors hermes_constants.get_default_hermes_root() so
# install.sh and validate.sh look where `hermes profile create` writes.
hermes_root() {
  local native="$HOME/.hermes${HERMES_DATA_DIR_SUFFIX:-}" env_home="${HERMES_HOME:-}"
  if [[ -z "$env_home" ]]; then
    printf '%s\n' "$native"
    return
  fi
  [[ "$env_home" == \~ || "$env_home" == \~/* ]] && env_home="$HOME${env_home#\~}"
  local env_real native_real
  env_real="$(realpath -m "$env_home")"
  native_real="$(realpath -m "$native")"
  if [[ "$env_real" == "$native_real" || "$env_real" == "$native_real"/* ]]; then
    printf '%s\n' "$native"
  elif [[ "$(basename "$(dirname "$env_home")")" == profiles ]]; then
    dirname "$(dirname "$env_home")"
  else
    printf '%s\n' "$env_home"
  fi
}

# The portable dir is the private config repo whose profiles/, default/ and
# hooks/ install.sh links into the Hermes root. It reads the same .env as
# bin/hermes-config: sourced as shell in a subshell, so its variables do not
# reach the caller, but any command in it runs. Like load_env it counts a
# repo only when its REMOTE is set: a personal-only .env
# that kept WORK_DIR from .env.example still resolves to the personal repo.
# Prints nothing when none is configured. A relative dir is made absolute
# from the current dir: a link stores its target as given, and a relative
# target would be read from the link's own dir.
hermes_portable_dir() {
  local repo_dir="$1" dir="${HERMES_PORTABLE_DIR:-}"
  local env_file="${HERMES_CONFIG_SYNC_ENV:-$repo_dir/.env}"
  if [[ -z "$dir" && -f "$env_file" ]]; then
    dir="$(
      set -a
      # shellcheck source=/dev/null
      source "$env_file" >/dev/null
      set +a
      if [[ -n "${HERMES_PORTABLE_DIR:-}" ]]; then printf '%s' "$HERMES_PORTABLE_DIR"
      elif [[ -n "${HERMES_CONFIG_SYNC_WORK_REMOTE:-}" ]]; then printf '%s' "${HERMES_CONFIG_SYNC_WORK_DIR:-}"
      elif [[ -n "${HERMES_CONFIG_SYNC_PERSONAL_REMOTE:-}" ]]; then printf '%s' "${HERMES_CONFIG_SYNC_PERSONAL_DIR:-}"
      fi
    )"
  fi
  [[ -n "$dir" ]] || return 0
  dir="${dir/#\~/$HOME}"
  [[ "$dir" == /* ]] || dir="$PWD/${dir#./}"
  printf '%s\n' "$dir"
}

# 0 when the two dirs are the same or one holds the other, after resolving
# symlinks. A portable dir that overlaps the Hermes root would have install.sh
# replace live files with links to themselves.
hermes_paths_overlap() {
  local a b
  a="$(realpath -m -- "$1")" b="$(realpath -m -- "$2")"
  [[ "$a" == / || "$b" == / || "$a" == "$b" || "$a" == "$b"/* || "$b" == "$a"/* ]]
}
