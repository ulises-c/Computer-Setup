#!/usr/bin/env bash
set -euo pipefail

# ---- Inputs (can be provided as env vars or will be prompted) ----
EMAIL="${EMAIL:-}"
KEY_NAME="${KEY_NAME:-}"
GIT_HOST="${GIT_HOST:-}"

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

prompt EMAIL "Email (comment in key)"

# ---- Git host selection ----
IS_SELF_HOSTED="${IS_SELF_HOSTED:-}"
GIT_HOSTNAME="${GIT_HOSTNAME:-}"
GIT_SSH_PORT="${GIT_SSH_PORT:-}"

if [[ -z "$GIT_HOST" ]]; then
  echo ""
  echo "Select a Git host:"
  echo "  1) github.com"
  echo "  2) gitlab.com"
  echo "  3) bitbucket.org"
  echo "  4) hf.co"
  echo "  5) Self-Hosted Git Server"
  echo "  0) Custom"
  read -r -p "Choice [1]: " host_choice
  case "${host_choice:-1}" in
    1) GIT_HOST="github.com" ;;
    2) GIT_HOST="gitlab.com" ;;
    3) GIT_HOST="bitbucket.org" ;;
    4) GIT_HOST="hf.co" ;;
    5)
      IS_SELF_HOSTED=true
      if [[ -z "$GIT_HOSTNAME" ]]; then
        read -r -p "Server hostname (e.g. hostname.ts.net): " GIT_HOSTNAME
        if [[ -z "$GIT_HOSTNAME" ]]; then
          echo "Error: GIT_HOSTNAME cannot be empty." >&2
          exit 1
        fi
      fi
      if [[ -z "$GIT_HOST" ]]; then
        read -r -p "SSH alias for this server [gitserver]: " GIT_HOST
        GIT_HOST="${GIT_HOST:-gitserver}"
      fi
      if [[ -z "$GIT_SSH_PORT" ]]; then
        read -r -p "SSH port [22]: " GIT_SSH_PORT
        GIT_SSH_PORT="${GIT_SSH_PORT:-22}"
      fi
      ;;
    0)
      read -r -p "Git host: " GIT_HOST
      if [[ -z "$GIT_HOST" ]]; then
        echo "Error: GIT_HOST cannot be empty." >&2
        exit 1
      fi
      ;;
    *)
      echo "Invalid choice." >&2
      exit 1
      ;;
  esac
fi

prompt KEY_NAME "Key file name (no path)" "${GIT_HOST%%.*}"

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

# ---- Agent timeout (passphrase-protected keys only) ----
AGENT_TIMEOUT="${AGENT_TIMEOUT:-}"
if [[ -n "$SSH_PASSPHRASE" ]]; then
  if [[ -z "$AGENT_TIMEOUT" ]]; then
    read -r -p "Minutes ssh-agent keeps the key unlocked (0 = ask every time) [15]: " AGENT_TIMEOUT
    AGENT_TIMEOUT="${AGENT_TIMEOUT:-15}"
  fi
  if [[ ! "$AGENT_TIMEOUT" =~ ^[0-9]+$ ]]; then
    echo "Error: AGENT_TIMEOUT must be a whole number of minutes." >&2
    exit 1
  fi
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
      echo "Keeping existing key."
      ;;
  esac
fi

if [[ ! -f "$KEY_PATH" ]]; then
  # ed25519 doesn't use -b; that's for RSA.
  ssh-keygen -t ed25519 -C "$EMAIL" -f "$KEY_PATH" -N "$SSH_PASSPHRASE"
fi

chmod 600 "$KEY_PATH"
chmod 644 "$PUB_PATH"

# ---- Start or reuse ssh-agent ----
if [[ -z "${SSH_AUTH_SOCK:-}" ]]; then
  eval "$(ssh-agent -s)" >/dev/null
fi

# ---- Add key to agent ----
if [[ -n "$SSH_PASSPHRASE" && "$AGENT_TIMEOUT" == "0" ]]; then
  echo "Not adding key to ssh-agent: passphrase will be asked on every use."
elif [[ -n "$SSH_PASSPHRASE" ]]; then
  ssh-add -t "${AGENT_TIMEOUT}m" "$KEY_PATH"
else
  ssh-add "$KEY_PATH"
fi

# AddKeysToAgent with a time interval needs OpenSSH 8.7+; without it, a key
# re-added on first use would stay unlocked forever, defeating the timeout.
ADD_KEYS_TO_AGENT="yes"
if [[ -n "$SSH_PASSPHRASE" ]]; then
  if [[ "$AGENT_TIMEOUT" == "0" ]]; then
    ADD_KEYS_TO_AGENT="no"
  else
    ADD_KEYS_TO_AGENT="${AGENT_TIMEOUT}m"
  fi
fi

# ---- Update ~/.ssh/config idempotently ----
touch "$CFG_PATH"
chmod 600 "$CFG_PATH"

# Remove any existing block for this host (simple, robust approach).
# This deletes from line "Host <GIT_HOST>" up to the next "Host " line (or EOF).
tmp_cfg="$(mktemp)"
awk -v host="$GIT_HOST" '
  BEGIN {skip=0}
  $1=="Host" && $2==host {skip=1; next}
  $1=="Host" && skip==1 {skip=0}
  skip==0 {print}
' "$CFG_PATH" > "$tmp_cfg"
mv "$tmp_cfg" "$CFG_PATH"

if [[ -n "$IS_SELF_HOSTED" ]]; then
  {
    echo ""
    echo "Host $GIT_HOST"
    echo "  HostName $GIT_HOSTNAME"
    # Port 22 is the SSH default — only emit the line for a non-standard port.
    [[ -n "$GIT_SSH_PORT" && "$GIT_SSH_PORT" != "22" ]] && echo "  Port $GIT_SSH_PORT"
    echo "  User git"
    echo "  AddKeysToAgent $ADD_KEYS_TO_AGENT"
    echo "  IdentityFile $KEY_PATH"
  } >> "$CFG_PATH"
else
  {
    echo ""
    echo "Host $GIT_HOST"
    echo "  AddKeysToAgent $ADD_KEYS_TO_AGENT"
    # macOS keychain optional:
    # echo "  UseKeychain yes"
    echo "  IdentityFile $KEY_PATH"
  } >> "$CFG_PATH"
fi

# ---- Show public key ----
echo ""
echo "Public key (add this to $GIT_HOST):"
echo "------------------------------------------------------------"
cat "$PUB_PATH"
echo "------------------------------------------------------------"
echo ""

read -r -p "Press [Enter] after adding the public key to your $GIT_HOST account..."

# ---- Test SSH connection ----
# -T avoids trying to open a shell; -v optional for debugging.
echo ""
if [[ -n "$IS_SELF_HOSTED" ]]; then
  echo "Testing SSH connection to self-hosted server ($GIT_HOSTNAME:${GIT_SSH_PORT:-22}) ..."
  ssh -T "$GIT_HOST" || true
else
  echo "Testing SSH connection to git@$GIT_HOST ..."
  ssh -T "git@$GIT_HOST" || true
fi

# ---- Configure git identity if not already set ----
existing_name="$(git config --global user.name 2>/dev/null || true)"
existing_email="$(git config --global user.email 2>/dev/null || true)"

if [[ -z "$existing_name" || -z "$existing_email" ]]; then
  echo ""
  read -r -p "Configure git user.name / user.email? (Y/n): " yn_git
  case "${yn_git:-Y}" in
    n|N) ;;
    *)
      if [[ -z "$existing_name" ]]; then
        read -r -p "Full name for git commits: " git_name
        if [[ -n "$git_name" ]]; then
          git config --global user.name "$git_name"
          echo "git user.name set to: $git_name"
        fi
      else
        echo "git user.name already set to: $existing_name (skipping)"
      fi

      if [[ -z "$existing_email" ]]; then
        git config --global user.email "$EMAIL"
        echo "git user.email set to: $EMAIL"
      else
        echo "git user.email already set to: $existing_email (skipping)"
      fi
      ;;
  esac
fi

echo ""
echo "Done. If you saw a success message (e.g., 'You've successfully authenticated'), you're set."
