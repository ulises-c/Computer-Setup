#!/usr/bin/env bash
set -euo pipefail

# Run on the backup host (the main server) with sudo. Gives one client an
# SFTP-only account, restic-<client>, chrooted to /srv/restic/<client>. Inside
# the chroot, /primary is a bind mount of its repository on the 1TB drive and
# /copy of its second copy on the 14TB drive, so the client sees only its own
# two repositories (sftp:<alias>:/primary and :/copy). Idempotent; never touches
# another client's account or repos. Omit <pubkey-file> to keep the account's
# existing authorized key.
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
chroot_dir="/srv/restic/$client"
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
# sshd requires every component of ChrootDirectory to be root-owned and not
# group/other-writable. The bind targets stay root-owned while unmounted, so a
# missing drive makes the backup fail instead of writing to the root disk.
run install -d -o root -g root -m 755 /srv/restic "$chroot_dir" "$chroot_dir/primary" "$chroot_dir/copy"
if [[ -z "$pubkey" && "$DRY_RUN" == false && ! -s "$home/.ssh/authorized_keys" ]]; then
  printf 'error: %s has no authorized key; pass the client public key\n' "$user" >&2
  exit 1
fi

declare -A binds=(
  [primary]="$PRIMARY_MOUNT|$PRIMARY_MOUNT/restic-$client"
  [copy]="$SECOND_MOUNT|$SECOND_MOUNT/restic-$client-copy"
)
units=()
for name in primary copy; do
  drive="${binds[$name]%%|*}"
  src="${binds[$name]#*|}"
  where="$chroot_dir/$name"
  unit="$(systemd-escape --path --suffix=mount "$where")"
  units+=("$unit")
  if [[ "$DRY_RUN" == true ]]; then
    printf '[dry-run] write /etc/systemd/system/%s: bind %s -> %s (only while %s is mounted)\n' "$unit" "$src" "$where" "$drive"
    continue
  fi
  cat >"/etc/systemd/system/$unit" <<EOF
[Unit]
Description=restic-$client $name repository in its SFTP chroot
RequiresMountsFor=$drive
ConditionPathIsMountPoint=$drive

[Mount]
What=$src
Where=$where
Type=none
Options=bind

[Install]
WantedBy=multi-user.target
EOF
done

if [[ "$DRY_RUN" == true ]]; then
  printf '[dry-run] %s %s/.ssh/authorized_keys\n' "${pubkey:+write (restrict) }${pubkey:-keep}" "$home"
  printf '[dry-run] write %s: Match User %s, ChrootDirectory %s, ForceCommand internal-sftp\n' "$dropin" "$user" "$chroot_dir"
  exit 0
fi
systemctl daemon-reload
systemctl enable --now "${units[@]}"
for name in primary copy; do
  mountpoint -q "$chroot_dir/$name" || { printf 'error: %s/%s is not mounted\n' "$chroot_dir" "$name" >&2; exit 1; }
done

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
# Via a temp file: uutils install (Ubuntu 26.04) fails reading /dev/stdin onto
# an existing destination.
if [[ -n "$pubkey" ]]; then
  printf 'restrict %s\n' "$pubkey" >"$tmp"
  install -o "$user" -g "$user" -m 600 "$tmp" "$home/.ssh/authorized_keys"
fi
printf 'Match User %s\n    ChrootDirectory %s\n    ForceCommand internal-sftp\n    AllowTcpForwarding no\n    AllowAgentForwarding no\n    X11Forwarding no\n    PermitTTY no\n    PasswordAuthentication no\n' \
  "$user" "$chroot_dir" >"$tmp"
install -m 644 "$tmp" "$dropin"
if ! sshd -t; then
  rm -f "$dropin"
  printf 'error: sshd rejected %s; removed it, sshd unchanged\n' "$dropin" >&2
  exit 1
fi
systemctl reload ssh

# The Match block must bind only this account. sshd -T quoting differs across
# OpenSSH releases, so compare case-insensitively with optional quotes.
sshd -T -C "user=$user,host=check,addr=127.0.0.1" >"$tmp"
if ! grep -qiE '^forcecommand "?internal-sftp"?$' "$tmp" || ! grep -qiE "^chrootdirectory \"?$chroot_dir\"?$" "$tmp"; then
  rm -f "$dropin"
  systemctl reload ssh
  printf 'error: %s is not chrooted SFTP-only (sshd -T: %s); removed %s\n' \
    "$user" "$(grep -iE '^(forcecommand|chrootdirectory)' "$tmp" | tr '\n' ' ')" "$dropin" >&2
  exit 1
fi
sshd -T -C "user=${SUDO_USER:-root},host=check,addr=127.0.0.1" >"$tmp"
if ! grep -qiE '^forcecommand "?none"?$' "$tmp" || ! grep -qiE '^permittty "?yes"?$' "$tmp"; then
  rm -f "$dropin"
  systemctl reload ssh
  printf 'error: the drop-in leaked onto %s; removed it and reloaded sshd\n' "${SUDO_USER:-root}" >&2
  exit 1
fi
printf 'ok: %s is chrooted to %s; repositories are sftp:<alias>:/primary and sftp:<alias>:/copy\n' "$user" "$chroot_dir"
