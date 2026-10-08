#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  add_remote_host.sh
      Create a key for a remote host, copy it there, and write its ~/.ssh/config
      block. Inputs are prompted for, or read from HOST_ALIAS, REMOTE_HOSTS
      (or REMOTE_HOST), REMOTE_USER, PORT and KEY_NAME.

  add_remote_host.sh --add-address <alias> <address>...
      Add addresses to an alias that already has a block.

Addresses you give go first, in your order; addresses already stored for the
alias keep their order after them. Giving a stored address moves it forward.

An alias can have several addresses (IPs, <hostname>.local, ...), tried in
order: the first that accepts a TCP connection on the SSH port is used, and the
last one is the fallback. The host key is pinned to the alias, so a new address
for the same machine does not trigger a host-key warning, while a different
machine at a stale address still does.
EOF
}

SSH_DIR="$HOME/.ssh"
CFG_PATH="$SSH_DIR/config"
KNOWN_HOSTS="$SSH_DIR/known_hosts"

die() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

# Lowercase only: ssh lowercases HostKeyAlias, so a pin for "Lab" would never match.
valid_alias() {
  [[ "$1" =~ ^[a-z0-9._-]+$ && "$1" != -* ]] || die "invalid alias: $1 (use lowercase letters, digits, '.', '_' or '-')"
}

# Addresses end up inside a Match exec command, so allow only host/IP characters
# (no %, which ssh would expand as a token).
valid_address() {
  [[ "$1" =~ ^[A-Za-z0-9._:-]+$ && "$1" != -* ]]
}

# Dies unless every add_remote_host.sh block is a closed, non-nested BEGIN..END
# pair and no alias has two; a bad pair would make the rewrite drop or keep the
# wrong lines.
check_markers() {
  [[ -f "$CFG_PATH" ]] || return 0
  awk '
    { sub(/\r$/, "") }
    index($0, "# BEGIN add_remote_host.sh: ") == 1 {
      name = substr($0, 29)
      if (open != "" || seen[name]++) exit 1
      open = name
    }
    index($0, "# END add_remote_host.sh: ") == 1 {
      if (substr($0, 27) != open) exit 1
      open = ""
    }
    END { if (open != "") exit 1 }
  ' "$CFG_PATH" || die "$CFG_PATH has unpaired, nested or repeated add_remote_host.sh markers; fix them by hand."
}

# extract: prints the alias's block. replace: prints the config with that block
# swapped, in place, for the contents of $3 (appended when the alias is new).
# A block from an earlier version of this script (a bare "Host <alias>" up to
# the next Host/Match/managed block) counts as the alias's block too.
config_blocks() {
  local mode="$1" alias="$2" block_file="${3:-}"
  [[ -f "$CFG_PATH" ]] || return 0
  awk -v mode="$mode" -v alias="$alias" -v block_file="$block_file" '
    BEGIN {
      begin = "# BEGIN add_remote_host.sh: " alias
      end = "# END add_remote_host.sh: " alias
    }
    { raw = $0; sub(/\r$/, "") }
    function is_stanza(line) {
      return line ~ /^[ \t]*([Hh][Oo][Ss][Tt]|[Mm][Aa][Tt][Cc][Hh])([ \t]|=)/
    }
    # "Host <alias>", "Host=<alias>" or with a trailing comment; one pattern only.
    function is_alias_host(line) {
      if (line !~ /^[ \t]*[Hh][Oo][Ss][Tt]([ \t]|=)/) return 0
      sub(/^[ \t]*[Hh][Oo][Ss][Tt][ \t]*=?[ \t]*/, "", line)
      sub(/[ \t]*(#.*)?$/, "", line)
      return line == alias
    }
    function put_new(    line) {
      if (placed) return
      while ((getline line < block_file) > 0) print line
      placed = 1
    }
    $0 == begin {
      managed = 1
      found = 1
      if (mode == "replace") put_new()
    }
    managed {
      if (mode == "extract") print
      if ($0 == end) managed = 0
      next
    }
    legacy && /^[ \t]*(#.*)?$/ { pending = pending raw "\n"; next }
    legacy && (is_stanza($0) || index($0, "# BEGIN ") == 1) {
      legacy = 0
      if (mode == "replace") printf "%s", pending
      pending = ""
    }
    legacy { old = old pending $0 "\n"; pending = ""; next }
    is_alias_host($0) {
      legacy = 1
      if (mode == "replace") put_new()
      next
    }
    mode == "replace" { print raw }
    END {
      if (mode == "extract" && !found) printf "%s", old
      if (mode == "replace") {
        printf "%s", pending
        if (!placed) {
          if (NR > 0) print ""
          put_new()
        }
      }
    }
  ' "$CFG_PATH"
}

# Sets EXISTING_* from the alias's current block; its HostName lines, in order,
# are the addresses. EXISTING_EXTRA lists what a rewrite would drop or change.
read_existing_block() {
  local keyword value addr name
  check_markers "$1"
  EXISTING_ADDRESSES=()
  EXISTING_USER=""
  EXISTING_PORT=""
  EXISTING_KEY=""
  EXISTING_EXTRA=""
  while read -r name value rest; do
    keyword="$(tr '[:upper:]' '[:lower:]' <<< "$name")"
    if [[ -n "$rest" && "$keyword" != \#* && "$keyword" != host && "$keyword" != match ]]; then
      EXISTING_EXTRA+="${EXISTING_EXTRA:+, }$name with several values"
      continue
    fi
    case "$keyword" in
      hostname) EXISTING_ADDRESSES+=("$value") ;;
      user|port|identityfile)
        if [[ "$keyword" == user && -z "$EXISTING_USER" ]]; then
          EXISTING_USER="$value"
        elif [[ "$keyword" == port && -z "$EXISTING_PORT" ]]; then
          EXISTING_PORT="$value"
        elif [[ "$keyword" == identityfile && -z "$EXISTING_KEY" ]]; then
          EXISTING_KEY="$value"
        else
          EXISTING_EXTRA+="${EXISTING_EXTRA:+, }a second $name"
        fi
        ;;
      userknownhostsfile)
        [[ "$value" == "$KNOWN_HOSTS" ]] || EXISTING_EXTRA+="${EXISTING_EXTRA:+, }$name"
        ;;
      ""|\#*|host|match|hostkeyalias|addkeystoagent|usekeychain|identitiesonly) ;;
      *) EXISTING_EXTRA+="${EXISTING_EXTRA:+, }$name" ;;
    esac
  done < <(config_blocks extract "$1")
  for addr in ${EXISTING_ADDRESSES[@]+"${EXISTING_ADDRESSES[@]}"}; do
    valid_address "$addr" || die "the existing block for $1 has an unexpected HostName: $addr"
  done
  [[ -z "$EXISTING_PORT" || "$EXISTING_PORT" =~ ^[0-9]+$ ]] || die "the existing block for $1 has an unexpected Port: $EXISTING_PORT"
}

dedupe_addresses() {
  local addr seen=" "
  ADDRESSES=()
  for addr in "$@"; do
    [[ "$seen" == *" $addr "* ]] && continue
    seen+="$addr "
    ADDRESSES+=("$addr")
  done
}

# Without nc every Match probe fails, and only the last address would ever be used.
require_nc_for_multiple() {
  if ((${#ADDRESSES[@]} > 1)) && ! command -v nc &>/dev/null; then
    die "several addresses need nc (netcat) to pick a reachable one; install it (e.g. apt install netcat-openbsd) and run again."
  fi
}

render_block() {
  local alias="$1" user="$2" port="$3" key="$4"
  shift 4
  local addresses=("$@") last=$(($# - 1)) i
  printf '# BEGIN add_remote_host.sh: %s\n' "$alias"
  for ((i = 0; i < last; i++)); do
    printf 'Match originalhost %s exec "nc -z -w 1 %s %s"\n' "$alias" "${addresses[i]}" "$port"
    printf '  HostName %s\n' "${addresses[i]}"
  done
  printf 'Host %s\n' "$alias"
  printf '  HostName %s\n' "${addresses[last]}"
  printf '  HostKeyAlias %s\n' "$alias"
  printf '  UserKnownHostsFile %s\n' "$KNOWN_HOSTS"
  printf '  User %s\n' "$user"
  printf '  Port %s\n' "$port"
  printf '  AddKeysToAgent yes\n'
  if [[ "$(uname)" == "Darwin" ]]; then
    printf '  UseKeychain yes\n'
  fi
  printf '  IdentityFile %s\n' "$key"
  printf '  IdentitiesOnly yes\n'
  printf '# END add_remote_host.sh: %s\n' "$alias"
}

write_config() {
  local alias="$1" tmp_cfg block_file
  mkdir -p "$SSH_DIR"
  chmod 700 "$SSH_DIR"
  touch "$CFG_PATH"
  tmp_cfg="$(mktemp "$SSH_DIR/config.XXXXXX")"
  block_file="$(mktemp "$SSH_DIR/config-block.XXXXXX")"
  render_block "$@" > "$block_file"
  config_blocks replace "$alias" "$block_file" > "$tmp_cfg"
  rm -f "$block_file"
  chmod 600 "$tmp_cfg"
  if ! verify_effective "$tmp_cfg" "$@"; then
    rm -f "$tmp_cfg"
    die "another entry in $CFG_PATH (e.g. an earlier Host * or multi-name Host line) overrides the block for $alias, sets a proxy for it, or adds trust sources besides $KNOWN_HOSTS (UserKnownHostsFile, KnownHostsCommand); nothing was changed."
  fi
  mv "$tmp_cfg" "$CFG_PATH"
}

# OpenSSH keeps the first value it sees, so an earlier matching entry would win.
verify_effective() {
  local cfg="$1" alias="$2" user="$3" port="$4" key="$5" out
  shift 5
  out="$(ssh -G -F "$cfg" "$alias" 2>/dev/null)" || return 1
  grep -Fx "user $user" <<< "$out" >/dev/null &&
    grep -Fx "port $port" <<< "$out" >/dev/null &&
    grep -Fx "hostkeyalias $alias" <<< "$out" >/dev/null &&
    grep -Fx "identitiesonly yes" <<< "$out" >/dev/null &&
    ! grep -Eq '^(proxycommand|proxyjump) ' <<< "$out" &&
    awk -v kh="$KNOWN_HOSTS" '$1 == "userknownhostsfile" { sub(/^~/, ENVIRON["HOME"], $2); ok = NF == 2 && $2 == kh } END { exit !ok }' <<< "$out" &&
    ! grep -Ev '^knownhostscommand none$' <<< "$out" | grep -q '^knownhostscommand ' &&
    awk -v key="${key/#\~/$HOME}" '$1 == "identityfile" { sub(/^~/, ENVIRON["HOME"], $2); if ($2 == key) ok = 1 } END { exit !ok }' <<< "$out" &&
    awk -v list=" $* " '$1 == "hostname" { ok = index(list, " " $2 " ") > 0 } END { exit !ok }' <<< "$out"
}

known_hosts_name() {
  if [[ "$2" == 22 ]]; then
    printf '%s' "$1"
  else
    printf '[%s]:%s' "$1" "$2"
  fi
}

# Sets HOST_KEY_PINS to known_hosts lines that pin the alias to the keys already
# trusted for its addresses, so an existing host moves to HostKeyAlias without a
# new trust-on-first-use. Every address with known keys must share a key with
# the first one and have no key of the same type that differs; otherwise they may
# be different machines, and this dies before anything is written.
# Prints "<type> <key>" for each known_hosts entry of name $1 (already in
# known_hosts form): plain keys, or with $2 = revoked, @revoked ones.
known_keys() {
  [[ -f "$KNOWN_HOSTS" ]] || return 0
  { ssh-keygen -F "$1" -f "$KNOWN_HOSTS" 2>/dev/null || true; } |
    awk -v want="${2:-plain}" '
      /^#/ || NF < 3 { next }
      $1 == "@revoked" { if (want == "revoked" && NF >= 4) print $3, $4; next }
      $1 ~ /^@/ { next }
      want == "plain" { print $2, $3 }
    '
}

alias_is_pinned() {
  [[ -n "$(known_keys "$1")" ]]
}

plan_host_key_pins() {
  local alias="$1" port="$2" addr entries="" name
  shift 2
  HOST_KEY_PINS=""
  [[ -f "$KNOWN_HOSTS" ]] || return 0
  for name in "$alias" "$@"; do
    [[ "$name" == "$alias" ]] || name="$(known_hosts_name "$name" "$port")"
    if [[ -n "$(known_keys "$name" revoked)" ]]; then
      die "known_hosts has a @revoked key for $name; resolve it by hand before using $alias."
    fi
  done
  alias_is_pinned "$alias" && return 0
  for addr in "$@"; do
    entries+="$(known_keys "$(known_hosts_name "$addr" "$port")" | awk -v addr="$addr" '{ print addr, $0 }')"$'\n'
  done
  # Exit 3 = conflict. The anchor is the first address with known keys; every
  # other address must share one of its keys and have no other key of a type
  # the anchor has.
  if ! HOST_KEY_PINS="$(awk -v alias="$alias" '
    !NF { next }
    anchor == "" { anchor = $1 }
    $1 == anchor {
      if (($2 in anchor_type) && !anchor_key[$2 FS $3]) exit 3
      if (!seen[$2 FS $3]++) pins[++n] = $2 FS $3
      anchor_type[$2] = 1
      anchor_key[$2 FS $3] = 1
      next
    }
    {
      others[$1] = 1
      if (anchor_key[$2 FS $3]) shared[$1] = 1
      else if ($2 in anchor_type) differs[$1] = 1
    }
    END {
      for (a in others) if (differs[a] || !shared[a]) exit 3
      for (i = 1; i <= n; i++) print alias, pins[i]
    }
  ' <<< "$entries")"; then
    die "known_hosts has host keys for the addresses of $alias that do not match each other, so they may be different machines. Remove the stale entries (ssh-keygen -R <address>) and run again."
  fi
}

# First use of an alias with no trusted key: show the fingerprint of the address
# the key will be copied to and ask, instead of trusting whatever answers there
# (with several addresses, a stale one may now belong to another machine).
confirm_host_key() {
  local alias="$1" addr="$2" port="$3" scanned yn
  [[ -n "$HOST_KEY_PINS" ]] && return 0
  alias_is_pinned "$alias" && return 0
  scanned="$(ssh-keyscan -p "$port" -T 5 "$addr" 2>/dev/null | awk '!/^#/ && NF >= 3 { print $2, $3 }' || true)"
  [[ -n "$scanned" ]] || die "could not read the host key of $addr port $port."
  printf '\nNo host key is trusted for %s yet. %s port %s presents:\n' "$alias" "$addr" "$port"
  awk -v a="$addr" '{ print a, $0 }' <<< "$scanned" | ssh-keygen -lf - | sed 's/^/  /'
  printf 'Compare with the output of "ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub" on that machine.\n'
  read -r -p "Trust this machine as $alias? (y/N): " yn
  [[ "$yn" == y || "$yn" == Y ]] || die "host key not trusted; nothing was changed."
  HOST_KEY_PINS="$(awk -v alias="$alias" '{ print alias, $1, $2 }' <<< "$scanned")"
}

apply_host_key_pins() {
  [[ -n "$HOST_KEY_PINS" ]] || return 0
  if [[ -s "$KNOWN_HOSTS" && -n "$(tail -c 1 "$KNOWN_HOSTS")" ]]; then
    printf '\n' >> "$KNOWN_HOSTS"
  fi
  printf '%s\n' "$HOST_KEY_PINS" >> "$KNOWN_HOSTS"
  printf 'Pinned the host key to %s in %s.\n' "$1" "$KNOWN_HOSTS"
}

# Run a command with a hard wall-clock timeout; ConnectTimeout alone doesn't cover auth hangs
ssh_with_timeout() {
  local secs="$1"; shift
  "$@" &
  local pid=$!
  local rc=0
  { sleep "$secs" && kill "$pid" 2>/dev/null; } &
  local watcher=$!
  wait "$pid" 2>/dev/null || rc=$?
  { kill "$watcher" && wait "$watcher"; } 2>/dev/null || true
  return $rc
}

test_alias() {
  printf '\nTesting SSH connection: ssh %s ...\n' "$1"
  if ssh_with_timeout 20 ssh -o BatchMode=yes -o ConnectTimeout=10 "$1" exit 2>/dev/null; then
    printf 'Success: key-based auth is working.\n'
  else
    printf 'Connection test failed. Run "ssh %s" to see why.\n' "$1" >&2
  fi
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

# ---- --add-address mode ----
if [[ "${1:-}" == "--add-address" ]]; then
  (($# >= 3)) || { usage >&2; exit 1; }
  HOST_ALIAS="$2"
  shift 2
  valid_alias "$HOST_ALIAS"
  for addr in "$@"; do
    valid_address "$addr" || die "invalid address: $addr"
  done
  read_existing_block "$HOST_ALIAS"
  ((${#EXISTING_ADDRESSES[@]} > 0)) || die "no Host block for $HOST_ALIAS in $CFG_PATH; run without --add-address first."
  [[ -n "$EXISTING_USER" && -n "$EXISTING_KEY" ]] || die "the block for $HOST_ALIAS has no User or IdentityFile; run without --add-address to rewrite it."
  [[ -z "$EXISTING_EXTRA" ]] || die "the block for $HOST_ALIAS also sets $EXISTING_EXTRA, which a rewrite would drop; edit it by hand."
  PORT="${EXISTING_PORT:-22}"
  dedupe_addresses "$@" "${EXISTING_ADDRESSES[@]}"
  require_nc_for_multiple
  plan_host_key_pins "$HOST_ALIAS" "$PORT" "${ADDRESSES[@]}"
  write_config "$HOST_ALIAS" "$EXISTING_USER" "$PORT" "$EXISTING_KEY" "${ADDRESSES[@]}"
  printf 'Addresses for %s, in order: %s\n' "$HOST_ALIAS" "${ADDRESSES[*]}"
  apply_host_key_pins "$HOST_ALIAS"
  test_alias "$HOST_ALIAS"
  exit 0
fi

(($# == 0)) || { usage >&2; exit 1; }

# ---- Check dependencies ----
if ! command -v sshpass &>/dev/null; then
  echo "Note: sshpass is not installed. You will be prompted for the remote password manually during key installation."
  echo "      To avoid this: brew install sshpass  (or apt install sshpass)"
  echo ""
  USE_SSHPASS=false
else
  USE_SSHPASS=true
fi

# ---- Inputs (can be provided as env vars or will be prompted) ----
HOST_ALIAS="${HOST_ALIAS:-}"
REMOTE_HOSTS="${REMOTE_HOSTS:-${REMOTE_HOST:-}}"
REMOTE_USER="${REMOTE_USER:-}"
PORT="${PORT:-}"
KEY_NAME="${KEY_NAME:-}"

prompt() {
  local var_name="$1" label="$2" default="${3:-}"
  local current="${!var_name:-}"
  if [[ -n "$current" ]]; then return 0; fi

  if [[ -n "$default" ]]; then
    read -r -p "$label [$default]: " value
    value="${value:-$default}"
  else
    read -r -p "$label: " value
  fi

  if [[ -z "$value" ]]; then
    echo "Error: $var_name cannot be empty." >&2
    exit 1
  fi
  printf -v "$var_name" '%s' "$value"
}

prompt HOST_ALIAS   "SSH alias (friendly name, e.g. homepc)"
prompt REMOTE_HOSTS "Remote addresses, space-separated, most preferred first (IPs or <hostname>.local)"
prompt REMOTE_USER  "Remote username"
prompt PORT         "SSH port" "22"
prompt KEY_NAME     "Key file name (no path)" "$HOST_ALIAS"

valid_alias "$HOST_ALIAS"
[[ "$PORT" =~ ^[0-9]+$ ]] || die "invalid port: $PORT"
[[ -n "$REMOTE_USER" && "$REMOTE_USER" != *[[:space:]]* ]] || die "invalid username: $REMOTE_USER"
read -r -a NEW_ADDRESSES <<< "${REMOTE_HOSTS//,/ }"
((${#NEW_ADDRESSES[@]} > 0)) || die "REMOTE_HOSTS cannot be empty."
for addr in "${NEW_ADDRESSES[@]}"; do
  valid_address "$addr" || die "invalid address: $addr"
done

# Re-running for an existing alias keeps its addresses, after the new ones.
read_existing_block "$HOST_ALIAS"
[[ -z "$EXISTING_EXTRA" ]] || die "the existing block for $HOST_ALIAS also sets $EXISTING_EXTRA, which a rewrite would drop; edit it by hand."
dedupe_addresses "${NEW_ADDRESSES[@]}" ${EXISTING_ADDRESSES[@]+"${EXISTING_ADDRESSES[@]}"}
require_nc_for_multiple
plan_host_key_pins "$HOST_ALIAS" "$PORT" "${ADDRESSES[@]}"

# The key copy goes to the first address that answers on the SSH port.
REMOTE_HOST="${ADDRESSES[${#ADDRESSES[@]} - 1]}"
if command -v nc &>/dev/null; then
  for addr in "${ADDRESSES[@]}"; do
    if nc -z -w 2 "$addr" "$PORT" 2>/dev/null; then
      REMOTE_HOST="$addr"
      break
    fi
  done
fi

confirm_host_key "$HOST_ALIAS" "$REMOTE_HOST" "$PORT"

# ---- Remote account password (optional, used once for ssh-copy-id) ----
REMOTE_PASSWORD="${REMOTE_PASSWORD:-}"
if [[ "$USE_SSHPASS" == true && -z "$REMOTE_PASSWORD" ]]; then
  read -r -s -p "Remote account password for $REMOTE_USER@$REMOTE_HOST (leave blank to be prompted later): " REMOTE_PASSWORD
  echo ""
  if [[ -n "$REMOTE_PASSWORD" ]]; then
    read -r -s -p "Confirm password: " REMOTE_PASSWORD2
    echo ""
    if [[ "$REMOTE_PASSWORD" != "$REMOTE_PASSWORD2" ]]; then
      echo "Error: passwords do not match." >&2
      exit 1
    fi
  fi
fi

# ---- Optional passphrase ----
SSH_PASSPHRASE="${SSH_PASSPHRASE:-}"
if [[ -z "$SSH_PASSPHRASE" ]]; then
  read -r -p "Add a passphrase to the key? (y/N): " use_passphrase
  case "${use_passphrase:-N}" in
    y|Y)
      read -r -s -p "Passphrase: " SSH_PASSPHRASE
      echo ""
      read -r -s -p "Confirm passphrase: " SSH_PASSPHRASE2
      echo ""
      if [[ "$SSH_PASSPHRASE" != "$SSH_PASSPHRASE2" ]]; then
        echo "Error: passphrases do not match." >&2
        exit 1
      fi
      ;;
    *)
      SSH_PASSPHRASE=""
      ;;
  esac
fi

KEY_PATH="$SSH_DIR/$KEY_NAME"
PUB_PATH="$KEY_PATH.pub"

# ---- Ensure ~/.ssh exists with correct perms ----
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

# ---- Create key if it doesn't exist ----
if [[ -f "$KEY_PATH" || -f "$PUB_PATH" ]]; then
  echo "Key already exists at: $KEY_PATH"
  read -r -p "Overwrite? (y/N): " yn
  case "${yn:-N}" in
    y|Y)
      rm -f "$KEY_PATH" "$PUB_PATH"
      ;;
    *)
      echo "Reusing existing key."
      ;;
  esac
fi

if [[ ! -f "$KEY_PATH" ]]; then
  ssh-keygen -t ed25519 -C "$HOST_ALIAS" -f "$KEY_PATH" -N "$SSH_PASSPHRASE"
fi

chmod 600 "$KEY_PATH"
chmod 644 "$PUB_PATH"

# ---- Start or reuse ssh-agent ----
if [[ -z "${SSH_AUTH_SOCK:-}" ]]; then
  eval "$(ssh-agent -s)" >/dev/null
fi

# ---- Add key to agent (store passphrase in Keychain on macOS) ----
if [[ "$(uname)" == "Darwin" ]]; then
  ssh-add --apple-use-keychain "$KEY_PATH"
else
  ssh-add "$KEY_PATH"
fi

# ---- Update ~/.ssh/config idempotently ----
write_config "$HOST_ALIAS" "$REMOTE_USER" "$PORT" "$KEY_PATH" "${ADDRESSES[@]}"
printf 'Addresses for %s, in order: %s\n' "$HOST_ALIAS" "${ADDRESSES[*]}"
apply_host_key_pins "$HOST_ALIAS"

# ---- Copy public key to remote ----
echo ""
echo "Copying public key to $REMOTE_USER@$REMOTE_HOST:$PORT ..."
# -F /dev/null: the copy goes to exactly $REMOTE_HOST, whatever ~/.ssh/config says
# about that address; the host key was pinned to the alias above.
SSH_BASE_OPTS=(-F /dev/null -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS" \
  -o HostKeyAlias="$HOST_ALIAS" -o ConnectTimeout=10 -p "$PORT")
# Base64 is only used for the sshpass path: sshpass creates a PTY that intercepts stdin,
# so the key must travel inline in the command string. Key-based and interactive auth
# don't have that problem — they can use a plain stdin pipe.
PUB_KEY_B64="$(base64 < "$PUB_PATH" | tr -d '\n')"
APPEND_CMD="mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
APPEND_CMD_B64="mkdir -p ~/.ssh && chmod 700 ~/.ssh && printf '%s\n' '${PUB_KEY_B64}' | base64 -d >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"

copy_key() {
  # 1. Try BatchMode first (existing agent keys, Tailscale auth, etc.) with stdin pipe.
  #    No sshpass = no PTY = stdin works correctly.
  if ssh_with_timeout 10 ssh "${SSH_BASE_OPTS[@]}" -o BatchMode=yes \
      "$REMOTE_USER@$REMOTE_HOST" "$APPEND_CMD" < "$PUB_PATH" 2>/dev/null; then
    echo "Key copied (BatchMode/agent auth)."
    return 0
  fi
  # 2. sshpass with password — must use base64 inline to avoid PTY swallowing stdin.
  if [[ "$USE_SSHPASS" == true && -n "$REMOTE_PASSWORD" ]]; then
    if ssh_with_timeout 15 sshpass -p "$REMOTE_PASSWORD" ssh "${SSH_BASE_OPTS[@]}" \
        -o PubkeyAuthentication=no "$REMOTE_USER@$REMOTE_HOST" "$APPEND_CMD_B64"; then
      echo "Key copied (password auth)."
      return 0
    fi
  fi
  # 3. Interactive fallback — user types password at the prompt; stdin pipe is safe here too.
  if ssh "${SSH_BASE_OPTS[@]}" -o PubkeyAuthentication=no \
      "$REMOTE_USER@$REMOTE_HOST" "$APPEND_CMD" < "$PUB_PATH"; then
    echo "Key copied (interactive auth)."
    return 0
  fi
  return 1
}

KEY_COPIED=false
if copy_key; then
  # Verify the key actually landed in authorized_keys (guards against false-positive exits)
  KEY_SEGMENT="$(awk '{print $2}' "$PUB_PATH")"
  VERIFY_CMD="grep -qF '${KEY_SEGMENT}' ~/.ssh/authorized_keys"
  if ssh_with_timeout 10 ssh "${SSH_BASE_OPTS[@]}" -o BatchMode=yes \
      "$REMOTE_USER@$REMOTE_HOST" "$VERIFY_CMD" 2>/dev/null; then
    KEY_COPIED=true
  else
    echo "Warning: copy appeared to succeed but key not found in remote authorized_keys." >&2
    KEY_COPIED=false
  fi
fi

if [[ "$KEY_COPIED" == false ]]; then
  echo ""
  echo "Automatic key copy failed. SSH into the remote machine and run:" >&2
  echo "" >&2
  echo "  echo '$(cat "$PUB_PATH")' >> ~/.ssh/authorized_keys" >&2
fi

# Goes through the alias, so it exercises address selection and the pinned host key.
test_alias "$HOST_ALIAS"

echo ""
echo "Done. Connect any time with: ssh $HOST_ALIAS"
