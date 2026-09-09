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

if [[ "$KEY_NAME" == "." || "$KEY_NAME" == ".." || ! "$KEY_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  echo "Error: KEY_NAME must be a simple key file name without a path, whitespace, or control characters." >&2
  exit 1
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

validate_host_token() {
  local value="$1" label="$2"
  if [[ -z "$value" ]]; then
    printf 'Error: %s cannot be empty.\n' "$label" >&2
    exit 1
  fi
  if [[ "$value" == *://* || "$value" == *[[:space:][:cntrl:]]* || "$value" == -* || "$value" == *\** || "$value" == *\?* || "$value" == *\!* || "$value" == */* ]]; then
    printf 'Error: %s must be one literal SSH host token, not a URL, wildcard, negated pattern, or value containing whitespace/control characters.\n' "$label" >&2
    exit 1
  fi
}

if [[ -n "$GIT_HOSTNAME" && -z "$IS_SELF_HOSTED" ]]; then
  echo "Error: GIT_HOSTNAME requires IS_SELF_HOSTED=true." >&2
  exit 1
fi

validate_host_token "$GIT_HOST" "GIT_HOST"
if [[ -n "$IS_SELF_HOSTED" ]]; then
  validate_host_token "$GIT_HOSTNAME" "GIT_HOSTNAME"
  GIT_SSH_PORT="${GIT_SSH_PORT:-22}"
  if [[ ! "$GIT_SSH_PORT" =~ ^[0-9]+$ ]] || (( GIT_SSH_PORT < 1 || GIT_SSH_PORT > 65535 )); then
    echo "Error: GIT_SSH_PORT must be a number from 1 to 65535." >&2
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

managed_begin="# BEGIN create_ssh_key.sh: $KEY_NAME"
legacy_begin='# BEGIN create_ssh_key.sh'
legacy_end='# END create_ssh_key.sh'
managed_end="# END create_ssh_key.sh: $KEY_NAME"
tmp_cfg="$(mktemp "$SSH_DIR/config.XXXXXX")"
trap 'rm -f "$tmp_cfg"' EXIT
awk -v begin="$managed_begin" -v legacy_begin="$legacy_begin" -v legacy_end="$legacy_end" -v end="$managed_end" '
  function flush_block(    i) {
    for (i = 1; i <= block_lines; i++) print block[i]
    block_lines = 0
  }
  ($0 == begin || $0 == legacy_begin) {
    in_block = 1
    block_lines = 1
    block[block_lines] = $0
    next
  }
  in_block {
    block[++block_lines] = $0
    if ($0 == end || $0 == legacy_end) {
      in_block = 0
      block_lines = 0
    }
    next
  }
  {print}
  END {
    if (in_block) flush_block()
  }
' "$CFG_PATH" > "$tmp_cfg"

managed_block="$(mktemp "$SSH_DIR/config-block.XXXXXX")"
final_cfg="$(mktemp "$SSH_DIR/config.XXXXXX")"
trap 'rm -f "$tmp_cfg" "$managed_block" "$final_cfg"' EXIT
{
  printf '%s\n' "$managed_begin"
  if [[ -n "$IS_SELF_HOSTED" ]]; then
    printf 'Host %s %s\n' "$GIT_HOST" "$GIT_HOSTNAME"
    printf '  HostName %s\n' "$GIT_HOSTNAME"
    [[ "$GIT_SSH_PORT" != "22" ]] && printf '  Port %s\n' "$GIT_SSH_PORT"
    printf '  User git\n'
  else
    printf 'Host %s\n' "$GIT_HOST"
  fi
  printf '  AddKeysToAgent %s\n' "$ADD_KEYS_TO_AGENT"
  printf '  IdentityFile %s\n' "$KEY_PATH"
  printf '%s\n' "$managed_end"
} > "$managed_block"

{
  cat "$managed_block"
  cat "$tmp_cfg"
} > "$final_cfg"
mv "$final_cfg" "$CFG_PATH"
rm -f "$tmp_cfg" "$managed_block"
trap - EXIT

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
