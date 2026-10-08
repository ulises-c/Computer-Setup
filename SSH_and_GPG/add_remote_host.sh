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

valid_alias() {
  [[ "$1" =~ ^[A-Za-z0-9._-]+$ && "$1" != -* ]]
}

# Addresses end up inside a Match exec command, so allow only host/IP characters
# (no %, which ssh would expand as a token).
valid_address() {
  [[ "$1" =~ ^[A-Za-z0-9._:-]+$ && "$1" != -* ]]
}

# Prints the alias's block (extract) or the config without it (strip). A block
# from an earlier version of this script (a bare "Host <alias>" up to the next
# Host/Match/managed block) counts as the alias's block too.
config_blocks() {
  local mode="$1" alias="$2"
  [[ -f "$CFG_PATH" ]] || return 0
  awk -v mode="$mode" -v alias="$alias" '
    BEGIN {
      begin = "# BEGIN add_remote_host.sh: " alias
      end = "# END add_remote_host.sh: " alias
    }
    function emit(line) {
      if (line ~ /^[ \t]*$/) { blanks = blanks line "\n"; return }
      printf "%s", blanks
      blanks = ""
      print line
    }
    $0 == begin { managed = 1; found = 1 }
    managed {
      if (mode == "extract") print
      if ($0 == end) managed = 0
      next
    }
    legacy && (tolower($1) == "host" || tolower($1) == "match" || index($0, "# BEGIN ") == 1) { legacy = 0 }
    tolower($1) == "host" && $2 == alias && NF == 2 { legacy = 1 }
    legacy {
      old[++n] = $0
      next
    }
    mode == "strip" { emit($0) }
    END {
      if (mode == "extract" && !found) for (i = 1; i <= n; i++) print old[i]
    }
  ' "$CFG_PATH"
}

# Sets EXISTING_* from the alias's current block; its HostName lines, in order,
# are the addresses. EXISTING_EXTRA lists options the rewritten block would drop.
read_existing_block() {
  local keyword value
  EXISTING_ADDRESSES=()
  EXISTING_USER=""
  EXISTING_PORT=""
  EXISTING_KEY=""
  EXISTING_EXTRA=""
  while read -r keyword value _; do
    case "$(tr '[:upper:]' '[:lower:]' <<< "$keyword")" in
      hostname) EXISTING_ADDRESSES+=("$value") ;;
      user) EXISTING_USER="$value" ;;
      port) EXISTING_PORT="$value" ;;
      identityfile) EXISTING_KEY="$value" ;;
      ""|\#*|host|match|hostkeyalias|addkeystoagent|usekeychain|identitiesonly) ;;
      *) EXISTING_EXTRA+="${EXISTING_EXTRA:+, }$keyword" ;;
    esac
  done < <(config_blocks extract "$1")
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
  local alias="$1" tmp_cfg
  mkdir -p "$SSH_DIR"
  chmod 700 "$SSH_DIR"
  touch "$CFG_PATH"
  tmp_cfg="$(mktemp "$SSH_DIR/config.XXXXXX")"
  config_blocks strip "$alias" > "$tmp_cfg"
  if [[ -s "$tmp_cfg" ]]; then
    printf '\n' >> "$tmp_cfg"
  fi
  render_block "$@" >> "$tmp_cfg"
  chmod 600 "$tmp_cfg"
  mv "$tmp_cfg" "$CFG_PATH"
}

known_hosts_name() {
  if [[ "$2" == 22 ]]; then
    printf '%s' "$1"
  else
    printf '[%s]:%s' "$1" "$2"
  fi
}

# Pins the keys already trusted for the alias's addresses to the alias, so an
# existing host moves to HostKeyAlias without a new trust-on-first-use.
seed_known_hosts() {
  local alias="$1" port="$2" addr found="" lines="" new
  shift 2
  [[ -f "$KNOWN_HOSTS" ]] || return 0
  ssh-keygen -F "$alias" -f "$KNOWN_HOSTS" >/dev/null 2>&1 && return 0
  for addr in "$@"; do
    new="$(ssh-keygen -F "$(known_hosts_name "$addr" "$port")" -f "$KNOWN_HOSTS" 2>/dev/null | grep -v '^[#@]' || true)"
    [[ -n "$new" ]] || continue
    found+="${found:+, }$addr"
    lines+="$new"$'\n'
  done
  [[ -n "$lines" ]] || return 0
  if ! awk 'NF { if (($2 in key) && key[$2] != $3) exit 1; key[$2] = $3 }' <<< "$lines"; then
    printf 'Warning: known_hosts has different host keys for %s; not pinning any to %s.\n' "$found" "$alias" >&2
    printf '         Remove the stale entries (ssh-keygen -R <address>), then connect once to pin the right key.\n' >&2
    return 0
  fi
  awk -v alias="$alias" 'NF && !seen[$2 FS $3]++ { print alias, $2, $3 }' <<< "$lines" >> "$KNOWN_HOSTS"
  printf 'Pinned the host key already trusted for %s to %s.\n' "$found" "$alias"
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
  valid_alias "$HOST_ALIAS" || die "invalid alias: $HOST_ALIAS"
  for addr in "$@"; do
    valid_address "$addr" || die "invalid address: $addr"
  done
  read_existing_block "$HOST_ALIAS"
  ((${#EXISTING_ADDRESSES[@]} > 0)) || die "no Host block for $HOST_ALIAS in $CFG_PATH; run without --add-address first."
  [[ -n "$EXISTING_USER" && -n "$EXISTING_KEY" ]] || die "the block for $HOST_ALIAS has no User or IdentityFile; run without --add-address to rewrite it."
  [[ -z "$EXISTING_EXTRA" ]] || die "the block for $HOST_ALIAS also sets $EXISTING_EXTRA, which a rewrite would drop; edit it by hand."
  PORT="${EXISTING_PORT:-22}"
  dedupe_addresses "$@" "${EXISTING_ADDRESSES[@]}"
  write_config "$HOST_ALIAS" "$EXISTING_USER" "$PORT" "$EXISTING_KEY" "${ADDRESSES[@]}"
  printf 'Addresses for %s, in order: %s\n' "$HOST_ALIAS" "${ADDRESSES[*]}"
  seed_known_hosts "$HOST_ALIAS" "$PORT" "${ADDRESSES[@]}"
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

valid_alias "$HOST_ALIAS" || die "invalid alias: $HOST_ALIAS"
[[ "$PORT" =~ ^[0-9]+$ ]] || die "invalid port: $PORT"
read -r -a NEW_ADDRESSES <<< "${REMOTE_HOSTS//,/ }"
((${#NEW_ADDRESSES[@]} > 0)) || die "REMOTE_HOSTS cannot be empty."
for addr in "${NEW_ADDRESSES[@]}"; do
  valid_address "$addr" || die "invalid address: $addr"
done

# Re-running for an existing alias keeps its addresses, after the new ones.
read_existing_block "$HOST_ALIAS"
if [[ -n "$EXISTING_EXTRA" ]]; then
  printf 'Warning: the existing block for %s also sets %s; the rewritten block drops it.\n' "$HOST_ALIAS" "$EXISTING_EXTRA" >&2
fi
dedupe_addresses "${NEW_ADDRESSES[@]}" "${EXISTING_ADDRESSES[@]}"

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
seed_known_hosts "$HOST_ALIAS" "$PORT" "${ADDRESSES[@]}"

# ---- Copy public key to remote ----
echo ""
echo "Copying public key to $REMOTE_USER@$REMOTE_HOST:$PORT ..."
SSH_BASE_OPTS=(-o StrictHostKeyChecking=accept-new -o HostKeyAlias="$HOST_ALIAS" -o ConnectTimeout=10 -p "$PORT")
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
