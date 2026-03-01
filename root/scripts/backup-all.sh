#!/usr/bin/env bash
set -euo pipefail

# path: /root/scripts/backup-all.sh

umask 077
mkdir -p /root/backup

# Optional: prevent parallel runs
exec 200>/var/lock/backup-all.lock
flock -n 200 || { echo "Backup already running — aborting."; exit 1; }

# === Settings ===
export MAILCOW_BACKUP_LOCATION="/root/backup/mailcow"  # important: export for the sub-script
STORAGEBOX_USER="uXXXXXX"
STORAGEBOX_HOST="uXXXXXX.your-storagebox.de"
STORAGEBOX_PORT=23
STORAGEBOX_DIR="/home/backup"

DATE="$(date -I)"

# Helper for tar (always with -C and relative paths)
tarc() { # tarc <archive> <src_dir> [paths...]
  local archive="$1"; shift
  local srcdir="$1"; shift
  tar -C "$srcdir" -czf "$archive" "$@"
}

# --- Delete old static backups ---
find /root/backup -maxdepth 1 -type f -name "*-backup_*.tar.gz" -delete

# --- Static backups ---
tarc "/root/backup/home-backup_${DATE}.tar.gz"      "/" "home"
tarc "/root/backup/nginx-backup_${DATE}.tar.gz"     "/" "etc/nginx"
tarc "/root/backup/repo-backup_${DATE}.tar.gz"      "/" "srv/repo"
tarc "/root/backup/php8-backup_${DATE}.tar.gz"      "/" "etc/php8"

# --- Mailcow backup ---
/root/scripts/mailcow-backup.sh

# --- Put Nextcloud in maintenance mode, then backup vhosts + MySQL ---
# Make sure to disable maintenance mode on exit
cleanup_occ() {
  sudo -u nginx /usr/bin/php /srv/www/vhosts/example.com/sync.example.com/occ maintenance:mode --off || true
}
trap cleanup_occ EXIT

sudo -u nginx /usr/bin/php /srv/www/vhosts/example.com/sync.example.com/occ maintenance:mode --on

tarc "/root/backup/vhosts-backup_${DATE}.tar.gz" "/" "srv/www/vhosts"

mysqldump --tz-utc --all-databases --single-transaction --routines --triggers --events --hex-blob -r "/root/backup/mysql-backup_${DATE}.sql"

tar cfz /root/backup/mysql-backup_"$DATE".tar.gz /root/backup/mysql-backup_"$DATE".sql
rm /root/backup/mysql-backup_"$DATE".sql

# Safely disable maintenance mode (also handled by trap)
sudo -u nginx /usr/bin/php /srv/www/vhosts/example.com/sync.example.com/occ maintenance:mode --off
trap - EXIT

# --- Rsync to Storage Box ---
/usr/bin/rsync -az --delete -e "ssh -p ${STORAGEBOX_PORT}" "/root/backup/" "${STORAGEBOX_USER}@${STORAGEBOX_HOST}:${STORAGEBOX_DIR}/"

echo -e "done\n"
