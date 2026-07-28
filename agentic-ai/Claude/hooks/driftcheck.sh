#!/usr/bin/env bash
# Stop hook: validates project conventions before Claude finishes a session.
# Exit 2 = block stop (stderr injected back into Claude; must fix and try again).
#
# Checks git-tracked .sh files for consistency:
#   - has shebang but not executable → flag (meant to run but can't)
#   - is executable but no shebang  → flag (can run but no interpreter declared)
# Library/sourced files (no shebang, not executable) are intentionally skipped.
# Repo-root-relative glob patterns in ~/.claude/hooks/driftcheck-ignore
# (global) and <repo-root>/.driftcheckignore (per-repo) are exempt (for repos
# whose documented convention conflicts, e.g. scripts that are intentionally
# non-executable because a Dockerfile chmods its copies). The hook runs from
# the repo root regardless of where the session started, so patterns always
# match against repo-root-relative paths.
set -euo pipefail
trap 'exit 2' ERR

git rev-parse --git-dir &>/dev/null || exit 0
cd "$(git rev-parse --show-toplevel)"

ignore_patterns=()
for ignore_file in "$HOME/.claude/hooks/driftcheck-ignore" .driftcheckignore; do
  [[ -f "$ignore_file" ]] || continue
  while IFS= read -r pat; do
    [[ -n "$pat" && "$pat" != '#'* ]] && ignore_patterns+=("$pat")
  done < "$ignore_file"
done

issues=()

while IFS= read -r f; do
  [[ -f "$f" ]] || continue
  skipped=false
  # macOS ships bash 3.2, where "${arr[@]}" on an empty array trips set -u.
  for pat in ${ignore_patterns[@]+"${ignore_patterns[@]}"}; do
    # shellcheck disable=SC2053  # unquoted RHS is the point: patterns are globs
    if [[ "$f" == $pat ]]; then
      skipped=true
      break
    fi
  done
  "$skipped" && continue
  read -r first_line < "$f" || first_line=""
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
