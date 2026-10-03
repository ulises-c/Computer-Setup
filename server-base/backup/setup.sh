#!/usr/bin/env bash
set -euo pipefail

# Install a host's backup units. Run through the host's symlink
# (sudo bash <host>/backup/setup.sh); unit names come from its sources.sh and
# the unit templates are the host's own files next to it.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
HOST_DIR="$(dirname -- "$SCRIPT_DIR")"
DRY_RUN=false
unit="$(sed -n 's/^BACKUP_UNIT=//p' "$SCRIPT_DIR/sources.sh")"
prefix="${unit%.service}"
BUNDLE_DIR="/usr/local/libexec/computer-setup-backup/$prefix"
STATE_DIR="/var/lib/computer-setup-backup/$prefix"
BUNDLE_SAVE_SOURCE="$HOST_DIR/dragonwilds/backup-save.py"
BUNDLE_SAVE_TARGET="$BUNDLE_DIR/backup-save.py"
BUNDLE_SAVE_SCRIPT=""
BUNDLE_SAVE_SCRIPT_SHA256=""
[[ -f "$BUNDLE_SAVE_SOURCE" ]] && BUNDLE_SAVE_SCRIPT="$BUNDLE_SAVE_TARGET"
file_sha256() {
  if command -v sha256sum >/dev/null; then
    sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null; then
    shasum -a 256 "$1" | cut -d' ' -f1
  else
    printf 'error: sha256sum or shasum is required\n' >&2
    return 1
  fi
}
if [[ -f "$BUNDLE_SAVE_SOURCE" ]]; then
  BUNDLE_SAVE_SCRIPT_SHA256="$(file_sha256 "$BUNDLE_SAVE_SOURCE")"
fi
BACKUP_DRAGONWILDS_INSTALL_DIR=""
BACKUP_FORGEJO_DATA_PATH="$HOST_DIR/forgejo/data"
read_env_value() {
  local file="$1" key="$2" value
  value="$(grep -E "^(export[[:space:]]+)?${key}=" "$file" | tail -1 | cut -d= -f2- || true)"
  value="${value%$'\r'}"
  value="${value%%[[:space:]]#*}"
  if [[ "$value" =~ ^\"(.*)\"$ || "$value" =~ ^\'(.*)\'$ ]]; then
    value="${BASH_REMATCH[1]}"
  fi
  printf '%s' "$value"
}
if [[ -f "$HOST_DIR/dragonwilds/.env" ]]; then
  BACKUP_DRAGONWILDS_INSTALL_DIR="$(read_env_value "$HOST_DIR/dragonwilds/.env" DRAGONWILDS_INSTALL_DIR)"
fi
if [[ -f "$HOST_DIR/forgejo/.env" ]]; then
  fdp="$(read_env_value "$HOST_DIR/forgejo/.env" FORGEJO_DATA_PATH)"
  if [[ -n "$fdp" ]]; then
    if [[ "$fdp" == /* ]]; then
      BACKUP_FORGEJO_DATA_PATH="$fdp"
    else
      BACKUP_FORGEJO_DATA_PATH="$HOST_DIR/forgejo/${fdp#./}"
    fi
  fi
fi
[[ "$prefix" =~ ^[a-z][a-z-]*$ ]] || { printf 'error: bad BACKUP_UNIT in %s/sources.sh\n' "$SCRIPT_DIR" >&2; exit 1; }

case "${1:-}" in
  "") ;;
  --dry-run) DRY_RUN=true ;;
  *) printf 'error: unknown argument: %s\n' "$1" >&2; exit 1 ;;
esac

if ! [[ "$SCRIPT_DIR" =~ ^/[[:alnum:]_./-]+$ ]]; then
  printf 'error: unsupported character in checkout path: %s\n' "$SCRIPT_DIR" >&2
  exit 1
fi
if ! [[ "$HOST_DIR" =~ ^/[[:alnum:]_./-]+$ ]]; then
  printf 'error: unsupported host checkout path: %s\n' "$HOST_DIR" >&2
  exit 1
fi
if [[ -n "$BACKUP_DRAGONWILDS_INSTALL_DIR" ]] && ! [[ "$BACKUP_DRAGONWILDS_INSTALL_DIR" =~ ^/[[:alnum:]_./-]+$ && "$BACKUP_DRAGONWILDS_INSTALL_DIR" != *//* && "$BACKUP_DRAGONWILDS_INSTALL_DIR" != */./* && "$BACKUP_DRAGONWILDS_INSTALL_DIR" != */. && "$BACKUP_DRAGONWILDS_INSTALL_DIR" != */../* && "$BACKUP_DRAGONWILDS_INSTALL_DIR" != */.. && "$BACKUP_DRAGONWILDS_INSTALL_DIR" != */ ]]; then
  printf 'error: invalid DRAGONWILDS_INSTALL_DIR in %s/dragonwilds/.env\n' "$HOST_DIR" >&2
  exit 1
fi
if ! [[ "$BACKUP_FORGEJO_DATA_PATH" =~ ^/[[:alnum:]_./-]+$ && "$BACKUP_FORGEJO_DATA_PATH" != *//* && "$BACKUP_FORGEJO_DATA_PATH" != */./* && "$BACKUP_FORGEJO_DATA_PATH" != */. && "$BACKUP_FORGEJO_DATA_PATH" != */../* && "$BACKUP_FORGEJO_DATA_PATH" != */.. && "$BACKUP_FORGEJO_DATA_PATH" != */ ]]; then
  printf 'error: invalid FORGEJO_DATA_PATH in %s/forgejo/.env\n' "$HOST_DIR" >&2
  exit 1
fi
if [[ "$DRY_RUN" == false ]]; then
  [[ $EUID -eq 0 ]] || { printf 'error: run with sudo: sudo bash %s\n' "$0" >&2; exit 1; }
  [[ -f "$SCRIPT_DIR/.env" ]] || { printf 'error: create %s/.env before installing\n' "$SCRIPT_DIR" >&2; exit 1; }
  if [[ "$unit" == "game-backup.service" && ! -f "$BUNDLE_SAVE_SOURCE" ]]; then
    printf 'error: cannot install game backup without %s\n' "$BUNDLE_SAVE_SOURCE" >&2
    exit 1
  fi
  if [[ ("$unit" == "game-backup.service" || "$unit" == "backup.service") && -z "$BACKUP_DRAGONWILDS_INSTALL_DIR" ]]; then
    printf 'error: cannot install %s without DRAGONWILDS_INSTALL_DIR in %s/dragonwilds/.env\n' "$unit" "$HOST_DIR" >&2
    exit 1
  fi
  if [[ "$unit" == "game-backup.service" && -z "$BUNDLE_SAVE_SCRIPT_SHA256" ]]; then
    printf 'error: cannot pin the game backup helper hash\n' >&2
    exit 1
  fi
  chmod 600 "$SCRIPT_DIR/.env"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

render_unit() {
  local src="$1" dest="$2"
  sed \
    -e "s|@BACKUP_SCRIPT@|$BUNDLE_DIR/backup.sh|g" \
    -e "s|@BACKUP_ENV@|$BUNDLE_DIR/.env|g" \
    -e "s|@BACKUP_HOST_DIR@|$HOST_DIR|g" \
    -e "s|@BACKUP_SAVE_SCRIPT@|$BUNDLE_SAVE_SCRIPT|g" \
    -e "s|@BACKUP_SAVE_SCRIPT_SHA256@|$BUNDLE_SAVE_SCRIPT_SHA256|g" \
    -e "s|@BACKUP_DRAGONWILDS_INSTALL_DIR@|$BACKUP_DRAGONWILDS_INSTALL_DIR|g" \
    -e "s|@BACKUP_FORGEJO_DATA_PATH@|$BACKUP_FORGEJO_DATA_PATH|g" \
    -e "s|@BACKUP_STATUS_JSON@|$STATE_DIR/backup-status.json|g" \
    "$src" > "$tmp/$dest"
  if [[ "$DRY_RUN" == true ]]; then
    printf '[dry-run] install %s as /etc/systemd/system/%s\n' "$src" "$dest"
  else
    install -o root -g root -m 644 "$tmp/$dest" "/etc/systemd/system/$dest"
  fi
}

install_bundle() {
  install -d -o root -g root -m 755 "$BUNDLE_DIR"
  install -d -o root -g root -m 755 "$STATE_DIR"
  install -o root -g root -m 755 "$SCRIPT_DIR/backup.sh" "$BUNDLE_DIR/backup.sh"
  install -o root -g root -m 644 "$SCRIPT_DIR/sources.sh" "$BUNDLE_DIR/sources.sh"
  install -o root -g root -m 600 "$SCRIPT_DIR/.env" "$BUNDLE_DIR/.env"
  if [[ -f "$BUNDLE_SAVE_SOURCE" ]]; then
    install -o root -g root -m 644 "$BUNDLE_SAVE_SOURCE" "$BUNDLE_SAVE_TARGET"
  else
    rm -f "$BUNDLE_SAVE_TARGET"
  fi
}

render_unit "$SCRIPT_DIR/$prefix.service.template" "$prefix.service"
render_unit "$SCRIPT_DIR/$prefix-failure.service.template" "$prefix-failure.service"
[[ "$DRY_RUN" == true ]] || install_bundle
if command -v systemd-analyze >/dev/null; then
  systemd-analyze verify "$tmp/$prefix.service" "$tmp/$prefix-failure.service" "$SCRIPT_DIR/$prefix.timer"
fi

if [[ "$DRY_RUN" == true ]]; then
  printf '[dry-run] install root-owned backup executor bundle into %s\n' "$BUNDLE_DIR"
  printf '[dry-run] install %s as /etc/systemd/system/%s.timer\n' "$SCRIPT_DIR/$prefix.timer" "$prefix"
  printf '[dry-run] systemctl daemon-reload\n'
  printf '[dry-run] systemctl enable --now %s.timer\n' "$prefix"
else
  install -o root -g root -m 644 "$SCRIPT_DIR/$prefix.timer" "/etc/systemd/system/$prefix.timer"
  systemctl daemon-reload
  systemctl enable --now "$prefix.timer"
  printf 'Installed and enabled %s.timer\n' "$prefix"
fi
