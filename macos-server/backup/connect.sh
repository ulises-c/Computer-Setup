#!/usr/bin/env bash
set -euo pipefail

# macOS counterpart of server-base/backup/sftp-client.sh: the Mac's backup runs
# as the login user (a LaunchAgent), so its key, SSH alias and known_hosts live
# in ~/.ssh and no sudo is needed. Two steps around sftp-target.sh, run on the
# main server:
#
#   bash macos-server/backup/connect.sh key
#     creates ~/.ssh/mac-backup and prints the public key for sftp-target.sh
#   bash macos-server/backup/connect.sh connect <target-ip> <host-key-sha256>
#     pins the main server's ed25519 key, writes the mac-backup-target alias,
#     creates backup/.env with a new restic password if missing, and
#     initializes the primary and second repositories

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
[[ $EUID -ne 0 ]] || { printf 'error: run as the login user, not with sudo\n' >&2; exit 1; }
name="$(sed -n 's/^BACKUP_NAME=//p' "$SCRIPT_DIR/sources.sh")"
[[ "$name" =~ ^[a-z][a-z0-9-]*$ ]] || { printf 'error: bad BACKUP_NAME in sources.sh\n' >&2; exit 1; }
key="$HOME/.ssh/$name-backup"
alias="$name-backup-target"
env_file="$SCRIPT_DIR/.env"

case "${1:-}" in
  key)
    command -v restic >/dev/null || brew install restic
    install -d -m 700 "$HOME/.ssh"
    [[ -f "$key" ]] || ssh-keygen -q -t ed25519 -N "" -C "$name-backup@$(hostname -s)" -f "$key"
    printf 'public key (%s.pub), for sftp-target.sh %s on the main server:\n' "$key" "$name"
    cat "$key.pub"
    ;;
  connect)
    target="${2:?target ip}"
    want="${3:?expected SHA256 fingerprint of the backup host ed25519 key}"
    [[ "$target" =~ ^[0-9.]+$ ]] || { printf 'error: target must be an IPv4 address\n' >&2; exit 1; }
    [[ -f "$key" ]] || { printf 'error: run the key step first\n' >&2; exit 1; }
    scanned="$(mktemp)"
    trap 'rm -f "$scanned"' EXIT
    ssh-keyscan -q -t ed25519 "$target" >"$scanned" || true
    got=""
    [[ -s "$scanned" ]] && got="$(ssh-keygen -lf "$scanned" | awk '{print $2}')"
    [[ "$got" == "$want" ]] || {
      printf 'error: %s presented %s, expected %s; refusing to trust it\n' "$target" "${got:-nothing}" "$want" >&2
      exit 1
    }
    touch "$HOME/.ssh/known_hosts"
    ssh-keygen -F "$target" -f "$HOME/.ssh/known_hosts" >/dev/null || cat "$scanned" >>"$HOME/.ssh/known_hosts"
    if grep -qx "Host $alias" "$HOME/.ssh/config" 2>/dev/null; then
      # An existing alias pointing elsewhere is not rewritten silently.
      awk -v a="Host $alias" '$0==a{f=1;next} /^Host /{f=0} f && $1=="HostName"{print $2}' "$HOME/.ssh/config" \
        | grep -qx "$target" || {
        printf 'error: %s in ~/.ssh/config points elsewhere; fix it by hand\n' "$alias" >&2
        exit 1
      }
    else
      printf '\nHost %s\n    HostName %s\n    User restic-%s\n    IdentityFile %s\n    IdentitiesOnly yes\n    StrictHostKeyChecking yes\n' \
        "$alias" "$target" "$name" "$key" >>"$HOME/.ssh/config"
      chmod 600 "$HOME/.ssh/config"
    fi
    if [[ ! -f "$env_file" ]]; then
      tmp="$(mktemp "$SCRIPT_DIR/.env.XXXXXX")"
      password="$(openssl rand -hex 32)"
      sed "s|^RESTIC_PASSWORD=.*|RESTIC_PASSWORD=$password|" "$SCRIPT_DIR/.env.example" >"$tmp"
      chmod 600 "$tmp"
      mv "$tmp" "$env_file"
      printf 'created %s with a new RESTIC_PASSWORD. Save it in the password manager now:\n' "$env_file"
      printf '  grep ^RESTIC_PASSWORD= %s\n' "$env_file"
    fi
    set -a
    # shellcheck source=/dev/null
    source "$env_file"
    set +a
    export RESTIC_REPOSITORY RESTIC_PASSWORD RESTIC_FROM_PASSWORD="$RESTIC_PASSWORD"
    # Only SFTP repositories on the chrooted target are created here.
    for repo in "$RESTIC_REPOSITORY" "${SECOND_RESTIC_REPOSITORY:-}"; do
      [[ -z "$repo" || "$repo" == sftp:* ]] || { printf 'error: %s is not an sftp: repository\n' "$repo" >&2; exit 1; }
    done
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
    printf 'next: bash %s/agents.sh install\n' "$(dirname -- "$SCRIPT_DIR")"
    ;;
  *)
    printf 'usage: bash %s key | connect <target-ip> <host-key-sha256>\n' "$0" >&2
    exit 1
    ;;
esac
