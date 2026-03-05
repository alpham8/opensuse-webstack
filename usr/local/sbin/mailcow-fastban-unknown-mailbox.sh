#!/usr/bin/env bash
set -euo pipefail

MAILCOW_DIR=${MAILCOW_DIR:-/root/mailcow-dockerized}
BAN_COOLDOWN_SECS=${BAN_COOLDOWN_SECS:-14400}
DOCKER_BIN=${DOCKER_BIN:-/usr/bin/docker}
LOG_SINCE=${LOG_SINCE:-10s}

log() {
  logger -t mailcow-fastban -- "$@"
  echo "mailcow-fastban: $*" >&2
}

require_file() {
  if [[ ! -f "$1" ]]; then
    log "missing required file: $1"
    exit 2
  fi
}

require_file "${MAILCOW_DIR}/mailcow.conf"
# shellcheck disable=SC1090
source "${MAILCOW_DIR}/mailcow.conf"

container_id() {
  local service="$1"
  $DOCKER_BIN ps -q --filter "label=com.docker.compose.service=${service}" | head -n 1
}

postfix_cid="$(container_id postfix-mailcow)"
dovecot_cid="$(container_id dovecot-mailcow)"
redis_cid="$(container_id redis-mailcow)"
mysql_cid="$(container_id mysql-mailcow)"

if [[ -z "${postfix_cid}" || -z "${dovecot_cid}" || -z "${redis_cid}" || -z "${mysql_cid}" ]]; then
  log "could not resolve one or more mailcow container IDs (postfix/dovecot/redis/mysql)"
  exit 2
fi

redis_cmd() {
  # redis-cli is available inside the redis container image
  $DOCKER_BIN exec "${redis_cid}" redis-cli -a "${REDISPASS}" "$@"
}

mysql_query_scalar() {
  local sql="$1"
  $DOCKER_BIN exec "${mysql_cid}" mysql -N -s -u"${DBUSER}" -p"${DBPASS}" "${DBNAME}" -e "${sql}" 2>/dev/null | head -n 1 || true
}

is_public_ip() {
  local ip="$1"
  python3 - "$ip" <<'PY'
import ipaddress, sys
ip = ipaddress.ip_address(sys.argv[1])
if (ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_multicast or ip.is_reserved):
  raise SystemExit(1)
raise SystemExit(0)
PY
}

is_safe_email() {
  local email="$1"
  [[ "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]
}

mailbox_exists() {
  local email_lc
  email_lc="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  if ! is_safe_email "$email_lc"; then
    echo "0"
    return
  fi
  local res
  res="$(mysql_query_scalar "SELECT 1 FROM mailbox WHERE username='${email_lc}' AND active='1' LIMIT 1;")"
  if [[ "$res" == "1" ]]; then
    echo "1"
  else
    echo "0"
  fi
}

get_max_attempts() {
  local opts max_attempts
  opts="$(redis_cmd GET F2B_OPTIONS 2>/dev/null || true)"
  if [[ -n "$opts" ]]; then
    max_attempts="$(
      python3 -c 'import json,sys; print(int(json.loads(sys.stdin.read()).get("max_attempts", 10)))' \
        <<<"$opts" 2>/dev/null || true
    )"
  fi
  if [[ -z "${max_attempts:-}" ]]; then
    max_attempts="$(redis_cmd GET F2B_MAX_ATTEMPTS 2>/dev/null || true)"
  fi
  if [[ -z "${max_attempts:-}" || ! "$max_attempts" =~ ^[0-9]+$ || "$max_attempts" -lt 1 ]]; then
    max_attempts=10
  fi
  echo "$max_attempts"
}

declare -A fastbanned_until=()

fastban_unknown_mailbox() {
  local ip="$1"
  local user="$2"

  if ! is_public_ip "$ip"; then
    return
  fi

  local now
  now="$(date +%s)"
  if [[ -n "${fastbanned_until[$ip]:-}" && "${fastbanned_until[$ip]}" -gt "$now" ]]; then
    return
  fi

  local max_attempts
  max_attempts="$(get_max_attempts)"

  local msg
  msg="warning: unknown[${ip}]: SASL LOGIN authentication failed: (fastban unknown mailbox), sasl_username=${user}"

  for ((i=0; i<max_attempts; i++)); do
    redis_cmd PUBLISH F2B_CHANNEL "$msg" >/dev/null || true
  done

  fastbanned_until["$ip"]=$((now + BAN_COOLDOWN_SECS))
  log "fastbanned (unknown mailbox) ip=${ip} user=${user} published=${max_attempts}"
}

handle_postfix_line() {
  local line="$1"
  [[ "$line" == *"SASL "* && "$line" == *"authentication failed"* && "$line" == *"sasl_username="* ]] || return 0

  local ip user
  if [[ "$line" =~ \[([0-9A-Fa-f:.]+)\] ]]; then
    ip="${BASH_REMATCH[1]}"
  else
    return 0
  fi

  if [[ "$line" =~ sasl_username=([^,\ \t]+) ]]; then
    user="${BASH_REMATCH[1]}"
  else
    return 0
  fi

  if [[ "$(mailbox_exists "$user")" == "0" ]]; then
    fastban_unknown_mailbox "$ip" "$user"
  fi
}

handle_dovecot_line() {
  local line="$1"
  [[ "$line" == *"auth failed"* && "$line" == *"user=<"* && "$line" == *"rip="* ]] || return 0

  local ip user
  if [[ "$line" =~ user=\<([^>]+)\> ]]; then
    user="${BASH_REMATCH[1]}"
  else
    return 0
  fi
  if [[ "$line" =~ rip=([0-9A-Fa-f:.]+) ]]; then
    ip="${BASH_REMATCH[1]}"
  else
    return 0
  fi

  if [[ "$(mailbox_exists "$user")" == "0" ]]; then
    fastban_unknown_mailbox "$ip" "$user"
  fi
}

log "starting (postfix_cid=${postfix_cid} dovecot_cid=${dovecot_cid})"

(
  $DOCKER_BIN logs -f --since "${LOG_SINCE}" "${postfix_cid}" 2>&1 | while IFS= read -r line; do
    handle_postfix_line "$line" || true
  done
) &

(
  $DOCKER_BIN logs -f --since "${LOG_SINCE}" "${dovecot_cid}" 2>&1 | while IFS= read -r line; do
    handle_dovecot_line "$line" || true
  done
) &

wait
