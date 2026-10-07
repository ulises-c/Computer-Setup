#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
SCRIPT="$REPO_ROOT/SSH_and_GPG/ssh-agent-login-unlock.sh"

home="$TMP_ROOT/home"
mkdir -p "$home/.ssh"
printf 'private key\n' > "$home/.ssh/gitkey"
printf '%s\n' 'Host git.example' "  IdentityFile $home/.ssh/gitkey" > "$home/.ssh/config"
printf '%s\n' 'alias ll="ls -l"' > "$home/.bashrc"
cp "$home/.ssh/config" "$TMP_ROOT/config.orig"
cp "$home/.bashrc" "$TMP_ROOT/bashrc.orig"

run() {
  env HOME="$home" SHELL=/bin/bash KEY_NAME=gitkey GIT_HOST=git.example AGENT_TIMEOUT=15 \
    bash "$SCRIPT" "$@" >/dev/null
}

run
run

[[ "$(grep -Fxc '# >>> ssh-agent-login-unlock: gitkey >>>' "$home/.bashrc")" == 1 ]]
[[ "$(grep -Fxc '# BEGIN ssh-agent-login-unlock: gitkey' "$home/.ssh/config")" == 1 ]]
[[ "$(head -n 1 "$home/.ssh/config")" == '# BEGIN ssh-agent-login-unlock: gitkey' ]]
grep -Fx 'alias ll="ls -l"' "$home/.bashrc" >/dev/null
grep -F 'ssh-add -t 900' "$home/.bashrc" >/dev/null
bash -n "$home/.bashrc"

output="$(ssh -G -F "$home/.ssh/config" git.example 2>/dev/null)"
grep -Fx "identityagent $home/.ssh/agent.sock" <<< "$output" >/dev/null
grep -Fx "identityfile $home/.ssh/gitkey" <<< "$output" >/dev/null

run --remove
cmp -s "$home/.ssh/config" "$TMP_ROOT/config.orig"
cmp -s "$home/.bashrc" "$TMP_ROOT/bashrc.orig"

if env HOME="$home" SHELL=/bin/bash KEY_NAME=missing GIT_HOST=git.example \
  bash "$SCRIPT" >/dev/null 2>&1; then
  printf 'error: a missing key was accepted\n' >&2
  exit 1
fi

printf 'ssh-agent-login-unlock tests passed.\n'
