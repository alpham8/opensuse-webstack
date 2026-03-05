#!/bin/bash
set -euo pipefail

NFT=${NFT:-/usr/sbin/nft}

POSTFIX_V4=172.22.1.253
DOVECOT_V4=172.22.1.250
NGINX_V4=172.22.1.12

POSTFIX_V6=fd4d:6169:6c63:6f77::11
DOVECOT_V6=fd4d:6169:6c63:6f77::b
NGINX_V6=fd4d:6169:6c63:6f77::10

# --- IPv4 ---
$NFT list table ip mailcow_net >/dev/null 2>&1 || $NFT add table ip mailcow_net

if ! $NFT list chain ip mailcow_net prerouting >/dev/null 2>&1; then
  $NFT add chain ip mailcow_net prerouting { type nat hook prerouting priority -100\; policy accept\; }
fi

if ! $NFT list chain ip mailcow_net postrouting >/dev/null 2>&1; then
  $NFT add chain ip mailcow_net postrouting { type nat hook postrouting priority 100\; policy accept\; }
fi

$NFT flush chain ip mailcow_net prerouting
$NFT flush chain ip mailcow_net postrouting

# Direct DNAT (bypass docker-proxy) -> preserve real client IPs.
# Only for traffic from the internet.
$NFT add rule ip mailcow_net prerouting iifname "eno1" tcp dport 25 dnat to ${POSTFIX_V4}:25
$NFT add rule ip mailcow_net prerouting iifname "eno1" tcp dport 465 dnat to ${POSTFIX_V4}:465
$NFT add rule ip mailcow_net prerouting iifname "eno1" tcp dport 587 dnat to ${POSTFIX_V4}:587
$NFT add rule ip mailcow_net prerouting iifname "eno1" tcp dport 143 dnat to ${DOVECOT_V4}:143
$NFT add rule ip mailcow_net prerouting iifname "eno1" tcp dport 993 dnat to ${DOVECOT_V4}:993
$NFT add rule ip mailcow_net prerouting iifname "eno1" tcp dport 4190 dnat to ${DOVECOT_V4}:4190
$NFT add rule ip mailcow_net prerouting iifname "eno1" tcp dport 4443 dnat to ${NGINX_V4}:4443
$NFT add rule ip mailcow_net prerouting iifname "eno1" tcp dport 8080 dnat to ${NGINX_V4}:8080

# Container egress NAT (DNS, outgoing delivery) restricted to eno1 only.
$NFT add rule ip mailcow_net postrouting iifname "br-mailcow" oifname "eno1" masquerade

# --- IPv6 ---
$NFT list table ip6 mailcow_net6 >/dev/null 2>&1 || $NFT add table ip6 mailcow_net6

if ! $NFT list chain ip6 mailcow_net6 prerouting >/dev/null 2>&1; then
  $NFT add chain ip6 mailcow_net6 prerouting { type nat hook prerouting priority -100\; policy accept\; }
fi

$NFT flush chain ip6 mailcow_net6 prerouting

# Direct DNAT for v6 published listeners.
$NFT add rule ip6 mailcow_net6 prerouting iifname "eno1" tcp dport 25 dnat to [${POSTFIX_V6}]:25
$NFT add rule ip6 mailcow_net6 prerouting iifname "eno1" tcp dport 465 dnat to [${POSTFIX_V6}]:465
$NFT add rule ip6 mailcow_net6 prerouting iifname "eno1" tcp dport 587 dnat to [${POSTFIX_V6}]:587
$NFT add rule ip6 mailcow_net6 prerouting iifname "eno1" tcp dport 143 dnat to [${DOVECOT_V6}]:143
$NFT add rule ip6 mailcow_net6 prerouting iifname "eno1" tcp dport 993 dnat to [${DOVECOT_V6}]:993
$NFT add rule ip6 mailcow_net6 prerouting iifname "eno1" tcp dport 4190 dnat to [${DOVECOT_V6}]:4190
$NFT add rule ip6 mailcow_net6 prerouting iifname "eno1" tcp dport 4443 dnat to [${NGINX_V6}]:4443
$NFT add rule ip6 mailcow_net6 prerouting iifname "eno1" tcp dport 8080 dnat to [${NGINX_V6}]:8080
