# shellcheck shell=bash
# Runtime files, caches, credentials and backups that never go into a config
# repo: the one list for the state snapshot (bin/hermes-config) and for
# install.sh (--adopt, and the profile scripts it copies). A name matches on
# any path component, so a dir named like one (archive.bak-old/, auth.json/)
# keeps out everything under it.
HERMES_NEVER_COPY=(__pycache__ mcp-tokens '*.pyc' '*.lock' '*.bak*' '.env*' auth.json '*.db*')

# The same list as find(1) tests, to prune with: -o -name a -o -name b ...
HERMES_NEVER_COPY_FIND=()
for _glob in "${HERMES_NEVER_COPY[@]}"; do HERMES_NEVER_COPY_FIND+=(-o -name "$_glob"); done
unset _glob

# 0 when one component of the relative path <path> is on the list.
hermes_never_copy() {
  local rest="$1/" part glob
  while [[ -n "$rest" ]]; do
    part="${rest%%/*}" rest="${rest#*/}"
    [[ -n "$part" ]] || continue
    for glob in "${HERMES_NEVER_COPY[@]}"; do
      # shellcheck disable=SC2053  # $glob is a glob on purpose
      [[ "$part" == $glob ]] && return 0
    done
  done
  return 1
}
