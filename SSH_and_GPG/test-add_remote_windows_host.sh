#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/SSH_and_GPG/add_remote_windows_host.sh"
PWSH_IMAGE="mcr.microsoft.com/powershell:latest"

# The config rewrite and host-key pinning are shared with add_remote_host.sh.
SCRIPT_UNDER_TEST="$SCRIPT" bash "$REPO_ROOT/SSH_and_GPG/test-add_remote_host.sh" > /dev/null

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
SSH_BIN="$(command -v ssh)"
STUB_BIN="$TMP_ROOT/bin"
mkdir -p "$STUB_BIN"

# Config evaluation (-G) goes to the real client; connections are only logged.
#   SSH_FAIL_FIRST=<file>  the first connection fails once (reaches the next copy method)
#   SSH_FAIL=copy|keylogin|alias  that kind of connection fails
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
case "\${SSH_FAIL:-}:\$*" in
  copy:*powershell* | keylogin:*IdentitiesOnly=yes*exit | alias:*' win exit') exit 255 ;;
esac
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
    bash "$SCRIPT" > "$CASE_HOME/out" 2>&1
}

# The PowerShell a remote command line runs: base64 -> gzip -> text.
decode_ps() {
  sed -E "s/.*FromBase64String\('([^']+)'\).*/\1/" | base64 -d | gzip -dc
}

# The key line the decoded PowerShell installs.
installed_line() {
  decode_ps | sed -nE "1s/^\\\$keyB64 = '([^']+)'\$/\1/p" | base64 -d
}

COPY_RE="^-F /dev/null -o StrictHostKeyChecking=yes .*HostKeyAlias=win .*me@192\.0\.2\.10 powershell -NoProfile -NonInteractive -Command \"iex\(\(New-Object IO\.StreamReader\(\(New-Object IO\.Compression\.GZipStream\(\(New-Object IO\.MemoryStream\(,\[Convert\]::FromBase64String\('[A-Za-z0-9+/=]+'\)\)\), \[IO\.Compression\.CompressionMode\]::Decompress\)\)\)\)\.ReadToEnd\(\)\)\"$"

# Every copy is the encoded PowerShell, isolated from ~/.ssh/config and checked
# against the pinned host key; then one login with only the new key; then the alias.
check_flow() {
  local name="$1" copies="$2" line
  line="$(head -n 1 "$CASE_HOME/.ssh/win.pub")"
  ! grep -E 'mkdir -p|grep -qF|base64 -d|Add-Content' "$SSH_LOG" >/dev/null || fail "$name: sent a Unix command"
  [[ "$(grep -c 'powershell' "$SSH_LOG")" == "$copies" ]] || fail "$name: expected $copies copy attempt(s): $(cat "$SSH_LOG")"
  grep 'powershell' "$SSH_LOG" | grep -vE "$COPY_RE" >/dev/null && fail "$name: a copy is not isolated, strict and encoded"
  [[ "$(grep 'powershell' "$SSH_LOG" | tail -n 1 | installed_line)" == "$line" ]] || fail "$name: the command installs a different key line"
  grep 'powershell' "$SSH_LOG" | tail -n 1 | decode_ps | grep -F 'administrators_authorized_keys' >/dev/null ||
    fail "$name: no admin key file"
  grep -E "^-F /dev/null -o StrictHostKeyChecking=yes .*HostKeyAlias=win .*-o BatchMode=yes -o IdentitiesOnly=yes -o IdentityFile=$CASE_HOME/.ssh/win -o PasswordAuthentication=no -o PubkeyAcceptedAlgorithms=-\*-cert-v01@openssh\.com .*PreferredAuthentications=publickey me@192\.0\.2\.10 exit$" \
    "$SSH_LOG" >/dev/null || fail "$name: no login check with only the new key: $(cat "$SSH_LOG")"
  [[ "$(tail -n 1 "$SSH_LOG")" == *' win exit' ]] || fail "$name: the alias test is not last"
  grep -F 'Login with only the new key works.' "$CASE_HOME/out" >/dev/null || fail "$name: no key-only login reported"
  grep -F 'Done. Connect any time' "$CASE_HOME/out" >/dev/null || fail "$name: no Done"
}

new_home banner
run_script SCAN_BANNER='SSH-2.0-OpenSSH_for_Windows_9.5' < /dev/null || fail "banner: failed: $(cat "$CASE_HOME/out")"
check_flow banner 1
grep -F 'Key copied (BatchMode' "$CASE_HOME/out" >/dev/null || fail "banner: no BatchMode copy"

# No banner (e.g. keyscan blocked): the copy still runs; the key-only login decides.
new_home no-banner
run_script < /dev/null || fail "no-banner: failed: $(cat "$CASE_HOME/out")"
check_flow no-banner 1

# The password path sends the same command.
new_home sshpass
run_script SCAN_BANNER='SSH-2.0-OpenSSH_for_Windows_9.5' SSH_FAIL_FIRST="$CASE_HOME/failed-once" < /dev/null ||
  fail "sshpass: failed: $(cat "$CASE_HOME/out")"
check_flow sshpass 2
grep -E 'PubkeyAuthentication=no me@192\.0\.2\.10 powershell ' "$SSH_LOG" >/dev/null || fail "sshpass: no password copy"
grep -F 'Key copied (password auth)' "$CASE_HOME/out" >/dev/null || fail "sshpass: not reported"

# A key sshd does not accept fails the run, even though the copy "worked".
new_home keylogin-fails
if run_script SSH_FAIL=keylogin < /dev/null; then
  fail "keylogin-fails: exited 0"
fi
grep -F 'does not accept it' "$CASE_HOME/out" >/dev/null || fail "keylogin-fails: wrong error: $(cat "$CASE_HOME/out")"
! grep -F 'Done.' "$CASE_HOME/out" >/dev/null || fail "keylogin-fails: printed Done"

new_home alias-fails
if run_script SSH_FAIL=alias < /dev/null; then
  fail "alias-fails: exited 0"
fi
grep -F 'Connection test failed' "$CASE_HOME/out" >/dev/null || fail "alias-fails: wrong error: $(cat "$CASE_HOME/out")"
! grep -F 'Done.' "$CASE_HOME/out" >/dev/null || fail "alias-fails: printed Done"

# Every copy method failing exits non-zero and prints the same encoded command to run by hand.
new_home manual
if run_script SSH_FAIL=copy < /dev/null; then
  fail "manual: exited 0"
fi
grep -F 'Automatic key copy failed.' "$CASE_HOME/out" >/dev/null || fail "manual: no failure message"
manual_cmd="$(grep -E '^powershell -NoProfile -NonInteractive -Command "iex' "$CASE_HOME/out" || true)"
[[ -n "$manual_cmd" ]] || fail "manual: no command printed: $(cat "$CASE_HOME/out")"
[[ "$(installed_line <<< "$manual_cmd")" == "$(head -n 1 "$CASE_HOME/.ssh/win.pub")" ]] || fail "manual: command installs a different key"
! grep -F 'Add-Content' "$CASE_HOME/out" >/dev/null || fail "manual: printed hand-written commands"
! grep -F 'Done.' "$CASE_HOME/out" >/dev/null || fail "manual: printed Done"

# A reused key whose comment would be PowerShell syntax travels only as data.
new_home inject
ssh-keygen -q -t ed25519 -N '' -C "o’brien'; Write-Output INJECTED; ‘\$(x)\`" -f "$CASE_HOME/.ssh/win"
printf 'n\n' | run_script SCAN_BANNER='SSH-2.0-OpenSSH_for_Windows_9.5' || fail "inject: failed: $(cat "$CASE_HOME/out")"
check_flow inject 1
grep 'powershell' "$SSH_LOG" | decode_ps | grep -F 'INJECTED' >/dev/null && fail "inject: comment appears as PowerShell source"

# A reused RSA-4096 key fits under cmd.exe's limit.
new_home rsa4096
ssh-keygen -q -t rsa -b 4096 -N '' -C 'user@laptop' -f "$CASE_HOME/.ssh/win"
printf 'n\n' | run_script || fail "rsa4096: failed: $(cat "$CASE_HOME/out")"
check_flow rsa4096 1
(($(grep -m 1 'powershell' "$SSH_LOG" | sed 's/^.* powershell /powershell /' | wc -c) <= 8000)) || fail "rsa4096: command too long"

# A command that would be too long is refused before anything is written or sent.
new_home too-long
# ssh-keygen caps -C at 1023 characters, so the long comment is written directly.
ssh-keygen -q -t rsa -b 4096 -N '' -C 'x' -f "$CASE_HOME/.ssh/win"
printf '%s %s\n' "$(cut -d' ' -f1,2 "$CASE_HOME/.ssh/win.pub")" \
  "$(head -c 9000 /dev/urandom | base64 | tr -d '\n=+/' | head -c 6000)" > "$CASE_HOME/.ssh/win.pub.long"
mv "$CASE_HOME/.ssh/win.pub.long" "$CASE_HOME/.ssh/win.pub"
if printf 'n\n' | run_script; then
  fail "too-long: accepted"
fi
grep -F "over cmd.exe's limit" "$CASE_HOME/out" >/dev/null || fail "too-long: wrong error: $(cat "$CASE_HOME/out")"
[[ ! -s "$CONFIG" && ! -s "$SSH_LOG" ]] || fail "too-long: wrote config or connected"

# A public key file that is not "<type> <key> [comment]" is refused the same way.
new_home bad-pub
ssh-keygen -q -t ed25519 -N '' -C 'x' -f "$CASE_HOME/.ssh/win"
printf 'not-a-key AAAA x\n' > "$CASE_HOME/.ssh/win.pub"
if printf 'n\n' | run_script; then
  fail "bad-pub: accepted"
fi
grep -F 'supported key type' "$CASE_HOME/out" >/dev/null || fail "bad-pub: wrong error: $(cat "$CASE_HOME/out")"
[[ ! -s "$CONFIG" && ! -s "$SSH_LOG" ]] || fail "bad-pub: wrote config or connected"

# Only the first line is installed, so only the first line is validated.
new_home second-line
ssh-keygen -q -t ed25519 -N '' -C 'x' -f "$CASE_HOME/.ssh/win"
{ printf 'ssh-ed25519 AAAAbroken first\n'; cat "$CASE_HOME/.ssh/win.pub"; } > "$CASE_HOME/.ssh/win.pub.two"
mv "$CASE_HOME/.ssh/win.pub.two" "$CASE_HOME/.ssh/win.pub"
if printf 'n\n' | run_script; then
  fail "second-line: accepted an invalid first line"
fi
grep -F 'cannot read the first line' "$CASE_HOME/out" >/dev/null || fail "second-line: wrong error: $(cat "$CASE_HOME/out")"
[[ ! -s "$CONFIG" && ! -s "$SSH_LOG" ]] || fail "second-line: wrote config or connected"

# Extra spaces between the type and the key are normalized before installing.
new_home spacing
ssh-keygen -q -t ed25519 -N '' -C 'a  b' -f "$CASE_HOME/.ssh/win"
canonical="$(head -n 1 "$CASE_HOME/.ssh/win.pub")"
awk '{ printf "%s  %s \t%s  b\r\n", $1, $2, $3 }' "$CASE_HOME/.ssh/win.pub" > "$CASE_HOME/.ssh/win.pub.sp"
mv "$CASE_HOME/.ssh/win.pub.sp" "$CASE_HOME/.ssh/win.pub"
printf 'n\n' | run_script || fail "spacing: failed: $(cat "$CASE_HOME/out")"
[[ "$(grep 'powershell' "$SSH_LOG" | installed_line)" == "$canonical" ]] || fail "spacing: installed $(grep 'powershell' "$SSH_LOG" | installed_line)"

# A non-Windows server is refused before anything is written or sent.
new_home unix
if run_script SCAN_BANNER='SSH-2.0-OpenSSH_9.6p1 Ubuntu-3' < /dev/null; then
  fail "unix: accepted a non-Windows server"
fi
grep -F 'use add_remote_host.sh' "$CASE_HOME/out" >/dev/null || fail "unix: wrong error: $(cat "$CASE_HOME/out")"
[[ ! -s "$CONFIG" && ! -s "$SSH_LOG" && ! -e "$CASE_HOME/.ssh/win" ]] || fail "unix: wrote or connected before refusing"
run_script SCAN_BANNER='SSH-2.0-OpenSSH_9.6p1 Ubuntu-3' SKIP_OS_CHECK=1 < /dev/null || fail "unix: SKIP_OS_CHECK did not skip"

# ---- The generated PowerShell, executed ----
# Runs the real command in PowerShell 7 on Linux. Only what needs Windows is
# replaced: the Administrators check and the two ACL functions (Get-Acl/Set-Acl
# do not exist on Linux). Those run for real only on a Windows host.
if [[ "${SKIP_PWSH:-}" == 1 ]]; then
  printf 'add_remote_windows_host.sh tests passed (PowerShell execution skipped).\n'
  exit 0
fi
command -v docker >/dev/null || fail "docker is needed to run the PowerShell; set SKIP_PWSH=1 to skip"

PS_ROOT="$TMP_ROOT/ps"
mkdir -p "$PS_ROOT/keys"
# shellcheck source=/dev/null # sourced for its functions only.
source "$SCRIPT"
set -euo pipefail

FAKES="$(cat <<'PS'
function Test-Admin { $env:FAKE_ADMIN -eq '1' }
function Assert-UserFileAcl($f) { if ($env:FAKE_BAD_ACL -eq '1') { throw "FAKE: another account can write to $f" } }
function Set-AdminFileAcl($f) { Add-Content -LiteralPath (Join-Path $env:CASE 'acl.log') -Value "ACL-SET $f" }
PS
)"

# ps_case <name> <pub file> [ENV=value ...]: stores the command line the
# script sends, with only its payload swapped for one that has the fakes added
# before the final "try { Main }" line, and the case's environment.
ps_case() {
  local name="$1" pub="$2" cmd script last payload
  shift 2
  mkdir -p "$PS_ROOT/$name/home" "$PS_ROOT/$name/pd/ssh"
  cmd="$(windows_key_command "$pub")"
  script="$(decode_ps <<< "$cmd")"
  last="$(tail -n 1 <<< "$script")"
  # shellcheck disable=SC2016 # PowerShell text.
  [[ "$last" == 'try { Main } catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }' ]] ||
    fail "pwsh: unexpected last line of the PowerShell: $last"
  payload="$(printf '%s\n%s\n%s' "$(sed '$d' <<< "$script")" "$FAKES" "$last" | gzip -c | base64 | tr -d '\n')"
  [[ "$cmd" == *"FromBase64String('"*"')"* ]] || fail "pwsh: unexpected command shape"
  printf '%s' "${cmd%%FromBase64String\(\'*}FromBase64String('$payload')${cmd#*FromBase64String\(\'*\')}" > "$PS_ROOT/$name/cmd"
  [[ "$(sed -E "s/FromBase64String\('[^']+'\)/X/" "$PS_ROOT/$name/cmd")" == "$(sed -E "s/FromBase64String\('[^']+'\)/X/" <<< "$cmd")" ]] ||
    fail "pwsh: the stored command differs from the script's apart from the payload"
  printf '%s\n' "$@" > "$PS_ROOT/$name/env"
}

ssh-keygen -q -t ed25519 -N '' -C 'new@host' -f "$PS_ROOT/keys/ed"
ssh-keygen -q -t ed25519 -N '' -C 'old@host' -f "$PS_ROOT/keys/old"
ssh-keygen -q -t rsa -b 4096 -N '' -C 'user@laptop' -f "$PS_ROOT/keys/rsa"
ssh-keygen -q -t ed25519 -N '' -C "o’brien'; Write-Output INJECTED; ‘\$(Write-Output INJECTED2)\`" -f "$PS_ROOT/keys/inject"
NEW="$(cat "$PS_ROOT/keys/ed.pub")"
NEW_ID="$(cut -d' ' -f1,2 "$PS_ROOT/keys/ed.pub")"
OLD="$(cat "$PS_ROOT/keys/old.pub")"
OLD_ID="$(cut -d' ' -f1,2 "$PS_ROOT/keys/old.pub")"
printf '%s\x07bell\n' "$NEW_ID" > "$PS_ROOT/keys/ctrl.pub"

# seed <case> <printf format> <args...>: the case's existing authorized_keys.
seed() {
  mkdir -p "$PS_ROOT/$1/home/.ssh"
  # shellcheck disable=SC2059 # the format is the file layout.
  printf "$2" "${@:3}" > "$PS_ROOT/$1/home/.ssh/authorized_keys"
  cp "$PS_ROOT/$1/home/.ssh/authorized_keys" "$PS_ROOT/$1/before"
}

ps_case user-new "$PS_ROOT/keys/ed.pub"
ps_case user-again "$PS_ROOT/keys/ed.pub"
seed user-again '%s\r\n' "$NEW"
ps_case user-no-eol "$PS_ROOT/keys/ed.pub"
seed user-no-eol '%s' "$OLD"
ps_case user-commented "$PS_ROOT/keys/ed.pub"
seed user-commented '# %s disabled\n' "$NEW_ID"
ps_case user-options "$PS_ROOT/keys/ed.pub"
seed user-options 'from="192.0.2.1",no-pty %s kept\n' "$NEW_ID"
ps_case user-substring "$PS_ROOT/keys/ed.pub"
seed user-substring '%sXYZ other\n' "$NEW_ID"
ps_case user-bom "$PS_ROOT/keys/ed.pub"
seed user-bom '\xef\xbb\xbf%s\n' "$OLD"
ps_case user-bom-same "$PS_ROOT/keys/ed.pub"
seed user-bom-same '\xef\xbb\xbf%s\n' "$NEW"
ps_case user-utf16 "$PS_ROOT/keys/ed.pub"
seed user-utf16 '\xff\xfeX\x00'
ps_case user-bad-acl "$PS_ROOT/keys/ed.pub" FAKE_BAD_ACL=1
seed user-bad-acl '%s\n' "$OLD"
ps_case user-new-bad-acl "$PS_ROOT/keys/ed.pub" FAKE_BAD_ACL=1
ps_case opt-has-new "$PS_ROOT/keys/ed.pub"
seed opt-has-new 'command="say %s now" %s old\n' "$NEW_ID" "$OLD_ID"
ps_case opt-escaped "$PS_ROOT/keys/ed.pub"
seed opt-escaped 'command="x \\" y",no-pty %s kept\n' "$NEW_ID"
ps_case opt-spaces "$PS_ROOT/keys/ed.pub"
seed opt-spaces 'command="a b",from="x y" %s kept\n' "$NEW_ID"
ps_case opt-unclosed "$PS_ROOT/keys/ed.pub"
seed opt-unclosed 'command="a %s\n' "$NEW_ID"
ps_case defaultshell "$PS_ROOT/keys/ed.pub"
ps_case inject "$PS_ROOT/keys/inject.pub"
ps_case rsa4096 "$PS_ROOT/keys/rsa.pub"
ps_case ctrl "$PS_ROOT/keys/ctrl.pub"
ps_case admin "$PS_ROOT/keys/ed.pub" FAKE_ADMIN=1
printf 'AuthorizedKeysFile .ssh/authorized_keys\nMatch Group administrators\n  AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys\n' > "$PS_ROOT/admin/pd/ssh/sshd_config"
ps_case admin-no-match "$PS_ROOT/keys/ed.pub" FAKE_ADMIN=1
printf 'AuthorizedKeysFile .ssh/authorized_keys\n' > "$PS_ROOT/admin-no-match/pd/ssh/sshd_config"
ps_case admin-no-config "$PS_ROOT/keys/ed.pub" FAKE_ADMIN=1

# Runs each case's command line with "powershell" mapped to pwsh. bash parses
# the line the way cmd.exe hands it on (no $ or backtick in it to expand); the
# defaultshell case is parsed by PowerShell instead, as with DefaultShell set.
mkdir -p "$PS_ROOT/bin"
printf '#!/bin/sh\nexec pwsh "$@"\n' > "$PS_ROOT/bin/powershell"
chmod +x "$PS_ROOT/bin/powershell"
cat > "$PS_ROOT/run.sh" <<'EOF'
#!/usr/bin/env bash
for d in /t/*/; do
  [[ -f "$d/cmd" ]] || continue
  (
    cd "$d" || exit 1
    while IFS= read -r kv; do [[ -n "$kv" ]] && export "${kv?}"; done < env
    export USERPROFILE="${d}home" ProgramData="${d}pd" CASE="$d" HOME=/tmp PATH="/t/bin:$PATH"
    if [[ "$d" == */defaultshell/ ]]; then
      pwsh -NoProfile -NonInteractive -Command "$(cat cmd)" > out 2> err
    else
      bash -c "$(cat cmd)" > out 2> err
    fi
    echo $? > rc
  )
done
EOF
docker run --rm --user "$(id -u):$(id -g)" -v "$PS_ROOT:/t" "$PWSH_IMAGE" bash /t/run.sh ||
  fail "pwsh: the container did not run"

ps_rc() { cat "$PS_ROOT/$1/rc"; }
ps_out() { cat "$PS_ROOT/$1/out" "$PS_ROOT/$1/err"; }
user_file() { printf '%s' "$PS_ROOT/$1/home/.ssh/authorized_keys"; }
expect_ok() {
  [[ "$(ps_rc "$1")" == 0 ]] || fail "pwsh $1: exit $(ps_rc "$1"): $(ps_out "$1")"
  grep -F "$2" "$PS_ROOT/$1/out" >/dev/null || fail "pwsh $1: expected '$2': $(ps_out "$1")"
}
# expect_file <file> <case> <printf format> <args...>
expect_file() {
  local file="$1" name="$2" fmt="$3"
  shift 3
  # shellcheck disable=SC2059 # the format is the expected layout.
  cmp -s "$file" <(printf "$fmt" "$@") || fail "pwsh $name: file content differs: $(od -c "$file" | head -n 6)"
}

expect_ok user-new 'Key added to'
expect_file "$(user_file user-new)" user-new '%s\r\n' "$NEW"
expect_ok user-again 'Key already in'
cmp -s "$(user_file user-again)" "$PS_ROOT/user-again/before" || fail "pwsh user-again: changed the file"
expect_ok user-no-eol 'Key added to'
expect_file "$(user_file user-no-eol)" user-no-eol '%s\r\n%s\r\n' "$OLD" "$NEW"
expect_ok user-commented 'Key added to'
expect_file "$(user_file user-commented)" user-commented '# %s disabled\n%s\r\n' "$NEW_ID" "$NEW"
expect_ok user-options 'Key already in'
cmp -s "$(user_file user-options)" "$PS_ROOT/user-options/before" || fail "pwsh user-options: changed the file"
expect_ok user-substring 'Key added to'
expect_file "$(user_file user-substring)" user-substring '%sXYZ other\n%s\r\n' "$NEW_ID" "$NEW"
expect_ok user-bom 'Key added to'
expect_file "$(user_file user-bom)" user-bom '\xef\xbb\xbf%s\n%s\r\n' "$OLD" "$NEW"
expect_ok user-bom-same 'Key added to'
expect_file "$(user_file user-bom-same)" user-bom-same '\xef\xbb\xbf%s\n%s\r\n' "$NEW" "$NEW"
[[ "$(ps_rc user-utf16)" == 2 ]] || fail "pwsh user-utf16: exit $(ps_rc user-utf16): $(ps_out user-utf16)"
grep -F 'UTF-16' "$PS_ROOT/user-utf16/err" >/dev/null || fail "pwsh user-utf16: wrong error: $(ps_out user-utf16)"
cmp -s "$(user_file user-utf16)" "$PS_ROOT/user-utf16/before" || fail "pwsh user-utf16: changed the file"
[[ "$(ps_rc user-bad-acl)" == 1 ]] || fail "pwsh user-bad-acl: exit $(ps_rc user-bad-acl)"
grep -F 'FAKE: another account' "$PS_ROOT/user-bad-acl/err" >/dev/null || fail "pwsh user-bad-acl: wrong error: $(ps_out user-bad-acl)"
cmp -s "$(user_file user-bad-acl)" "$PS_ROOT/user-bad-acl/before" || fail "pwsh user-bad-acl: changed the file"
[[ "$(ps_rc user-new-bad-acl)" == 1 && ! -e "$(user_file user-new-bad-acl)" ]] ||
  fail "pwsh user-new-bad-acl: left a key file behind or exited $(ps_rc user-new-bad-acl): $(ps_out user-new-bad-acl)"
grep -F 'FAKE: another account' "$PS_ROOT/user-new-bad-acl/err" >/dev/null || fail "pwsh user-new-bad-acl: ACL not checked before writing"
expect_ok opt-has-new 'Key added to'
expect_file "$(user_file opt-has-new)" opt-has-new 'command="say %s now" %s old\n%s\r\n' "$NEW_ID" "$OLD_ID" "$NEW"
expect_ok opt-escaped 'Key already in'
cmp -s "$(user_file opt-escaped)" "$PS_ROOT/opt-escaped/before" || fail "pwsh opt-escaped: changed the file"
expect_ok opt-spaces 'Key already in'
cmp -s "$(user_file opt-spaces)" "$PS_ROOT/opt-spaces/before" || fail "pwsh opt-spaces: changed the file"
expect_ok opt-unclosed 'Key added to'
expect_ok defaultshell 'Key added to'
expect_file "$(user_file defaultshell)" defaultshell '%s\r\n' "$NEW"
expect_ok inject 'Key added to'
! grep -F 'INJECTED' "$PS_ROOT/inject/out" "$PS_ROOT/inject/err" >/dev/null || fail "pwsh inject: the comment ran as PowerShell"
expect_file "$(user_file inject)" inject '%s\r\n' "$(cat "$PS_ROOT/keys/inject.pub")"
expect_ok rsa4096 'Key added to'
expect_file "$(user_file rsa4096)" rsa4096 '%s\r\n' "$(cat "$PS_ROOT/keys/rsa.pub")"
[[ "$(ps_rc ctrl)" == 1 && ! -e "$(user_file ctrl)" ]] || fail "pwsh ctrl: accepted a key line with a control character: $(ps_out ctrl)"
for c in admin admin-no-config; do
  expect_ok "$c" 'administrators_authorized_keys'
  expect_file "$PS_ROOT/$c/pd/ssh/administrators_authorized_keys" "$c" '%s\r\n' "$NEW"
  grep -Fx "ACL-SET /t/$c/pd/ssh/administrators_authorized_keys" "$PS_ROOT/$c/acl.log" >/dev/null 2>&1 ||
    fail "pwsh $c: admin ACL not set on the admin file: $(cat "$PS_ROOT/$c/acl.log" 2>&1)"
  [[ ! -e "$(user_file "$c")" ]] || fail "pwsh $c: also wrote the user file"
done
expect_ok admin-no-match 'Key added to'
[[ -e "$(user_file admin-no-match)" && ! -e "$PS_ROOT/admin-no-match/pd/ssh/administrators_authorized_keys" ]] ||
  fail "pwsh admin-no-match: used the admin file without Match Group administrators"
[[ ! -e "$PS_ROOT/user-new/acl.log" && ! -e "$PS_ROOT/admin-no-match/acl.log" ]] || fail "pwsh: set the admin ACL on a user file"

printf 'add_remote_windows_host.sh tests passed.\n'
