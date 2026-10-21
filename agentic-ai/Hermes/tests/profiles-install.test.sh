#!/usr/bin/env bash
# Regression test for the profile root used by install.sh and validate.sh:
# default root, a named-profile HERMES_HOME, and a custom root (plus a named
# profile under it). Runs the real `hermes` CLI against a throwaway HOME and
# touches nothing under the real ~/.hermes.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v hermes >/dev/null || { printf 'skip: hermes not on PATH\n'; exit 0; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
FAILS=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1" >&2; FAILS=$(( FAILS + 1 )); }

# shellcheck source=../lib/hermes-root.sh
source "$REPO_DIR/lib/hermes-root.sh"
mapfile -t ROLES < <(find "$REPO_DIR/profiles" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)

expect_root() {
  local desc="$1" hermes_home="$2" want="$3" got
  got="$(unset HERMES_DATA_DIR_SUFFIX; HOME="$T/home" HERMES_HOME="$hermes_home" hermes_root)"
  if [[ "$got" == "$want" ]]; then pass "hermes_root: $desc"; else fail "hermes_root: $desc (got $got, want $want)"; fi
}

run_case() {
  local desc="$1" root="$2" hermes_home="$3" rc profile file
  local -a env_args=(env -u HERMES_HOME -u HERMES_DATA_DIR_SUFFIX HOME="$T/home" PATH="$PATH")
  [[ "$root" == "$T"/* ]] || { fail "$desc: refusing root outside the sandbox: $root"; return; }
  [[ -n "$hermes_home" ]] && env_args+=(HERMES_HOME="$hermes_home")
  for run in 1 2; do
    rc=0
    "${env_args[@]}" "$REPO_DIR/install.sh" >"$T/out" 2>&1 || rc=$?
    if (( rc )); then fail "$desc: install run $run rc=$rc"; sed 's/^/       /' "$T/out" >&2; return; fi
  done
  if grep -qE '^(Linked: profiles/|Copied: |Created profile|Backed up: )' "$T/out"; then
    fail "$desc: second install changed profiles"; sed 's/^/       /' "$T/out" >&2
  else
    pass "$desc: second install is a no-op for profiles"
  fi
  for profile in "${ROLES[@]}"; do
    for file in config.yaml profile.yaml SOUL.md; do
      [[ -L "$root/profiles/$profile/$file" ]] || { fail "$desc: $root/profiles/$profile/$file not linked"; continue 2; }
    done
    if [[ -n "$hermes_home" && "$hermes_home" != "$root" && -e "$hermes_home/profiles/$profile" ]]; then
      fail "$desc: nested $hermes_home/profiles/$profile created"
    fi
  done
  pass "$desc: all ${#ROLES[@]} roles linked under $root/profiles"
  rc=0
  "${env_args[@]}" "$REPO_DIR/validate.sh" >"$T/out" 2>&1 || rc=$?
  if (( rc )); then fail "$desc: validate rc=$rc"; grep -F '[FAIL]' "$T/out" | sed 's/^/       /' >&2; else pass "$desc: validate passes"; fi
}

printf '=== hermes_root ===\n'
expect_root "unset" "" "$T/home/.hermes"
expect_root "default root" "$T/home/.hermes" "$T/home/.hermes"
expect_root "named profile" "$T/home/.hermes/profiles/coder" "$T/home/.hermes"
# shellcheck disable=SC2088  # a literal ~ is the input under test
expect_root "tilde named profile" '~/.hermes/profiles/coder' "$T/home/.hermes"
expect_root "custom root" "$T/custom" "$T/custom"
expect_root "custom named profile" "$T/custom/profiles/coder" "$T/custom"

printf '\n=== install + validate ===\n'
mkdir -p "$T/home/.hermes"
run_case "default root" "$T/home/.hermes" ""
run_case "named-profile HERMES_HOME" "$T/home/.hermes" "$T/home/.hermes/profiles/review-openai"

default_before="$(find "$T/home/.hermes/profiles" | sort)"
mkdir -p "$T/custom"
run_case "custom root" "$T/custom" "$T/custom"
run_case "custom named-profile HERMES_HOME" "$T/custom" "$T/custom/profiles/review-openai"
if [[ "$(find "$T/home/.hermes/profiles" | sort)" == "$default_before" ]]; then
  pass "custom root: default root profiles untouched"
else
  fail "custom root: default root profiles changed"
fi

printf '\n'
if (( FAILS )); then printf '%d failure(s)\n' "$FAILS" >&2; exit 1; fi
printf 'all passed\n'
