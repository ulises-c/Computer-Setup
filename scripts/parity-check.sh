#!/usr/bin/env bash
# Phase 1 parity harness for the setup-script unification (UNIFICATION.md, issue #36).
#
# For every platform × priority tier × flag combination, computes the install list
# from the unified root packages.json (using the planned lib/core.sh selection
# semantics) and diffs it against the list the legacy per-folder setup.sh would
# compute from its own JSON (replicating each legacy script's exact jq filters).
#
# Intentional, documented differences absorbed here:
#   - Legacy "curl"-manager entries are folded into "custom" (migration rule 3),
#     so legacy curl+custom buckets are compared against the unified custom bucket.
#   - macOS work:true is modeled as environment:["work"] (rule 2). The legacy
#     macOS --work install ignores priority; the unified model installs work
#     packages inside their priority tier, so the work bucket is compared across
#     all auto-installable tiers (high/medium/low — never "none").
#   - install_command may be a bare string in the unified schema (applies to any
#     platform that consumes it) or an object keyed by platform.
#   - Comparison is order-insensitive: legacy scripts batch installs per tier,
#     so within-tier order is not behavior.
#
# Usage: bash scripts/parity-check.sh           # failures + summary
#        VERBOSE=1 bash scripts/parity-check.sh # every check

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NEW_JSON="$REPO_ROOT/packages.json"
MAC_JSON="$REPO_ROOT/macOS/macOS_packages.json"
LD_JSON="$REPO_ROOT/linux-desktop/linux_desktop_packages.json"
SRV_JSON="$REPO_ROOT/linux-server/linux_server_packages.json"
VERBOSE="${VERBOSE:-0}"

CHECKS=0
FAILURES=0

norm() { sort <<< "$1" | sed '/^$/d'; }

compare() {
  local label="$1" old="$2" new="$3"
  CHECKS=$((CHECKS + 1))
  if [[ "$(norm "$old")" == "$(norm "$new")" ]]; then
    [[ "$VERBOSE" == "1" ]] && printf '  ok   %s\n' "$label"
    return 0
  fi
  FAILURES=$((FAILURES + 1))
  printf 'FAIL   %s   (< legacy | > unified)\n' "$label"
  diff <(norm "$old") <(norm "$new") | sed 's/^/         /' || true
}

# ── Unified-JSON selection (the planned core semantics) ───────────────────────

# shellcheck disable=SC2016  # $vars below are jq variables, not shell expansions
NEW_DEFS='
def envok($w; $p):
  (.environment == null) or
  (($w == "true") and (.environment | index("work"))) or
  (($p == "true") and (.environment | index("personal")));
def icfor($plat):
  (.install_command | if type == "object" then .[$plat] else . end);
def pname($plat): (.[$plat + "_name"] // .name);
'

new_names() {
  local plat="$1" mgr="$2" pr="$3" w="$4" p="$5"
  jq -r --arg plat "$plat" --arg m "$mgr" --arg pr "$pr" --arg w "$w" --arg p "$p" \
    "$NEW_DEFS"'.[] | select(
        .package_manager[$plat] == $m and .priority == $pr and envok($w; $p)
      ) | pname($plat)' "$NEW_JSON"
}

new_custom() {
  local plat="$1" pr="$2" w="$3" p="$4"
  jq -r --arg plat "$plat" --arg pr "$pr" --arg w "$w" --arg p "$p" \
    "$NEW_DEFS"'.[] | select(
        .package_manager[$plat] == "custom" and .priority == $pr and
        envok($w; $p) and (icfor($plat) != null)
      ) | "\(.name)|\(icfor($plat))"' "$NEW_JSON"
}

new_snap_regular() {
  local plat="$1" pr="$2" w="$3" p="$4"
  jq -r --arg plat "$plat" --arg pr "$pr" --arg w "$w" --arg p "$p" \
    "$NEW_DEFS"'.[] | select(
        .package_manager[$plat] == "snap" and .priority == $pr and
        envok($w; $p) and (icfor($plat) == null)
      ) | pname($plat)' "$NEW_JSON"
}

new_snap_custom() {
  local plat="$1" pr="$2" w="$3" p="$4"
  jq -r --arg plat "$plat" --arg pr "$pr" --arg w "$w" --arg p "$p" \
    "$NEW_DEFS"'.[] | select(
        .package_manager[$plat] == "snap" and .priority == $pr and
        envok($w; $p) and (icfor($plat) != null)
      ) | "\(.name)|\(icfor($plat))"' "$NEW_JSON"
}

new_pipx_cmds() {
  local plat="$1" pr="$2" w="$3" p="$4"
  jq -r --arg plat "$plat" --arg pr "$pr" --arg w "$w" --arg p "$p" \
    "$NEW_DEFS"'.[] | select(
        .package_manager[$plat] == "pipx" and .priority == $pr and envok($w; $p)
      ) | (icfor($plat) // ("pipx install " + .name))' "$NEW_JSON"
}

new_pnpm_names() {
  local plat="$1" pr="$2" w="$3" p="$4"
  jq -r --arg plat "$plat" --arg pr "$pr" --arg w "$w" --arg p "$p" \
    "$NEW_DEFS"'.[] | select(
        .package_manager[$plat] == "pnpm" and .priority == $pr and envok($w; $p)
      ) | .name' "$NEW_JSON"
}

new_work_names() {
  local plat="$1" mgr="$2"
  jq -r --arg plat "$plat" --arg m "$mgr" \
    "$NEW_DEFS"'.[] | select(
        .package_manager[$plat] == $m and .priority != "none" and
        ((.environment // []) | index("work"))
      ) | pname($plat)' "$NEW_JSON"
}

# ── Legacy macOS selection (macOS/setup.sh filters, verbatim) ─────────────────

old_mac_brew() {
  local pr="$1" opt="$2"
  jq -r --arg p "$pr" --argjson opt "$opt" \
    '.[] | select(
        .package_manager == "brew" and .priority == $p and (.work != true) and
        (.install_command == null or .install_command == "") and
        (if $opt then true else .optional == false end)
      ) | .name' "$MAC_JSON"
}

old_mac_names() {
  local mgr="$1" pr="$2" opt="$3"
  jq -r --arg m "$mgr" --arg p "$pr" --argjson opt "$opt" \
    '.[] | select(
        .package_manager == $m and .priority == $p and (.work != true) and
        (if $opt then true else .optional == false end)
      ) | .name' "$MAC_JSON"
}

old_mac_brew_custom() {
  local pr="$1" opt="$2"
  jq -r --arg p "$pr" --argjson opt "$opt" \
    '.[] | select(
        .package_manager == "brew" and .priority == $p and (.work != true) and
        (.install_command != null and .install_command != "") and
        (if $opt then true else .optional == false end)
      ) | "\(.name)|\(.install_command)"' "$MAC_JSON"
}

old_mac_curl() {
  local pr="$1" opt="$2"
  jq -r --arg p "$pr" --argjson opt "$opt" \
    '.[] | select(
        .package_manager == "curl" and .priority == $p and (.work != true) and
        (if $opt then true else .optional == false end)
      ) | "\(.name)|\(.install_command)"' "$MAC_JSON"
}

old_mac_work() {
  local mgr="$1"
  jq -r --arg m "$mgr" \
    '.[] | select(.work == true and .package_manager == $m) | .name' "$MAC_JSON"
}

# ── Legacy linux-desktop selection (linux-desktop/setup.sh filters, verbatim) ──

# shellcheck disable=SC2016  # $vars below are jq variables, not shell expansions
OLD_LD_ENV='
  ((.environment == null) or
   (($w == "true") and (.environment | index("work"))) or
   (($p == "true") and (.environment | index("personal"))))
'

old_ld_names() {
  local d="$1" mgr="$2" pr="$3" w="$4" p="$5"
  jq -r --arg d "$d" --arg m "$mgr" --arg pr "$pr" --arg w "$w" --arg p "$p" \
    '.[] | select(
        .package_manager[$d] == $m and .priority == $pr and '"$OLD_LD_ENV"'
      ) | (.[$d + "_name"] // .name)' "$LD_JSON"
}

old_ld_cmds() {
  local d="$1" mgr="$2" pr="$3" w="$4" p="$5"
  jq -r --arg d "$d" --arg m "$mgr" --arg pr "$pr" --arg w "$w" --arg p "$p" \
    '.[] | select(
        .package_manager[$d] == $m and .priority == $pr and
        .install_command[$d] != null and '"$OLD_LD_ENV"'
      ) | "\(.name)|\(.install_command[$d])"' "$LD_JSON"
}

old_ld_snap_regular() {
  local d="$1" pr="$2" w="$3" p="$4"
  jq -r --arg d "$d" --arg pr "$pr" --arg w "$w" --arg p "$p" \
    '.[] | select(
        .package_manager[$d] == "snap" and .priority == $pr and
        .install_command[$d] == null and '"$OLD_LD_ENV"'
      ) | (.[$d + "_name"] // .name)' "$LD_JSON"
}

old_ld_pipx_cmds() {
  local d="$1" pr="$2" w="$3" p="$4"
  jq -r --arg d "$d" --arg pr "$pr" --arg w "$w" --arg p "$p" \
    '.[] | select(
        .package_manager[$d] == "pipx" and .priority == $pr and '"$OLD_LD_ENV"'
      ) | if .install_command[$d] != null then .install_command[$d]
          else "pipx install " + .name end' "$LD_JSON"
}

old_ld_pnpm_names() {
  local d="$1" pr="$2" w="$3" p="$4"
  jq -r --arg d "$d" --arg pr "$pr" --arg w "$w" --arg p "$p" \
    '.[] | select(
        .package_manager[$d] == "pnpm" and .priority == $pr and '"$OLD_LD_ENV"'
      ) | .name' "$LD_JSON"
}

# ── Legacy linux-server selection (linux-server/setup.sh filters, verbatim) ───

old_srv_apt() {
  local pr="$1"
  jq -r --arg p "$pr" \
    '.[] | select(.package_manager == "apt" and .priority == $p) | .name' "$SRV_JSON"
}

old_srv_custom_handled() {
  local pr="$1"
  jq -r --arg p "$pr" \
    '.[] | select(
        .package_manager == "custom" and .priority == $p and .handled_by_setup == true
      ) | "\(.name)|\(.install_command)"' "$SRV_JSON"
}

old_srv_reminders() {
  local pr="$1"
  jq -r --arg p "$pr" \
    '.[] | select(
        .package_manager == "custom" and .priority == $p and (.handled_by_setup != true)
      ) | .name' "$SRV_JSON"
}

new_srv_custom_handled() {
  local pr="$1"
  jq -r --arg pr "$pr" \
    "$NEW_DEFS"'.[] | select(
        .package_manager.server == "custom" and .priority == $pr and
        .handled_by_setup == true
      ) | "\(.name)|\(icfor("server"))"' "$NEW_JSON"
}

new_srv_reminders() {
  local pr="$1"
  jq -r --arg pr "$pr" \
    "$NEW_DEFS"'.[] | select(
        .package_manager.server == "custom" and .priority == $pr and
        (.handled_by_setup != true)
      ) | .name' "$NEW_JSON"
}

# ── macOS checks ───────────────────────────────────────────────────────────────
# Flags don't interact in the legacy macOS queries (work entries are excluded
# from every tier regardless of flags; --optional only enables the low tier),
# so each bucket is checked once with the optional filter its tier runs with.

printf '== macOS ==\n'
opt_for_tier() { case "$1" in high|medium) printf 'false' ;; *) printf 'true' ;; esac; }

for pr in high medium low none; do
  opt="$(opt_for_tier "$pr")"
  compare "macos brew $pr" \
    "$(old_mac_brew "$pr" "$opt")" \
    "$(new_names macos brew "$pr" false false)"
  compare "macos brew-cask $pr" \
    "$(old_mac_names brew-cask "$pr" "$opt")" \
    "$(new_names macos brew-cask "$pr" false false)"
  compare "macos custom $pr (legacy curl+brew_custom)" \
    "$(old_mac_curl "$pr" "$opt")"$'\n'"$(old_mac_brew_custom "$pr" "$opt")" \
    "$(new_custom macos "$pr" false false)"
  compare "macos pipx $pr" \
    "$(old_mac_names pipx "$pr" "$opt")" \
    "$(new_names macos pipx "$pr" false false)"
  compare "macos pnpm $pr" \
    "$(old_mac_names pnpm "$pr" "$opt")" \
    "$(new_names macos pnpm "$pr" false false)"
  compare "macos app-store $pr" \
    "$(old_mac_names app-store "$pr" "$opt")" \
    "$(new_names macos app-store "$pr" false false)"
done

for mgr in brew brew-cask app-store; do
  compare "macos --work $mgr" \
    "$(old_mac_work "$mgr")" \
    "$(new_work_names macos "$mgr")"
done

# ── linux-desktop checks (ubuntu + arch × every flag combo) ───────────────────

for d in ubuntu arch; do
  [[ "$d" == "ubuntu" ]] && pm="apt" || pm="yay"
  for w in false true; do
    for p in false true; do
      printf '== linux-desktop/%s work=%s personal=%s ==\n' "$d" "$w" "$p"
      for pr in high medium low none; do
        compare "ld/$d $pm $pr w=$w p=$p" \
          "$(old_ld_names "$d" "$pm" "$pr" "$w" "$p")" \
          "$(new_names "$d" "$pm" "$pr" "$w" "$p")"
        compare "ld/$d custom $pr w=$w p=$p (legacy custom+curl)" \
          "$(old_ld_cmds "$d" custom "$pr" "$w" "$p")"$'\n'"$(old_ld_cmds "$d" curl "$pr" "$w" "$p")" \
          "$(new_custom "$d" "$pr" "$w" "$p")"
        compare "ld/$d snap-regular $pr w=$w p=$p" \
          "$(old_ld_snap_regular "$d" "$pr" "$w" "$p")" \
          "$(new_snap_regular "$d" "$pr" "$w" "$p")"
        compare "ld/$d snap-custom $pr w=$w p=$p" \
          "$(old_ld_cmds "$d" snap "$pr" "$w" "$p")" \
          "$(new_snap_custom "$d" "$pr" "$w" "$p")"
        compare "ld/$d pipx $pr w=$w p=$p" \
          "$(old_ld_pipx_cmds "$d" "$pr" "$w" "$p")" \
          "$(new_pipx_cmds "$d" "$pr" "$w" "$p")"
        compare "ld/$d pnpm $pr w=$w p=$p" \
          "$(old_ld_pnpm_names "$d" "$pr" "$w" "$p")" \
          "$(new_pnpm_names "$d" "$pr" "$w" "$p")"
      done
    done
  done
done

# ── linux-server checks ────────────────────────────────────────────────────────

printf '== linux-server ==\n'
for pr in high medium low none; do
  compare "server apt $pr" \
    "$(old_srv_apt "$pr")" \
    "$(new_names server apt "$pr" false false)"
  compare "server custom-handled $pr" \
    "$(old_srv_custom_handled "$pr")" \
    "$(new_srv_custom_handled "$pr")"
  compare "server custom-reminders $pr" \
    "$(old_srv_reminders "$pr")" \
    "$(new_srv_reminders "$pr")"
done

# ── Summary ────────────────────────────────────────────────────────────────────

printf '\n%d checks, %d failures\n' "$CHECKS" "$FAILURES"
if [[ "$FAILURES" -gt 0 ]]; then
  printf 'parity-check: FAILED\n' >&2
  exit 1
fi
printf 'parity-check: PASSED — unified packages.json matches all three legacy JSONs\n'
