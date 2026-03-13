#!/usr/bin/env bash
# ==========================================================================
# Secure Erase: Delete sensitive data on the OLD server (OLD_SERVER_IP)
#
# WARNING: This script IRREVERSIBLY deletes all sensitive data!
#          Only run when the new server (NEW_SERVER_IP) is fully
#          verified and running stable.
#
# Usage:
#   DRY-RUN (default):  ./secure-erase-old-server.sh
#   ACTUALLY DELETE:     ./secure-erase-old-server.sh --execute
#
# Prerequisite: Run as root on the OLD server (OLD_SERVER_IP).
# ==========================================================================
set -euo pipefail

# --- Configuration ---
SHRED_PASSES=3          # Number of overwrite passes (DoD 5220.22-M: 3)
SHRED_CMD="shred -vzn ${SHRED_PASSES}"
DRY_RUN=true
LOG_FILE="/var/log/secure-erase-$(date +%Y%m%d_%H%M%S).log"
ERRORS=0

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# --- Parse arguments ---
if [[ "${1:-}" == "--execute" ]]; then
    DRY_RUN=false
fi

# --- Helper functions ---

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo -e "$msg"
    if [[ "$DRY_RUN" == false ]]; then
        echo "$msg" >> "$LOG_FILE"
    fi
}

warn() {
    log "${YELLOW}WARNING: $1${NC}"
}

ok() {
    log "${GREEN}OK: $1${NC}"
}

err() {
    log "${RED}ERROR: $1${NC}"
    ((ERRORS++)) || true
}

# Securely delete a single file
shred_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        if [[ "$DRY_RUN" == true ]]; then
            log "  [DRY-RUN] shred: $file"
        else
            if $SHRED_CMD "$file" 2>/dev/null; then
                rm -f "$file"
                ok "shred + rm: $file"
            else
                err "shred failed: $file"
            fi
        fi
    else
        log "  (not found, skipped: $file)"
    fi
}

# Securely delete a directory (shred all files, then rm -rf)
shred_dir() {
    local dir="$1"
    if [[ -d "$dir" ]]; then
        if [[ "$DRY_RUN" == true ]]; then
            local count
            count=$(find "$dir" -type f 2>/dev/null | wc -l)
            log "  [DRY-RUN] shred dir: $dir ($count files)"
        else
            find "$dir" -type f -exec $SHRED_CMD {} \; 2>/dev/null || true
            rm -rf "$dir"
            ok "shred + rm -rf: $dir"
        fi
    else
        log "  (not found, skipped: $dir)"
    fi
}

# Simple delete a file (for non-sensitive configs)
remove_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        if [[ "$DRY_RUN" == true ]]; then
            log "  [DRY-RUN] rm: $file"
        else
            rm -f "$file"
            ok "rm: $file"
        fi
    fi
}

# Simple delete a directory
remove_dir() {
    local dir="$1"
    if [[ -d "$dir" ]]; then
        if [[ "$DRY_RUN" == true ]]; then
            log "  [DRY-RUN] rm -rf: $dir"
        else
            rm -rf "$dir"
            ok "rm -rf: $dir"
        fi
    fi
}


# ==========================================================================
# Safety checks
# ==========================================================================

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Error: Must be run as root." >&2
    exit 1
fi

# Ensure we are on the OLD server
CURRENT_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
if [[ "$CURRENT_IP" == "NEW_SERVER_IP" ]]; then
    echo -e "${RED}ABORT: This script must NOT run on the NEW server!${NC}" >&2
    exit 1
fi

if [[ "$DRY_RUN" == true ]]; then
    echo ""
    echo -e "${YELLOW}======================================${NC}"
    echo -e "${YELLOW}  DRY-RUN MODE (no changes)          ${NC}"
    echo -e "${YELLOW}======================================${NC}"
    echo ""
    echo "To actually delete: $0 --execute"
    echo ""
else
    echo ""
    echo -e "${RED}==============================================${NC}"
    echo -e "${RED}  WARNING: DATA WILL BE IRREVERSIBLY         ${NC}"
    echo -e "${RED}           DELETED!                           ${NC}"
    echo -e "${RED}==============================================${NC}"
    echo ""
    echo "Server: $(hostname) ($CURRENT_IP)"
    echo "Logfile: $LOG_FILE"
    echo ""
    read -rp "Are you sure? Type 'YES DELETE' to continue: " confirm
    if [[ "$confirm" != "YES DELETE" ]]; then
        echo "Aborted."
        exit 0
    fi
    echo ""
    log "=== Secure Erase started on $(hostname) ($CURRENT_IP) ==="
fi


# ==========================================================================
# Phase 1: Stop services
# ==========================================================================

log "--- Phase 1: Stop services ---"

SERVICES=(
    compose-mailcow
    compose-umami
    compose-remark42
    compose-endlessh
    nginx
    php-fpm
    mariadb
    rabbitmq-server
    postfix
    crowdsec
    crowdsec-firewall-bouncer
    fail2ban
    alloy
    clamd
)

for svc in "${SERVICES[@]}"; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        if [[ "$DRY_RUN" == true ]]; then
            log "  [DRY-RUN] systemctl stop $svc"
        else
            systemctl stop "$svc" 2>/dev/null || warn "Stop failed: $svc"
            ok "stopped: $svc"
        fi
    else
        log "  (not active: $svc)"
    fi
done

# Stop Docker explicitly (after compose services)
if systemctl is-active --quiet docker 2>/dev/null; then
    if [[ "$DRY_RUN" == true ]]; then
        log "  [DRY-RUN] systemctl stop docker"
    else
        systemctl stop docker
        ok "stopped: docker"
    fi
fi


# ==========================================================================
# Phase 2: Drop databases (before MariaDB stop, if still running)
# ==========================================================================

log "--- Phase 2: MariaDB databases ---"

# Prompt for MySQL root password (mysql client requires password)
MYSQL_ROOT_PW=""
read -rsp "Enter MySQL root password: " MYSQL_ROOT_PW
echo ""

if [[ "$MYSQL_ROOT_PW" == "" ]]; then
    err "No MySQL password entered, skipping Phase 2."
fi

# Start MariaDB if not running (needed for this step)
if ! systemctl is-active --quiet mariadb 2>/dev/null; then
    if [[ "$DRY_RUN" == false ]]; then
        systemctl start mariadb 2>/dev/null || true
        sleep 2
    fi
fi

APP_DATABASES=(
    app1_db
    app2_db
    app3_db
    app4_db
    app4_db_test
    bugtracker_db
    groupware_db
    app5_db
    nextcloud_db
    app6_db
    shop1_db
    shop2_db
)

if [[ "$MYSQL_ROOT_PW" != "" ]]; then
    for db in "${APP_DATABASES[@]}"; do
        if [[ "$DRY_RUN" == true ]]; then
            log "  [DRY-RUN] DROP DATABASE IF EXISTS $db"
        else
            mysql -u root -p"${MYSQL_ROOT_PW}" -e "DROP DATABASE IF EXISTS \`${db}\`;" 2>/dev/null \
                && ok "DB dropped: $db" \
                || err "DB drop failed: $db"
        fi
    done

    # Drop all application users
    DB_USERS=(
        "shop1_user"
        "app6_user"
        "app1_user"
        "app5_user"
        "nc_user"
        "bugtracker_user"
        "groupware_user"
        "app3_user"
        "app4_user"
        "app2_user"
    )

    for user in "${DB_USERS[@]}"; do
        if [[ "$DRY_RUN" == true ]]; then
            log "  [DRY-RUN] DROP USER IF EXISTS '${user}'@'localhost'"
        else
            mysql -u root -p"${MYSQL_ROOT_PW}" -e "DROP USER IF EXISTS '${user}'@'localhost';" 2>/dev/null \
                && ok "DB user dropped: $user" \
                || err "User drop failed: $user"
        fi
    done

    if [[ "$DRY_RUN" == false ]]; then
        mysql -u root -p"${MYSQL_ROOT_PW}" -e "FLUSH PRIVILEGES;" 2>/dev/null || true
        systemctl stop mariadb 2>/dev/null || true
    fi
else
    log "  (skipped: no MySQL password)"
fi


# ==========================================================================
# Phase 3: SSH keys and migration keys
# ==========================================================================

log "--- Phase 3: SSH keys ---"

shred_file "/root/.ssh/migration_key"
shred_file "/root/.ssh/migration_key.pub"
# Additional private keys in .ssh directory
find /root/.ssh/ -name "id_*" -not -name "*.pub" 2>/dev/null | while read -r keyfile; do
    shred_file "$keyfile"
done
# authorized_keys (contains public keys, not highly sensitive, but clean up)
shred_file "/root/.ssh/authorized_keys"
shred_file "/root/.ssh/config"
shred_file "/root/.ssh/known_hosts"


# ==========================================================================
# Phase 4: Database credentials
# ==========================================================================

log "--- Phase 4: Database credentials ---"

shred_file "/root/.my.cnf"
shred_file "/root/mariadb_user.sql"


# ==========================================================================
# Phase 5: SSL/TLS certificates and private keys
# ==========================================================================

log "--- Phase 5: SSL/TLS ---"

# Let's Encrypt (private keys + DNS plugin credentials)
shred_file "/etc/letsencrypt/dns-plugin.cfg"
# Private keys in all archive versions
find /etc/letsencrypt/ -name "privkey*.pem" 2>/dev/null | while read -r keyfile; do
    shred_file "$keyfile"
done
# Remove entire letsencrypt directory afterwards
remove_dir "/etc/letsencrypt"

# RabbitMQ SSL
shred_file "/etc/rabbitmq/ssl/privkey.pem"
shred_file "/etc/rabbitmq/ssl/fullchain.pem"
remove_dir "/etc/rabbitmq/ssl"


# ==========================================================================
# Phase 6: Mailcow (config + Docker volumes)
# ==========================================================================

log "--- Phase 6: Mailcow ---"

# mailcow.conf (contains DBPASS, DBROOT, REDISPASS, etc.)
shred_file "/root/mailcow-dockerized/mailcow.conf"

# Mailcow SSL copies
shred_file "/root/mailcow-dockerized/data/assets/ssl/key.pem"
shred_file "/root/mailcow-dockerized/data/assets/ssl/cert.pem"

# Docker volumes (contain mail data, encryption keys, DKIM)
MAILCOW_VOLUMES=(
    mailcowdockerized_crypt-vol-1
    mailcowdockerized_mysql-vol-1
    mailcowdockerized_redis-vol-1
    mailcowdockerized_vmail-vol-1
    mailcowdockerized_vmail-index-vol-1
    mailcowdockerized_postfix-vol-1
    mailcowdockerized_postfix-tlspol-vol-1
    mailcowdockerized_rspamd-vol-1
    mailcowdockerized_clamd-db-vol-1
    mailcowdockerized_sogo-userdata-backup-vol-1
    mailcowdockerized_sogo-web-vol-1
    mailcowdockerized_mysql-socket-vol-1
)

for vol in "${MAILCOW_VOLUMES[@]}"; do
    local_path="/var/lib/docker/volumes/${vol}/_data"
    if [[ -d "$local_path" ]]; then
        if [[ "$DRY_RUN" == true ]]; then
            declare -i count
            count=$(find "$local_path" -type f 2>/dev/null | wc -l)
            log "  [DRY-RUN] shred volume: $vol ($count files)"
        else
            # Crypt volume extra thorough (mail encryption keys!)
            if [[ "$vol" == *"crypt-vol"* ]]; then
                find "$local_path" -type f -exec shred -vzn 7 {} \; 2>/dev/null || true
            else
                find "$local_path" -type f -exec $SHRED_CMD {} \; 2>/dev/null || true
            fi
            rm -rf "$local_path"
            ok "Volume shredded: $vol"
        fi
    else
        log "  (Volume not found: $vol)"
    fi
done

# Remaining mailcow directory
remove_dir "/root/mailcow-dockerized"


# ==========================================================================
# Phase 7: Postfix SASL (SMTP relay password)
# ==========================================================================

log "--- Phase 7: Postfix ---"

shred_file "/etc/postfix/sasl_passwd"
shred_file "/etc/postfix/sasl_passwd.lmdb"
shred_file "/etc/postfix/sasl_passwd.db"


# ==========================================================================
# Phase 8: Application credentials
# ==========================================================================

log "--- Phase 8: Application credentials ---"

# Custom application
shred_file "/etc/myapp/environment"

# Grafana Alloy (Grafana Cloud API tokens)
shred_file "/etc/alloy/config.alloy"

# CrowdSec (LAPI credentials, bouncer keys)
shred_file "/etc/crowdsec/local_api_credentials.yaml"
shred_file "/etc/crowdsec/online_api_credentials.yaml"
shred_dir "/etc/crowdsec/bouncers"

# RabbitMQ
shred_file "/etc/rabbitmq/rabbitmq.conf"
shred_file "/etc/rabbitmq/advanced.conf"
shred_file "/etc/rabbitmq/definitions.json"

# Umami
shred_file "/opt/umami/.env"

# Remark42
shred_file "/opt/remark42/.env"


# ==========================================================================
# Phase 9: Web data with application secrets
# ==========================================================================

log "--- Phase 9: Web data ---"

# Nextcloud config (contains DB password, secret, salt)
shred_file "/srv/www/vhosts/example.com/sync.example.com/config/config.php"

# Shopware / other app configs with credentials
find /srv/www/ -name ".env" -o -name ".env.local" -o -name "config.php" \
    -o -name "parameters.yml" -o -name "env.php" 2>/dev/null | while read -r cfgfile; do
    # Only files that actually contain passwords
    if grep -qiE 'password|secret|api_key|token|dbpass' "$cfgfile" 2>/dev/null; then
        shred_file "$cfgfile"
    fi
done

# Delete entire web directory (161 GB, not shredding — too large)
if [[ -d "/srv/www/" ]]; then
    if [[ "$DRY_RUN" == true ]]; then
        size=$(du -sh /srv/www/ 2>/dev/null | cut -f1)
        log "  [DRY-RUN] rm -rf /srv/www/ ($size)"
    else
        rm -rf /srv/www/
        ok "rm -rf: /srv/www/"
    fi
fi


# ==========================================================================
# Phase 10: Scripts with credentials
# ==========================================================================

log "--- Phase 10: Scripts ---"

# Backup scripts (contain storage box credentials)
shred_file "/root/scripts/backup-all.php"
shred_file "/root/scripts/backup-all.sh"
shred_file "/root/scripts/mailcow-backup.sh"

# DMARC parser (IMAP password)
shred_file "/root/scripts/dmarc/parse-reports.php"

# RabbitMQ init (user passwords)
shred_file "/root/scripts/init-rabbitmq.sh"
shred_file "/root/scripts/rabbitmq-add-user.sh"

# cert-post-renew (paths, no secrets, but clean up)
remove_file "/root/cert-post-renew.sh"

# Remaining scripts directory
remove_dir "/root/scripts"


# ==========================================================================
# Phase 11: Docker leftovers (other services)
# ==========================================================================

log "--- Phase 11: Docker leftovers ---"

# Umami Docker volume (PostgreSQL with analytics data)
UMAMI_VOL="/var/lib/docker/volumes/umami_umami-db-data/_data"
if [[ -d "$UMAMI_VOL" ]]; then
    shred_dir "$UMAMI_VOL"
fi

# Remark42 Docker volume (comments + user tokens)
REMARK_VOL="/var/lib/docker/volumes/remark42_remark42-data/_data"
if [[ -d "$REMARK_VOL" ]]; then
    shred_dir "$REMARK_VOL"
fi

# Docker compose files
remove_dir "/root/endlessh-go"
remove_dir "/opt/umami"
remove_dir "/opt/remark42"

# Clean up Docker completely (all volumes, images, containers)
if command -v docker &>/dev/null; then
    if [[ "$DRY_RUN" == true ]]; then
        log "  [DRY-RUN] docker system prune -a --volumes"
    else
        docker system prune -af --volumes 2>/dev/null || true
        ok "Docker fully cleaned"
    fi
fi


# ==========================================================================
# Phase 12: Bash history, logs, temp files
# ==========================================================================

log "--- Phase 12: History and logs ---"

# Bash history (may contain passwords from CLI input)
shred_file "/root/.bash_history"
shred_file "/root/.mysql_history"

# MariaDB data directory (database files on disk)
shred_dir "/var/lib/mysql"

# RabbitMQ Mnesia database (user hashes, queue data)
shred_dir "/var/lib/rabbitmq"

# Temp files from the migration
remove_file "/tmp/all-databases.sql"
remove_file "/tmp/all-databases-final.sql"
remove_file "/tmp/all-grants.sql"
remove_file "/tmp/dbs_old.txt"
remove_file "/tmp/dbs_new.txt"
remove_file "/tmp/le_old.txt"
remove_file "/tmp/le_new.txt"

# Log files that may contain credentials
remove_dir "/var/log/mysql"
remove_dir "/var/log/dmarc"
# Clean systemd journal (contains service logs with potential leaks)
if [[ "$DRY_RUN" == true ]]; then
    log "  [DRY-RUN] journalctl --vacuum-time=0"
else
    journalctl --vacuum-time=1s 2>/dev/null || true
    ok "Systemd journal cleaned"
fi


# ==========================================================================
# Summary
# ==========================================================================

echo ""
echo "=========================================="
if [[ "$DRY_RUN" == true ]]; then
    echo -e "${YELLOW}DRY-RUN completed.${NC}"
    echo "No files were changed."
    echo ""
    echo "To actually delete: $0 --execute"
else
    if [[ "$ERRORS" -gt 0 ]]; then
        echo -e "${RED}Secure Erase completed with $ERRORS errors.${NC}"
    else
        echo -e "${GREEN}Secure Erase completed successfully.${NC}"
    fi
    echo "Log: $LOG_FILE"
    echo ""
    echo "Next steps:"
    echo "  1. Boot server into Hetzner Robot rescue system"
    echo "  2. If 'Device or resource busy' on wipefs/blkdiscard:"
    echo "       umount -l /dev/nvme0n1p* /dev/nvme1n1p*"
    echo "       swapoff -a"
    echo "       vgchange -an        # If LVM is active"
    echo "       mdadm --stop --scan # If MD-RAID is active"
    echo "  3. Wipe partition tables:"
    echo "       wipefs -af /dev/nvme0n1 /dev/nvme1n1"
    echo "  4. Erase data at disk level (one of these options):"
    echo "       blkdiscard /dev/nvme0n1 && blkdiscard /dev/nvme1n1  # NVMe TRIM, seconds"
    echo "       dd if=/dev/zero of=/dev/nvme0n1 bs=1M status=progress  # If no TRIM, hours"
    echo "  5. Cancel server at Hetzner"
fi
echo "=========================================="
echo ""

exit "$ERRORS"