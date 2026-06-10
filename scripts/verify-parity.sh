#!/usr/bin/env bash
# Phase 3 verify parity gate for the setup-script unification (UNIFICATION.md,
# issue #36): for every platform × flag combination, the root verify.sh must
# perform the same checks — same items, same pass/fail — as the legacy
# per-folder verify script.
#
# Both sides run on the same host in the same instant, so host-dependent checks
# (command -v, pipx list, config files) resolve identically. Only ✅/❌ check
# lines are compared, normalized:
#   - sorted (section order follows JSON order, which differs between files)
#   - legacy manager labels renamed where Phase 1 folded managers:
#     curl→custom (nvm/pyenv/claude-code), macOS mongodb-community brew→custom
#   - new-side macOS labels "name (mgr:rname)" collapse to "rname (mgr)" —
#     the legacy macOS json used the install token as the entry name
#   - pnpm-managed rows are excluded from the status diff: the legacy scripts
#     could not check pnpm packages (always ❌, macOS even labels it "unknown
#     manager"); the unified engine checks them for real. Row presence and
#     total check counts are still asserted on both sides.
#
# The legacy macOS verify.sh has no env flags and checks work-tagged packages
# unconditionally, so the unified side gets --work --personal on macOS rows.
#
# Usage: bash scripts/verify-parity.sh           # failures + summary
#        VERBOSE=1 bash scripts/verify-parity.sh # every check
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERBOSE="${VERBOSE:-0}"

CHECKS=0
FAILURES=0

# Check lines only (drop the summary line, which contains both glyphs).
checks_of() {
  grep -aE '^[[:space:]]*(✅|❌)' <<< "$1" | grep -av '✅.*❌' | sed -E 's/^[[:space:]]+//' || true
}

norm_legacy() {
  sed -E 's/ \(curl\)/ (custom)/
          s/mongodb-community \(brew\)/mongodb-community (custom)/
          s/ \(unknown manager: pnpm\)//'
}

norm_new_macos() {
  sed -E 's/([^ ()]+) \(([a-z-]+):([^)]+)\)/\3 (\2)/'
}

compare() {
  local label="$1" old_cmd="$2" new_cmd="$3" collapse="${4:-no}"
  CHECKS=$((CHECKS + 1))
  local old_raw new_raw old new
  old_raw="$(eval "$old_cmd" 2>/dev/null)" || true
  new_raw="$(eval "$new_cmd" 2>/dev/null)" || true
  old="$(checks_of "$old_raw" | norm_legacy)"
  new="$(checks_of "$new_raw")"
  [[ "$collapse" == yes ]] && new="$(norm_new_macos <<< "$new")"

  local old_n new_n
  old_n="$(grep -c . <<< "$old" || true)"
  new_n="$(grep -c . <<< "$new" || true)"

  local old_cmp new_cmp
  old_cmp="$(grep -avF ' (pnpm)' <<< "$old" | sort)"
  new_cmp="$(grep -avF ' (pnpm)' <<< "$new" | sort)"

  if [[ "$old_n" == "$new_n" && "$old_cmp" == "$new_cmp" ]]; then
    [[ "$VERBOSE" == "1" ]] && printf '  ok   %s   (%s checks)\n' "$label" "$old_n"
    return 0
  fi
  FAILURES=$((FAILURES + 1))
  printf 'FAIL   %s   (legacy %s checks | unified %s checks; < legacy | > unified)\n' \
    "$label" "$old_n" "$new_n"
  diff <(printf '%s\n' "$old_cmp") <(printf '%s\n' "$new_cmp") | sed 's/^/         /' || true
}

# ── macOS ──────────────────────────────────────────────────────────────────────
printf '== macos ==\n'
for flags in "" "--optional" "--all"; do
  compare "macos [$flags]" \
    "zsh '$REPO_ROOT/macOS/verify.sh' $flags" \
    "bash '$REPO_ROOT/verify.sh' --platform macos --work --personal $flags" \
    yes
done

# ── linux-desktop (ubuntu + arch × every flag combo) ──────────────────────────
for d in ubuntu arch; do
  printf '== %s ==\n' "$d"
  compare "$d [--all]" \
    "bash '$REPO_ROOT/linux-desktop/verify.sh' --distro $d --all" \
    "bash '$REPO_ROOT/verify.sh' --platform $d --all"
  for o in "" "--optional"; do
    for w in "" "--work"; do
      for p in "" "--personal"; do
        flags="$o $w $p"
        compare "$d [$flags]" \
          "bash '$REPO_ROOT/linux-desktop/verify.sh' --distro $d $flags" \
          "bash '$REPO_ROOT/verify.sh' --platform $d $flags"
      done
    done
  done
done

# ── Summary ────────────────────────────────────────────────────────────────────
printf '\n%d checks, %d failures\n' "$CHECKS" "$FAILURES"
if [[ "$FAILURES" -gt 0 ]]; then
  printf 'verify-parity: FAILED\n' >&2
  exit 1
fi
printf 'verify-parity: PASSED — root verify.sh matches both legacy verify scripts\n'
