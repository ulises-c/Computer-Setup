#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
STUB_BIN="$TMP_ROOT/bin"
mkdir -p "$STUB_BIN"

cat > "$STUB_BIN/ssh-keygen" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
while (($#)); do
  if [[ "$1" == "-f" ]]; then key_path="$2"; shift 2; else shift; fi
done
printf 'private test key\n' > "$key_path"
printf 'ssh-ed25519 AAAATEST public-test-key\n' > "$key_path.pub"
EOF
cat > "$STUB_BIN/ssh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SSH_TEST_LOG"
exit "${SSH_TEST_EXIT:-0}"
EOF
chmod +x "$STUB_BIN"/*

case_home="$TMP_ROOT/home"
mkdir -p "$case_home/.ssh"
printf 'Host unrelated\n  User preserve-me\n' > "$case_home/.ssh/config"
run_setup() {
  printf '\n' | env HOME="$case_home" PATH="$STUB_BIN:$PATH" SSH_TEST_LOG="$TMP_ROOT/ssh.log" \
    HOST_ALIAS=nas REMOTE_HOST=192.0.2.10 REMOTE_USER=nasuser PORT=22 KEY_NAME=nas \
    bash "$REPO_ROOT/SSH_and_GPG/add_truenas_host.sh"
}

output="$(run_setup)"
[[ "$output" == *'ssh-ed25519 AAAATEST public-test-key'* ]]
[[ "$output" == *'Success. Connect with: ssh nas'* ]]
grep -Fx 'Host unrelated' "$case_home/.ssh/config" >/dev/null
grep -Fx '  User preserve-me' "$case_home/.ssh/config" >/dev/null
grep -Fx 'Host nas' "$case_home/.ssh/config" >/dev/null
grep -Fx '  HostName 192.0.2.10' "$case_home/.ssh/config" >/dev/null
grep -Fx '  User nasuser' "$case_home/.ssh/config" >/dev/null
! grep -Fx '  Port 22' "$case_home/.ssh/config" >/dev/null
ssh -G -F "$case_home/.ssh/config" nas | grep -Fx 'hostname 192.0.2.10' >/dev/null
cp "$case_home/.ssh/config" "$TMP_ROOT/config.first"
run_setup >/dev/null
cmp -s "$TMP_ROOT/config.first" "$case_home/.ssh/config"
[[ "$(grep -Fc '# BEGIN add_truenas_host.sh: nas' "$case_home/.ssh/config")" == 1 ]]

printf 'Host nas\n  HostName existing.example\n  User existing-user\n' > "$case_home/.ssh/config"
cp "$case_home/.ssh/config" "$TMP_ROOT/config.alias"
if run_setup >/dev/null 2>&1; then
  printf 'Existing SSH alias unexpectedly accepted.\n' >&2
  exit 1
fi
cmp -s "$TMP_ROOT/config.alias" "$case_home/.ssh/config"

printf '# BEGIN add_truenas_host.sh: nas\nHost unrelated\n  User preserve-me\n' > "$case_home/.ssh/config"
cp "$case_home/.ssh/config" "$TMP_ROOT/config.malformed"
if run_setup >/dev/null 2>&1; then
  printf 'Unmatched managed marker unexpectedly accepted.\n' >&2
  exit 1
fi
cmp -s "$TMP_ROOT/config.malformed" "$case_home/.ssh/config"

if printf '\n' | env HOME="$case_home" PATH="$STUB_BIN:$PATH" SSH_TEST_LOG="$TMP_ROOT/ssh.log" \
  HOST_ALIAS=bad REMOTE_HOST=192.0.2.10 REMOTE_USER=nasuser PORT=22 KEY_NAME=../unsafe \
  bash "$REPO_ROOT/SSH_and_GPG/add_truenas_host.sh" >/dev/null 2>&1; then
  printf 'Unsafe key filename unexpectedly accepted.\n' >&2
  exit 1
fi

printf 'TrueNAS SSH setup tests passed.\n'
