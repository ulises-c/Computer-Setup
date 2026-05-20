#!/usr/bin/env bash
# Stop hook: validates project conventions before Claude finishes a session.
# Exit 2 = block stop (stderr injected back into Claude; must fix and try again).
#
# Checks git-tracked .sh files for consistency:
#   - has shebang but not executable → flag (meant to run but can't)
#   - is executable but no shebang  → flag (can run but no interpreter declared)
# Library/sourced files (no shebang, not executable) are intentionally skipped.

git rev-parse --git-dir &>/dev/null || exit 0

issues=()

while IFS= read -r f; do
  [[ -f "$f" ]] || continue
  read -r first_line < "$f"
  has_shebang=false; is_exec=false
  [[ "$first_line" == '#!'* ]] && has_shebang=true
  [[ -x "$f" ]] && is_exec=true

  if $has_shebang && ! $is_exec; then
    issues+=("has shebang but missing execute permission: $f")
  elif $is_exec && ! $has_shebang; then
    issues+=("is executable but missing shebang: $f")
  fi
done < <(git ls-files '*.sh')

if [[ ${#issues[@]} -gt 0 ]]; then
  printf 'driftcheck.sh: convention violations found:\n' >&2
  printf '  - %s\n' "${issues[@]}" >&2
  printf 'Fix these before finishing.\n' >&2
  exit 2
fi
