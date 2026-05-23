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
if [[ -f "$ROOT/.claude/test-cmd" ]]; then
  TEST_CMD=$(< "$ROOT/.claude/test-cmd")
elif [[ -f "$ROOT/Cargo.toml" ]]; then
  TEST_CMD="cargo test"
elif [[ -f "$ROOT/go.mod" ]]; then
  TEST_CMD="go test ./..."
elif [[ -f "$ROOT/pyproject.toml" || -f "$ROOT/pytest.ini" || -f "$ROOT/setup.py" ]]; then
  TEST_CMD="pytest"
elif [[ -f "$ROOT/package.json" ]]; then
  _npm_test=$(jq -r '.scripts.test // ""' "$ROOT/package.json" 2>/dev/null) || true
  [[ -n "$_npm_test" && "$_npm_test" != *'no test specified'* ]] && TEST_CMD="npm test"
elif [[ -f "$ROOT/Makefile" ]] && grep -q '^test[[:space:]]*:' "$ROOT/Makefile" 2>/dev/null; then
  TEST_CMD="make test"
fi

[[ -n "$TEST_CMD" ]] || exit 0

TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

START_MS=$(date +%s%3N)
(cd "$ROOT" && timeout 60 bash -c "$TEST_CMD") > "$TMPFILE" 2>&1
EXIT_CODE=$?
END_MS=$(date +%s%3N)
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
