#!/usr/bin/env bash
set -euo pipefail

# ---- Inputs (can be provided as env vars or will be prompted) ----
NAME="${NAME:-}"
EMAIL="${EMAIL:-}"
EXPIRY="${EXPIRY:-2y}"

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

prompt NAME  "Full name"
prompt EMAIL "Email"
prompt EXPIRY "Key expiry (e.g. 1y, 2y, 0 for no expiry)" "2y"

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

# ---- Find the new key ----
KEY_ID="$(gpg --list-secret-keys --keyid-format=long "$EMAIL" \
  | awk '/^sec/{split($2,a,"/"); print a[2]; exit}')"

if [[ -z "$KEY_ID" ]]; then
  echo "Error: could not find generated key for $EMAIL." >&2
  exit 1
fi

echo ""
echo "Key ID: $KEY_ID"

# ---- Show public key ----
echo ""
echo "Public key (add this to GitHub / GitLab / etc.):"
echo "------------------------------------------------------------"
gpg --armor --export "$KEY_ID"
echo "------------------------------------------------------------"
echo ""

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
