# shellcheck shell=bash
# Sourced by server-base/backup/backup.sh (as root). Names this host's backup
# and lists its paths; the repository is the main server over SFTP (.env).
# shellcheck disable=SC2034
BACKUP_NAME=game
BACKUP_LABEL="Game server"
BACKUP_UNIT=game-backup.service
BACKUP_SHARED_LOCK_PATH=/var/lib/dragonwilds/player-log/.backup.lock
# Written the first time a backup sees a world, and backed up with it so a full
# restore brings it back. From then on an empty SaveGames is a lost world, not a
# fresh install: the backup fails instead of succeeding (and pruning) without it,
# and the pre-update gate still runs. The main server's sources.sh keeps the same
# marker for the saves it holds.
BACKUP_WORLD_MARKER=/var/lib/dragonwilds/world-seen

# $1: the SaveGames dir this backup covers; $2: whether it holds a world.
check_world_marker() {
  local savegames="$1" present="$2" seen=""
  if [[ "$present" == true ]]; then
    if [[ -e "$BACKUP_WORLD_MARKER" ]]; then
      seen="$(head -n1 -- "$BACKUP_WORLD_MARKER")"
      [[ "$seen" == "$savegames" ]] \
        || log "warning: the world was first backed up from $seen, now from $savegames; check nothing was left behind"
    else
      install -d -m 755 "$(dirname -- "$BACKUP_WORLD_MARKER")"
      printf '%s\n' "$savegames" >"$BACKUP_WORLD_MARKER"
    fi
  elif [[ -e "$BACKUP_WORLD_MARKER" ]]; then
    die "no Dragonwilds world in $savegames, but one was backed up before; restore it, or delete $BACKUP_WORLD_MARKER if it was removed on purpose"
  fi
}

saved=""
install_dir=""
world_exists=false
resolve_sources() {
  world_exists=false
  install_dir="${BACKUP_DRAGONWILDS_INSTALL_DIR:-}"
  [[ -n "$install_dir" ]] || die "BACKUP_DRAGONWILDS_INSTALL_DIR is not rendered into game-backup.service"
  [[ "$install_dir" =~ ^/[[:alnum:]_./-]+$ && "$install_dir" != *//* && "$install_dir" != */./* && "$install_dir" != */. && "$install_dir" != */../* && "$install_dir" != */.. && "$install_dir" != */ ]] \
    || die "invalid fixed Dragonwilds install path"
  configured_install_dir="$(systemctl show dragonwilds.service --property=WorkingDirectory --value)" \
    || die "cannot read dragonwilds.service's install path from systemd"
  [[ "$configured_install_dir" == "$install_dir" ]] \
    || die "game and backup Dragonwilds install paths differ; rerun both setup scripts"
  saved="$install_dir/RSDragonwilds/Saved"
  [[ -d "$saved" ]] || { log "warning: Dragonwilds saves not found at $saved — not backed up"; saved=""; }
  if [[ -n "$saved" ]] && compgen -G "$saved/SaveGames/*.sav" >/dev/null; then
    world_exists=true
  fi
  check_world_marker "${saved:-$install_dir/RSDragonwilds/Saved}/SaveGames" "$world_exists"

  # Worlds and server config only (OwnerId, identity, world password); the game
  # install comes back from steamcmd. The repository is encrypted.
  CANDIDATES+=("$HOST_DIR/homepage/config")
  CANDIDATES+=("/var/lib/dragonwilds/player-log" "$BACKUP_WORLD_MARKER")
  if [[ -n "$saved" ]]; then
    CANDIDATES+=("$saved/SaveGames" "$saved/Config")
  fi
  resolve_2004scape_sources
}

# 2004Scape state only: the engine/content/client checkouts come back from the
# bootstrap's revision clone. The engine scans the RS-SDK data dir for SQLite;
# Lost City's db.sqlite sits beside the checkout, so stage_extra snapshots it.
# The game containers can write these trees, so a symlink in the fixed path
# could point root's backup elsewhere; only canonical paths are accepted.
BACKUP_2004SCAPE_MARKER_DIR=/var/lib/computer-setup-backup/game-backup
resolve_2004scape_sources() {
  local runtime="${BACKUP_LOSTCITY_RUNTIME_DIR:-}" rs_sdk="${BACKUP_RS_SDK_DATA_DIR:-}" path
  for path in "$runtime" "$rs_sdk"; do
    [[ -z "$path" ]] && continue
    [[ "$path" =~ ^/[[:alnum:]_./-]+$ && "$path" != *//* && "$path" != */./* && "$path" != */. && "$path" != */../* && "$path" != */.. && "$path" != */ ]] \
      || die "invalid fixed 2004Scape data path"
  done
  [[ -z "$runtime" ]] || add_2004scape_tree lostcity "$runtime/engine" "Lost City runtime" \
    "$runtime/server.json" "$runtime/engine/.env" "$runtime/engine/data/players" "$runtime/engine/data/config"
  [[ -z "$rs_sdk" ]] || add_2004scape_tree rs-sdk "$rs_sdk" "RS-SDK data" "$rs_sdk"
}

# $1 stack, $2 dir that must exist, $3 label, $4.. paths to back up. A stack
# seen by an earlier backup and now missing fails the run instead of pruning it.
add_2004scape_tree() {
  local stack="$1" dir="$2" label="$3" marker="$BACKUP_2004SCAPE_MARKER_DIR/$1-seen" real
  shift 3
  if [[ ! -d "$dir" ]]; then
    [[ ! -e "$marker" ]] \
      || die "$label missing at $dir, but it was backed up before; restore it, or delete $marker if it was removed on purpose"
    log "warning: $label not found at $dir — not backed up"
    return 0
  fi
  real="$(realpath -e -- "$dir")" || die "cannot resolve $dir"
  [[ "$real" == "$dir" ]] || die "$label path $dir resolves to $real; refusing to follow a symlink"
  if [[ "$stack" == lostcity ]]; then
    real="$(realpath -e -- "$dir/data")" || die "cannot resolve $dir/data"
    [[ "$real" == "$dir/data" ]] || die "$label path $dir/data is a symlink; refusing to follow it"
  fi
  if [[ ! -e "$marker" ]]; then
    install -d -m 755 "$BACKUP_2004SCAPE_MARKER_DIR"
    printf '%s\n' "$dir" >"$marker"
  fi
  CANDIDATES+=("$@" "$marker")
}

stage_lostcity_db() {
  local db="${BACKUP_LOSTCITY_RUNTIME_DIR:-}/engine/db.sqlite"
  [[ -n "${BACKUP_LOSTCITY_RUNTIME_DIR:-}" ]] && [[ -e "$db" || -L "$db" ]] || return 0
  [[ -f "$db" && ! -L "$db" ]] || die "Lost City $db is not a regular file; refusing to follow it"
  command -v sqlite3 >/dev/null || die "sqlite3 not installed (apt install sqlite3); needed for $db"
  install -d -m 700 "$STAGING_DIR/lostcity"
  # Lost City uses a rollback journal: wait out a write instead of failing the night.
  sqlite3 "$db" ".timeout 30000" ".backup '$STAGING_DIR/lostcity/db.sqlite.sqlitebak'" \
    || die "sqlite snapshot of $db failed"
  log "sqlite snapshot: Lost City db.sqlite"
}

# Player saves are rewritten in place, not atomically, so a live copy can catch
# one mid-write. Stage a copy of each that was stable while read and passes the
# save's own check (0x2004 magic, big-endian CRC32 of the rest in the last four
# bytes), with a .sha256 sidecar that restore-check verifies. A save that never
# validates keeps only its raw copy in the backup, and is reported.
stage_2004scape_saves() {
  local -a roots=()
  [[ -z "${BACKUP_LOSTCITY_RUNTIME_DIR:-}" ]] || roots+=("lostcity=$BACKUP_LOSTCITY_RUNTIME_DIR/engine/data/players")
  [[ -z "${BACKUP_RS_SDK_DATA_DIR:-}" ]] || roots+=("rs-sdk=$BACKUP_RS_SDK_DATA_DIR/players")
  (( ${#roots[@]} )) || return 0
  local out
  out="$(python3 - "$STAGING_DIR/saves" "${roots[@]}" <<'PY'
import hashlib, os, stat, sys, time, zlib

dest_root, roots = sys.argv[1], sys.argv[2:]
staged = bad = 0

def valid(data):
    return (len(data) >= 8 and data[:2] == b"\x20\x04"
            and zlib.crc32(data[:-4]) == int.from_bytes(data[-4:], "big"))

def stable_read(path):
    for _ in range(5):
        try:
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        except OSError:
            return None
        try:
            before = os.fstat(fd)
            if not stat.S_ISREG(before.st_mode):
                return None
            with os.fdopen(fd, "rb", closefd=False) as f:
                data = f.read()
            after = os.fstat(fd)
        finally:
            os.close(fd)
        if (before.st_mtime_ns, before.st_size) == (after.st_mtime_ns, after.st_size) \
                and len(data) == after.st_size and valid(data):
            return data
        time.sleep(0.2)
    return False

for spec in roots:
    stack, root = spec.split("=", 1)
    if os.path.islink(root) or not os.path.isdir(root):
        continue
    for dirpath, dirnames, filenames in os.walk(root):
        for name in sorted(filenames):
            if not name.endswith(".sav"):
                continue
            src = os.path.join(dirpath, name)
            data = stable_read(src)
            if data is None:
                continue
            rel = os.path.relpath(src, root)
            if data is False:
                bad += 1
                print(f"warning: {stack} save {rel} failed its check; only the raw copy is backed up", file=sys.stderr)
                continue
            dest = os.path.join(dest_root, stack, rel)
            os.makedirs(os.path.dirname(dest), mode=0o700, exist_ok=True)
            with open(dest, "xb") as f:
                f.write(data)
            with open(dest + ".sha256", "x") as f:
                f.write(f"{hashlib.sha256(data).hexdigest()}  {name}\n")
            staged += 1
print(f"{staged} {bad}")
PY
)" || die "staging 2004Scape player saves failed"
  log "staged CRC-checked 2004Scape saves: ${out% *} (failed the check: ${out#* })"
}

# The game writes its world while running, so a raw file copy can be torn. Also
# stage a header-checked, hash-verified copy taken while the file was stable.
stage_extra() {
  stage_lostcity_db
  stage_2004scape_saves
  [[ "$world_exists" == true ]] || return 0
  [[ "${BACKUP_SAVE_SCRIPT:-}" == "$SCRIPT_DIR/backup-save.py" ]] \
    || die "Dragonwilds backup helper is not the installed root-owned bundle copy"
  [[ -n "${BACKUP_SAVE_SCRIPT:-}" ]] || die "root-owned Dragonwilds backup helper is not installed"
  [[ -x "$BACKUP_SAVE_SCRIPT" || -f "$BACKUP_SAVE_SCRIPT" ]] \
    || die "root-owned Dragonwilds backup helper is missing"
  [[ "${BACKUP_SAVE_SCRIPT_SHA256:-}" =~ ^[[:xdigit:]]{64}$ ]] \
    || die "Dragonwilds backup helper hash is not pinned in game-backup.service"
  local helper_hash
  if command -v sha256sum >/dev/null; then
    helper_hash="$(sha256sum "$BACKUP_SAVE_SCRIPT" | cut -d' ' -f1)"
  elif command -v shasum >/dev/null; then
    helper_hash="$(shasum -a 256 "$BACKUP_SAVE_SCRIPT" | cut -d' ' -f1)"
  else
    die "sha256sum or shasum is required to verify the Dragonwilds backup helper"
  fi
  [[ "$helper_hash" == "$BACKUP_SAVE_SCRIPT_SHA256" ]] \
    || die "Dragonwilds backup helper hash does not match game-backup.service"
  install -d -m 700 "$STAGING_DIR/dragonwilds"
  python3 "$BACKUP_SAVE_SCRIPT" \
    --install-dir "$install_dir" --output-dir "$STAGING_DIR/dragonwilds" >/dev/null
  log "staged verified Dragonwilds world copy"
}
