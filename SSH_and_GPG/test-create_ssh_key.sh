#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
SSH_BIN="$(command -v ssh)"

STUB_BIN="$TMP_ROOT/bin"
mkdir -p "$STUB_BIN"

cat > "$STUB_BIN/ssh-keygen" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

key_path=""
while (($#)); do
  if [[ "$1" == "-f" ]]; then
    key_path="$2"
    shift 2
  else
    shift
  fi
done
printf 'private key\n' > "$key_path"
printf 'public key\n' > "$key_path.pub"
EOF

cat > "$STUB_BIN/ssh-add" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "$STUB_BIN/ssh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "$STUB_BIN/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "$*" in
  "config --global user.name") printf 'Test User\n' ;;
  "config --global user.email") printf 'test@example.invalid\n' ;;
  *) exit 0 ;;
esac
EOF

chmod +x "$STUB_BIN"/*

run_case() {
  local case_name="$1" git_host="$2" git_hostname="$3" expected_host="$4"
  local case_home="$TMP_ROOT/$case_name"
  local config output target count
  mkdir -p "$case_home/.ssh"
  config="$case_home/.ssh/config"
  printf '%s\n' \
    '# BEGIN create_ssh_key.sh' \
    'Host obsolete.example' \
    '  IdentityFile /obsolete/key' \
    '# END create_ssh_key.sh' \
    'Host unrelated.example' \
    '  User preserve-me' > "$config"

  printf '\n' | env \
    HOME="$case_home" \
    PATH="$STUB_BIN:$PATH" \
    SSH_AUTH_SOCK="$case_home/agent.sock" \
    EMAIL='test@example.invalid' \
    KEY_NAME='forgejo' \
    GIT_HOST="$git_host" \
    IS_SELF_HOSTED=true \
    GIT_HOSTNAME="$git_hostname" \
    GIT_SSH_PORT=2222 \
    SSH_PASSPHRASE='test-passphrase' \
    AGENT_TIMEOUT=15 \
    bash "$REPO_ROOT/SSH_and_GPG/create_ssh_key.sh" >/dev/null

  cp "$config" "$case_home/config.first-run"

  printf 'n\n\n' | env \
    HOME="$case_home" \
    PATH="$STUB_BIN:$PATH" \
    SSH_AUTH_SOCK="$case_home/agent.sock" \
    EMAIL='test@example.invalid' \
    KEY_NAME='forgejo' \
    GIT_HOST="$git_host" \
    IS_SELF_HOSTED=true \
    GIT_HOSTNAME="$git_hostname" \
    GIT_SSH_PORT=2222 \
    SSH_PASSPHRASE='test-passphrase' \
    AGENT_TIMEOUT=15 \
    bash "$REPO_ROOT/SSH_and_GPG/create_ssh_key.sh" >/dev/null

  cmp -s "$config" "$case_home/config.first-run"
  count="$(grep -Fxc '# BEGIN create_ssh_key.sh: forgejo' "$config" || true)"
  [[ "$count" == 1 ]]
  count="$(grep -Fxc "Host $expected_host" "$config" || true)"
  [[ "$count" == 1 ]]
  ! grep -F 'obsolete.example' "$config" >/dev/null
  ! grep -Fx '# BEGIN create_ssh_key.sh' "$config" >/dev/null
  ! grep -Fx '# END create_ssh_key.sh' "$config" >/dev/null
  grep -Fx 'Host unrelated.example' "$config" >/dev/null
  grep -Fx '  User preserve-me' "$config" >/dev/null

  for target in "$git_host" "$git_hostname"; do
    output="$("$SSH_BIN" -G -F "$config" "$target" 2>/dev/null)"
    grep -Fx "hostname $git_hostname" <<< "$output" >/dev/null
    grep -Fx 'user git' <<< "$output" >/dev/null
    grep -Fx 'port 2222' <<< "$output" >/dev/null
    grep -Fx 'addkeystoagent 900' <<< "$output" >/dev/null
    grep -Fx 'identitiesonly yes' <<< "$output" >/dev/null
    grep -Fx "identityfile $case_home/.ssh/forgejo" <<< "$output" >/dev/null
  done
}

run_case distinct-hosts gitserver forgejo.example 'gitserver forgejo.example'
run_case identical-hosts forgejo.example forgejo.example forgejo.example

printf 'SSH config tests passed.\n'
