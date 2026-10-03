#!/usr/bin/env bash
set -euo pipefail

# Run on the backup host (the main server) with sudo. Gives one client an
# SFTP-only account, restic-<client>, holding its primary repository on the 1TB
# drive and its second copy on the 14TB drive, and authorizes the client's root
# backup key. Idempotent; never touches another client's account or repos.
# Omit <pubkey-file> to keep the account's existing authorized key (repairing
# an account whose sshd Match block was lost).
#
#   sudo bash server-base/backup/sftp-target.sh [--dry-run] <client> [<pubkey-file>]

DRY_RUN=false
[[ "${1:-}" == --dry-run ]] && { DRY_RUN=true; shift; }
client="${1:-}"
pubkey_file="${2:-}"
[[ "$client" =~ ^[a-z][a-z0-9-]{0,20}$ && ( -z "$pubkey_file" || -f "$pubkey_file" ) ]] || {
  printf 'usage: sudo bash %s [--dry-run] <client> [<pubkey-file>]\n' "$0" >&2
  exit 1
}
: "${PRIMARY_MOUNT:=/mnt/wd1tb}"
: "${SECOND_MOUNT:=/mnt/wd14tb}"
user="restic-$client"
pubkey=""
if [[ -n "$pubkey_file" ]]; then
  pubkey="$(head -1 "$pubkey_file")"
  [[ "$pubkey" =~ ^ssh-ed25519\ [A-Za-z0-9+/=]+(\ [^[:space:]]+)?$ ]] || {
    printf 'error: %s is not a single ed25519 public key\n' "$pubkey_file" >&2
    exit 1
  }
fi
dropin="/etc/ssh/sshd_config.d/60-$user.conf"

for m in "$PRIMARY_MOUNT" "$SECOND_MOUNT"; do
  mountpoint -q "$m" && [[ -f "$m/.backup-target-ok" ]] || {
    printf 'error: %s is not a mounted backup drive (.backup-target-ok missing)\n' "$m" >&2
    exit 1
  }
done

run() {
  if [[ "$DRY_RUN" == true ]]; then printf '[dry-run] %s\n' "$*"; else "$@"; fi
}
[[ "$DRY_RUN" == true || $EUID -eq 0 ]] || { printf 'error: run with sudo\n' >&2; exit 1; }

# /bin/false, not nologin: nologin prints a message that corrupts the SFTP stream.
if ! id "$user" &>/dev/null; then
  run useradd --create-home --shell /bin/false "$user"
fi
home="$(getent passwd "$user" | cut -d: -f6 || true)"
home="${home:-/home/$user}"
run install -d -o "$user" -g "$user" -m 700 "$PRIMARY_MOUNT/restic-$client" "$SECOND_MOUNT/restic-$client-copy"
run install -d -o "$user" -g "$user" -m 700 "$home/.ssh"
if [[ -z "$pubkey" && "$DRY_RUN" == false && ! -s "$home/.ssh/authorized_keys" ]]; then
  printf 'error: %s has no authorized key; pass the client public key\n' "$user" >&2
  exit 1
fi
if [[ "$DRY_RUN" == true ]]; then
  printf '[dry-run] %s %s/.ssh/authorized_keys\n' "${pubkey:+write (restrict) }${pubkey:-keep}" "$home"
  printf '[dry-run] write %s: Match User %s, ForceCommand internal-sftp\n' "$dropin" "$user"
  exit 0
fi
if [[ -n "$pubkey" ]]; then
  printf 'restrict %s\n' "$pubkey" | install -o "$user" -g "$user" -m 600 /dev/stdin "$home/.ssh/authorized_keys"
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
printf 'Match User %s\n    ForceCommand internal-sftp\n    AllowTcpForwarding no\n    AllowAgentForwarding no\n    X11Forwarding no\n    PermitTTY no\n    PasswordAuthentication no\n' \
  "$user" >"$tmp"
install -m 644 "$tmp" "$dropin"
if ! sshd -t; then
  rm -f "$dropin"
  printf 'error: sshd rejected %s; removed it, sshd unchanged\n' "$dropin" >&2
  exit 1
fi
systemctl reload ssh

# The Match block must bind only this account.
sshd -T -C "user=$user,host=check,addr=127.0.0.1" | grep -qx 'forcecommand internal-sftp' || {
  printf 'error: %s does not get ForceCommand internal-sftp\n' "$user" >&2
  exit 1
}
sshd -T -C "user=${SUDO_USER:-root},host=check,addr=127.0.0.1" >"$tmp"
if ! grep -qx 'forcecommand none' "$tmp" || ! grep -qx 'permittty yes' "$tmp"; then
  rm -f "$dropin"
  systemctl reload ssh
  printf 'error: the drop-in leaked onto %s; removed it and reloaded sshd\n' "${SUDO_USER:-root}" >&2
  exit 1
fi
printf 'ok: %s is SFTP-only; repos %s and %s\n' "$user" \
  "$PRIMARY_MOUNT/restic-$client" "$SECOND_MOUNT/restic-$client-copy"
