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
if [[ "$USE_SSHPASS" == true && -n "$REMOTE_PASSWORD" ]]; then
  sshpass -p "$REMOTE_PASSWORD" ssh-copy-id -o PubkeyAuthentication=no -i "$PUB_PATH" -p "$PORT" "$REMOTE_USER@$REMOTE_HOST"
else
  ssh-copy-id -o PubkeyAuthentication=no -i "$PUB_PATH" -p "$PORT" "$REMOTE_USER@$REMOTE_HOST"
fi

# ---- Test SSH connection ----
echo ""
echo "Testing SSH connection via alias '$HOST_ALIAS' ..."
if ssh -o BatchMode=yes "$HOST_ALIAS" exit 2>/dev/null; then
  echo "Success — key-based auth is working."
else
  echo "Warning: connection test failed. Check that sshd is running on the remote and the key was accepted." >&2
fi

echo ""
echo "Done. Connect any time with: ssh $HOST_ALIAS"
