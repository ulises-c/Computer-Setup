#!/usr/bin/env bash
set -euo pipefail

# --------------------------
# git-add-ssh-signer.sh
# --------------------------
# Usage:
#   git-add-ssh-signer.sh <email> <ssh-public-key-path> [--local]
# Example:
#   # Add global trust for multiple keys
#   git-add-ssh-signer.sh me@gmail.com ~/.ssh/github.pub
#   git-add-ssh-signer.sh me@work.edu ~/.ssh/work.pub
#
#   # Configure a repo for a specific identity
#   cd my-repo
#   git-add-ssh-signer.sh me@work.edu ~/.ssh/work.pub --local
# --------------------------

print_usage() {
  echo "Usage: $0 <email> <ssh-public-key-path> [--local]"
  echo "  --local : configure signing for current repo (default is global trust only)"
  exit 1
}

# --------------------------
# Parse arguments
# --------------------------
if [[ $# -lt 2 || $# -gt 3 ]]; then
  print_usage
fi

EMAIL="$1"
SSH_PUB_KEY_PATH="$2"
MODE="${3:-}"

ALLOWED_SIGNERS="$HOME/.config/git/allowed_signers"

# --------------------------
# Sanity checks
# --------------------------
if [[ ! -f "$SSH_PUB_KEY_PATH" ]]; then
  echo "❌ SSH public key not found: $SSH_PUB_KEY_PATH"
  exit 1
fi

if ! grep -qE '^ssh-(ed25519|rsa|ecdsa|sk-)' "$SSH_PUB_KEY_PATH"; then
  echo "❌ File does not look like a valid SSH public key"
  exit 1
fi

# --------------------------
# Trust the key globally
# --------------------------
mkdir -p "$(dirname "$ALLOWED_SIGNERS")"
touch "$ALLOWED_SIGNERS"

PUB_KEY="$(tr -d '\n' < "$SSH_PUB_KEY_PATH" | xargs)"
ENTRY="$EMAIL $PUB_KEY"

if ! grep -Fqx "$ENTRY" "$ALLOWED_SIGNERS"; then
  echo "$ENTRY" >> "$ALLOWED_SIGNERS"
  echo "✅ Trusted signer added: $EMAIL"
else
  echo "ℹ️ Signer already present: $EMAIL"
fi

git config --global gpg.format ssh
git config --global gpg.ssh.allowedSignersFile "$ALLOWED_SIGNERS"

# --------------------------
# Optional per-repo identity
# --------------------------
if [[ "$MODE" == "--local" ]]; then
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "❌ Not inside a Git repository"
    exit 1
  fi

  CURRENT_KEY=$(git config user.signingkey || echo "")
  CURRENT_EMAIL=$(git config user.email || echo "")

  if [[ "$CURRENT_KEY" == "$SSH_PUB_KEY_PATH" && "$CURRENT_EMAIL" == "$EMAIL" ]]; then
    echo "ℹ️ Repo already configured for this identity"
  else
    git config user.email "$EMAIL"
    git config user.signingkey "$SSH_PUB_KEY_PATH"
    git config commit.gpgsign true
    echo "🔐 Repo configured to sign with this key: $EMAIL"
  fi
else
  echo "ℹ️ Global trust configured only."
  echo "   To activate in a repo:"
  echo "     git config user.email $EMAIL"
  echo "     git config user.signingkey $SSH_PUB_KEY_PATH"
  echo "     git config commit.gpgsign true"
fi
