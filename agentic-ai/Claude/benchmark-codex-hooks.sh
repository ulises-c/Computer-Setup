#!/usr/bin/env bash
# Deterministic Codex hook benchmark. Runs fixed protocol cases in disposable state.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOKS_DIR="$SCRIPT_DIR/hooks"
RAILGUARD_BIN=${RAILGUARD_BIN:-railguard}
CASE_INDEX=0
FAILURES=0
LAST_STATUS=0
LAST_OUTPUT=""
LAST_ERROR=""
LAST_DETAIL=""

resolve_railguard() {
  if [[ "$RAILGUARD_BIN" == */* ]]; then
    [[ -x "$RAILGUARD_BIN" ]] || return 1
  else
    RAILGUARD_BIN=$(command -v "$RAILGUARD_BIN") || return 1
  fi
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'Bail out! required command is unavailable: %s\n' "$1"
    exit 2
  }
}

resolve_railguard || {
  printf 'Bail out! Railguard binary is unavailable: %s\n' "$RAILGUARD_BIN"
  exit 2
}
require_command bash
require_command git
require_command jq
require_command shellcheck

BENCH_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/codex-hook-benchmark.XXXXXX")
PROJECT_DIR="$BENCH_ROOT/project"
OUTSIDE_DIR="$BENCH_ROOT/outside"
RAILGUARD_STATE="$BENCH_ROOT/railguard-state"

cleanup() {
  rm -rf -- "$BENCH_ROOT"
}
trap cleanup EXIT

mkdir -p "$PROJECT_DIR/.claude" "$PROJECT_DIR/src" "$OUTSIDE_DIR" "$RAILGUARD_STATE"
git init --quiet "$PROJECT_DIR"
printf 'true\n' > "$PROJECT_DIR/.claude/test-cmd"
printf '#!/usr/bin/env bash\nprintf "benchmark\\n"\n' > "$PROJECT_DIR/valid.sh"
printf '#!/usr/bin/env bash\nlocal value=1\nprintf "%%s\\n" "$value"\n' > "$PROJECT_DIR/invalid.sh"
printf 'pub fn benchmark_probe() {}\n' > "$PROJECT_DIR/src/probe.rs"
printf 'version: 1\nblocklist: []\nfence:\n  enabled: true\n  allowed_paths:\n    - "%s"\n' \
  "$PROJECT_DIR" > "$PROJECT_DIR/railguard.yaml"

now_ms() {
  local ms
  ms=$(date +%s%3N 2>/dev/null)
  if [[ -z "$ms" || "$ms" == *N* ]]; then
    if command -v python3 >/dev/null 2>&1; then
      ms=$(python3 -c 'import time; print(int(time.time() * 1000))')
    else
      ms=$(( $(date +%s) * 1000 ))
    fi
  fi
  printf '%s\n' "$ms"
}

fail_case() {
  LAST_DETAIL=$1
  return 1
}

capture_hook() {
  local hook=$1
  local input=$2
  local stdout_file="$BENCH_ROOT/hook.stdout"
  local stderr_file="$BENCH_ROOT/hook.stderr"

  printf '%s\n' "$input" | bash "$hook" > "$stdout_file" 2> "$stderr_file"
  LAST_STATUS=$?
  LAST_OUTPUT=$(< "$stdout_file")
  LAST_ERROR=$(< "$stderr_file")
}

capture_railguard() {
  local tool_name=$1
  local tool_input=$2
  local stdout_file="$BENCH_ROOT/railguard.stdout"
  local stderr_file="$BENCH_ROOT/railguard.stderr"
  local input

  input=$(jq -nc \
    --arg session_id "codex-hook-benchmark-$$-$CASE_INDEX" \
    --arg cwd "$PROJECT_DIR" \
    --arg tool_name "$tool_name" \
    --argjson tool_input "$tool_input" \
    '{session_id: $session_id, cwd: $cwd, hook_event_name: "PreToolUse", tool_name: $tool_name, tool_input: $tool_input, tool_use_id: "benchmark"}')

  printf '%s\n' "$input" | env \
    RAILGUARD_HOME="$RAILGUARD_STATE" \
    RAILGUARD_NO_KILL=1 \
    "$RAILGUARD_BIN" hook --client codex --event PreToolUse \
    > "$stdout_file" 2> "$stderr_file"
  LAST_STATUS=$?
  LAST_OUTPUT=$(< "$stdout_file")
  LAST_ERROR=$(< "$stderr_file")
}

expect_status() {
  local expected=$1
  local context=$2
  [[ $LAST_STATUS -eq $expected ]] || fail_case "$context: expected exit $expected, got $LAST_STATUS"
}

expect_output() {
  local filter=$1
  local context=$2
  jq -e "$filter" <<< "$LAST_OUTPUT" >/dev/null 2>&1 \
    || fail_case "$context: unexpected output: $LAST_OUTPUT"
}

case_railguard_safe_noop() {
  capture_railguard Bash "$(jq -nc '{command: "git status --short"}')"
  expect_status 0 "Railguard safe response" || return 1
  expect_output 'type == "object" and length == 0' "Codex safe response must omit permissionDecision"
}

case_railguard_hard_deny() {
  capture_railguard Bash "$(jq -nc '{command: "rm -rf /"}')"
  expect_status 0 "Railguard hard deny" || return 1
  expect_output '.hookSpecificOutput.permissionDecision == "deny"' "destructive command must be denied"
}

case_railguard_approval_becomes_deny() {
  capture_railguard Bash "$(jq -nc '{command: "npm publish"}')"
  expect_status 0 "Railguard approval response" || return 1
  expect_output \
    '.hookSpecificOutput.permissionDecision == "deny" and (.hookSpecificOutput.permissionDecisionReason | ascii_downcase | contains("requires human approval"))' \
    "Codex approval-required response must be an actionable deny"
}

case_railguard_outside_fence() {
  capture_railguard Write "$(jq -nc --arg path "$OUTSIDE_DIR/probe.txt" '{file_path: $path, content: "probe"}')"
  expect_status 0 "Railguard path fence response" || return 1
  expect_output '.hookSpecificOutput.permissionDecision == "deny"' "write outside project fence must be denied"
}

case_validate_bash_safe() {
  capture_hook "$HOOKS_DIR/validate-bash.sh" \
    "$(jq -nc '{tool_name: "Bash", tool_input: {command: "git status --short"}}')"
  expect_status 0 "safe custom Bash hook"
}

case_validate_bash_bulk_stage() {
  capture_hook "$HOOKS_DIR/validate-bash.sh" \
    "$(jq -nc '{tool_name: "Bash", tool_input: {command: "git add --all"}}')"
  expect_status 2 "bulk staging custom Bash hook"
}

case_validate_bash_patch_text() {
  capture_hook "$HOOKS_DIR/validate-bash.sh" \
    "$(jq -nc --arg cwd "$PROJECT_DIR" --arg command $'*** Begin Patch\n*** Update File: README.md\n@@\n+sudo --version\n*** End Patch' '{cwd: $cwd, tool_name: "apply_patch", tool_input: {command: $command}}')"
  expect_status 0 "apply_patch text must not be parsed as a shell command"
}

case_validate_write_sensitive_patch() {
  capture_hook "$HOOKS_DIR/validate-write.sh" \
    "$(jq -nc --arg cwd "$PROJECT_DIR" --arg command $'*** Begin Patch\n*** Update File: /etc/benchmark-probe\n@@\n+probe\n*** End Patch' '{cwd: $cwd, tool_name: "apply_patch", tool_input: {command: $command}}')"
  expect_status 2 "sensitive Codex patch path"
}

case_shellcheck_valid_patch() {
  capture_hook "$HOOKS_DIR/post-edit-shellcheck.sh" \
    "$(jq -nc --arg cwd "$PROJECT_DIR" --arg command $'*** Begin Patch\n*** Update File: valid.sh\n*** End Patch' '{cwd: $cwd, tool_name: "apply_patch", tool_input: {command: $command}}')"
  expect_status 0 "valid shell patch"
}

case_shellcheck_invalid_patch() {
  capture_hook "$HOOKS_DIR/post-edit-shellcheck.sh" \
    "$(jq -nc --arg cwd "$PROJECT_DIR" --arg command $'*** Begin Patch\n*** Update File: invalid.sh\n*** End Patch' '{cwd: $cwd, tool_name: "apply_patch", tool_input: {command: $command}}')"
  expect_status 2 "invalid shell patch"
}

case_test_runner_patch() {
  capture_hook "$HOOKS_DIR/post-test-runner.sh" \
    "$(jq -nc --arg cwd "$PROJECT_DIR" --arg command $'*** Begin Patch\n*** Update File: src/probe.rs\n*** End Patch' '{cwd: $cwd, tool_name: "apply_patch", tool_input: {command: $command}}')"
  expect_status 0 "Codex source patch test runner" || return 1
  [[ "$LAST_ERROR" == *'post-test-runner: true passed'* ]] \
    || fail_case "test runner did not report the isolated test command: $LAST_ERROR"
}

run_case() {
  local name=$1
  local function_name=$2
  local start_ms end_ms elapsed_ms

  CASE_INDEX=$(( CASE_INDEX + 1 ))
  LAST_DETAIL=""
  start_ms=$(now_ms)
  if "$function_name"; then
    end_ms=$(now_ms)
    elapsed_ms=$(( end_ms - start_ms ))
    printf 'ok %d - %s # time=%dms\n' "$CASE_INDEX" "$name" "$elapsed_ms"
  else
    end_ms=$(now_ms)
    elapsed_ms=$(( end_ms - start_ms ))
    FAILURES=$(( FAILURES + 1 ))
    printf 'not ok %d - %s # time=%dms\n' "$CASE_INDEX" "$name" "$elapsed_ms"
    printf '# %s\n' "${LAST_DETAIL:-case failed without diagnostics}"
  fi
}

CASE_NAMES=(
  'Railguard safe Codex response is a no-op'
  'Railguard hard block is a deny'
  'Railguard approval requirement becomes a Codex deny'
  'Railguard rejects a write outside the project fence'
  'custom Bash hook allows a safe command'
  'custom Bash hook blocks bulk staging'
  'custom Bash hook ignores apply_patch body text'
  'custom write hook blocks a sensitive patch path'
  'post-edit ShellCheck accepts a valid patch'
  'post-edit ShellCheck catches an invalid patch'
  'post-edit test runner executes for a Codex source patch'
)
CASE_FUNCTIONS=(
  case_railguard_safe_noop
  case_railguard_hard_deny
  case_railguard_approval_becomes_deny
  case_railguard_outside_fence
  case_validate_bash_safe
  case_validate_bash_bulk_stage
  case_validate_bash_patch_text
  case_validate_write_sensitive_patch
  case_shellcheck_valid_patch
  case_shellcheck_invalid_patch
  case_test_runner_patch
)
TOTAL_CASES=${#CASE_NAMES[@]}
RAILGUARD_VERSION=$("$RAILGUARD_BIN" --version 2>/dev/null || printf 'unknown')
printf 'TAP version 13\n'
printf '1..%d\n' "$TOTAL_CASES"
printf '# railguard=%s\n' "$RAILGUARD_BIN"
printf '# version=%s\n' "$RAILGUARD_VERSION"
printf '# workspace=%s\n' "$BENCH_ROOT"

for (( case_offset = 0; case_offset < TOTAL_CASES; case_offset++ )); do
  run_case "${CASE_NAMES[$case_offset]}" "${CASE_FUNCTIONS[$case_offset]}"
done

printf '# result=%d passed, %d failed\n' "$(( TOTAL_CASES - FAILURES ))" "$FAILURES"
[[ $FAILURES -eq 0 ]]
