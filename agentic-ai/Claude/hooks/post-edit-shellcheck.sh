#!/usr/bin/env bash
# PostToolUse hook for Write/Edit/MultiEdit/apply_patch: runs shellcheck on edited .sh files.
# Exit 2 = block (Claude sees stderr and must fix before continuing).
set -euo pipefail
trap 'exit 2' ERR

command -v shellcheck &>/dev/null || exit 0

INPUT=$(cat)
CWD=$(jq -r '.cwd // ""' <<< "$INPUT")
FILES=$(jq -r '
  if (.tool_input.file_path // "") != "" then
    .tool_input.file_path
  else
    (.tool_input.command // "")
    | split("\n")[]
    | select(test("^\\*\\*\\* (Add|Update|Delete) File: |^\\*\\*\\* Move to: "))
    | sub("^\\*\\*\\* (Add|Update|Delete) File: "; "")
    | sub("^\\*\\*\\* Move to: "; "")
  end
' <<< "$INPUT")

while IFS= read -r file; do
  [[ -n "$file" ]] || continue
  if [[ "$file" != /* && -n "$CWD" ]]; then
    file="$CWD/$file"
  fi
  [[ "$file" == *.sh ]] || continue
  [[ -f "$file" ]] || continue

  # Skip zsh shebangs — only sh/bash/dash/ksh/busybox are supported (SC1071).
  [[ "$(head -n1 "$file")" == *zsh* ]] && continue

  if ! shellcheck --severity=error "$file" >&2; then
    printf '\npost-edit-shellcheck.sh: shellcheck errors in %s — fix before continuing.\n' "$file" >&2
    exit 2
  fi
done <<< "$FILES"
