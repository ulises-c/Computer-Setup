# Bash Style Rules

- Shebang: always `#!/usr/bin/env bash` (not `/bin/bash`).
- Set at the top of every non-trivial script: `set -euo pipefail`.
- Use `[[ ]]` not `[ ]` for conditionals.
- Quote all variable expansions: `"$var"`, `"${arr[@]}"`.
- Use `printf` not `echo` for reliable, portable output.
- Declare function-local variables with `local`.
- Write error messages to stderr: `printf 'error: %s\n' "$msg" >&2`.
- Prefer `command -v foo` over `which foo` to check for executables.
- Use `<<< "$var"` (herestring) instead of `echo "$var" |` to avoid a subshell.
