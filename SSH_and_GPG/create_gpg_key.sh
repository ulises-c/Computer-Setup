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

prompt NAME   "Full name"
prompt EMAIL  "Primary email"
prompt EXPIRY "Key expiry (e.g. 1y, 2y, 0 for no expiry)" "2y"

# ---- Collect additional emails ----
EXTRA_EMAILS=()
echo ""
echo "Enter additional emails to attach to this key (one per line, empty line to finish):"
while true; do
  read -r -p "  Additional email (or Enter to finish): " extra
  [[ -z "$extra" ]] && break
  EXTRA_EMAILS+=("$extra")
done

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

# ---- Add extra UIDs ----
for extra_email in "${EXTRA_EMAILS[@]+"${EXTRA_EMAILS[@]}"}"; do
  echo "Adding UID: $NAME <$extra_email>..."
  gpg --command-fd 0 --no-tty --edit-key "$KEY_ID" <<EOF
adduid
$NAME
$extra_email

O
save
EOF
done

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
