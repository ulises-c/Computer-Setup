#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/SSH_and_GPG/add_remote_host.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
SSH_BIN="$(command -v ssh)"

STUB_BIN="$TMP_ROOT/bin"
mkdir -p "$STUB_BIN"

cat > "$STUB_BIN/ssh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SSH_LOG"
exit 0
EOF

cat > "$STUB_BIN/ssh-add" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

# Reachable only for addresses listed in NC_UP; the last two arguments are address and port.
cat > "$STUB_BIN/nc" <<'EOF'
#!/usr/bin/env bash
addr="${*: -2:1}"
[[ " ${NC_UP:-} " == *" $addr "* ]]
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

run_script() {
  env HOME="$CASE_HOME" PATH="$STUB_BIN:$PATH" SSH_LOG="$SSH_LOG" NC_UP="${NC_UP:-}" \
    SSH_AUTH_SOCK="$CASE_HOME/agent.sock" REMOTE_PASSWORD=unused SSH_PASSPHRASE=test-passphrase \
    "$@"
}

resolved() {
  env PATH="$STUB_BIN:$PATH" NC_UP="$2" "$SSH_BIN" -G -F "$CONFIG" "$1" 2>/dev/null
}

expect_hostname() {
  local alias="$1" up="$2" want="$3" output
  output="$(resolved "$alias" "$up")"
  grep -Fx "hostname $want" <<< "$output" >/dev/null ||
    fail "$alias with reachable [$up]: wanted hostname $want, got $(grep '^hostname ' <<< "$output")"
  grep -Fx "hostkeyalias $alias" <<< "$output" >/dev/null || fail "$alias: no hostkeyalias"
}

fake_host_key() {
  ssh-keygen -q -t ed25519 -N '' -C '' -f "$TMP_ROOT/hostkey-$1"
  cut -d' ' -f1,2 "$TMP_ROOT/hostkey-$1.pub"
}
KEY_A="$(fake_host_key a)"
KEY_B="$(fake_host_key b)"

# One address: the same block as before, plus HostKeyAlias and the managed markers.
new_home single
printf 'Host keep.example\n  User keep\n' > "$CONFIG"
printf '192.0.2.10 %s\n' "$KEY_A" > "$KNOWN"
ssh-keygen -q -H -f "$KNOWN" > /dev/null 2>&1
rm -f "$KNOWN.old"
run_script HOST_ALIAS=lab REMOTE_HOST=192.0.2.10 REMOTE_USER=me PORT=22 KEY_NAME=lab \
  bash "$SCRIPT" < /dev/null > /dev/null
! grep -q '^Match ' "$CONFIG" || fail "single address wrote a Match block"
grep -Fx '  HostKeyAlias lab' "$CONFIG" >/dev/null || fail "no HostKeyAlias"
grep -Fx '  User keep' "$CONFIG" >/dev/null || fail "unrelated block lost"
expect_hostname lab "" 192.0.2.10
output="$(resolved lab "")"
for line in 'user me' 'port 22' 'identitiesonly yes' "identityfile $CASE_HOME/.ssh/lab"; do
  grep -Fx "$line" <<< "$output" >/dev/null || fail "single: missing '$line'"
done
ssh-keygen -F lab -f "$KNOWN" | grep -F "${KEY_A#* }" >/dev/null || fail "trusted key not pinned to alias"
grep -F 'HostKeyAlias=lab' "$SSH_LOG" >/dev/null || fail "key copy did not use HostKeyAlias"
grep -E '(^| )me@192\.0\.2\.10( |$)' "$SSH_LOG" >/dev/null || fail "key copy went to the wrong address"
grep -E 'BatchMode=yes .* lab exit$' "$SSH_LOG" >/dev/null || fail "connection test did not go through the alias"

cp "$CONFIG" "$CASE_HOME/config.before"
cp "$KNOWN" "$CASE_HOME/known.before"
printf 'n\n' | run_script HOST_ALIAS=lab REMOTE_HOST=192.0.2.10 REMOTE_USER=me PORT=22 KEY_NAME=lab \
  bash "$SCRIPT" > /dev/null
cmp -s "$CONFIG" "$CASE_HOME/config.before" || fail "re-run with the same input changed the config"
cmp -s "$KNOWN" "$CASE_HOME/known.before" || fail "re-run pinned the key twice"

# A block from the previous version is migrated by --add-address, keeping its address last.
new_home legacy
printf '%s\n' \
  'Host before.example' '  User before' '' \
  'Host lab' '  HostName 192.0.2.10' '  User me' '  Port 22' '  AddKeysToAgent yes' \
  "  IdentityFile $CASE_HOME/.ssh/lab" '  IdentitiesOnly yes' '' \
  'Host after.example' '  User after' > "$CONFIG"
run_script bash "$SCRIPT" --add-address lab 198.51.100.20 lab.local > /dev/null
[[ "$(grep -c '^Match originalhost lab exec' "$CONFIG")" == 2 ]] || fail "expected two Match blocks"
[[ "$(grep -cx 'Host lab' "$CONFIG")" == 1 ]] || fail "legacy block not replaced"
grep -Fx '  User before' "$CONFIG" >/dev/null || fail "block before lost"
grep -Fx '  User after' "$CONFIG" >/dev/null || fail "block after lost"
expect_hostname lab "198.51.100.20 lab.local" 198.51.100.20
expect_hostname lab "lab.local" lab.local
expect_hostname lab "" 192.0.2.10
[[ "$(resolved after.example "" | grep '^hostname ')" == 'hostname after.example' ]] || fail "other hosts affected"

cp "$CONFIG" "$CASE_HOME/config.before"
run_script bash "$SCRIPT" --add-address lab 198.51.100.20 > /dev/null
cmp -s "$CONFIG" "$CASE_HOME/config.before" || fail "re-adding the first address changed the config"
run_script bash "$SCRIPT" --add-address lab lab.local > /dev/null
[[ "$(grep -c '^Match ' "$CONFIG")" == 2 ]] || fail "re-adding a stored address duplicated it"
expect_hostname lab "198.51.100.20 lab.local" lab.local
expect_hostname lab "198.51.100.20" 198.51.100.20

# A full re-run with a new address keeps the stored ones after it.
printf 'n\n' | run_script HOST_ALIAS=lab REMOTE_HOSTS='203.0.113.5' REMOTE_USER=me PORT=22 KEY_NAME=lab \
  bash "$SCRIPT" > /dev/null
expect_hostname lab "203.0.113.5 198.51.100.20" 203.0.113.5
expect_hostname lab "lab.local" lab.local
expect_hostname lab "" 192.0.2.10

# Comma- or space-separated input, non-22 port, key copied to the first reachable address.
new_home multi
printf '[192.0.2.10]:2222 %s\n' "$KEY_A" > "$KNOWN"
NC_UP="192.0.2.10" run_script HOST_ALIAS=box REMOTE_HOSTS='box.local, 192.0.2.10' REMOTE_USER=me PORT=2222 KEY_NAME=box \
  bash "$SCRIPT" < /dev/null > /dev/null
expect_hostname box "" 192.0.2.10
expect_hostname box "box.local 192.0.2.10" box.local
grep -F 'exec "nc -z -w 1 box.local 2222"' "$CONFIG" >/dev/null || fail "probe does not use the port"
grep -E '(^| )me@192\.0\.2\.10( |$)' "$SSH_LOG" >/dev/null || fail "key copy skipped the reachable address"
ssh-keygen -F box -f "$KNOWN" | grep -F "${KEY_A#* }" >/dev/null || fail "non-22 port key not pinned"

# Conflicting trusted keys for two addresses: pin nothing.
new_home conflict
printf '%s\n' 'Host lab' '  HostName 192.0.2.10' '  User me' "  IdentityFile $CASE_HOME/.ssh/lab" > "$CONFIG"
printf '192.0.2.10 %s\n198.51.100.20 %s\n' "$KEY_A" "$KEY_B" > "$KNOWN"
run_script bash "$SCRIPT" --add-address lab 198.51.100.20 > /dev/null 2> "$CASE_HOME/err"
grep -F 'different host keys' "$CASE_HOME/err" >/dev/null || fail "no conflict warning"
! ssh-keygen -F lab -f "$KNOWN" >/dev/null || fail "pinned a key despite the conflict"

# Input is validated before anything is written.
new_home invalid
if run_script HOST_ALIAS=lab REMOTE_HOSTS='192.0.2.10;touch /tmp/x' REMOTE_USER=me PORT=22 KEY_NAME=lab \
  bash "$SCRIPT" < /dev/null > /dev/null 2>&1; then
  fail "accepted an address with shell characters"
fi
[[ ! -s "$CONFIG" ]] || fail "wrote config for invalid input"
if run_script bash "$SCRIPT" --add-address nope 192.0.2.10 > /dev/null 2>&1; then
  fail "--add-address accepted an unknown alias"
fi

# --add-address refuses to drop options it does not manage.
new_home extra
printf '%s\n' 'Host lab' '  HostName 192.0.2.10' '  User me' '  ProxyJump bastion' "  IdentityFile $CASE_HOME/.ssh/lab" > "$CONFIG"
cp "$CONFIG" "$CASE_HOME/config.before"
if run_script bash "$SCRIPT" --add-address lab 198.51.100.20 > /dev/null 2> "$CASE_HOME/err"; then
  fail "--add-address rewrote a block with ProxyJump"
fi
grep -F 'ProxyJump' "$CASE_HOME/err" >/dev/null || fail "did not name the option it would drop"
cmp -s "$CONFIG" "$CASE_HOME/config.before" || fail "changed the config while refusing"

printf 'add_remote_host.sh tests passed.\n'
