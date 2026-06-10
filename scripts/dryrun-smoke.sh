#!/usr/bin/env bash
# Post-unification smoke gate (UNIFICATION.md Phase 4): the root setup.sh must
# complete a --dry-run on every platform and emit install actions. Replaces the
# legacy-parity gates deleted in Phase 4 (the per-folder scripts are shims now,
# so there is nothing left to compare against); catches engine and
# platform-module breakage on the platforms CI can't run live.
#
# A stub `brew` is put on PATH so the macOS Homebrew bootstrap (which curls the
# install script even in dry-run) is skipped.
#
# Usage: bash scripts/dryrun-smoke.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_DIR/brew"
chmod +x "$STUB_DIR/brew"

FAILURES=0
for platform in macos ubuntu arch server; do
  out=""
  if ! out="$(PATH="$STUB_DIR:$PATH" bash "$REPO_ROOT/setup.sh" \
      --dry-run --optional --work --personal --platform "$platform" 2>&1)"; then
    printf 'FAIL %s: setup.sh exited non-zero; last lines:\n' "$platform" >&2
    tail -n 5 <<< "$out" | sed 's/^/       /' >&2
    FAILURES=$((FAILURES + 1))
    continue
  fi
  n="$(grep -c '\[dry-run\]' <<< "$out" || true)"
  if (( n < 10 )); then
    printf 'FAIL %s: only %d dry-run actions (expected a full install plan)\n' \
      "$platform" "$n" >&2
    FAILURES=$((FAILURES + 1))
  else
    printf 'ok   %s: %d dry-run actions\n' "$platform" "$n"
  fi
done

if (( FAILURES > 0 )); then
  printf 'dryrun-smoke: FAILED (%d platforms)\n' "$FAILURES" >&2
  exit 1
fi
printf 'dryrun-smoke: PASSED — root setup.sh dry-runs clean on all four platforms\n'
