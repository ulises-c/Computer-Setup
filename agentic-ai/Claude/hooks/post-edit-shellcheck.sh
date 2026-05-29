#!/usr/bin/env bash
# PostToolUse hook for Write/Edit/MultiEdit: runs shellcheck on edited .sh files.
# Exit 2 = block (Claude sees stderr and must fix before continuing).
set -euo pipefail
trap 'exit 2' ERR

command -v shellcheck &>/dev/null || exit 0

INPUT=$(cat)
FILE=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // ""')

[[ "$FILE" == *.sh ]] || exit 0
[[ -f "$FILE" ]] || exit 0

# Skip zsh shebangs — only sh/bash/dash/ksh/busybox are supported (SC1071).
[[ "$(head -n1 "$FILE")" == *zsh* ]] && exit 0

if ! shellcheck --severity=error "$FILE" >&2; then
  printf '\npost-edit-shellcheck.sh: shellcheck errors in %s — fix before continuing.\n' "$FILE" >&2
  exit 2
fi
