#!/usr/bin/env bash
set -euo pipefail

# Download the latest server backups to a local external drive.
# Requires SSH access configured in ~/.ssh/config (Host "myserver").

# Automatically determine the latest backup date from the server
date=$(ssh myserver "ls /root/backup/home-backup_*.tar.gz 2>/dev/null | sort | tail -1 | sed 's/.*home-backup_\(.*\)\.tar\.gz/\1/'")

if [[ -z "$date" ]]; then
    echo "No backup found on the server!"
    exit 1
fi

echo "Latest backup: $date"

dest="/path/to/external-drive/ServerBackup"

for prefix in home-backup nginx-backup repo-backup php8-backup vhosts-backup mysql-backup; do
    echo -e "\n--- ${prefix}_${date}.tar.gz ---"
    scp "myserver:/root/backup/${prefix}_${date}.tar.gz" "$dest/"
done

echo -e "\n--- nc-db-backup_${date}.sql.gz ---"
scp "myserver:/root/backup/nc-db-backup_${date}.sql.gz" "$dest/"

echo -e "\n--- Mailcow (rsync) ---"
rsync -av -zz --update --delete --stats myserver:/root/backup/mailcow/ "$dest/mailcow/"

echo -e "\nDone."
