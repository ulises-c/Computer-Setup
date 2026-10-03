#!/usr/bin/env bash
set -euo pipefail

# Run on a backup client with sudo, in two steps around sftp-target.sh on the
# backup host:
#
#   sudo bash server-base/backup/sftp-client.sh <host-dir> key
#     installs restic, creates root's backup key, copies the public half to
#     /tmp/<name>-backup.pub for the backup host
#   sudo bash server-base/backup/sftp-client.sh <host-dir> connect <target-ip> <host-key-sha256>
#     pins the backup host's ed25519 key, writes the <name>-backup-target SSH
#     alias, creates <host-dir>/backup/.env with a new restic password if it is
#     missing, and initializes the primary and second repositories
#
# <name> is BACKUP_NAME from <host-dir>/backup/sources.sh.

host_dir="$(cd -- "${1:?usage: see header}" && pwd)"
step="${2:-}"
[[ $EUID -eq 0 ]] || { printf 'error: run with sudo\n' >&2; exit 1; }
name="$(sed -n 's/^BACKUP_NAME=//p' "$host_dir/backup/sources.sh")"
[[ "$name" =~ ^[a-z][a-z0-9-]*$ ]] || { printf 'error: bad BACKUP_NAME in sources.sh\n' >&2; exit 1; }
owner="${SUDO_USER:?run with sudo from the login user}"
key="/root/.ssh/$name-backup"
alias="$name-backup-target"
env_file="$host_dir/backup/.env"

case "$step" in
  key)
    apt-get install -y restic jq
    install -d -m 700 /root/.ssh
    [[ -f "$key" ]] || ssh-keygen -q -t ed25519 -N "" -C "$name-backup@$(hostname)" -f "$key"
    install -m 644 "$key.pub" "/tmp/$name-backup.pub"
    printf 'public key copied to /tmp/%s-backup.pub:\n' "$name"
    cat "$key.pub"
    ;;
  connect)
    target="${3:?target ip}"
    want="${4:?expected SHA256 fingerprint of the backup host ed25519 key}"
    [[ "$target" =~ ^[0-9.]+$ ]] || { printf 'error: target must be an IPv4 address\n' >&2; exit 1; }
    scanned="$(mktemp)"
    trap 'rm -f "$scanned"' EXIT
    ssh-keyscan -q -t ed25519 "$target" >"$scanned"
    got="$(ssh-keygen -lf "$scanned" | awk '{print $2}')"
    [[ "$got" == "$want" ]] || {
      printf 'error: %s presented %s, expected %s; refusing to trust it\n' "$target" "${got:-nothing}" "$want" >&2
      exit 1
    }
    touch /root/.ssh/known_hosts
    grep -qF "$(cut -d' ' -f2- "$scanned")" /root/.ssh/known_hosts || cat "$scanned" >>/root/.ssh/known_hosts
    chmod 600 /root/.ssh/known_hosts
    if ! grep -qx "Host $alias" /root/.ssh/config 2>/dev/null; then
      printf '\nHost %s\n    HostName %s\n    User restic-%s\n    IdentityFile %s\n    IdentitiesOnly yes\n    StrictHostKeyChecking yes\n' \
        "$alias" "$target" "$name" "$key" >>/root/.ssh/config
      chmod 600 /root/.ssh/config
    fi
    if [[ ! -f "$env_file" ]]; then
      install -o "$owner" -g "$(id -gn "$owner")" -m 600 "$host_dir/backup/.env.example" "$env_file"
      sed -i "s|^RESTIC_PASSWORD=.*|RESTIC_PASSWORD=$(openssl rand -hex 32)|" "$env_file"
      printf 'created %s with a new RESTIC_PASSWORD. Save it in the password manager now:\n' "$env_file"
      printf '  sudo grep ^RESTIC_PASSWORD= %s\n' "$env_file"
    fi
    set -a
    # shellcheck source=/dev/null
    source "$env_file"
    set +a
    export RESTIC_REPOSITORY RESTIC_PASSWORD RESTIC_FROM_PASSWORD="$RESTIC_PASSWORD"
    if restic cat config >/dev/null 2>&1; then
      printf 'primary repository already initialized\n'
    else
      restic init
    fi
    if [[ -n "${SECOND_RESTIC_REPOSITORY:-}" ]]; then
      if restic -r "$SECOND_RESTIC_REPOSITORY" cat config >/dev/null 2>&1; then
        printf 'second repository already initialized\n'
      else
        restic -r "$SECOND_RESTIC_REPOSITORY" init --copy-chunker-params --from-repo "$RESTIC_REPOSITORY"
      fi
    fi
    printf 'next: bash %s/backup/setup.sh --dry-run, then sudo bash %s/backup/setup.sh\n' "$host_dir" "$host_dir"
    ;;
  *)
    printf 'usage: sudo bash %s <host-dir> key | connect <target-ip> <host-key-sha256>\n' "$0" >&2
    exit 1
    ;;
esac
