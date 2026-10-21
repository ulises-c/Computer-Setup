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
