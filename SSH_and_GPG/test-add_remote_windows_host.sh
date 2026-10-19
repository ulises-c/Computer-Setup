#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/SSH_and_GPG/add_remote_windows_host.sh"

# The config rewrite and host-key pinning are shared with add_remote_host.sh.
SCRIPT_UNDER_TEST="$SCRIPT" bash "$REPO_ROOT/SSH_and_GPG/test-add_remote_host.sh" > /dev/null

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
SSH_BIN="$(command -v ssh)"
STUB_BIN="$TMP_ROOT/bin"
mkdir -p "$STUB_BIN"

# Config evaluation (-G) goes to the real client; connections are only logged.
# SSH_FAIL_FIRST=<file>: the first connection fails once, to reach the next copy method.
cat > "$STUB_BIN/ssh" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == -G ]]; then
  exec "$SSH_BIN" "\$@"
fi
printf '%s\\n' "\$*" >> "\$SSH_LOG"
if [[ -n "\${SSH_FAIL_FIRST:-}" && ! -e "\$SSH_FAIL_FIRST" ]]; then
  : > "\$SSH_FAIL_FIRST"
  exit 1
fi
exit 0
EOF

cat > "$STUB_BIN/ssh-add" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

# Prints SCAN_BANNER as the server version on stderr and SCAN_KEY as the host key, as ssh-keyscan does.
cat > "$STUB_BIN/ssh-keyscan" <<'EOF'
#!/usr/bin/env bash
[[ -n "${SCAN_BANNER:-}" ]] && printf '# %s:22 %s\n' "${*: -1}" "$SCAN_BANNER" >&2
[[ -n "${SCAN_KEY:-}" ]] && printf '%s %s\n' "${*: -1}" "$SCAN_KEY"
exit 0
EOF

# Drops "-p <password>" and runs the rest.
cat > "$STUB_BIN/sshpass" <<'EOF'
#!/usr/bin/env bash
shift 2
exec "$@"
EOF

chmod +x "$STUB_BIN"/*

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

new_home() {
  CASE_HOME="$TMP_ROOT/$1"
  mkdir -p "$CASE_HOME/.ssh"
  CONFIG="$CASE_HOME/.ssh/config"
  KNOWN="$CASE_HOME/.ssh/known_hosts"
  SSH_LOG="$CASE_HOME/ssh.log"
  : > "$SSH_LOG"
}

ssh-keygen -q -t ed25519 -N '' -C '' -f "$TMP_ROOT/hostkey"
KEY_A="$(cut -d' ' -f1,2 "$TMP_ROOT/hostkey.pub")"

run_script() {
  printf '192.0.2.10 %s\n' "$KEY_A" > "$KNOWN"
  env HOME="$CASE_HOME" PATH="$STUB_BIN:$PATH" SSH_LOG="$SSH_LOG" SSH_AUTH_SOCK="$CASE_HOME/agent.sock" \
    REMOTE_PASSWORD=unused SSH_PASSPHRASE=test-passphrase \
    HOST_ALIAS=win REMOTE_HOST=192.0.2.10 REMOTE_USER=me PORT=22 KEY_NAME=win "$@" \
    bash "$SCRIPT" < /dev/null > "$CASE_HOME/out" 2>&1
}

decode_ps() {
  awk '{ print $NF }' | base64 -d | iconv -f UTF-16LE -t UTF-8
}

# Every connection to the remote is one encoded PowerShell command, isolated
# from ~/.ssh/config and checked against the pinned host key.
check_commands() {
  local name="$1" copies="$2" blob line
  ! grep -E 'mkdir -p|grep -qF|base64 -d' "$SSH_LOG" >/dev/null || fail "$name: sent a Unix command"
  [[ "$(grep -c -- '-EncodedCommand' "$SSH_LOG")" == $((copies + 1)) ]] ||
    fail "$name: expected $copies copy attempt(s) and a check: $(cat "$SSH_LOG")"
  grep -- '-EncodedCommand' "$SSH_LOG" | grep -vE '^-F /dev/null -o StrictHostKeyChecking=yes .*HostKeyAlias=win .*me@192\.0\.2\.10 powershell -NoProfile -NonInteractive -EncodedCommand [A-Za-z0-9+/=]+$' >/dev/null &&
    fail "$name: a command is not isolated and strict"
  blob="$(awk '{ print $2 }' "$CASE_HOME/.ssh/win.pub")"
  line="$(head -n 1 "$CASE_HOME/.ssh/win.pub")"
  grep -m 1 -- '-EncodedCommand' "$SSH_LOG" | decode_ps > "$CASE_HOME/copy.ps1"
  grep -- '-EncodedCommand' "$SSH_LOG" | tail -n 1 | decode_ps > "$CASE_HOME/verify.ps1"
  grep -Fx "\$blob = '$blob'" "$CASE_HOME/copy.ps1" >/dev/null || fail "$name: key not in the command"
  grep -Fx "\$line = '$line'" "$CASE_HOME/copy.ps1" >/dev/null || fail "$name: key line not in the command"
  grep -Fx "\$verifyOnly = \$false" "$CASE_HOME/copy.ps1" >/dev/null || fail "$name: copy runs in verify mode"
  grep -Fx "\$verifyOnly = \$true" "$CASE_HOME/verify.ps1" >/dev/null || fail "$name: check does not run in verify mode"
  grep -F 'administrators_authorized_keys' "$CASE_HOME/copy.ps1" >/dev/null || fail "$name: no admin key file"
  (($(grep -m 1 -- '-EncodedCommand' "$SSH_LOG" | awk '{ print length }') < 8000)) ||
    fail "$name: command too long for cmd.exe"
}

new_home banner
run_script SCAN_BANNER='SSH-2.0-OpenSSH_for_Windows_9.5' || fail "banner: failed: $(cat "$CASE_HOME/out")"
check_commands banner 1
grep -F 'Key copied (BatchMode' "$CASE_HOME/out" >/dev/null || fail "banner: no BatchMode copy"

# No banner (e.g. keyscan blocked): the copy still runs; it fails on its own if the remote is not Windows.
new_home no-banner
run_script || fail "no-banner: failed: $(cat "$CASE_HOME/out")"
check_commands no-banner 1

# The password path sends the same command.
new_home sshpass
run_script SCAN_BANNER='SSH-2.0-OpenSSH_for_Windows_9.5' SSH_FAIL_FIRST="$CASE_HOME/failed-once" ||
  fail "sshpass: failed: $(cat "$CASE_HOME/out")"
check_commands sshpass 2
grep -E 'PubkeyAuthentication=no me@192\.0\.2\.10 powershell ' "$SSH_LOG" >/dev/null || fail "sshpass: no password copy"
grep -F 'Key copied (password auth)' "$CASE_HOME/out" >/dev/null || fail "sshpass: not reported"
grep -E 'PubkeyAuthentication=no me@192\.0\.2\.10 powershell ' "$SSH_LOG" | decode_ps |
  grep -Fx "\$verifyOnly = \$false" >/dev/null || fail "sshpass: password copy runs in verify mode"

# A reused key whose comment has a ' still makes a valid PowerShell string ('' inside '...').
new_home quote
ssh-keygen -q -t ed25519 -N '' -C "o'brien@laptop" -f "$CASE_HOME/.ssh/win"
printf '192.0.2.10 %s\n' "$KEY_A" > "$KNOWN"
printf 'n\n' | env HOME="$CASE_HOME" PATH="$STUB_BIN:$PATH" SSH_LOG="$SSH_LOG" SSH_AUTH_SOCK="$CASE_HOME/agent.sock" \
  REMOTE_PASSWORD=unused SSH_PASSPHRASE=unused SCAN_BANNER='SSH-2.0-OpenSSH_for_Windows_9.5' \
  HOST_ALIAS=win REMOTE_HOST=192.0.2.10 REMOTE_USER=me PORT=22 KEY_NAME=win \
  bash "$SCRIPT" > "$CASE_HOME/out" 2>&1 || fail "quote: failed: $(cat "$CASE_HOME/out")"
grep -m 1 -- '-EncodedCommand' "$SSH_LOG" | decode_ps |
  grep -Fx "\$line = '$(sed "s/'/''/g" "$CASE_HOME/.ssh/win.pub")'" >/dev/null || fail "quote: ' not escaped"

# A non-Windows server is refused before anything is written or sent.
new_home unix
if run_script SCAN_BANNER='SSH-2.0-OpenSSH_9.6p1 Ubuntu-3'; then
  fail "unix: accepted a non-Windows server"
fi
grep -F 'use add_remote_host.sh' "$CASE_HOME/out" >/dev/null || fail "unix: wrong error: $(cat "$CASE_HOME/out")"
[[ ! -s "$CONFIG" && ! -s "$SSH_LOG" && ! -e "$CASE_HOME/.ssh/win" ]] || fail "unix: wrote or connected before refusing"
run_script SCAN_BANNER='SSH-2.0-OpenSSH_9.6p1 Ubuntu-3' SKIP_OS_CHECK=1 || fail "unix: SKIP_OS_CHECK did not skip"

# A failed copy prints PowerShell instructions, not a bash one-liner.
new_home manual
cat > "$CASE_HOME/ssh" <<EOF
#!/usr/bin/env bash
[[ "\$1" == -G ]] && exec "$SSH_BIN" "\$@"
printf '%s\\n' "\$*" >> "\$SSH_LOG"
exit 255
EOF
chmod +x "$CASE_HOME/ssh"
run_script PATH="$CASE_HOME:$STUB_BIN:$PATH" SCAN_BANNER='SSH-2.0-OpenSSH_for_Windows_9.5' ||
  fail "manual: failed: $(cat "$CASE_HOME/out")"
# shellcheck disable=SC2016 # $env: is PowerShell text, not a shell expansion.
grep -F 'Add-Content -Encoding ascii "$env:ProgramData\ssh\administrators_authorized_keys"' "$CASE_HOME/out" >/dev/null ||
  fail "manual: no PowerShell instructions"
grep -F "'$(head -n 1 "$CASE_HOME/.ssh/win.pub")'" "$CASE_HOME/out" >/dev/null || fail "manual: key not in the instructions"
! grep -F '>> ~/.ssh/authorized_keys' "$CASE_HOME/out" >/dev/null || fail "manual: printed the Unix command"

printf 'add_remote_windows_host.sh tests passed.\n'
