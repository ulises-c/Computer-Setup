#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/SSH_and_GPG/add_remote_host.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
SSH_BIN="$(command -v ssh)"

STUB_BIN="$TMP_ROOT/bin"
mkdir -p "$STUB_BIN"

# Config evaluation (-G) goes to the real client; connections are only logged.
cat > "$STUB_BIN/ssh" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == -G ]]; then
  exec "$SSH_BIN" "\$@"
fi
printf '%s\\n' "\$*" >> "\$SSH_LOG"
exit 0
EOF

cat > "$STUB_BIN/ssh-add" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

# Presents SCAN_KEY ("<type> <base64>") as the host key of any address.
cat > "$STUB_BIN/ssh-keyscan" <<'EOF'
#!/usr/bin/env bash
[[ -n "${SCAN_KEY:-}" ]] && printf '%s %s\n' "${*: -1}" "$SCAN_KEY"
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
  env HOME="$CASE_HOME" PATH="$STUB_BIN:$PATH" SSH_LOG="$SSH_LOG" NC_UP="${NC_UP:-}" SCAN_KEY="${SCAN_KEY:-}" \
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
grep -E '^-F /dev/null -o StrictHostKeyChecking=yes .*me@192\.0\.2\.10' "$SSH_LOG" >/dev/null ||
  fail "key copy is not isolated from ~/.ssh/config or not strict"
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

# A full re-run with a new address keeps the stored ones after it. Nothing is
# trusted for this alias yet, so the scanned key is confirmed first.
printf 'y\nn\n' | SCAN_KEY="$KEY_A" run_script HOST_ALIAS=lab REMOTE_HOSTS='203.0.113.5' REMOTE_USER=me PORT=22 KEY_NAME=lab \
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

# Addresses whose trusted keys disagree may be different machines: refuse before writing.
conflict_case() {
  local name="$1" key_other="$2"
  new_home "conflict-$name"
  printf '%s\n' 'Host lab' '  HostName 192.0.2.10' '  User me' "  IdentityFile $CASE_HOME/.ssh/lab" > "$CONFIG"
  printf '192.0.2.10 %s\n198.51.100.20 %s\n' "$KEY_A" "$key_other" > "$KNOWN"
  cp "$CONFIG" "$CASE_HOME/config.before"
  if run_script bash "$SCRIPT" --add-address lab 198.51.100.20 > /dev/null 2> "$CASE_HOME/err"; then
    fail "$name: --add-address accepted conflicting host keys"
  fi
  grep -F 'may be different machines' "$CASE_HOME/err" >/dev/null || fail "$name: no conflict error"
  cmp -s "$CONFIG" "$CASE_HOME/config.before" || fail "$name: changed the config despite the conflict"
  ! ssh-keygen -F lab -f "$KNOWN" >/dev/null || fail "$name: pinned a key despite the conflict"

  : > "$SSH_LOG"
  if printf 'n\n' | run_script HOST_ALIAS=lab REMOTE_HOSTS='198.51.100.20' REMOTE_USER=me PORT=22 KEY_NAME=lab \
    bash "$SCRIPT" > /dev/null 2>&1; then
    fail "$name: setup run accepted conflicting host keys"
  fi
  [[ ! -s "$SSH_LOG" ]] || fail "$name: connected despite the conflict"
}
conflict_case same-type "$KEY_B"
ssh-keygen -q -t rsa -b 2048 -N '' -C '' -f "$TMP_ROOT/hostkey-rsa"
conflict_case other-type "$(cut -d' ' -f1,2 "$TMP_ROOT/hostkey-rsa.pub")"

# Two addresses that share a key are the same machine. Only the first address's
# keys are pinned; the others are checked against it, never added to it.
new_home shared
printf '%s\n' 'Host lab' '  HostName 192.0.2.10' '  User me' "  IdentityFile $CASE_HOME/.ssh/lab" > "$CONFIG"
printf '192.0.2.10 %s\n192.0.2.10 %s\n198.51.100.20 %s\n' "$KEY_A" "$(cut -d' ' -f1,2 "$TMP_ROOT/hostkey-rsa.pub")" "$KEY_A" > "$KNOWN"
run_script bash "$SCRIPT" --add-address lab 198.51.100.20 > /dev/null
[[ "$(ssh-keygen -F lab -f "$KNOWN" | grep -vc '^#')" == 1 ]] || fail "shared: expected only the first address's key pinned"
ssh-keygen -F lab -f "$KNOWN" | grep -F "${KEY_A#* }" >/dev/null || fail "shared: wrong key pinned"

# Same-type keys that differ on the first address (the new one, listed first)
# are a conflict even when another address shares one of them.
new_home anchor-conflict
printf '%s\n' 'Host lab' '  HostName 192.0.2.10' '  User me' "  IdentityFile $CASE_HOME/.ssh/lab" > "$CONFIG"
printf '198.51.100.20 %s\n198.51.100.20 %s\n192.0.2.10 %s\n' "$KEY_A" "$KEY_B" "$KEY_A" > "$KNOWN"
if run_script bash "$SCRIPT" --add-address lab 198.51.100.20 > /dev/null 2>&1; then
  fail "anchor-conflict: accepted two different same-type keys"
fi
! ssh-keygen -F lab -f "$KNOWN" >/dev/null || fail "anchor-conflict: pinned"

# A @revoked key for one of the addresses stops the run.
new_home revoked
printf '%s\n' 'Host lab' '  HostName 192.0.2.10' '  User me' "  IdentityFile $CASE_HOME/.ssh/lab" > "$CONFIG"
printf '@revoked 198.51.100.20 %s\n' "$KEY_B" > "$KNOWN"
cp "$CONFIG" "$CASE_HOME/config.before"
if run_script bash "$SCRIPT" --add-address lab 198.51.100.20 > /dev/null 2> "$CASE_HOME/err"; then
  fail "revoked: accepted"
fi
grep -F '@revoked' "$CASE_HOME/err" >/dev/null || fail "revoked: wrong error: $(cat "$CASE_HOME/err")"
cmp -s "$CONFIG" "$CASE_HOME/config.before" || fail "revoked: changed the config"

# First use with nothing trusted: the scanned key must be confirmed; "no" changes nothing.
new_home first-use
printf 'n\n' | SCAN_KEY="$KEY_B" run_script HOST_ALIAS=lab REMOTE_HOSTS='192.0.2.10' REMOTE_USER=me PORT=22 KEY_NAME=lab \
  bash "$SCRIPT" > "$CASE_HOME/out" 2>&1 && fail "first-use: accepted without confirmation"
grep -F 'SHA256:' "$CASE_HOME/out" >/dev/null || fail "first-use: no fingerprint shown"
[[ ! -s "$CONFIG" && ! -s "$SSH_LOG" ]] || fail "first-use: wrote config or connected after 'no'"
[[ ! -e "$KNOWN" ]] || ! ssh-keygen -F lab -f "$KNOWN" >/dev/null || fail "first-use: pinned after 'no'"
printf 'y\n' | SCAN_KEY="$KEY_B" run_script HOST_ALIAS=lab REMOTE_HOSTS='192.0.2.10' REMOTE_USER=me PORT=22 KEY_NAME=lab \
  bash "$SCRIPT" > /dev/null 2>&1 || fail "first-use: failed after 'yes'"
ssh-keygen -F lab -f "$KNOWN" | grep -F "${KEY_B#* }" >/dev/null || fail "first-use: scanned key not pinned"

# An alias named like a word the script prints internally is not special.
new_home odd-alias
printf '%s\n' 'Host conflict' '  HostName 192.0.2.10' '  User me' "  IdentityFile $CASE_HOME/.ssh/lab" > "$CONFIG"
printf '192.0.2.10 %s\n' "$KEY_A" > "$KNOWN"
run_script bash "$SCRIPT" --add-address conflict 198.51.100.20 > /dev/null || fail "odd-alias: failed"
ssh-keygen -F conflict -f "$KNOWN" >/dev/null || fail "odd-alias: not pinned"
new_home upper-alias
printf '%s\n' 'Host Lab' '  HostName 192.0.2.10' '  User me' "  IdentityFile $CASE_HOME/.ssh/lab" > "$CONFIG"
if run_script bash "$SCRIPT" --add-address Lab 198.51.100.20 > /dev/null 2> "$CASE_HOME/err"; then
  fail "accepted an uppercase alias"
fi
grep -F 'invalid alias' "$CASE_HOME/err" >/dev/null || fail "upper-alias: wrong error: $(cat "$CASE_HOME/err")"

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

# The block stays where it was, so an earlier wildcard cannot override it on re-runs.
new_home position
printf '%s\n' 'Host lab' '  HostName 192.0.2.10' '  User me' "  IdentityFile $CASE_HOME/.ssh/lab" '' \
  'Host *' '  User generic' > "$CONFIG"
run_script bash "$SCRIPT" --add-address lab 198.51.100.20 > /dev/null
run_script bash "$SCRIPT" --add-address lab 203.0.113.5 > /dev/null
[[ "$(sed -n 1p "$CONFIG")" == '# BEGIN add_remote_host.sh: lab' ]] || fail "block moved"
resolved lab "" | grep -Fx 'user me' >/dev/null || fail "wildcard overrides the block"
[[ "$(tail -n 2 "$CONFIG" | head -n 1)" == 'Host *' ]] || fail "wildcard block moved"

# An earlier entry that would override the block makes the run fail without writing.
new_home shadowed
printf '%s\n' 'Host *' '  User generic' '' 'Host lab' '  HostName 192.0.2.10' '  User me' "  IdentityFile $CASE_HOME/.ssh/lab" > "$CONFIG"
cp "$CONFIG" "$CASE_HOME/config.before"
if run_script bash "$SCRIPT" --add-address lab 198.51.100.20 > /dev/null 2> "$CASE_HOME/err"; then
  fail "wrote a block that an earlier Host * overrides"
fi
grep -F 'overrides the block' "$CASE_HOME/err" >/dev/null || fail "shadowed: no error"
cmp -s "$CONFIG" "$CASE_HOME/config.before" || fail "shadowed: changed the config"

# Host=alias and a trailing comment are the same legacy block; a comment that
# introduces the next stanza stays with it.
legacy_syntax_case() {
  local name="$1" host_line="$2"
  new_home "legacy-$name"
  printf '%s\n' "$host_line" '  HostName 192.0.2.10' '  User me' "  IdentityFile $CASE_HOME/.ssh/lab" '' \
    '# about other' 'Host other.example' '  User other' > "$CONFIG"
  run_script bash "$SCRIPT" --add-address lab 198.51.100.20 > /dev/null || fail "legacy-$name: failed"
  [[ "$(grep -c '192.0.2.10' "$CONFIG")" == 1 ]] || fail "legacy-$name: old block kept"
  grep -Fx "$host_line" "$CONFIG" >/dev/null && fail "legacy-$name: old Host line kept"
  grep -Fx '# about other' "$CONFIG" >/dev/null || fail "legacy-$name: comment of the next block lost"
  expect_hostname lab "" 192.0.2.10
}
legacy_syntax_case equals 'Host=lab'
legacy_syntax_case comment 'Host lab # the lab box'

# Earlier entries that change where or how the alias connects are refused.
shadow_case() {
  local name="$1"
  shift
  new_home "shadow-$name"
  printf '%s\n' 'Host *' "$@" '' 'Host lab' '  HostName 192.0.2.10' '  User me' "  IdentityFile $CASE_HOME/.ssh/lab" > "$CONFIG"
  cp "$CONFIG" "$CASE_HOME/config.before"
  if run_script bash "$SCRIPT" --add-address lab 198.51.100.20 > /dev/null 2>&1; then
    fail "shadow-$name: accepted"
  fi
  cmp -s "$CONFIG" "$CASE_HOME/config.before" || fail "shadow-$name: changed the config"
}
shadow_case hostname '  HostName wrong.example'
shadow_case proxyjump '  ProxyJump bastion.example'
shadow_case knownhosts "  UserKnownHostsFile $TMP_ROOT/elsewhere"

# Normal mode refuses to drop options too.
new_home extra-normal
printf '%s\n' 'Host lab' '  HostName 192.0.2.10' '  User me' '  ProxyJump bastion' "  IdentityFile $CASE_HOME/.ssh/lab" > "$CONFIG"
printf '192.0.2.10 %s\n' "$KEY_A" > "$KNOWN"
cp "$CONFIG" "$CASE_HOME/config.before"
if printf 'n\n' | run_script HOST_ALIAS=lab REMOTE_HOSTS='198.51.100.20' REMOTE_USER=me PORT=22 KEY_NAME=lab \
  bash "$SCRIPT" > /dev/null 2>&1; then
  fail "extra-normal: rewrote a block with ProxyJump"
fi
cmp -s "$CONFIG" "$CASE_HOME/config.before" || fail "extra-normal: changed the config"

# Unpaired markers would make the rewrite drop the rest of the file (lone BEGIN)
# or keep a stale copy (two blocks): refuse both.
marker_case() {
  local name="$1"
  shift
  new_home "markers-$name"
  printf '%s\n' "$@" 'Host other.example' '  User other' > "$CONFIG"
  cp "$CONFIG" "$CASE_HOME/config.before"
  if run_script bash "$SCRIPT" --add-address lab 198.51.100.20 > /dev/null 2> "$CASE_HOME/err"; then
    fail "markers-$name: accepted bad markers"
  fi
  grep -F 'markers' "$CASE_HOME/err" >/dev/null || fail "markers-$name: wrong error: $(cat "$CASE_HOME/err")"
  cmp -s "$CONFIG" "$CASE_HOME/config.before" || fail "markers-$name: changed the config"
}
block=('Host lab' '  HostName 192.0.2.10' '  User me' "  IdentityFile $TMP_ROOT/lab")
marker_case lone-begin '# BEGIN add_remote_host.sh: lab' "${block[@]}"
marker_case twice '# BEGIN add_remote_host.sh: lab' "${block[@]}" '# END add_remote_host.sh: lab' \
  '# BEGIN add_remote_host.sh: lab' "${block[@]}" '# END add_remote_host.sh: lab'
marker_case lone-end "${block[@]}" '# END add_remote_host.sh: lab'
marker_case nested '# BEGIN add_remote_host.sh: other' 'Host other' '  User other' \
  '# BEGIN add_remote_host.sh: lab' "${block[@]}" '# END add_remote_host.sh: lab' '# END add_remote_host.sh: other'

# Values in an existing block are validated like new input before reaching Match exec.
tainted_case() {
  local name="$1" marker="$TMP_ROOT/pwned-$1"
  shift
  new_home "tainted-$name"
  printf '%s\n' "$@" > "$CONFIG"
  cp "$CONFIG" "$CASE_HOME/config.before"
  if run_script bash "$SCRIPT" --add-address lab 203.0.113.5 > /dev/null 2> "$CASE_HOME/err"; then
    fail "tainted-$name: accepted the block"
  fi
  grep -F 'unexpected' "$CASE_HOME/err" >/dev/null || fail "tainted-$name: wrong error: $(cat "$CASE_HOME/err")"
  cmp -s "$CONFIG" "$CASE_HOME/config.before" || fail "tainted-$name: changed the config"
  [[ ! -e "$marker" ]] || fail "tainted-$name: command ran"
}
tainted_case port 'Host lab' '  HostName 192.0.2.10' '  User me' "  Port 22\$(touch\${IFS}$TMP_ROOT/pwned-port)" \
  "  IdentityFile $TMP_ROOT/lab"
tainted_case hostname '# BEGIN add_remote_host.sh: lab' 'Match originalhost lab exec "true"' \
  "  HostName 192.0.2.10;touch\${IFS}$TMP_ROOT/pwned-hostname" 'Host lab' '  HostName 192.0.2.20' '  User me' \
  "  IdentityFile $TMP_ROOT/lab" '# END add_remote_host.sh: lab'

# A second User/IdentityFile would be lost on rewrite: refuse.
new_home duplicate
printf '%s\n' 'Host lab' '  HostName 192.0.2.10' '  User alice' '  User bob' \
  "  IdentityFile $CASE_HOME/.ssh/lab" "  IdentityFile $CASE_HOME/.ssh/other" > "$CONFIG"
if run_script bash "$SCRIPT" --add-address lab 198.51.100.20 > /dev/null 2> "$CASE_HOME/err"; then
  fail "accepted a block with two User lines"
fi
grep -F 'a second User' "$CASE_HOME/err" >/dev/null || fail "duplicate: did not name the second User"

# CRLF line endings: the block is still found and replaced, other lines kept as they were.
new_home crlf
printf '%s\r\n' 'Host lab' '  HostName 192.0.2.10' '  User me' "  IdentityFile $CASE_HOME/.ssh/lab" '' \
  'Host other.example' '  User other' > "$CONFIG"
run_script bash "$SCRIPT" --add-address lab 198.51.100.20 > /dev/null
[[ "$(grep -c 'HostName 192.0.2.10' "$CONFIG")" == 1 ]] || fail "crlf: old block kept"
grep -qF $'  User other\r' "$CONFIG" || fail "crlf: other block changed"
expect_hostname lab "198.51.100.20" 198.51.100.20

# Several addresses need nc; without it the run fails before writing.
new_home no-nc
NO_NC_BIN="$TMP_ROOT/no-nc-bin"
mkdir -p "$NO_NC_BIN"
for tool in bash env awk grep tr cut mktemp chmod mkdir touch mv rm cat uname ssh-keygen; do
  ln -sf "$(command -v "$tool")" "$NO_NC_BIN/$tool"
done
ln -sf "$STUB_BIN/ssh" "$NO_NC_BIN/ssh"
printf '%s\n' 'Host lab' '  HostName 192.0.2.10' '  User me' "  IdentityFile $CASE_HOME/.ssh/lab" > "$CONFIG"
cp "$CONFIG" "$CASE_HOME/config.before"
if env HOME="$CASE_HOME" PATH="$NO_NC_BIN" SSH_LOG="$SSH_LOG" bash "$SCRIPT" --add-address lab 198.51.100.20 > /dev/null 2> "$CASE_HOME/err"; then
  fail "accepted several addresses without nc"
fi
grep -F 'need nc' "$CASE_HOME/err" >/dev/null || fail "no-nc: no error"
cmp -s "$CONFIG" "$CASE_HOME/config.before" || fail "no-nc: changed the config"

printf 'add_remote_host.sh tests passed.\n'
