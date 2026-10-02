# shellcheck shell=bash
# Sourced by server-base/backup/backup.sh (as root). Names this host's backup
# and lists its paths; the repository is the main server over SFTP (.env).
# shellcheck disable=SC2034
BACKUP_NAME=pi
BACKUP_LABEL=Pi
BACKUP_UNIT=pi-backup.service

CANDIDATES+=(
  "$HOST_DIR/adguard/conf"
  "$HOST_DIR/homepage/config"
  /etc/motioneye
  /etc/cups
)
