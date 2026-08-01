#!/usr/bin/env bash
# PreToolUse hook for Write/Edit/MultiEdit/apply_patch: blocks writes to sensitive file paths.
# Exit 2 = block the tool call (stderr is shown to Claude as the reason).
set -euo pipefail
trap 'exit 2' ERR

INPUT=$(cat)
CWD=$(jq -r '.cwd // ""' <<< "$INPUT")
FILE_PATHS=$(jq -r '
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

block() {
  printf 'validate-write.sh blocked: %s\n' "$1" >&2
  exit 2
}

SENSITIVE_PREFIXES=(
  "$HOME/.ssh"
  "$HOME/.aws"
  "$HOME/.gnupg"
  "$HOME/.config/gh"
  "/etc"
  "/usr"
  "/boot"
  "/sys"
  "/proc"
)

while IFS= read -r file_path; do
  [[ -n "$file_path" ]] || continue
  expanded="${file_path/#\~/$HOME}"
  if [[ "$expanded" != /* && -n "$CWD" ]]; then
    expanded="$CWD/$expanded"
  fi
  for prefix in "${SENSITIVE_PREFIXES[@]}"; do
    if [[ "$expanded" == "$prefix" || "$expanded" == "$prefix/"* ]]; then
      block "write to sensitive path: $file_path"
    fi
  done
done <<< "$FILE_PATHS"

exit 0
