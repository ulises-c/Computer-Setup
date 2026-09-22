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

if [[ "$*" == "config --global user.name" || "$*" == "config --global user.email" ]]; then
  exit 1
fi
exit 0
EOF

chmod +x "$STUB_BIN"/*

run_case() {
  local case_name="$1" git_host="$2" git_hostname="$3" expected_host="$4"
  local case_home="$TMP_ROOT/$case_name"
  local config
  mkdir -p "$case_home"

  printf '\n n\n' | env \
    HOME="$case_home" \
    PATH="$STUB_BIN:$PATH" \
    SSH_AUTH_SOCK="$case_home/agent.sock" \
    EMAIL='test@example.invalid' \
    KEY_NAME='forgejo' \
    GIT_HOST="$git_host" \
    IS_SELF_HOSTED=true \
    GIT_HOSTNAME="$git_hostname" \
    GIT_SSH_PORT=22 \
    SSH_PASSPHRASE='test-passphrase' \
    AGENT_TIMEOUT=15 \
    bash "$REPO_ROOT/SSH_and_GPG/create_ssh_key.sh" >/dev/null

  config="$case_home/.ssh/config"
  grep -Fx "Host $expected_host" "$config" >/dev/null
  grep -Fx '  IdentitiesOnly yes' "$config" >/dev/null
}

run_case distinct-hosts gitserver forgejo.example 'gitserver forgejo.example'
run_case identical-hosts forgejo.example forgejo.example forgejo.example

printf 'SSH config tests passed.\n'
