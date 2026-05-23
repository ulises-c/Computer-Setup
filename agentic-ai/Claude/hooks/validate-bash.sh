#!/usr/bin/env bash
# PreToolUse hook for Bash: blocks dangerous command patterns.
# Exit 2 = block the tool call (stderr is shown to Claude as the reason).
set -euo pipefail
trap 'exit 2' ERR

COMMAND=$(jq -r '.tool_input.command // ""')
# Heredoc bodies are message text, not executed code — policy checks use only the first line.
FIRST_LINE=$(head -1 <<< "$COMMAND")

block() {
  printf 'validate-bash.sh blocked: %s\n' "$1" >&2
  exit 2
}

# rm -rf targeting root or home directory
if grep -qE 'rm[[:space:]]+-[a-zA-Z]*(rf|fr)[a-zA-Z]*' <<< "$COMMAND" \
   && grep -qE '(^|[[:space:]])(\/|~\/?|\$HOME\/?)([[:space:]]|$)' <<< "$COMMAND"; then
  block "rm -rf on root or home directory"
fi

# dd writing to a raw device node
grep -qE '\bdd\b.*\bof=/dev/' <<< "$COMMAND" && block "dd targeting a device node"

# filesystem format
grep -qE '(^|[[:space:]])mkfs([[:space:]]|$)' <<< "$COMMAND" && block "mkfs would format a filesystem"

# redirect to block device
grep -qE '>[[:space:]]*/dev/sd' <<< "$COMMAND" && block "redirect to block device"

# redirect to sensitive credential / system paths (covers the gap that validate-write.sh can't close for shell redirects)
grep -qE '>{1,2}[[:space:]]*((~|\$HOME)/\.(ssh|aws|gnupg|config/gh)|/(etc|usr|boot|sys|proc))' <<< "$COMMAND" \
  && block "redirect to sensitive path"

# piped shell execution (curl/wget | sh)
grep -qE '(curl|wget)[[:space:]].*\|[[:space:]]*(sudo[[:space:]]+)?(ba)?sh\b' <<< "$COMMAND" \
  && block "piped shell execution (curl/wget | sh)"
grep -qE '(curl|wget)[[:space:]].*\|[[:space:]]*(python3?|ruby|node|perl)\b' <<< "$COMMAND" \
  && block "piped interpreter execution (curl/wget | interpreter)"

# force-push to main/master
grep -qE 'git[[:space:]]+push[[:space:]].*(-f\b|--force\b).*(main|master)' <<< "$COMMAND" \
  && block "force-push to main/master"
grep -qE 'git[[:space:]]+push[[:space:]].*(main|master).*(-f\b|--force\b)' <<< "$COMMAND" \
  && block "force-push to main/master"

# sudo escalation (must be explicit, not autonomous)
grep -qE '(^|[^[:alnum:]_])sudo[[:space:]]' <<< "$FIRST_LINE" \
  && block "sudo: escalation must be explicit — run the command yourself"

# git add -A / --all / . (bulk staging can silently include secrets)
grep -qE 'git[[:space:]]+add[[:space:]]+(-A\b|--all\b)' <<< "$FIRST_LINE" \
  && block "git add -A/--all — stage specific files instead"
grep -qE 'git[[:space:]]+add[[:space:]]+\.([[:space:]]|$)' <<< "$FIRST_LINE" \
  && block "git add . — stage specific files instead"

# python -c with subprocess/os.system (scoped to FIRST_LINE — same heredoc reason as sudo/git-add)
grep -qE 'python3?[[:space:]]+-c' <<< "$FIRST_LINE" \
  && grep -qE 'os\.(system|exec[vl]|popen)|subprocess\.(Popen|check_output|call|run)' <<< "$FIRST_LINE" \
  && block "python -c: inline subprocess/shell execution"

# node -e with child_process
grep -qE 'node[[:space:]]+-e' <<< "$FIRST_LINE" \
  && grep -qE "require\(['\"]child_process|execSync[[:space:]]*\(|spawnSync[[:space:]]*\(" <<< "$FIRST_LINE" \
  && block "node -e: child_process execution"

# perl -e with shell execution
grep -qE 'perl[[:space:]]+-e' <<< "$FIRST_LINE" \
  && grep -qE '(^|[^[:alnum:]_])(system|exec)[[:space:]]*\(' <<< "$FIRST_LINE" \
  && block "perl -e: inline shell execution"

exit 0
