#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   create_gpg_key.sh                       create a new key (prompts; NAME/EMAIL/EXPIRY env vars pre-fill)
#   create_gpg_key.sh --add-email <key-id>  add one or more emails to an existing key
#
# A key's emails are public once the key is published, and a published email can
# be revoked but never removed, so only add emails you are fine linking together.

usage() {
  sed -n '4,9p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

# ---- Inputs (can be provided as env vars or will be prompted) ----
NAME="${NAME:-}"
EMAIL="${EMAIL:-}"
EXPIRY="${EXPIRY:-2y}"
ADD_TO_KEY=""

case "${1:-}" in
  "") ;;
  --add-email)
    ADD_TO_KEY="${2:-}"
    [[ -n "$ADD_TO_KEY" ]] || { echo "Error: --add-email needs a key id." >&2; usage 2; }
    ;;
  -h|--help) usage 0 ;;
  *) echo "Error: unknown argument: $1" >&2; usage 2 ;;
esac

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

collect_emails() {
  EXTRA_EMAILS=()
  echo ""
  echo "Enter $1 emails to attach to this key (one per line, empty line to finish):"
  while true; do
    read -r -p "  Email (or Enter to finish): " extra
    [[ -z "$extra" ]] && break
    EXTRA_EMAILS+=("$extra")
  done
}

# Adds each EXTRA_EMAILS entry as a UID on key $1; skips emails the key already has.
add_uids() {
  local key_id="$1" extra_email
  for extra_email in "${EXTRA_EMAILS[@]+"${EXTRA_EMAILS[@]}"}"; do
    if gpg --list-keys --with-colons "$key_id" | awk -F: '$1=="uid"{print $10}' | grep -Fq "<$extra_email>"; then
      echo "Key already has <$extra_email> (skipping)."
      continue
    fi
    echo "Adding UID: $NAME <$extra_email>..."
    gpg --quick-add-uid "$key_id" "$NAME <$extra_email>"
  done
}

print_public_key() {
  echo ""
  echo "Public key (add this to GitHub / GitLab / etc.):"
  echo "------------------------------------------------------------"
  gpg --armor --export "$1"
  echo "------------------------------------------------------------"
  echo ""
}

# ---- Add emails to an existing key ----
if [[ -n "$ADD_TO_KEY" ]]; then
  if ! gpg --list-secret-keys "$ADD_TO_KEY" >/dev/null 2>&1; then
    echo "Error: no secret key found for $ADD_TO_KEY." >&2
    exit 1
  fi
  KEY_ID="$(gpg --list-secret-keys --with-colons "$ADD_TO_KEY" | awk -F: '$1=="sec"{print $5; exit}')"
  if [[ -z "$NAME" ]]; then
    # Default the name to the key's first UID, without its comment and email.
    NAME="$(gpg --list-keys --with-colons "$KEY_ID" | awk -F: '$1=="uid"{print $10; exit}' | sed -E 's/ *(\(.*\))? *<.*>$//')"
  fi
  prompt NAME "Full name"
  echo "Key $KEY_ID currently has:"
  gpg --list-keys --with-colons "$KEY_ID" | awk -F: '$1=="uid"{print "  " $10}'
  collect_emails "the"
  if [[ ${#EXTRA_EMAILS[@]} -eq 0 ]]; then
    echo "No emails given; nothing to do."
    exit 0
  fi
  add_uids "$KEY_ID"
  print_public_key "$KEY_ID"
  echo "Re-upload this public key everywhere the old one is registered, so the host knows the new email."
  echo "Git hosts check the email of each commit against the emails on the key."
  exit 0
fi

prompt NAME   "Full name"
prompt EMAIL  "Primary email"
prompt EXPIRY "Key expiry (e.g. 1y, 2y, 0 for no expiry)" "2y"

# ---- Collect additional emails ----
collect_emails "additional"

# ---- Generate key ----
echo ""
echo "Generating GPG key for $NAME <$EMAIL> (expires: $EXPIRY)..."

gpg --batch --gen-key <<EOF
%no-protection
Key-Type: eddsa
Key-Curve: Ed25519
Key-Usage: sign
Subkey-Type: ecdh
Subkey-Curve: Curve25519
Subkey-Usage: encrypt
Name-Real: $NAME
Name-Comment: GPG Signing Key
Name-Email: $EMAIL
Expire-Date: $EXPIRY
%commit
EOF

# ---- Find the new key (newest secret key for this email, in case an older key shares it) ----
KEY_ID="$(gpg --list-secret-keys --with-colons "<$EMAIL>" \
  | awk -F: '$1=="sec"{print $6, $5}' | sort -n | tail -1 | cut -d' ' -f2)"

if [[ -z "$KEY_ID" ]]; then
  echo "Error: could not find generated key for $EMAIL." >&2
  exit 1
fi

echo ""
echo "Key ID: $KEY_ID"

# ---- Add extra UIDs ----
add_uids "$KEY_ID"

# ---- Show public key ----
print_public_key "$KEY_ID"

# ---- Configure git to use this key (optional) ----
read -r -p "Configure git to sign commits with this key? (Y/n): " yn
case "${yn:-Y}" in
  n|N)
    echo "Skipping git config."
    ;;
  *)
    git config --global user.signingkey "$KEY_ID"
    git config --global commit.gpgsign true
    echo "git configured to sign commits with $KEY_ID."

    existing_name="$(git config --global user.name 2>/dev/null || true)"
    existing_email="$(git config --global user.email 2>/dev/null || true)"

    if [[ -z "$existing_name" ]]; then
      git config --global user.name "$NAME"
      echo "git user.name set to: $NAME"
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

# ---- Verify key can sign ----
echo ""
echo "Verifying key can sign..."
if echo "test" | gpg --clearsign --local-user "$KEY_ID" > /dev/null 2>&1; then
  echo "Key verified — signing works."
else
  echo "Warning: signing test failed. Check gpg-agent is running." >&2
fi

echo ""
echo "Done. Add the public key above to your Git host account."
