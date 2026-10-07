#!/usr/bin/env bash
set -euo pipefail

# Unlock a passphrase-protected SSH key once per interactive login and keep it
# for a fixed time in one agent on a fixed socket. Non-interactive SSH and git
# (cron, scripts, `ssh host cmd`, agent tools) never source the shell's agent
# variables, so the Host block points them at that socket with IdentityAgent.
#
#   KEY_NAME=bitbucket GIT_HOST=bitbucket.org bash ssh-agent-login-unlock.sh
#   ... --remove   # take the snippet and the IdentityAgent line out again

KEY_NAME="${KEY_NAME:-}"
GIT_HOST="${GIT_HOST:-}"
AGENT_TIMEOUT="${AGENT_TIMEOUT:-15}"
SHELL_RC="${SHELL_RC:-}"
REMOVE=0
[[ "${1:-}" == "--remove" ]] && REMOVE=1

if [[ -z "$KEY_NAME" ]]; then
  read -r -p "Key file name in ~/.ssh: " KEY_NAME
fi
if [[ -z "$GIT_HOST" ]]; then
  read -r -p "SSH host pattern the key is used for (e.g. bitbucket.org): " GIT_HOST
fi
if [[ "$KEY_NAME" == "." || "$KEY_NAME" == ".." || ! "$KEY_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  printf 'error: KEY_NAME must be a simple file name in ~/.ssh\n' >&2
  exit 1
fi
if [[ ! "$GIT_HOST" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]]; then
  printf 'error: GIT_HOST must be one literal host name\n' >&2
  exit 1
fi
if [[ ! "$AGENT_TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
  printf 'error: AGENT_TIMEOUT must be a whole number of minutes, 1 or more\n' >&2
  exit 1
fi
if [[ -z "$SHELL_RC" ]]; then
  case "$(basename "${SHELL:-bash}")" in
    zsh) SHELL_RC="$HOME/.zshrc" ;;
    *) SHELL_RC="$HOME/.bashrc" ;;
  esac
fi

SSH_DIR="$HOME/.ssh"
KEY_PATH="$SSH_DIR/$KEY_NAME"
CFG_PATH="$SSH_DIR/config"
SOCK="$SSH_DIR/agent.sock"
SECONDS_TTL=$((AGENT_TIMEOUT * 60))
FN="sshkey_${KEY_NAME//[.-]/_}"

rc_begin="# >>> ssh-agent-login-unlock: $KEY_NAME >>>"
rc_end="# <<< ssh-agent-login-unlock: $KEY_NAME <<<"
cfg_begin="# BEGIN ssh-agent-login-unlock: $KEY_NAME"
cfg_end="# END ssh-agent-login-unlock: $KEY_NAME"

strip_block() {
  local file="$1" begin="$2" end="$3" tmp
  [[ -f "$file" ]] || return 0
  tmp="$(mktemp "$file.XXXXXX")"
  awk -v b="$begin" -v e="$end" '$0 == b {skip = 1; next} skip && $0 == e {skip = 0; next} !skip' "$file" > "$tmp"
  chmod --reference="$file" "$tmp" 2>/dev/null || chmod 600 "$tmp"
  mv "$tmp" "$file"
}

strip_block "$SHELL_RC" "$rc_begin" "$rc_end"
strip_block "$CFG_PATH" "$cfg_begin" "$cfg_end"

if [[ "$REMOVE" == 1 ]]; then
  printf 'Removed the %s unlock snippet from %s and its IdentityAgent block from %s.\n' "$KEY_NAME" "$SHELL_RC" "$CFG_PATH"
  exit 0
fi

if [[ ! -f "$KEY_PATH" ]]; then
  printf 'error: %s does not exist; create it with create_ssh_key.sh first\n' "$KEY_PATH" >&2
  exit 1
fi

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
touch "$CFG_PATH"
chmod 600 "$CFG_PATH"

# Prepended: ssh uses the first value it finds for each option, so this block
# must come before any other Host block for the same host.
cfg_tmp="$(mktemp "$CFG_PATH.XXXXXX")"
{
  printf '%s\n' "$cfg_begin"
  printf 'Host %s\n' "$GIT_HOST"
  printf '  IdentityAgent %s\n' "$SOCK"
  printf '%s\n' "$cfg_end"
  cat "$CFG_PATH"
} > "$cfg_tmp"
chmod 600 "$cfg_tmp"
mv "$cfg_tmp" "$CFG_PATH"

# The snippet is plain POSIX-ish shell so it works in both bash and zsh.
{
  printf '%s\n' "$rc_begin"
  printf '# One ssh-agent on %s, shared by every shell and by non-interactive\n' "$SOCK"
  printf '# ssh/git (via IdentityAgent in ~/.ssh/config). An interactive login asks\n'
  printf '# for the %s passphrase when the key is not loaded; the agent drops it\n' "$KEY_NAME"
  printf '# %s minutes later. Ctrl-C skips. Reload any time with: %s\n' "$AGENT_TIMEOUT" "$FN"
  printf '%s() { SSH_AUTH_SOCK=%q ssh-add -t %s %q; }\n' "$FN" "$SOCK" "$SECONDS_TTL" "$KEY_PATH"
  printf 'SSH_AUTH_SOCK=%q ssh-add -l >/dev/null 2>&1\n' "$SOCK"
  printf 'if [ $? -eq 2 ]; then\n'
  printf '    rm -f %q\n' "$SOCK"
  printf '    ssh-agent -a %q -t %s >/dev/null\n' "$SOCK" "$SECONDS_TTL"
  printf 'fi\n'
  printf 'if [ -t 0 ] && [ -f %q ] &&\n' "$KEY_PATH"
  printf '   ! SSH_AUTH_SOCK=%q ssh-add -T %q >/dev/null 2>&1; then\n' "$SOCK" "$KEY_PATH.pub"
  printf '    echo "%s key not loaded (%s min lifetime). Ctrl-C to skip."\n' "$KEY_NAME" "$AGENT_TIMEOUT"
  printf '    %s\n' "$FN"
  printf 'fi\n'
  printf '%s\n' "$rc_end"
} >> "$SHELL_RC"

printf 'Added the %s unlock snippet to %s and IdentityAgent %s for %s in %s.\n' \
  "$KEY_NAME" "$SHELL_RC" "$SOCK" "$GIT_HOST" "$CFG_PATH"
printf 'Open a new login shell to unlock it, or run: %s\n' "$FN"
