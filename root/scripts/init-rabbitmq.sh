#!/usr/bin/env bash
set -euo pipefail

zypper in --no-recommends rabbitmq-server blog erlang erlang-epmd libblogger2 rabbitmq-server-plugins socat

LE_DOMAIN="example.com"
LE_LIVE_DIR="/etc/letsencrypt/live/${LE_DOMAIN}"
RABBIT_SSL_DIR="/etc/rabbitmq/ssl"

# RabbitMQ local only (very secure, no firewall rules needed)
systemctl enable rabbitmq-server
systemctl start rabbitmq-server
rabbitmq-plugins enable rabbitmq_management
install -d -m 0755 /etc/rabbitmq
install -d -m 0750 -o rabbitmq -g rabbitmq "${RABBIT_SSL_DIR}"

if [[ -f "${LE_LIVE_DIR}/fullchain.pem" && -f "${LE_LIVE_DIR}/privkey.pem" ]]; then
  echo "Copying certificates..."
  # --dereference follows symlinks (live/ contains symlinks)
  cp --dereference "${LE_LIVE_DIR}/fullchain.pem" "${RABBIT_SSL_DIR}/fullchain.pem"
  cp --dereference "${LE_LIVE_DIR}/privkey.pem"   "${RABBIT_SSL_DIR}/privkey.pem"
  chown rabbitmq:rabbitmq "${RABBIT_SSL_DIR}/fullchain.pem" "${RABBIT_SSL_DIR}/privkey.pem"
  chmod 0640 "${RABBIT_SSL_DIR}/fullchain.pem" "${RABBIT_SSL_DIR}/privkey.pem"
else
  echo "WARNING: Certificates not found under: ${LE_LIVE_DIR}"
  echo "    You can do it later, or adjust LE_DOMAIN/LE_LIVE_DIR."
fi

rabbitmqctl delete_user guest 2>/dev/null || true

DROPIN_DIR="/etc/systemd/system/rabbitmq-server.service.d"
DROPIN_FILE="${DROPIN_DIR}/override.conf"
mkdir -p "${DROPIN_DIR}"

# bind Erlang distribution (25672) strict to loopback + enforce IPv4-only
cat > "${DROPIN_FILE}" <<'EOF'
[Service]
Environment="RABBITMQ_DIST_PORT=25672"
Environment="RABBITMQ_SERVER_ADDITIONAL_ERL_ARGS=-proto_dist inet_tcp -kernel inet_dist_use_interface {127,0,0,1} inet_dist_listen_min 25672 inet_dist_listen_max 25672"
EOF

chmod 0644 "${DROPIN_FILE}"

echo "[*] Drop-in written: ${DROPIN_FILE}"

# 4) systemd reload + RabbitMQ restart
systemctl daemon-reload
systemctl restart rabbitmq-server

echo
echo "=== Verification ==="
echo "[*] systemd Environment:"
systemctl show rabbitmq-server -p Environment --no-pager || true

echo
echo "[*] Listening sockets (15672 mgmt, 25672 dist):"
ss -lntp | egrep '(:15672|:25672)\b' || true

echo
echo "[*] Done."

# use the "hammer-method" and block it via firewalld:
firewall-cmd --permanent --add-rich-rule='rule family=ipv6 port port=15672 protocol=tcp reject'
firewall-cmd --permanent --add-rich-rule='rule family=ipv6 port port=25672 protocol=tcp reject'
firewall-cmd --reload
