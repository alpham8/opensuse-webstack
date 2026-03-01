#!/usr/bin/env bash
set -euo pipefail

echo "=== RabbitMQ: Add user/vHost ==="

read -r -p "Username: " RB_USER
if [[ -z "${RB_USER}" ]]; then
  echo "Error: Username must not be empty."
  exit 1
fi

# Default vHost: /<username>
read -r -p "vHost (Enter = /${RB_USER}): " RB_VHOST
RB_VHOST="${RB_VHOST:-/${RB_USER}}"

# Enter password (hidden) + optional confirmation
read -r -s -p "Password: " RB_PASS
echo
if [[ -z "${RB_PASS}" ]]; then
  echo "Error: Password must not be empty."
  exit 1
fi

read -r -s -p "Password (repeat): " RB_PASS2
echo
if [[ "${RB_PASS}" != "${RB_PASS2}" ]]; then
  echo "Error: Passwords do not match."
  exit 1
fi

echo "---"
echo "Creating/updating:"
echo "  User : ${RB_USER}"
echo "  vHost: ${RB_VHOST}"
echo "---"

# Create vHost (idempotent)
rabbitmqctl add_vhost "${RB_VHOST}" >/dev/null 2>&1 || true

# Create user; if exists, update password
if rabbitmqctl list_users | awk '{print $1}' | grep -qx "${RB_USER}"; then
  rabbitmqctl change_password "${RB_USER}" "${RB_PASS}"
else
  rabbitmqctl add_user "${RB_USER}" "${RB_PASS}"
fi

# Set permissions (full access on vHost)
rabbitmqctl set_permissions -p "${RB_VHOST}" "${RB_USER}" ".*" ".*" ".*"

echo "Done."
echo "Note: Management UI only via SSH tunnel:"
echo "  ssh -i ~/.ssh/root_key -N -L 8080:127.0.0.1:15672 root@203.0.113.1"
