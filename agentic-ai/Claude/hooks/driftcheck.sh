#!/usr/bin/env bash
# Stop hook: reports shell-script convention drift when Claude finishes a session.
# Findings are a nudge, never a block: they go out as hook JSON (systemMessage)
# with exit 0, so the agent is free to stop. Exit 1 = the check itself could not
# run, surfaced loudly rather than passing silently.
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
# match against repo-root-relative paths. validate.sh regression-tests this
# parsing; a revert dropped it silently once already.
set -euo pipefail

die() { printf 'driftcheck.sh: %s\n' "$1" >&2; exit 1; }

git rev-parse --git-dir &>/dev/null || exit 0
cd "$(git rev-parse --show-toplevel)"

[[ -n "${HOME:-}" ]] || die 'HOME is unset, cannot read the global ignore list'

ignore_patterns=()
for ignore_file in "$HOME/.claude/hooks/driftcheck-ignore" .driftcheckignore; do
  [[ -f "$ignore_file" ]] || continue
  while IFS= read -r pat; do
    [[ -n "$pat" && "$pat" != '#'* ]] && ignore_patterns+=("$pat")
  done < "$ignore_file"
done

# A process substitution hides git's exit status from set -e, so a failed
# listing would read as "nothing to check". Capture the list first.
tracked=$(git ls-files '*.sh') || die 'git ls-files failed, nothing was checked'

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
done <<< "$tracked"

[[ ${#issues[@]} -gt 0 ]] || exit 0

printf 'driftcheck.sh: convention drift (not blocking):\n' >&2
printf '  - %s\n' "${issues[@]}" >&2

message=$(printf 'driftcheck: %s\n' "${issues[@]}")
message_json=$(jq -Rs . <<< "$message")
printf '{"systemMessage":%s}\n' "$message_json"
