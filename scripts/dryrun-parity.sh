#!/usr/bin/env bash
# Phase 2 dry-run parity gate for the setup-script unification (UNIFICATION.md,
# issue #36): for every platform × flag combination, the root setup.sh must
# perform the same install/eval actions as the legacy per-folder script.
#
# Raw output is normalized before diffing — cosmetic text is out of scope:
#   - only "[dry-run]" lines are compared
#   - batch installs are split into one package per line (the unified engine
#     may batch differently, e.g. macOS work casks merged into their tier)
#   - "eval: " prefixes are stripped (run vs run_eval is not behavior)
#   - timestamped backup filenames are canonicalized
#   - lines are sorted (legacy scripts batch per tier; order is not behavior)
#
# A stub `brew` is put on PATH for the macOS runs so the Homebrew bootstrap
# (which curls the install script even in dry-run) is skipped identically on
# both sides — the bootstrap block is ported verbatim and not exercised here.
#
# Host-state note: both sides run on the same host in the same instant, so
# host-dependent branches (command -v tailscale/claude/pnpm, existing configs)
# resolve identically for old and new.
#
# Usage: bash scripts/dryrun-parity.sh           # failures + summary
#        VERBOSE=1 bash scripts/dryrun-parity.sh # every check

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERBOSE="${VERBOSE:-0}"

CHECKS=0
FAILURES=0

STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_DIR/brew"
chmod +x "$STUB_DIR/brew"

normalize() {
  sed -n 's/^[[:space:]]*\[dry-run\][[:space:]]//p' \
    | sed 's/^eval: //' \
    | awk '{
        if (match($0, /^(brew install --cask |brew install |sudo apt install -y |yay -S --needed --noconfirm |sudo pacman -S --needed --noconfirm |pnpm add -g )/)) {
          prefix = substr($0, 1, RLENGTH)
          n = split(substr($0, RLENGTH + 1), pkgs, " ")
          for (i = 1; i <= n; i++) if (pkgs[i] != "") print prefix pkgs[i]
        } else {
          print
        }
      }' \
    | sed 's/\.bak\.[0-9]\{8\}_[0-9]\{6\}/.bak.<ts>/g' \
    | sort
}

run_norm() {
  local out status=0
  out="$(eval "$1" 2>/dev/null)" || status=$?
  if [[ $status -ne 0 ]]; then
    printf 'WARN: exited %d: %s\n' "$status" "$1" >&2
  fi
  normalize <<< "$out"
}

compare() {
  local label="$1" old_cmd="$2" new_cmd="$3" old new
  CHECKS=$((CHECKS + 1))
  old="$(run_norm "$old_cmd")"
  new="$(run_norm "$new_cmd")"
  if [[ "$old" == "$new" ]]; then
    [[ "$VERBOSE" == "1" ]] && printf '  ok   %s\n' "$label"
    return 0
  fi
  FAILURES=$((FAILURES + 1))
  printf 'FAIL   %s   (< legacy | > unified)\n' "$label"
  diff <(printf '%s\n' "$old") <(printf '%s\n' "$new") | sed 's/^/         /' || true
}

# ── macOS ──────────────────────────────────────────────────────────────────────
printf '== macos ==\n'
for flags in "" "--optional" "--work" "--optional --work"; do
  compare "macos [$flags]" \
    "PATH='$STUB_DIR:$PATH' bash '$REPO_ROOT/macOS/setup.sh' --dry-run $flags" \
    "PATH='$STUB_DIR:$PATH' bash '$REPO_ROOT/setup.sh' --dry-run --platform macos $flags"
done

# ── linux-desktop (ubuntu + arch × every flag combo) ──────────────────────────
for d in ubuntu arch; do
  printf '== %s ==\n' "$d"
  for o in "" "--optional"; do
    for w in "" "--work"; do
      for p in "" "--personal"; do
        flags="$o $w $p"
        compare "$d [$flags]" \
          "bash '$REPO_ROOT/linux-desktop/setup.sh' --dry-run --distro $d $flags" \
          "bash '$REPO_ROOT/setup.sh' --dry-run --platform $d $flags"
      done
    done
  done
done

# ── linux-server ───────────────────────────────────────────────────────────────
printf '== server ==\n'
for flags in "" "--optional"; do
  compare "server [$flags]" \
    "bash '$REPO_ROOT/linux-server/setup.sh' --dry-run $flags" \
    "bash '$REPO_ROOT/setup.sh' --dry-run --platform server $flags"
done

# ── Summary ────────────────────────────────────────────────────────────────────
printf '\n%d checks, %d failures\n' "$CHECKS" "$FAILURES"
if [[ "$FAILURES" -gt 0 ]]; then
  printf 'dryrun-parity: FAILED\n' >&2
  exit 1
fi
printf 'dryrun-parity: PASSED — root setup.sh matches all three legacy scripts\n'
