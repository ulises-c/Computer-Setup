#!/usr/bin/env bash
# Regression test for install.sh and validate.sh: the profile root (default
# root, a named-profile HERMES_HOME, a custom root), the portable dir they
# link from (profiles, default/SOUL.md, hooks), --adopt, --take-live and the
# default heal. Runs the real `hermes` CLI against a throwaway HOME and a
# temp portable dir, and touches nothing under the real ~/.hermes.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v hermes >/dev/null || { printf 'skip: hermes not on PATH\n'; exit 0; }

T="$(mktemp -d)"
SBHOME="$T/home" # the sandbox home; a variable keeps the privacy check from reading these as real home paths
trap 'rm -rf "$T"' EXIT
FAILS=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1" >&2; FAILS=$(( FAILS + 1 )); }
expect_rc() {
  local want="$1" desc="$2" rc=0
  shift 2
  "$@" >"$T/out" 2>&1 || rc=$?
  if [[ "$rc" == "$want" ]]; then pass "$desc"; else fail "$desc (rc=$rc, want $want)"; sed 's/^/       /' "$T/out" >&2; fi
}
check() {
  local desc="$1"
  shift
  if "$@" >/dev/null; then pass "$desc"; else fail "$desc"; fi
}
expect_out() { if grep -qE -- "$1" "$T/out"; then pass "$2"; else fail "$2"; sed 's/^/       /' "$T/out" >&2; fi; }
reject_out() { reject_out_of "$1" "$T/out" "$2"; }
# reject_out_of <regex> <file> <desc>: passes only when grep ran and found
# no match; a grep error is a failure, not proof of absence.
reject_out_of() {
  local rc=0
  grep -qE -- "$1" "$2" || rc=$?
  case "$rc" in 1) pass "$3" ;; 0) fail "$3"; sed 's/^/       /' "$2" >&2 ;; *) fail "$3 (grep failed, rc=$rc)" ;; esac
}
# none_found <desc> <find args...>: passes only when find succeeds and
# prints nothing.
none_found() {
  local desc="$1" rc=0
  shift
  find "$@" -print > "$T/inspect" 2>&1 || rc=$?
  if (( rc )); then fail "$desc (find failed, rc=$rc)"; sed 's/^/       /' "$T/inspect" >&2
  elif [[ -s "$T/inspect" ]]; then fail "$desc (found)"; sed 's/^/       /' "$T/inspect" >&2
  else pass "$desc"; fi
}
# Every path, type, mode and link target under the given paths (relative to
# $T), plus each file's content hash: a same-size edit still shows.
tree_sum() { (cd "$T" && find "$@" -printf '%p %y %m %l\n' | LC_ALL=C sort && find "$@" -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum); }
linked_to() { [[ -L "$1" && "$(readlink "$1")" == "$2" ]]; }
real_file() { [[ -f "$1" && ! -L "$1" ]]; }
# Lines that mean install.sh changed a portable link, copy or backup.
CHANGED='^(Linked: (profiles/|default/|hooks)|Copied: |Created profile|Backed up: |Moved aside: |Took live: |Adopted: )'

printf '=== test helpers ===\n'
# A negative check must fail, not pass, when its inspection fails.
# helper_counts <n> <desc> <helper call...>: the call must record exactly n
# failures; they are then taken back, so only this check's result counts.
helper_counts() {
  local want="$1" desc="$2" before="$FAILS"
  shift 2
  "$@" >/dev/null 2>&1
  local got=$(( FAILS - before ))
  FAILS="$before"
  if (( got == want )); then pass "$desc"; else fail "$desc (recorded $got failures, want $want)"; fi
}
helper_fails() { helper_counts 1 "$@"; }
helper_fails "none_found fails when find fails" none_found x "$T/no-such-dir"
helper_fails "reject_out_of fails when grep fails" reject_out_of x "$T/no-such-file" x
printf 'needle\n' > "$T/hay"
helper_fails "reject_out_of fails on a match" reject_out_of needle "$T/hay" x
mkdir -p "$T/sum/d" && printf 'aaaa\n' > "$T/sum/d/f" && sum_before="$(tree_sum sum)" && printf 'bbbb\n' > "$T/sum/d/f"
check "tree_sum sees a same-size content change" test "$(tree_sum sum)" != "$sum_before"
rm -r "$T/sum" "$T/hay"

# shellcheck source=../lib/hermes-root.sh
source "$REPO_DIR/lib/hermes-root.sh"

# A clean environment (env -i): the caller's Hermes session variables
# (gateway, kanban, profile pins) must not reach the sandboxed CLI, and no
# .env is read, so the portable dir comes only from the case.
# usage: run <home> <portable or ''> <script> [args...]; extra env in EXTRA_ENV.
EXTRA_ENV=()
run() {
  local home="$1" portable="$2" script="$3"
  shift 3
  local -a env_args=(env -i HOME="$home" PATH="$PATH" HERMES_CONFIG_SYNC_ENV="$T/none.env" "${EXTRA_ENV[@]}")
  [[ -n "${TMPDIR:-}" ]] && env_args+=(TMPDIR="$TMPDIR")
  [[ -n "$portable" ]] && env_args+=(HERMES_PORTABLE_DIR="$portable")
  "${env_args[@]}" "$REPO_DIR/$script" "$@"
}

# Two roles: alpha has all three files and a cron script, beta has no SOUL.md.
make_portable() {
  local p="$1"
  mkdir -p "$p/profiles/alpha/scripts" "$p/profiles/beta" "$p/default" "$p/hooks/lib" "$p/skills"
  printf 'description: alpha test role\ndescription_auto: false\n' > "$p/profiles/alpha/profile.yaml"
  printf '# alpha config\n' > "$p/profiles/alpha/config.yaml"
  printf 'You are alpha.\n' > "$p/profiles/alpha/SOUL.md"
  printf '#!/bin/sh\necho job\n' > "$p/profiles/alpha/scripts/job.sh"
  chmod +x "$p/profiles/alpha/scripts/job.sh"
  printf 'description: beta test role\ndescription_auto: false\n' > "$p/profiles/beta/profile.yaml"
  printf '# beta config\n' > "$p/profiles/beta/config.yaml"
  printf 'You are the default agent.\n' > "$p/default/SOUL.md"
  printf '#!/bin/sh\nexit 0\n' > "$p/hooks/gate.sh"
  printf 'X = 1\n' > "$p/hooks/lib/util.py"
}

# A sandbox Hermes root whose profile dirs already exist, so install.sh skips
# `hermes profile create` (fast; used by the scenario cases).
make_home() {
  local home="$1" profile
  mkdir -p "$home/.hermes"
  for profile in "${@:2}"; do mkdir -p "$home/.hermes/profiles/$profile"; done
}

printf '=== hermes_root ===\n'
expect_root() {
  local desc="$1" hermes_home="$2" want="$3" got
  got="$(unset HERMES_DATA_DIR_SUFFIX; HOME="$T/home" HERMES_HOME="$hermes_home" hermes_root)"
  if [[ "$got" == "$want" ]]; then pass "hermes_root: $desc"; else fail "hermes_root: $desc (got $got, want $want)"; fi
}
expect_root "unset" "" "$SBHOME/.hermes"
expect_root "default root" "$SBHOME/.hermes" "$SBHOME/.hermes"
expect_root "named profile" "$SBHOME/.hermes/profiles/coder" "$SBHOME/.hermes"
# shellcheck disable=SC2088  # a literal ~ is the input under test
expect_root "tilde named profile" '~/.hermes/profiles/coder' "$SBHOME/.hermes"
expect_root "custom root" "$T/custom" "$T/custom"
expect_root "custom named profile" "$T/custom/profiles/coder" "$T/custom"

printf '\n=== hermes_portable_dir ===\n'
expect_portable() {
  local desc="$1" env_var="$2" env_file="$3" want="$4" got
  # shellcheck disable=SC2016  # expanded by the inner bash
  got="$(env -i HOME="$T/home" PATH="$PATH" HERMES_PORTABLE_DIR="$env_var" HERMES_CONFIG_SYNC_ENV="$env_file" \
    bash -c 'source "$1"; hermes_portable_dir "$2"' _ "$REPO_DIR/lib/hermes-root.sh" "$REPO_DIR")"
  if [[ "$got" == "$want" ]]; then pass "hermes_portable_dir: $desc"; else fail "hermes_portable_dir: $desc (got '$got', want '$want')"; fi
}
# shellcheck disable=SC2016  # $HOME is expanded when the .env is sourced
{
  printf 'HERMES_PORTABLE_DIR=$HOME/p-env\nHERMES_CONFIG_SYNC_WORK_REMOTE=x\nHERMES_CONFIG_SYNC_WORK_DIR=$HOME/work\n' > "$T/portable.env"
  printf 'HERMES_CONFIG_SYNC_WORK_REMOTE=x\nHERMES_CONFIG_SYNC_WORK_DIR=$HOME/work\nHERMES_CONFIG_SYNC_PERSONAL_REMOTE=y\nHERMES_CONFIG_SYNC_PERSONAL_DIR=$HOME/personal\n' > "$T/both.env"
  # Personal-only: WORK_DIR left over from .env.example, but no WORK_REMOTE.
  printf 'HERMES_CONFIG_SYNC_WORK_DIR=$HOME/work\nHERMES_CONFIG_SYNC_PERSONAL_REMOTE=y\nHERMES_CONFIG_SYNC_PERSONAL_DIR=$HOME/personal\n' > "$T/personal.env"
}
expect_portable "environment wins over .env" "$T/p-var" "$T/portable.env" "$T/p-var"
expect_portable ".env HERMES_PORTABLE_DIR" "" "$T/portable.env" "$SBHOME/p-env"
expect_portable ".env work repo dir" "" "$T/both.env" "$SBHOME/work"
expect_portable ".env personal-only (work dir ignored without its remote)" "" "$T/personal.env" "$SBHOME/personal"
expect_portable "nothing configured" "" "$T/none.env" ""
# shellcheck disable=SC2088  # a literal ~ is the input under test
expect_portable "tilde expanded" '~/p' "$T/none.env" "$SBHOME/p"
expect_portable "relative made absolute from the cwd" './p' "$T/none.env" "$PWD/p"

printf '\n=== install + validate (real hermes profile create) ===\n'
P="$T/portable"
make_portable "$P"
run_case() {
  local desc="$1" root="$2" hermes_home="$3" rc n
  [[ "$root" == "$T"/* ]] || { fail "$desc: refusing root outside the sandbox: $root"; return; }
  EXTRA_ENV=()
  [[ -n "$hermes_home" ]] && EXTRA_ENV=(HERMES_HOME="$hermes_home")
  for n in 1 2; do
    rc=0
    run "$T/home" "$P" install.sh >"$T/out" 2>&1 || rc=$?
    if (( rc )); then fail "$desc: install run $n rc=$rc"; sed 's/^/       /' "$T/out" >&2; EXTRA_ENV=(); return; fi
  done
  reject_out "$CHANGED" "$desc: second install is a no-op for portable files"
  check "$desc: alpha config.yaml linked from the portable dir" linked_to "$root/profiles/alpha/config.yaml" "$P/profiles/alpha/config.yaml"
  check "$desc: alpha profile.yaml linked" linked_to "$root/profiles/alpha/profile.yaml" "$P/profiles/alpha/profile.yaml"
  check "$desc: alpha SOUL.md linked" linked_to "$root/profiles/alpha/SOUL.md" "$P/profiles/alpha/SOUL.md"
  check "$desc: beta (no SOUL.md) still links config.yaml" linked_to "$root/profiles/beta/config.yaml" "$P/profiles/beta/config.yaml"
  check "$desc: beta profile.yaml linked" linked_to "$root/profiles/beta/profile.yaml" "$P/profiles/beta/profile.yaml"
  check "$desc: beta SOUL.md not a link" test ! -L "$root/profiles/beta/SOUL.md"
  check "$desc: script copied, not linked" real_file "$root/profiles/alpha/scripts/job.sh"
  check "$desc: copied script matches" cmp -s "$root/profiles/alpha/scripts/job.sh" "$P/profiles/alpha/scripts/job.sh"
  check "$desc: default/SOUL.md linked at the root" linked_to "$root/SOUL.md" "$P/default/SOUL.md"
  check "$desc: hooks linked as agent-hooks" linked_to "$root/agent-hooks" "$P/hooks"
  if [[ -n "$hermes_home" && "$hermes_home" != "$root" ]]; then
    check "$desc: no nested profiles under HERMES_HOME" test ! -e "$hermes_home/profiles/alpha"
  fi
  rc=0
  run "$T/home" "$P" validate.sh >"$T/out" 2>&1 || rc=$?
  if (( rc )); then fail "$desc: validate rc=$rc"; grep -F '[FAIL]' "$T/out" | sed 's/^/       /' >&2; else pass "$desc: validate passes"; fi
  EXTRA_ENV=()
}
mkdir -p "$SBHOME/.hermes"
run_case "default root" "$SBHOME/.hermes" ""
run_case "named-profile HERMES_HOME" "$SBHOME/.hermes" "$SBHOME/.hermes/profiles/alpha"

default_before="$(find "$SBHOME/.hermes/profiles" | sort)"
mkdir -p "$T/custom"
run_case "custom root" "$T/custom" "$T/custom"
run_case "custom named-profile HERMES_HOME" "$T/custom" "$T/custom/profiles/alpha"
if [[ "$(find "$SBHOME/.hermes/profiles" | sort)" == "$default_before" ]]; then
  pass "custom root: default root profiles untouched"
else
  fail "custom root: default root profiles changed"
fi

printf '\n=== heal: regular file where a link belongs ===\n'
# Reuses the default-root sandbox above, whose profiles hermes created.
H="$T/home"
# What `sed -i` does to a symlink: a regular file with the edited content.
rm "$H/.hermes/profiles/alpha/config.yaml"
printf '# edited live\n' > "$H/.hermes/profiles/alpha/config.yaml"
expect_rc 1 "heal: validate fails on the regular file" run "$H" "$P" validate.sh
expect_out 'alpha/config\.yaml is a regular file.*install\.sh --take-live' "heal: validate names both fixes"
expect_rc 0 "heal default: install exits 0" run "$H" "$P" install.sh
expect_out '^Backed up: .*alpha/config\.yaml' "heal default: live file backed up"
check "heal default: relinked" linked_to "$H/.hermes/profiles/alpha/config.yaml" "$P/profiles/alpha/config.yaml"
check "heal default: portable copy wins" grep -qx '# alpha config' "$P/profiles/alpha/config.yaml"
check "heal default: backup holds the live edit" grep -qx '# edited live' "$H"/.hermes/profiles/alpha/config.yaml.bak-*
rm "$H/.hermes/profiles/alpha/SOUL.md"
printf 'You are alpha, edited live.\n' > "$H/.hermes/profiles/alpha/SOUL.md"
# The first install already backed up the SOUL.md that hermes created.
backups_before="$(compgen -G "$H/.hermes/profiles/alpha/SOUL.md.bak-*" || true)"
expect_rc 0 "take-live: install exits 0" run "$H" "$P" install.sh --take-live
expect_out '^Took live: .*alpha/SOUL\.md' "take-live: prints the file"
check "take-live: live content copied to portable" grep -qx 'You are alpha, edited live.' "$P/profiles/alpha/SOUL.md"
check "take-live: relinked" linked_to "$H/.hermes/profiles/alpha/SOUL.md" "$P/profiles/alpha/SOUL.md"
check "take-live: no new backup" test "$(compgen -G "$H/.hermes/profiles/alpha/SOUL.md.bak-*" || true)" == "$backups_before"
expect_rc 0 "heal: validate passes again" run "$H" "$P" validate.sh
expect_rc 0 "heal: rerun exits 0" run "$H" "$P" install.sh
reject_out "$CHANGED" "heal: rerun is a no-op"

printf '\n=== no portable dir ===\n'
H="$T/s-none"
make_home "$H"
expect_rc 0 "no portable dir: install exits 0" run "$H" "" install.sh
expect_out '^Skipped portable files: no portable dir configured' "no portable dir: one clear message"
check "no portable dir: hermes-config on PATH" linked_to "$H/.local/bin/hermes-config" "$REPO_DIR/bin/hermes-config"
widget="$(find "$REPO_DIR/tui-widgets" -name '*.mjs' -print -quit)"
check "no portable dir: widgets linked" linked_to "$H/.hermes/tui-widgets/$(basename "$widget")" "$widget"
check "this repo no longer carries profiles/" test ! -e "$REPO_DIR/profiles"
expect_rc 0 "missing portable dir: install exits 0" run "$H" "$T/not-cloned" install.sh
expect_out "^Skipped portable files: portable dir $T/not-cloned not found" "missing portable dir: says so"
expect_rc 0 "no portable dir: validate passes" run "$H" "" validate.sh
expect_out '\[WARN\] no portable dir configured' "no portable dir: validate warns"

printf '\n=== relative portable dir ===\n'
# A link stores its target as given, and a relative one is read from the
# link's own dir, so ./portable must become absolute first.
in_dir() { local d="$1"; shift; (cd "$d" && "$@"); }
H="$T/s-rel"; make_home "$H" alpha beta; mkdir -p "$T/relcwd"; make_portable "$T/relcwd/portable"
expect_rc 0 "relative portable dir: install exits 0" in_dir "$T/relcwd" run "$H" ./portable install.sh
check "relative portable dir: SOUL.md link target is absolute" bash -c "[[ \"\$(readlink '$H/.hermes/SOUL.md')\" == /* ]]"
check "relative portable dir: SOUL.md readable through the link" grep -qx 'You are the default agent.' "$H/.hermes/SOUL.md"
check "relative portable dir: profile file linked to the absolute path" linked_to "$H/.hermes/profiles/alpha/config.yaml" "$T/relcwd/portable/profiles/alpha/config.yaml"
expect_rc 0 "relative portable dir: validate passes from another cwd with the absolute path" in_dir "$T" run "$H" "$T/relcwd/portable" validate.sh

printf '\n=== hooks dir ===\n'
H="$T/s-hooks-same"; P2="$T/p-hooks-same"
make_portable "$P2"; make_home "$H" alpha beta
cp -r "$P2/hooks" "$H/.hermes/agent-hooks"
mkdir -p "$H/.hermes/agent-hooks/__pycache__"; printf 'cache' > "$H/.hermes/agent-hooks/__pycache__/gate.pyc"
expect_rc 0 "identical hooks dir: install exits 0" run "$H" "$P2" install.sh
check "identical hooks dir: now linked" linked_to "$H/.hermes/agent-hooks" "$P2/hooks"
expect_out '^Moved aside: .*/agent-hooks → .*/agent-hooks\.bak-' "identical hooks dir: reports the move"
check "identical hooks dir: old dir kept aside" compgen -G "$H/.hermes/agent-hooks.bak-*/gate.sh"
expect_rc 0 "linked hooks dir: rerun exits 0" run "$H" "$P2" install.sh
reject_out '(Moved aside|Linked: hooks)' "linked hooks dir: rerun leaves it alone"

H="$T/s-hooks-diff"; P2="$T/p-hooks-diff"
make_portable "$P2"; make_home "$H" alpha beta
cp -r "$P2/hooks" "$H/.hermes/agent-hooks"
printf '#!/bin/sh\nexit 1\n' > "$H/.hermes/agent-hooks/gate.sh"
printf 'live only\n' > "$H/.hermes/agent-hooks/extra.sh"
expect_rc 1 "differing hooks dir: install reports failure" run "$H" "$P2" install.sh
expect_out 'gate\.sh.*differ' "differing hooks dir: names the differing file"
expect_out 'extra\.sh' "differing hooks dir: names the live-only file"
expect_out 'resolve:' "differing hooks dir: says how to resolve"
check "differing hooks dir: left a real dir" test ! -L "$H/.hermes/agent-hooks"
check "differing hooks dir: content untouched" grep -q 'exit 1' "$H/.hermes/agent-hooks/gate.sh"
check "differing hooks dir: other links still done" linked_to "$H/.hermes/profiles/alpha/config.yaml" "$P2/profiles/alpha/config.yaml"

printf '\n=== portable dir overlapping the Hermes root ===\n'
H="$T/s-overlap"; R="$H/.hermes"
make_home "$H" alpha
printf '# live alpha config\n' > "$R/profiles/alpha/config.yaml"
printf 'description: alpha\n' > "$R/profiles/alpha/profile.yaml"
mkdir -p "$R/hooks" && printf 'x\n' > "$R/hooks/gate.sh"
ln -s "$R" "$T/root-link"
overlap_intact() {
  real_file "$R/profiles/alpha/config.yaml" && real_file "$R/profiles/alpha/profile.yaml" \
    && grep -qx '# live alpha config' "$R/profiles/alpha/config.yaml" && grep -qx 'description: alpha' "$R/profiles/alpha/profile.yaml" \
    && [[ ! -e "$R/agent-hooks" && ! -e "$H/.local/bin/hermes-config" ]]
}
for case in "root:$R" "symlink to the root:$T/root-link" "inside the root:$R/profiles" "holds the root:$H"; do
  expect_rc 1 "overlap, ${case%%:*}: install refused" run "$H" "${case#*:}" install.sh
  expect_out 'overlaps the Hermes root' "overlap, ${case%%:*}: says why"
  check "overlap, ${case%%:*}: profile files unchanged, still regular, nothing installed" overlap_intact
done
expect_rc 1 "overlap: validate fails" run "$H" "$T/root-link" validate.sh
expect_out 'overlaps the Hermes root' "overlap: validate says why"

# A portable file that is the live file under another name (a symlink to it,
# or a hard link) must not be replaced by a link to itself.
H="$T/s-alias"; P3="$T/p-alias"
make_home "$H" alpha
mkdir -p "$P3/profiles/alpha"
printf '# shared config\n' > "$H/.hermes/profiles/alpha/config.yaml"
ln -s "$H/.hermes/profiles/alpha/config.yaml" "$P3/profiles/alpha/config.yaml"
printf 'description: shared\n' > "$H/.hermes/profiles/alpha/profile.yaml"
ln "$H/.hermes/profiles/alpha/profile.yaml" "$P3/profiles/alpha/profile.yaml"
expect_rc 1 "same-file alias: install reports failure" run "$H" "$P3" install.sh
expect_out 'config\.yaml .*are the same file' "same-file alias: names the symlinked one"
expect_out 'profile\.yaml .*are the same file' "same-file alias: names the hard-linked one"
check "same-file alias: live files still regular with their content" bash -c "[[ -f '$H/.hermes/profiles/alpha/config.yaml' && ! -L '$H/.hermes/profiles/alpha/config.yaml' && ! -L '$H/.hermes/profiles/alpha/profile.yaml' ]] && grep -qx '# shared config' '$H/.hermes/profiles/alpha/config.yaml' && grep -qx 'description: shared' '$H/.hermes/profiles/alpha/profile.yaml'"

printf '\n=== profile scripts ===\n'
H="$T/s-scripts"; P3="$T/p-scripts"; L="$H/.hermes/profiles/alpha/scripts"
make_portable "$P3"; make_home "$H" alpha beta
mkdir -p "$P3/profiles/alpha/scripts/lib" "$P3/profiles/alpha/scripts/__pycache__" "$L"
printf 'helper v1\n' > "$P3/profiles/alpha/scripts/lib/util.sh"
printf 'portable other\n' > "$P3/profiles/alpha/scripts/other.sh"
printf 'bytecode\n' > "$P3/profiles/alpha/scripts/__pycache__/x.pyc"
printf '#!/bin/sh\necho live edit\n' > "$L/job.sh"
printf 'outside\n' > "$T/outside-target.sh"
ln -s "$T/outside-target.sh" "$L/other.sh"
expect_rc 0 "scripts: install exits 0" run "$H" "$P3" install.sh
expect_out '^Backed up: .*alpha/scripts/job\.sh' "scripts: differing live script backed up"
check "scripts: backup holds the live edit" grep -qx 'echo live edit' "$L"/job.sh.bak-*
check "scripts: differing live script replaced" cmp -s "$L/job.sh" "$P3/profiles/alpha/scripts/job.sh"
check "scripts: symlinked destination now a real file with the portable content" bash -c "[[ -f '$L/other.sh' && ! -L '$L/other.sh' ]] && cmp -s '$L/other.sh' '$P3/profiles/alpha/scripts/other.sh'"
check "scripts: the symlink's target untouched" grep -qx outside "$T/outside-target.sh"
check "scripts: nested script installed" bash -c "[[ -f '$L/lib/util.sh' && ! -L '$L/lib/util.sh' ]] && cmp -s '$L/lib/util.sh' '$P3/profiles/alpha/scripts/lib/util.sh'"
check "scripts: never-copy names not installed" test ! -e "$L/__pycache__"
expect_rc 0 "scripts: validate passes" run "$H" "$P3" validate.sh
expect_out 'alpha/scripts/lib/util\.sh matches' "scripts: validate checks the nested script"
printf 'drift\n' > "$L/lib/util.sh"
expect_rc 1 "scripts: validate fails on a drifted nested script" run "$H" "$P3" validate.sh
expect_out 'alpha/scripts/lib/util\.sh missing or differs' "scripts: validate names it"
rm "$L/lib/util.sh"; ln -s "$T/outside-target.sh" "$L/lib/util.sh"
expect_rc 1 "scripts: validate fails on a symlinked script" run "$H" "$P3" validate.sh
expect_out 'alpha/scripts/lib/util\.sh missing or differs' "scripts: validate names the symlinked one"
expect_rc 0 "scripts: install heals both" run "$H" "$P3" install.sh
check "scripts: healed to a real file, target untouched" bash -c "[[ ! -L '$L/lib/util.sh' ]] && cmp -s '$L/lib/util.sh' '$P3/profiles/alpha/scripts/lib/util.sh' && grep -qx outside '$T/outside-target.sh'"
expect_rc 0 "scripts: rerun exits 0" run "$H" "$P3" install.sh
reject_out "$CHANGED" "scripts: rerun is a no-op"
mkdir -p "$T/outside-dir"; rm -r "${L:?}/lib"; ln -s "$T/outside-dir" "$L/lib"
expect_rc 1 "scripts: a symlinked dir inside scripts/ is refused" run "$H" "$P3" install.sh
expect_out 'lib is a symlink' "scripts: says which dir"
none_found "scripts: nothing written through the dir link" "$T/outside-dir" -mindepth 1

printf '\n=== symlinked live dirs ===\n'
# A live script that is a link to an outside dir: a plain `mv` would move the
# new file into that dir.
H="$T/s-leafdir"; P3="$T/p-leafdir"; L="$H/.hermes/profiles/alpha/scripts"
make_portable "$P3"; make_home "$H" alpha beta
mkdir -p "$L" "$T/outside-leaf"; ln -s "$T/outside-leaf" "$L/job.sh"
expect_rc 0 "leaf link to a dir: install exits 0" run "$H" "$P3" install.sh
check "leaf link to a dir: now a real file with the portable content" bash -c "[[ -f '$L/job.sh' && ! -L '$L/job.sh' ]] && cmp -s '$L/job.sh' '$P3/profiles/alpha/scripts/job.sh'"
none_found "leaf link to a dir: nothing written into it" "$T/outside-leaf" -mindepth 1
expect_rc 0 "leaf link to a dir: validate passes" run "$H" "$P3" validate.sh
# A symlinked profile dir, or scripts/ dir: install would work through it.
# Refused before anything in that profile changes; validate fails too.
for what in profile scripts; do
  H="$T/s-$what-link"; P3="$T/p-$what-link"; R="$H/.hermes/profiles/alpha"
  make_portable "$P3"; make_home "$H" alpha beta
  expect_rc 0 "$what dir link: first install" run "$H" "$P3" install.sh
  if [[ $what == profile ]]; then mv "$R" "$T/outside-$what"; ln -s "$T/outside-$what" "$R"; want='profiles/alpha is a symlink'
  else mv "$R/scripts" "$T/outside-$what"; ln -s "$T/outside-$what" "$R/scripts"; want='alpha/scripts is a symlink'; fi
  expect_rc 1 "$what dir link: validate fails" run "$H" "$P3" validate.sh
  expect_out "$want" "$what dir link: validate says which dir"
  # Give install something to change in that profile.
  rm "$R/config.yaml"; printf 'drift\n' > "$R/scripts/job.sh"
  before="$(tree_sum "s-$what-link" "outside-$what")"
  expect_rc 1 "$what dir link: install refused" run "$H" "$P3" install.sh
  expect_out "$want" "$what dir link: install says which dir"
  check "$what dir link: nothing in the profile or its target changed" test "$(tree_sum "s-$what-link" "outside-$what")" == "$before"
  check "$what dir link: other profiles still linked" linked_to "$H/.hermes/profiles/beta/config.yaml" "$P3/profiles/beta/config.yaml"
done
# The same refusal when HERMES_HOME is that profile: the widgets go into it,
# so it is refused before anything is written, there or in its target. A
# trailing slash on HERMES_HOME (slash) must not make -L follow the link.
for what in profile slash scripts; do
  H="$T/s-active-$what"; P3="$T/p-active-$what"; R="$H/.hermes/profiles/alpha"; O="$T/outside-active-$what"
  make_portable "$P3"; make_home "$H" alpha beta
  if [[ $what != scripts ]]; then mv "$R" "$O"; ln -s "$O" "$R"; want='profiles/alpha is a symlink'
  else mkdir -p "$O"; ln -s "$O" "$R/scripts"; want='alpha/scripts is a symlink'; fi
  before="$(tree_sum "s-active-$what" "outside-active-$what")"
  EXTRA_ENV=(HERMES_HOME="$R")
  [[ $what == slash ]] && EXTRA_ENV=(HERMES_HOME="$R/")
  expect_rc 1 "active $what dir link: install refused" run "$H" "$P3" install.sh
  EXTRA_ENV=()
  expect_out "$want" "active $what dir link: install says which dir"
  check "active $what dir link: no tui-widgets in the profile or the link target" bash -c "[[ ! -e '$R/tui-widgets' && ! -e '$O/tui-widgets' ]]"
  check "active $what dir link: nothing in the home or the link target changed" test "$(tree_sum "s-active-$what" "outside-active-$what")" == "$before"
done

printf '\n=== backups never clobber; --take-live keeps the old portable copy ===\n'
H="$T/s-bak"; P3="$T/p-bak"; R="$H/.hermes"; ST=20300101-000000
make_portable "$P3"; make_home "$H" alpha beta
mkdir -p "$T/fakedate" && printf '#!/bin/sh\necho %s\n' "$ST" > "$T/fakedate/date" && chmod +x "$T/fakedate/date"
FAKE_PATH="$T/fakedate:$PATH"
printf '# live edit one\n' > "$R/profiles/alpha/config.yaml"
PATH="$FAKE_PATH" expect_rc 0 "same stamp: first heal" run "$H" "$P3" install.sh
rm "$R/profiles/alpha/config.yaml" && printf '# live edit two\n' > "$R/profiles/alpha/config.yaml"
PATH="$FAKE_PATH" expect_rc 0 "same stamp: second heal" run "$H" "$P3" install.sh
expect_out "Backed up: .*config\.yaml → .*config\.yaml\.bak-$ST-1" "same stamp: second backup gets a counter"
check "same stamp: both file backups kept" bash -c "grep -qx '# live edit one' '$R/profiles/alpha/config.yaml.bak-$ST' && grep -qx '# live edit two' '$R/profiles/alpha/config.yaml.bak-$ST-1'"
for n in 1 2; do
  rm "$R/agent-hooks" && cp -r "$P3/hooks" "$R/agent-hooks"
  PATH="$FAKE_PATH" expect_rc 0 "same stamp: identical hooks dir moved aside ($n)" run "$H" "$P3" install.sh
done
check "same stamp: both hooks backups kept, none nested" bash -c "[[ -f '$R/agent-hooks.bak-$ST/gate.sh' && -f '$R/agent-hooks.bak-$ST-1/gate.sh' && ! -e '$R/agent-hooks.bak-$ST/agent-hooks' ]]"
rm "$R/profiles/alpha/SOUL.md" && mkdir "$R/profiles/alpha/SOUL.md" && printf 'x\n' > "$R/profiles/alpha/SOUL.md/keep"
expect_rc 1 "a directory where a profile file belongs: refused" run "$H" "$P3" install.sh
expect_out 'SOUL\.md is a directory' "a directory where a profile file belongs: says so"
check "a directory where a profile file belongs: left untouched" test -f "$R/profiles/alpha/SOUL.md/keep"
rm -r "$R/profiles/alpha/SOUL.md"
git -C "$P3" init -q
expect_rc 0 "take-live: install relinks first" run "$H" "$P3" install.sh
rm "$R/profiles/alpha/SOUL.md" && printf 'You are alpha, live.\n' > "$R/profiles/alpha/SOUL.md"
expect_rc 0 "take-live: install exits 0" run "$H" "$P3" install.sh --take-live
expect_out 'Kept the old portable copy: .*alpha/SOUL\.md\.bak-.*ignored by git' "take-live: names the kept copy and that git ignores it"
check "take-live: old portable content recoverable" grep -qx 'You are alpha.' "$P3"/profiles/alpha/SOUL.md.bak-*
check "take-live: portable now has the live content" grep -qx 'You are alpha, live.' "$P3/profiles/alpha/SOUL.md"
none_found "take-live: no temp file left beside it" "$P3/profiles/alpha" -name '.take-live.*'
git -C "$P3" status --porcelain --untracked-files=all > "$T/status"
check "take-live: git status of the portable repo works" test -s "$T/status"
reject_out_of 'bak-' "$T/status" "take-live: the kept copy is ignored by git"

printf '\n=== --adopt ===\n'
H="$T/s-adopt"; P2="$T/p-adopt"
make_home "$H" gamma notarole
L="$H/.hermes/profiles/gamma"
mkdir -p "$P2/profiles/gamma" "$L/scripts" "$H/.hermes/agent-hooks/tests/__pycache__"
printf 'description: gamma\n' > "$L/profile.yaml"
printf '# live gamma config\n' > "$L/config.yaml"
# Still linked into an old checkout (the Computer-Setup profiles/ of before).
mkdir -p "$T/old-checkout"
printf 'You are gamma.\n' > "$T/old-checkout/SOUL.md"
ln -s "$T/old-checkout/SOUL.md" "$L/SOUL.md"
printf '#!/bin/sh\n' > "$L/scripts/run.sh"
mkdir -p "$L/scripts/lib" && printf 'nested helper\n' > "$L/scripts/lib/helper.sh"
printf 'old\n' > "$L/scripts/run.sh.bak-1"
printf 'bytecode\n' > "$L/scripts/run.pyc"
printf 'lock\n' > "$L/scripts/run.lock"
printf '# config kept in git\n' > "$P2/profiles/gamma/config.yaml"
printf 'x\n' > "$H/.hermes/profiles/notarole/SOUL.md"
printf 'You are the live default.\n' > "$H/.hermes/SOUL.md"
printf '#!/bin/sh\n' > "$H/.hermes/agent-hooks/gate.sh"
printf 'def test(): pass\n' > "$H/.hermes/agent-hooks/tests/test_gate.py"
printf 'bytecode\n' > "$H/.hermes/agent-hooks/tests/__pycache__/test_gate.cpython-314.pyc"
printf 'SECRET=1\n' > "$H/.hermes/agent-hooks/.env"
printf '{}\n' > "$H/.hermes/agent-hooks/auth.json"
# Never-copy names on a directory cover everything under it.
mkdir -p "$H/.hermes/agent-hooks/archive.bak-old" "$H/.hermes/agent-hooks/cache.db" "$H/.hermes/agent-hooks/creds/auth.json" "$H/.hermes/agent-hooks/mcp-tokens"
printf 'k\n' > "$H/.hermes/agent-hooks/archive.bak-old/keep.txt"
printf 'd\n' > "$H/.hermes/agent-hooks/cache.db/data.txt"
printf 'p\n' > "$H/.hermes/agent-hooks/creds/auth.json/payload.txt"
printf 't\n' > "$H/.hermes/agent-hooks/mcp-tokens/token.json"
snapshot() { tree_sum s-adopt p-adopt; }
before="$(snapshot)"
expect_rc 0 "adopt dry-run: exits 0" run "$H" "$P2" install.sh --adopt --dry-run
expect_out '^Would adopt: .*gamma/profile\.yaml' "adopt dry-run: prints the plan"
check "adopt dry-run: changes nothing" test "$(snapshot)" == "$before"
expect_rc 2 "--dry-run without --adopt is refused" run "$H" "$P2" install.sh --dry-run
# The live hooks dir keeps .env and auth.json, which are never adopted, so it
# differs from the adopted copy and must stay in place (exit 1).
expect_rc 1 "adopt: exits 1 while the live hooks dir differs" run "$H" "$P2" install.sh --adopt
expect_out '^Adopted: .*gamma/profile\.yaml' "adopt: one line per adopted item"
check "adopt: profile.yaml copied" grep -qx 'description: gamma' "$P2/profiles/gamma/profile.yaml"
check "adopt: SOUL.md copied" grep -qx 'You are gamma.' "$P2/profiles/gamma/SOUL.md"
check "adopt: a file linked into an old checkout is copied as a real file" real_file "$P2/profiles/gamma/SOUL.md"
check "adopt: script copied" real_file "$P2/profiles/gamma/scripts/run.sh"
check "adopt: nested script copied" grep -qx 'nested helper' "$P2/profiles/gamma/scripts/lib/helper.sh"
check "adopt: existing portable file not overwritten" grep -qx '# config kept in git' "$P2/profiles/gamma/config.yaml"
check "adopt: .bak skipped" test ! -e "$P2/profiles/gamma/scripts/run.sh.bak-1"
check "adopt: .pyc skipped" test ! -e "$P2/profiles/gamma/scripts/run.pyc"
check "adopt: .lock skipped" test ! -e "$P2/profiles/gamma/scripts/run.lock"
check "adopt: dir without profile.yaml skipped" test ! -e "$P2/profiles/notarole"
check "adopt: default SOUL.md copied" grep -qx 'You are the live default.' "$P2/default/SOUL.md"
check "adopt: hooks copied" real_file "$P2/hooks/tests/test_gate.py"
check "adopt: .env skipped" test ! -e "$P2/hooks/.env"
check "adopt: auth.json skipped" test ! -e "$P2/hooks/auth.json"
check "adopt: __pycache__ skipped" test ! -e "$P2/hooks/tests/__pycache__"
for d in archive.bak-old cache.db creds mcp-tokens; do
  check "adopt: never-copy dir $d/ skipped" test ! -e "$P2/hooks/$d"
done
reject_out 'keep\.txt|data\.txt|payload\.txt|token\.json' "adopt: a file inside a never-copy dir is not even mentioned"
check "adopt: live profile files now linked" linked_to "$L/profile.yaml" "$P2/profiles/gamma/profile.yaml"
check "adopt: live default SOUL.md now linked" linked_to "$H/.hermes/SOUL.md" "$P2/default/SOUL.md"
check "adopt: differing live config backed up" grep -qx '# live gamma config' "$L"/config.yaml.bak-*
check "adopt: differing live hooks dir left in place" test ! -L "$H/.hermes/agent-hooks"
rm "$H/.hermes/agent-hooks/.env" "$H/.hermes/agent-hooks/auth.json"
rm -r "$H/.hermes/agent-hooks/archive.bak-old" "$H/.hermes/agent-hooks/cache.db" "$H/.hermes/agent-hooks/creds" "$H/.hermes/agent-hooks/mcp-tokens"
expect_rc 0 "adopt: rerun after resolving hooks exits 0" run "$H" "$P2" install.sh --adopt
reject_out '^Adopted: ' "adopt: rerun adopts nothing"
check "adopt: hooks now linked" linked_to "$H/.hermes/agent-hooks" "$P2/hooks"
check "adopt: hooks moved aside with __pycache__" compgen -G "$H/.hermes/agent-hooks.bak-*/tests/__pycache__"
expect_rc 0 "adopt: third run exits 0" run "$H" "$P2" install.sh --adopt
reject_out "$CHANGED" "adopt: third run is a no-op"

printf '\n=== help ===\n'
expect_rc 0 "--help exits 0" run "$T/home" "" install.sh --help
expect_out '--take-live' "--help documents --take-live"
expect_out '--adopt' "--help documents --adopt"
expect_rc 2 "unknown option exits 2" run "$T/home" "" install.sh --bogus

printf '\n'
if (( FAILS )); then printf '%d failure(s)\n' "$FAILS" >&2; exit 1; fi
printf 'all passed\n'
