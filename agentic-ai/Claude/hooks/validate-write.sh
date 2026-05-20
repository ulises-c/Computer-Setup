#!/usr/bin/env bash
# PreToolUse hook for Write/Edit/MultiEdit: blocks writes to sensitive file paths.
# Exit 2 = block the tool call (stderr is shown to Claude as the reason).

INPUT=$(cat)
FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // ""')

block() {
  printf 'validate-write.sh blocked: %s\n' "$1" >&2
  exit 2
}

# Expand leading ~ to $HOME for comparison
EXPANDED="${FILE_PATH/#\~/$HOME}"

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

for prefix in "${SENSITIVE_PREFIXES[@]}"; do
  if [[ "$EXPANDED" == "$prefix"* ]]; then
    block "write to sensitive path: $FILE_PATH"
  fi
done

exit 0
