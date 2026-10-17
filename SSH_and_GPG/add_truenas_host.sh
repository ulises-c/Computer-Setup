#!/usr/bin/env bash
set -euo pipefail

HOST_ALIAS="${HOST_ALIAS:-}"
REMOTE_HOST="${REMOTE_HOST:-}"
REMOTE_USER="${REMOTE_USER:-}"
PORT="${PORT:-22}"
KEY_NAME="${KEY_NAME:-}"

prompt() {
  local var_name="$1" label="$2" default="${3:-}"
  local current="${!var_name:-}"
  [[ -n "$current" ]] && return 0
  if [[ -n "$default" ]]; then
    read -r -p "$label [$default]: " current
    current="${current:-$default}"
  else
    read -r -p "$label: " current
  fi
  [[ -n "$current" ]] || { printf 'Error: %s cannot be empty.\n' "$var_name" >&2; exit 1; }
  printf -v "$var_name" '%s' "$current"
}

prompt HOST_ALIAS "SSH alias" "truenas"
prompt REMOTE_HOST "TrueNAS hostname or IP"
prompt REMOTE_USER "TrueNAS SSH username"
prompt PORT "SSH port" "22"
prompt KEY_NAME "Key file name (no path)" "$HOST_ALIAS"

if [[ ! "$HOST_ALIAS" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  printf 'Error: SSH alias must contain only letters, numbers, dots, underscores, and hyphens.\n' >&2
  exit 1
fi
if [[ ! "$KEY_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  printf 'Error: key name must be a simple filename without a path.\n' >&2
  exit 1
fi
if [[ ! "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
  printf 'Error: SSH port must be a number from 1 to 65535.\n' >&2
  exit 1
fi
if [[ -z "$REMOTE_HOST" || "$REMOTE_HOST" == -* || "$REMOTE_HOST" == *[[:space:][:cntrl:]]* || "$REMOTE_HOST" == */* ]]; then
  printf 'Error: remote host must be a hostname or IP address.\n' >&2
  exit 1
fi
if [[ -z "$REMOTE_USER" || "$REMOTE_USER" == -* || "$REMOTE_USER" == *[[:space:][:cntrl:]]* || "$REMOTE_USER" == *[@/]* ]]; then
  printf 'Error: remote username must be a single username.\n' >&2
  exit 1
fi

SSH_DIR="$HOME/.ssh"
KEY_PATH="$SSH_DIR/$KEY_NAME"
PUB_PATH="$KEY_PATH.pub"
CFG_PATH="$SSH_DIR/config"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

if [[ -e "$KEY_PATH" || -e "$PUB_PATH" ]]; then
  if [[ ! -f "$KEY_PATH" || ! -f "$PUB_PATH" ]]; then
    printf 'Error: only one key file exists at %s; refusing to overwrite it.\n' "$KEY_PATH" >&2
    exit 1
  fi
  printf 'Reusing existing key: %s\n' "$KEY_PATH"
else
  ssh-keygen -t ed25519 -C "$HOST_ALIAS" -f "$KEY_PATH"
fi
chmod 600 "$KEY_PATH"
chmod 644 "$PUB_PATH"

managed_begin="# BEGIN add_truenas_host.sh: $HOST_ALIAS"
managed_end="# END add_truenas_host.sh: $HOST_ALIAS"
tmp_cfg="$(mktemp "$SSH_DIR/config.XXXXXX")"
trap 'rm -f "$tmp_cfg" "$tmp_cfg.new"' EXIT
if [[ -f "$CFG_PATH" ]]; then
  if awk -v begin="$managed_begin" -v end="$managed_end" -v host="$HOST_ALIAS" '
    $0 == begin { if (in_block) malformed = 1; in_block = 1; next }
    in_block { if ($0 == end) in_block = 0; next }
    $1 == "Host" { for (i = 2; i <= NF; i++) if ($i == host) conflict = 1 }
    END {
      if (in_block) malformed = 1
      if (malformed) exit 3
      if (conflict) exit 2
    }
  ' "$CFG_PATH"; then
    :
  else
    status=$?
    if [[ "$status" == 2 ]]; then
      printf 'Error: SSH alias %s already exists outside this script-managed block; choose another alias or edit ~/.ssh/config manually.\n' "$HOST_ALIAS" >&2
    else
      printf 'Error: found an incomplete managed SSH config block; fix ~/.ssh/config before continuing.\n' >&2
    fi
    exit 1
  fi
  awk -v begin="$managed_begin" -v end="$managed_end" '
    $0 == begin { in_block = 1; next }
    in_block && $0 == end { in_block = 0; next }
    !in_block { print }
  ' "$CFG_PATH" > "$tmp_cfg"
else
  : > "$tmp_cfg"
fi
{
  printf '%s\n' "$managed_begin"
  printf 'Host %s\n' "$HOST_ALIAS"
  printf '  HostName %s\n' "$REMOTE_HOST"
  printf '  User %s\n' "$REMOTE_USER"
  [[ "$PORT" == 22 ]] || printf '  Port %s\n' "$PORT"
  printf '  IdentityFile %s\n' "$KEY_PATH"
  printf '  IdentitiesOnly yes\n'
  printf '  AddKeysToAgent yes\n'
  if [[ "$(uname)" == Darwin ]]; then printf '  UseKeychain yes\n'; fi
  printf '%s\n' "$managed_end"
  [[ ! -s "$tmp_cfg" ]] || cat "$tmp_cfg"
} > "$tmp_cfg.new"
chmod 600 "$tmp_cfg.new"
mv "$tmp_cfg.new" "$CFG_PATH"
rm -f "$tmp_cfg"
trap - EXIT

printf '\nAdd this public key to the TrueNAS user %s in the web UI (Authorized Keys / SSH public key):\n' "$REMOTE_USER"
printf '%s\n' '--------------------------------------------------------------------------'
cat "$PUB_PATH"
printf '%s\n' '--------------------------------------------------------------------------'
printf 'Keep the private key (%s) secret.\n' "$KEY_PATH"
read -r -p 'Press Return after adding the public key in TrueNAS to test access: '

printf '\nTesting SSH connection to %s ...\n' "$HOST_ALIAS"
if ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST_ALIAS" true; then
  printf 'Success. Connect with: ssh %s\n' "$HOST_ALIAS"
else
  printf 'Key authentication failed. Confirm the public key is authorized for this TrueNAS user, then retry: ssh %s\n' "$HOST_ALIAS" >&2
  exit 1
fi
