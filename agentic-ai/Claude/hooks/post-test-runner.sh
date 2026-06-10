#!/usr/bin/env bash
# PostToolUse hook for Write/Edit/MultiEdit: runs the project test suite after source edits.
# Exit 2 = Claude sees failure output (warn). Exit 0 = passed (timing shown) or no suite found.
set -uo pipefail

INPUT=$(cat) || exit 0
FILE=$(jq -r '.tool_input.file_path // ""' <<< "$INPUT" 2>/dev/null) || exit 0
[[ -n "$FILE" ]] || exit 0

# Skip non-source extensions
case "${FILE##*.}" in
  md|txt|json|yaml|yml|toml|lock|rst|svg|png|jpg|jpeg|gif|pdf|ico) exit 0 ;;
esac

# Resolve project root via git; no repo = no test suite
ROOT=$(git -C "$(dirname "$FILE")" rev-parse --show-toplevel 2>/dev/null) || exit 0

# Discover test command: .claude/test-cmd override → auto-detect → skip
TEST_CMD=""
PROBE_CMD=""
if [[ -f "$ROOT/.claude/test-cmd" ]]; then
  TEST_CMD=$(< "$ROOT/.claude/test-cmd")
elif [[ -f "$ROOT/Cargo.toml" ]]; then
  TEST_CMD="cargo test"
elif [[ -f "$ROOT/go.mod" ]]; then
  TEST_CMD="go test ./..."
elif [[ -f "$ROOT/pyproject.toml" || -f "$ROOT/pytest.ini" || -f "$ROOT/setup.py" ]]; then
  # python -m: console-script bins are absent in uv --no-sync venvs (#30);
  # --no-sync so the hook never re-resolves an env with pinned torch builds
  if [[ -f "$ROOT/uv.lock" ]]; then
    TEST_CMD="uv run --no-sync python -m pytest"
  else
    TEST_CMD="python3 -m pytest"
  fi
  PROBE_CMD="${TEST_CMD% -m pytest} -c 'import pytest'"
elif [[ -f "$ROOT/package.json" ]]; then
  _npm_test=$(jq -r '.scripts.test // ""' "$ROOT/package.json" 2>/dev/null) || true
  [[ -n "$_npm_test" && "$_npm_test" != *'no test specified'* ]] && TEST_CMD="npm test"
elif [[ -f "$ROOT/Makefile" ]] && grep -q '^test[[:space:]]*:' "$ROOT/Makefile" 2>/dev/null; then
  TEST_CMD="make test"
fi

[[ -n "$TEST_CMD" ]] || exit 0

# Runner not installed (e.g. pytest on a fresh box) = no runnable suite, not a failure
command -v "${TEST_CMD%% *}" >/dev/null 2>&1 || exit 0
if [[ -n "$PROBE_CMD" ]]; then
  (cd "$ROOT" && bash -c "$PROBE_CMD") >/dev/null 2>&1 || exit 0
fi

TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

# BSD date has no %N (#33); python3 fallback covers macOS
now_ms() {
  local ms
  ms=$(date +%s%3N 2>/dev/null)
  [[ "$ms" == *N* || -z "$ms" ]] && ms=$(python3 -c 'import time; print(int(time.time() * 1000))')
  printf '%s\n' "$ms"
}
# macOS ships timeout only as coreutils' gtimeout (#33)
TIMEOUT_BIN=$(command -v timeout || command -v gtimeout || true)

START_MS=$(now_ms)
if [[ -n "$TIMEOUT_BIN" ]]; then
  (cd "$ROOT" && "$TIMEOUT_BIN" 60 bash -c "$TEST_CMD") > "$TMPFILE" 2>&1
else
  (cd "$ROOT" && bash -c "$TEST_CMD") > "$TMPFILE" 2>&1
fi
EXIT_CODE=$?
END_MS=$(now_ms)
ELAPSED_MS=$(( END_MS - START_MS ))
ELAPSED_FMT=$(printf '%d.%03ds' $(( ELAPSED_MS / 1000 )) $(( ELAPSED_MS % 1000 )))

if [[ $EXIT_CODE -eq 0 ]]; then
  printf 'post-test-runner: %s passed (%s)\n' "$TEST_CMD" "$ELAPSED_FMT" >&2
elif [[ $EXIT_CODE -eq 124 ]]; then
  printf 'post-test-runner: %s timed out after 60s — consider a longer timeout in .claude/test-cmd\n' "$TEST_CMD" >&2
  exit 2
else
  printf 'post-test-runner: %s failed (%s)\n' "$TEST_CMD" "$ELAPSED_FMT" >&2
  cat "$TMPFILE" >&2
  exit 2
fi
