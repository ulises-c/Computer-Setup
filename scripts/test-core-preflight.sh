#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

write_stub() {
  local name="$1"
  shift
  printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' "$@" > "$STUBS/$name"
  chmod +x "$STUBS/$name"
}

export SETUP_ROOT="$REPO_ROOT"
# shellcheck source=../lib/core.sh
source "$REPO_ROOT/lib/core.sh"

nvm_home="$WORK/nvm-home"
mkdir -p "$nvm_home"
printf '%s\n' \
  'registry=https://registry.npmjs.org/' \
  'prefix=/legacy/npm' \
  '  globalconfig = /legacy/npmrc' \
  'min-release-age=7' > "$nvm_home/.npmrc"
cp "$nvm_home/.npmrc" "$WORK/original.npmrc"

HOME="$nvm_home"
export NPM_CONFIG_PREFIX=/legacy/npm
export npm_config_prefix=/legacy/npm
export NPM_CONFIG_GLOBALCONFIG=/legacy/npmrc
export npm_config_globalconfig=/legacy/npmrc
prepare_nvm_environment >/dev/null

cmp -s "$nvm_home/.npmrc.nvm-preflight.bak" "$WORK/original.npmrc" \
  || fail 'nvm preflight backup does not match the original .npmrc'
! grep -Eq '^[[:space:]]*(prefix|globalconfig)[[:space:]]*=' "$nvm_home/.npmrc" \
  || fail 'nvm-incompatible settings remain in .npmrc'
grep -Fx 'registry=https://registry.npmjs.org/' "$nvm_home/.npmrc" >/dev/null \
  || fail 'nvm preflight removed an unrelated registry setting'
grep -Fx 'min-release-age=7' "$nvm_home/.npmrc" >/dev/null \
  || fail 'nvm preflight removed the npm release-age setting'
for variable in NPM_CONFIG_PREFIX npm_config_prefix NPM_CONFIG_GLOBALCONFIG npm_config_globalconfig; do
  ! declare -p "$variable" >/dev/null 2>&1 || fail "$variable remained set after nvm preflight"
done
cp "$nvm_home/.npmrc" "$WORK/clean.npmrc"
[[ -z "$(prepare_nvm_environment)" ]] || fail 'idempotent nvm preflight produced output'
cmp -s "$nvm_home/.npmrc" "$WORK/clean.npmrc" \
  || fail 'idempotent nvm preflight changed .npmrc'

STUBS="$WORK/stubs"
mkdir -p "$STUBS"
SUDO_LOG="$WORK/sudo.log"
export SUDO_LOG
write_stub sudo \
  'printf "%s\n" "$*" >> "$SUDO_LOG"' \
  'if [[ "${1:-}" == "-v" && "${SUDO_VALIDATE_FAIL:-false}" == true ]]; then exit 1; fi'
write_stub sleep 'exit 1'
PATH="$STUBS:$PATH"

export DRY_RUN=true
: > "$SUDO_LOG"
dry_run_output="$(core_prime_sudo)"
[[ "$dry_run_output" == *'[dry-run] sudo -v'* ]] \
  || fail 'sudo dry run did not describe credential priming'
[[ ! -s "$SUDO_LOG" ]] || fail 'sudo dry run executed sudo'

export DRY_RUN=false
: > "$SUDO_LOG"
core_prime_sudo >/dev/null
keepalive_pid="$!"
wait "$keepalive_pid" 2>/dev/null || true
sudo_calls=()
while IFS= read -r call; do sudo_calls+=("$call"); done < "$SUDO_LOG"
[[ "${#sudo_calls[@]}" == 2 ]] || fail "expected two sudo calls, found ${#sudo_calls[@]}"
[[ "${sudo_calls[0]}" == '-v' ]] || fail 'sudo validation was not the first call'
[[ "${sudo_calls[1]}" == '-n true' ]] || fail 'sudo keepalive did not use non-interactive refresh'

: > "$SUDO_LOG"
export SUDO_VALIDATE_FAIL=true
if core_prime_sudo >/dev/null 2>&1; then
  fail 'failed sudo validation did not abort the preflight'
fi
unset SUDO_VALIDATE_FAIL
sudo_calls=()
while IFS= read -r call; do sudo_calls+=("$call"); done < "$SUDO_LOG"
[[ "${#sudo_calls[@]}" == 1 && "${sudo_calls[0]}" == '-v' ]] \
  || fail 'failed sudo validation started the keepalive'

printf 'core preflight tests passed.\n'
