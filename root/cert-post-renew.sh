#!/usr/bin/env bash
set -Eeuo pipefail

# --- Configuration ---
MAILCOW_DIR="/root/mailcow-dockerized"
MAILCOW_SSL_DIR="${MAILCOW_DIR}/data/assets/ssl"
LOCKFILE="/run/lock/cert-deploy-mailcow.lock"

EXPECTED_LINEAGE="/etc/letsencrypt/live/example.com"

# --- Helper ---
log() { echo "[$(date -Is)] $*"; }

cleanup() {
  # Runs on exit/error
  :
}
trap cleanup EXIT

# --- Lock to prevent parallel runs ---
exec 9>"$LOCKFILE"
flock -n 9 || { log "Lock active, exiting."; exit 0; }

# --- Certbot info (set by deploy-hook) ---
# RENEWED_LINEAGE is the directory containing fullchain.pem/privkey.pem
# RENEWED_DOMAINS contains the domains of the renewed certificate
RENEWED_LINEAGE="${RENEWED_LINEAGE:-}"
RENEWED_DOMAINS="${RENEWED_DOMAINS:-}"

if [[ -z "$RENEWED_LINEAGE" ]]; then
  log "RENEWED_LINEAGE is empty – this script is intended for deploy-hook."
  log "Please use certbot renew with --deploy-hook."
  exit 1
fi

# Optionally restrict to a specific certificate:
if [[ -n "$EXPECTED_LINEAGE" && "$RENEWED_LINEAGE" != "$EXPECTED_LINEAGE" ]]; then
  log "Different certificate renewed ($RENEWED_LINEAGE), not $EXPECTED_LINEAGE – skipping Mailcow update."
  # Reload host nginx anyway if you have multiple vhosts:
  /usr/bin/systemctl reload nginx || true
  exit 0
fi

log "Certificate renewed: $RENEWED_LINEAGE"
log "Domains: ${RENEWED_DOMAINS:-<unknown>}"

# --- Verify files ---
FULLCHAIN="${RENEWED_LINEAGE}/fullchain.pem"
PRIVKEY="${RENEWED_LINEAGE}/privkey.pem"

[[ -r "$FULLCHAIN" ]] || { log "Missing/no read permission: $FULLCHAIN"; exit 1; }
[[ -r "$PRIVKEY"   ]] || { log "Missing/no read permission: $PRIVKEY"; exit 1; }

mkdir -p "$MAILCOW_SSL_DIR"

# --- Atomic deploy into Mailcow SSL directory ---
tmp_cert="$(mktemp "${MAILCOW_SSL_DIR}/cert.pem.XXXXXX")"
tmp_key="$(mktemp  "${MAILCOW_SSL_DIR}/key.pem.XXXXXX")"

install -m 0644 "$FULLCHAIN" "$tmp_cert"
install -m 0600 "$PRIVKEY"   "$tmp_key"

# Set ownership (if desired)
chown root:root "$tmp_cert" "$tmp_key"

# Atomic swap
mv -f "$tmp_cert" "${MAILCOW_SSL_DIR}/cert.pem"
mv -f "$tmp_key"  "${MAILCOW_SSL_DIR}/key.pem"

log "Mailcow certificates updated in: $MAILCOW_SSL_DIR"

# --- Reload/restart services ---
# Host nginx reload (quick, no drop)
/usr/bin/systemctl reload nginx

# Mailcow: targeted restart of relevant containers
docker compose -f "${MAILCOW_DIR}/docker-compose.yml" restart nginx-mailcow dovecot-mailcow postfix-mailcow > /dev/null

# Update RabbitMQ certificate (dereference symlinks!)
/usr/bin/install -d -m 0750 -o rabbitmq -g rabbitmq /etc/rabbitmq/ssl
/usr/bin/cp --dereference /etc/letsencrypt/live/example.com/fullchain.pem /etc/rabbitmq/ssl/fullchain.pem
/usr/bin/cp --dereference /etc/letsencrypt/live/example.com/privkey.pem   /etc/rabbitmq/ssl/privkey.pem
/usr/bin/chown rabbitmq:rabbitmq /etc/rabbitmq/ssl/fullchain.pem /etc/rabbitmq/ssl/privkey.pem
/usr/bin/chmod 0640 /etc/rabbitmq/ssl/fullchain.pem /etc/rabbitmq/ssl/privkey.pem
/usr/bin/systemctl restart rabbitmq-server

log "Done."
