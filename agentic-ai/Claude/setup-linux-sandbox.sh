#!/usr/bin/env bash
# One-time OS-level setup for Claude Code sandboxing on Ubuntu 24.04+.
# Ubuntu 24.04's AppArmor policy blocks bwrap from creating user namespaces;
# this profile grants exactly that capability and nothing else.
# Requires sudo. Safe to re-run.

set -euo pipefail

if ! command -v bwrap &>/dev/null; then
  printf 'bubblewrap not found. Install it first:\n'
  printf '  Ubuntu/Debian: sudo apt-get install bubblewrap socat\n'
  printf '  Fedora:        sudo dnf install bubblewrap socat\n'
  exit 1
fi

PROFILE="/etc/apparmor.d/bwrap"

if [[ -f "$PROFILE" ]]; then
  printf 'AppArmor profile already exists: %s\n' "$PROFILE"
  exit 0
fi

if ! command -v apparmor_status &>/dev/null; then
  printf 'AppArmor not detected — profile not required on this system.\n'
  exit 0
fi

printf 'Writing AppArmor profile: %s\n' "$PROFILE"
sudo tee "$PROFILE" > /dev/null <<'EOF'
abi <abi/4.0>,
include <tunables/global>

profile bwrap /usr/bin/bwrap flags=(unconfined) {
  userns,
  include if exists <local/bwrap>
}
EOF

printf 'Reloading AppArmor...\n'
sudo systemctl reload apparmor
printf 'Done. Restart Claude Code to activate sandboxing.\n'
