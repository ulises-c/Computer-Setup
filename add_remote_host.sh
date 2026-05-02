#!/usr/bin/env bash
set -euo pipefail

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
REMOTE_HOST="${REMOTE_HOST:-}"
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
prompt REMOTE_HOST     "Remote hostname or IP (e.g. 192.168.1.100 or mypc.local)"
prompt REMOTE_USER  "Remote username"
prompt PORT         "SSH port" "22"
prompt KEY_NAME     "Key file name (no path)" "$HOST_ALIAS"

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

SSH_DIR="$HOME/.ssh"
KEY_PATH="$SSH_DIR/$KEY_NAME"
PUB_PATH="$KEY_PATH.pub"
CFG_PATH="$SSH_DIR/config"

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
touch "$CFG_PATH"
chmod 600 "$CFG_PATH"

tmp_cfg="$(mktemp)"
awk -v host="$HOST_ALIAS" '
  BEGIN {skip=0}
  $1=="Host" && $2==host {skip=1; next}
  $1=="Host" && skip==1 {skip=0}
  skip==0 {print}
' "$CFG_PATH" > "$tmp_cfg"
mv "$tmp_cfg" "$CFG_PATH"

{
  echo ""
  echo "Host $HOST_ALIAS"
  echo "  HostName $REMOTE_HOST"
  echo "  User $REMOTE_USER"
  echo "  Port $PORT"
  echo "  AddKeysToAgent yes"
  if [[ "$(uname)" == "Darwin" ]]; then
    echo "  UseKeychain yes"
  fi
  echo "  IdentityFile $KEY_PATH"
  echo "  IdentitiesOnly yes"
} >> "$CFG_PATH"

# ---- Copy public key to remote ----
echo ""
echo "Copying public key to $REMOTE_USER@$REMOTE_HOST:$PORT ..."
SSH_BASE_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -p "$PORT")
# Base64 is only used for the sshpass path: sshpass creates a PTY that intercepts stdin,
# so the key must travel inline in the command string. Key-based and interactive auth
# don't have that problem — they can use a plain stdin pipe.
PUB_KEY_B64="$(base64 < "$PUB_PATH" | tr -d '\n')"
APPEND_CMD="mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
APPEND_CMD_B64="mkdir -p ~/.ssh && chmod 700 ~/.ssh && printf '%s\n' '${PUB_KEY_B64}' | base64 -d >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"

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

# ---- Test SSH connection ----
echo ""
echo "Testing SSH connection to $REMOTE_USER@$REMOTE_HOST ..."
# Test the new key directly (bypasses SSH config alias restrictions like IdentitiesOnly)
if ssh_with_timeout 10 ssh -o BatchMode=yes -o StrictHostKeyChecking=no \
    -o IdentitiesOnly=yes -i "$KEY_PATH" -p "$PORT" \
    "$REMOTE_USER@$REMOTE_HOST" exit 2>/dev/null; then
  echo "Success — key-based auth is working."
else
  echo "Key-based auth test failed. If this is a Tailscale SSH host, try connecting"
  echo "manually to confirm: ssh $HOST_ALIAS" >&2
fi

echo ""
echo "Done. Connect any time with: ssh $HOST_ALIAS"
