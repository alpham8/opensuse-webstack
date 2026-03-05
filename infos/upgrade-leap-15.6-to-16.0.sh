#!/usr/bin/env bash
# ==========================================================================
# In-Place Upgrade: openSUSE Leap 15.6 → 16.0
# Server: 203.0.113.1 (myserver, Hetzner Dedicated)
#
# Method: Manual zypper migration (based on opensuse-migration-tool)
#
# IMPORTANT: This script is intended as a reference and should NOT
# be executed blindly as a whole! Run each section individually
# and verify the result.
#
# Detailed information: infos/upgrade-156-160.md
#
# Risk: HIGH (remote server, network migration wicked→NM)
# Estimated downtime: 1-2 hours
# Prerequisite: Hetzner Rescue System as fallback!
#
# EXPERIENCE: The opensuse-migration-tool uses dialog (ncurses TUI)
# and is therefore NOT usable remotely via SSH. The steps in Phase 3
# perform the migration manually (identical to the tool, but scriptable).
# ==========================================================================

set -euo pipefail


# ==========================================================================
# PHASE 1: PREPARATION (before the upgrade)
# ==========================================================================

# --- 1.1 Fully update system to 15.6 ---
zypper refresh
zypper -n up

# --- 1.2 Document current state ---
# Save installed packages:
rpm -qa --qf '%{NAME}\n' | sort > /root/packages-before-upgrade.txt
# Save repo list:
zypper lr -d > /root/repos-before-upgrade.txt
# Save network configuration:
cp -a /etc/sysconfig/network /root/network-backup-156/
ip addr show > /root/ip-addr-before-upgrade.txt
ip route show > /root/ip-route-before-upgrade.txt
cat /etc/resolv.conf > /root/resolv-before-upgrade.txt
# Save service status:
systemctl list-units --type=service --state=running > /root/services-before-upgrade.txt

# --- 1.3 Create btrfs snapshot (rollback capability) ---
# NOTE: Snapper is not configured, so create manual snapshot.
# The snapshot enables rollback via the Rescue System.
btrfs subvolume snapshot / /@pre-upgrade
btrfs subvolume snapshot /srv /@srv-pre-upgrade
btrfs subvolume snapshot /home /@home-pre-upgrade
echo "btrfs snapshots created. Rollback instructions: see upgrade-156-160-infos.md"

# --- 1.4 Stop Docker containers ---
# Gracefully shut down all containers to avoid data loss.
# The systemd units stop docker compose gracefully.
systemctl stop compose-mailcow.service
systemctl stop compose-umami.service
systemctl stop compose-remark42.service
systemctl stop compose-endlessh.service
# Verify that no containers are still running:
docker ps --format "{{.Names}}" | head -5
# If containers are still running:
#   docker stop $(docker ps -q)

# --- 1.5 Stop non-essential services ---
# These services could cause conflicts during the upgrade.
systemctl stop fail2ban
systemctl stop crowdsec-firewall-bouncer
systemctl stop crowdsec
systemctl stop nginx
systemctl stop php-fpm
systemctl stop rabbitmq-server
systemctl stop alloy
systemctl stop clamd
# MariaDB and Postfix keep running (no conflicts expected).
# Do NOT stop sshd (remote access!)
# Do NOT stop Docker daemon (handled by the migration tool).

# --- 1.6 Disable third-party repos ---
# The opensuse-migration-tool also asks about this, but better to do it manually beforehand.
zypper mr --disable crowdsec_crowdsec
zypper mr --disable crowdsec_crowdsec-source
zypper mr --disable grafana
zypper mr --disable php  # already disabled


# ==========================================================================
# PHASE 2: NETWORK PREPARATION (CRITICAL!)
# ==========================================================================

# EXPERIENCE: wicked2nm is NOT available as a separate package in Leap 15.6.
# It is only provided by the opensuse-migration-tool, which is interactive.
# Instead: Install NetworkManager beforehand and create NM config manually.

# --- 2.1 Install NetworkManager beforehand ---
# CRITICAL: NetworkManager is NOT automatically installed during zypper dup!
# Without NM the server will be unreachable after reboot.
zypper -n in NetworkManager

# --- 2.2 Create NM connection file ---
# For Hetzner Point-to-Point (/32) configuration:
mkdir -p /etc/NetworkManager/system-connections
cat > /etc/NetworkManager/system-connections/enp0s31f6.nmconnection <<'EOF'
[connection]
id=enp0s31f6
type=ethernet
interface-name=enp0s31f6
autoconnect=true

[ethernet]

[ipv4]
method=manual
address1=203.0.113.1/32,203.0.113.129
dns=198.51.100.2;198.51.100.1;

[ipv6]
method=manual
address1=2001:db8::1/64
gateway=fe80::1
dns=2001:db8::53;

[proxy]
EOF
chmod 0600 /etc/NetworkManager/system-connections/enp0s31f6.nmconnection
echo "NM config created. Will be automatically loaded by NM after the upgrade."

# --- 2.3 Disable wicked, prepare NM ---
# Do NOT enable yet (wicked is still running), but prepare for after reboot:
systemctl disable wicked.service
systemctl enable NetworkManager.service
echo "wicked disabled, NetworkManager enabled — will become active after reboot."


# ==========================================================================
# PHASE 3: PERFORM UPGRADE (manual, since opensuse-migration-tool is interactive)
# ==========================================================================

# EXPERIENCE: opensuse-migration-tool uses dialog (ncurses TUI) and
# CANNOT be used via SSH without TTY. The following steps perform
# exactly the same actions manually.

# Best run in a tmux/screen session:
tmux new-session -s upgrade
# (If tmux is not installed: zypper in tmux)

# --- 3.1 Switch repo definitions to 16.0 ---
# openSUSE-repos-Leap contains the zypp service definitions.
# First install the package for 16.0:
zypper -n in --force-resolution openSUSE-repos
# If that's not enough: Add a temporary 16.0 repo:
zypper ar -f "https://download.opensuse.org/distribution/leap/16.0/repo/oss/" temp-160-oss
zypper -n in --from temp-160-oss openSUSE-repos-Leap
zypper rr temp-160-oss

# Update services:
zypper refresh-services

# Disable old Hetzner repo (15.6) (name may vary):
zypper mr --disable openSUSE-Leap-15.6-1 2>/dev/null || true

# --- 3.2 Verify repos point to 16.0 ---
zypper --releasever 16.0 refresh
# Expected: All repos should have 16.0 URLs (no more 15.6)
zypper --releasever 16.0 lr -u

# --- 3.3 Keep AppArmor (instead of SELinux) ---
# The opensuse-migration-tool would ask here. Ensure manually:
zypper -n in --force-resolution apparmor-profiles apparmor-utils
# Run keepapparmor script if opensuse-migration-tool is installed:
if [ -x /usr/share/opensuse-migration-tool/10_keepapparmor.sh ]; then
    /usr/share/opensuse-migration-tool/10_keepapparmor.sh
fi

# --- 3.4 Distribution Upgrade ---
# THE central command. 1000+ packages will be updated.
zypper --releasever 16.0 dup -y \
    --force-resolution \
    --allow-vendor-change \
    --download-in-advance
# CHECK OUTPUT CAREFULLY:
# - Error messages?
# - Are critical packages being removed? (sshd, kernel, NetworkManager)
# - Conflicts?

# --- 3.5 Adjust sshd_config NOW (BEFORE the reboot!) ---
# OpenSSH 10.x (in the just-installed packages) has breaking changes.
# THESE CHANGES MUST BE MADE BEFORE THE REBOOT!
# Details: see Phase 5 below.
# Short version:
if grep -q '^PrintLastLog' /etc/ssh/sshd_config; then
    sed -i 's/^PrintLastLog/#PrintLastLog/' /etc/ssh/sshd_config
fi
if ! grep -q 'PubkeyAcceptedAlgorithms' /etc/ssh/sshd_config; then
    echo "PubkeyAcceptedAlgorithms +ssh-rsa" >> /etc/ssh/sshd_config
fi
if grep -q '^MaxAuthTries [1-3]$' /etc/ssh/sshd_config; then
    sed -i 's/^MaxAuthTries [1-3]$/MaxAuthTries 6/' /etc/ssh/sshd_config
fi
sshd -t  # Check syntax!

# --- 3.6 Reboot ---
# WARNING: SSH connection will be lost!
# Make sure: Phase 2 (NetworkManager + NM config) has been executed!
# Make sure: sshd_config (3.5) has been executed!
reboot


# ==========================================================================
# PHASE 4: AFTER THE REBOOT — Initial verification
# ==========================================================================

# Re-establish SSH connection:
#   ssh -o IdentitiesOnly=yes -p 2424 root@203.0.113.1
# If SSH is unreachable: Use Hetzner Rescue System!
# (See upgrade-156-160-infos.md, section "Tips for Hetzner Rescue")

# --- 4.1 Verify OS version ---
cat /etc/os-release
# Expected: VERSION="16.0"
uname -r
# Expected: 6.12.x

# --- 4.2 Verify network ---
ip addr show enp0s31f6
ip route show
ping -c 3 1.1.1.1
ping6 -c 3 2606:4700:4700::1111
# If network is not working:
#   cp /root/nm-fallback-enp0s31f6.nmconnection /etc/NetworkManager/system-connections/
#   chmod 0600 /etc/NetworkManager/system-connections/nm-fallback-enp0s31f6.nmconnection
#   nmcli con reload
#   nmcli con up enp0s31f6

# --- 4.3 Verify DNS ---
dig example.com +short
nslookup google.com
cat /etc/resolv.conf

# --- 4.4 Check failed services ---
systemctl list-units --failed
# Expected: None (or only services not yet started)

# --- 4.5 Check RAID status ---
cat /proc/mdstat
# Expected: All arrays [UU]


# ==========================================================================
# PHASE 5: SSH CONFIGURATION — REFERENCE (already executed in Phase 3.5)
# ==========================================================================
# This section documents the required SSH changes in detail.
# The short version was already executed in Phase 3.5 BEFORE the reboot.
# If Phase 3.5 was skipped: DO IT NOW!
#
# OpenSSH 10.x in Leap 16.0 has breaking changes that can completely
# prevent SSH access.

# --- 5.1 Remove PrintLastLog ---
# OpenSSH 10.x no longer supports PrintLastLog. sshd starts but
# emits warnings. Comment it out:
if grep -q '^PrintLastLog' /etc/ssh/sshd_config; then
    sed -i 's/^PrintLastLog/#PrintLastLog/' /etc/ssh/sshd_config
    echo "PrintLastLog commented out"
fi

# --- 5.2 Enable ssh-rsa algorithm ---
# OpenSSH 10.x disables ssh-rsa (SHA-1 based) by default.
# If the SSH key is an RSA key (ssh-rsa in authorized_keys),
# this algorithm MUST be explicitly allowed:
if ! grep -q 'PubkeyAcceptedAlgorithms' /etc/ssh/sshd_config; then
    echo "" >> /etc/ssh/sshd_config
    echo "# OpenSSH 10.x: ssh-rsa (SHA-1) is disabled by default." >> /etc/ssh/sshd_config
    echo "# For older RSA keys it must be explicitly allowed:" >> /etc/ssh/sshd_config
    echo "PubkeyAcceptedAlgorithms +ssh-rsa" >> /etc/ssh/sshd_config
    echo "PubkeyAcceptedAlgorithms +ssh-rsa added"
fi
# LONG-TERM: Replace RSA key with Ed25519 and remove this line!
#   ssh-keygen -t ed25519 -C "root@server"

# --- 5.3 Increase MaxAuthTries ---
# If the SSH agent offers multiple keys, MaxAuthTries 3 can be
# too low. The correct key comes after the "wrong" ones.
# Alternative: Use -o IdentitiesOnly=yes on the client side.
if grep -q '^MaxAuthTries [1-3]$' /etc/ssh/sshd_config; then
    sed -i 's/^MaxAuthTries [1-3]$/MaxAuthTries 6/' /etc/ssh/sshd_config
    echo "MaxAuthTries increased to 6"
fi

# --- 5.4 Remove duplicate entries ---
# If PrintMotd or X11Forwarding appear twice:
# (check manually and clean up if necessary)

# Test sshd config (detect syntax errors):
sshd -t
# If errors: fix /etc/ssh/sshd_config!

systemctl restart sshd
# Test SSH connection (new session, keep old one open!):
#   ssh -o IdentitiesOnly=yes -p 2424 root@203.0.113.1


# ==========================================================================
# PHASE 6: SET UP THIRD-PARTY REPOS FOR 16.0
# ==========================================================================

# --- 6.1 CrowdSec repo ---
# The packagecloud repo is not tied to the OS version,
# but should still be verified:
zypper mr --enable crowdsec_crowdsec
zypper mr --enable crowdsec_crowdsec-source
zypper refresh crowdsec_crowdsec
# If errors: Remove repo and set up again:
#   curl -s https://install.crowdsec.net | bash

# --- 6.2 Grafana repo ---
# The Grafana repo is version-independent (rpm.grafana.com):
zypper mr --enable grafana
zypper refresh grafana

# --- 6.3 Fully update system to 16.0 ---
zypper refresh
zypper -n up


# ==========================================================================
# PHASE 7: ADJUST AND START SERVICES
# ==========================================================================

# --- 7.1 Postfix: Uncomment tlsmgr ---
# In Leap 16.0, tlsmgr is commented out by default.
# Without tlsmgr, no TLS → Mailcow rejects ("530 Must issue STARTTLS").
if grep -q '^#tlsmgr' /etc/postfix/master.cf; then
    sed -i 's/^#tlsmgr    unix/tlsmgr    unix/' /etc/postfix/master.cf
    echo "Postfix tlsmgr uncommented"
fi
systemctl restart postfix

# --- 7.2 nginx: Adjust http2 directive ---
# nginx 1.27 deprecated "listen ... http2".
# Check and adjust all vhost configs:
#   Old:  listen 443 ssl http2;
#   New:  listen 443 ssl;
#         http2 on;
#
# Remove http2_push_preload (obsolete):
#   grep -rn 'http2_push_preload\|listen.*http2' /etc/nginx/vhosts.d/
#
# IMPORTANT: The configs in the repo (etc/nginx/) are already adjusted for 1.27.
# If the repo configs were overwritten during the upgrade, redeploy:
#   cp etc/nginx/vhosts.d/*.conf /etc/nginx/vhosts.d/
#   cp etc/nginx/nginx.conf /etc/nginx/nginx.conf
nginx -t
systemctl start nginx

# --- 7.3 PHP-FPM + rebuild pecl extensions ---
# PHP goes from 8.2 to 8.4. The old .so files are incompatible!
# Install build dependencies (in case they were removed during the upgrade):
zypper -n in php8-devel php8-pear librabbitmq-devel ImageMagick-devel gcc make autoconf

# Remove old pecl extensions and rebuild:
pecl install -f redis
# pecl install -f imagick  # only if imagick is needed

# EXPERIENCE: `pecl install -f amqp` fails on Leap 16.0!
# The bundled config.sub is outdated and doesn't recognize the build type.
# Error: "config.sub: too many arguments"
# Workaround: Manual build with updated config.sub:
cd /tmp && rm -rf amqp-build && mkdir amqp-build && cd amqp-build
pecl download amqp
tar xzf amqp-*.tgz && cd amqp-*/
phpize
cp /usr/share/automake-*/config.sub build/config.sub
cp /usr/share/automake-*/config.guess build/config.guess
./configure --with-librabbitmq-dir=/usr
make -j$(nproc)
make install
cd / && rm -rf /tmp/amqp-build

# Check ini files (should still be present):
ls /etc/php8/conf.d/{redis,amqp,imagick}.ini
# If not:
#   echo "extension=redis.so"   > /etc/php8/conf.d/redis.ini
#   echo "extension=amqp.so"    > /etc/php8/conf.d/amqp.ini
#   echo "extension=imagick.so" > /etc/php8/conf.d/imagick.ini

php-fpm -t
systemctl start php-fpm

# --- 7.4 MariaDB: mysql_upgrade ---
# MariaDB 10.x → 11.8: Schema upgrade required.
systemctl start mariadb
mysql_upgrade
# If grants are lost (known issue with major upgrades):
# Check grants manually:
#   mysql -e "SELECT user, host FROM mysql.user;"
# If needed: Recreate grants (see Protokoll.md, MariaDB grants section)

# --- 7.5 RabbitMQ: NODENAME + /etc/hosts + Mnesia ---
# In Leap 16.0, epmd only listens on 127.0.0.1.
# NODENAME=rabbit@localhost must be in rabbitmq-env.conf.
#
# EXPERIENCE: The SUSE default file contains '#NODENAME=rabbit@localhost'
# (commented out). A simple grep -q would match that!
# Therefore: specifically uncomment instead of blind append.
sed -i 's/^#NODENAME=rabbit@localhost$/NODENAME=rabbit@localhost/' /etc/rabbitmq/rabbitmq-env.conf
grep -q '^NODENAME=rabbit@localhost' /etc/rabbitmq/rabbitmq-env.conf || \
    echo 'NODENAME=rabbit@localhost' >> /etc/rabbitmq/rabbitmq-env.conf
echo "RabbitMQ NODENAME=rabbit@localhost set"

# Ensure short hostname in /etc/hosts (epmd resolution):
# Without the short hostname, `getent hosts example` may resolve via DNS
# to the NEW server IP instead of localhost → epmd timeout.
# ADJUST: Adapt hostname and IP to your server!
if ! grep -qE '203\.0\.113\.1.*example[^.]' /etc/hosts; then
    sed -i 's/203.0.113.1 example.com/203.0.113.1 example.com example/' /etc/hosts
    echo "/etc/hosts: Short hostname example added"
fi

# EXPERIENCE: After upgrading RabbitMQ 3.x (Erlang/OTP 26) to 4.x
# (Erlang/OTP 27), startup fails with:
#   {disabled_required_feature_flag, classic_mirrored_queue_version}
# The old Mnesia DB is incompatible. If no queues/users are needed:
# Delete Mnesia and start fresh.
if [ -d /var/lib/rabbitmq/mnesia ] && \
   ls /var/lib/rabbitmq/mnesia/ | grep -q 'rabbit@'; then
    echo "WARNING: Old Mnesia data found. If RabbitMQ does not start:"
    echo "  systemctl stop rabbitmq-server"
    echo "  rm -rf /var/lib/rabbitmq/mnesia/*"
    echo "  systemctl start rabbitmq-server"
fi
systemctl start rabbitmq-server

# --- 7.6 CrowdSec + fail2ban ---
systemctl start crowdsec
systemctl start crowdsec-firewall-bouncer
systemctl start fail2ban
# Check fail2ban jails (1.1.0 requires <HOST> in all failregex):
fail2ban-client status
# If jails don't start → check filter regex:
#   fail2ban-client -d 2>&1 | grep -i error

# --- 7.7 ClamAV ---
systemctl start clamd

# --- 7.8 Rebuild certbot venv ---
# Python 3.11 → 3.13: Old venv is incompatible.
# EXPERIENCE: If the venv is not rebuilt, the cron job shows:
#   /usr/local/bin/certbot: cannot execute: required file not found
# Cause: Shebang points to python3.11, which no longer exists in Leap 16.0.
rm -rf /opt/certbot/venv
python3 -m venv /opt/certbot/venv
/opt/certbot/venv/bin/pip install --upgrade pip
/opt/certbot/venv/bin/pip install certbot certbot-dns-inwx
ln -sf /opt/certbot/venv/bin/certbot /usr/local/bin/certbot
# Test:
certbot --version
certbot renew --dry-run

# --- 7.9 Alloy (Monitoring) ---
systemctl start alloy

# --- 7.10 Audit ---
systemctl start auditd


# ==========================================================================
# PHASE 8: DOCKER + FIREWALL FIXES
# ==========================================================================

# --- 8.1 Docker zone: Disable broad masquerade + enable targeted Mailcow NAT ---
# EXPERIENCE: Broad masquerade on Docker/firewalld can hide real client IPs (everything looks like 172.22.1.1).
# We use a targeted nftables rule for Mailcow egress only: iif br-mailcow -> oif eno1 masquerade.
# Copy from repo first:
#   etc/systemd/system/nftables-mailcow-net.service -> /etc/systemd/system/nftables-mailcow-net.service
#   usr/local/sbin/nft-mailcow-net.sh               -> /usr/local/sbin/nft-mailcow-net.sh
firewall-cmd --permanent --zone=docker --remove-masquerade || true
firewall-cmd --reload
chmod 0750 /usr/local/sbin/nft-mailcow-net.sh
systemctl daemon-reload
systemctl enable --now nftables-mailcow-net.service

# --- 8.2 Systemd drop-ins: Fix boot race condition ---
# EXPERIENCE: Three problems during boot after the upgrade:
#
# a) Docker starts BEFORE firewalld → nftables chains are missing → Docker start fails.
#    Fix: Docker waits until firewalld is ready.
#   etc/systemd/system/docker.service.d/override.conf -> /etc/systemd/system/docker.service.d/
mkdir -p /etc/systemd/system/docker.service.d
# Contents: ExecStartPre=/bin/sh -c "until /usr/bin/firewall-cmd --state >/dev/null 2>&1; do sleep 1; done"
#
# b) firewall-cmd --reload destroys Docker's dynamic NAT rules.
#    Fix: Restart Docker after firewalld start AND reload.
#   etc/systemd/system/firewalld.service.d/restart-docker.conf -> /etc/systemd/system/firewalld.service.d/
mkdir -p /etc/systemd/system/firewalld.service.d
# Contents: ExecStartPost + ExecReload= (clear) + ExecReload HUP + ExecReload restart docker
#
# c) CrowdSec with Requires=docker.service goes down when Docker's first
#    start attempt fails. Wants= tolerates transient Docker failures.
#   etc/systemd/system/crowdsec.service.d/override.conf -> /etc/systemd/system/crowdsec.service.d/
mkdir -p /etc/systemd/system/crowdsec.service.d
# Contents: After=docker.service + Wants=docker.service

systemctl daemon-reload

# Docker daemon should already be running after reboot:
systemctl status docker

# --- 8.3 Start Docker containers ---
# Start containers (order matters):
systemctl start compose-endlessh.service
systemctl start compose-mailcow.service
# Wait until Mailcow network is up (Remark42 needs it for SMTP):
sleep 15
systemctl start compose-remark42.service
systemctl start compose-umami.service

# Check all containers:
docker ps --format "table {{.Names}}\t{{.Status}}"
# Expected: 22 containers, all UP


# ==========================================================================
# PHASE 9: POST-UPGRADE TASKS
# ==========================================================================

# --- 9.1 Logrotate: Remove duplicate entries ---
# EXPERIENCE: If /etc/logrotate.d/ was carried over from the old server,
# custom configs (e.g., mariadb-slow, nginx-access) can conflict with
# RPM wildcard configs. logrotate-all then breaks COMPLETELY!
# RPM configs cover everything via wildcards:
#   /usr/etc/logrotate.d/mariadb  → /var/log/mysql/*.log
#   /usr/etc/logrotate.d/nginx    → /var/log/nginx/*.log
for f in /etc/logrotate.d/mariadb-slow /etc/logrotate.d/nginx-access; do
    [ -f "$f" ] && rm -v "$f" && echo "Duplicate logrotate config removed: $f"
done
# Test logrotate (must not throw errors):
logrotate -d /etc/logrotate.conf 2>&1 | grep -i "error\|duplicate" || echo "Logrotate OK"

# --- 9.2 sshd: Disable PrintMotd ---
# EXPERIENCE: motd is displayed twice if both PrintMotd yes (sshd)
# and pam_motd.so (PAM) are active. pam_motd.so handles the display.
if grep -q '^PrintMotd yes\|^#PrintMotd yes' /etc/ssh/sshd_config; then
    sed -i 's/^#\?PrintMotd yes/PrintMotd no/' /etc/ssh/sshd_config
    systemctl reload sshd
    echo "PrintMotd set to no"
fi

# --- 9.3 Server prompt and login security info ---
# Deploy from the repo:
#   etc/profile.d/99-prompt.sh        -> /etc/profile.d/
#   etc/profile.d/99-security-info.sh -> /etc/profile.d/

# --- 9.4 Nextcloud cron: Increase memory limit ---
# EXPERIENCE: PHP CLI uses the default memory_limit=128M from /etc/php8/cli/php.ini.
# The FPM pools have their own limits (e.g., 1024M), but the cron runs via CLI.
# Fix: Append -d memory_limit=1024M to the cron command.
# Crontab entry (root):
#   */5 *  *  *  *  sudo -u nginx /usr/bin/php -d memory_limit=1024M -f /srv/www/vhosts/example.com/sync.example.com/cron.php


# ==========================================================================
# PHASE 10: VERIFICATION
# ==========================================================================

echo "=== OS Version ==="
cat /etc/os-release | grep PRETTY_NAME

echo ""
echo "=== Kernel ==="
uname -r

echo ""
echo "=== Failed Services ==="
systemctl list-units --failed

echo ""
echo "=== Running Services ==="
for svc in nginx php-fpm mariadb postfix docker crowdsec crowdsec-firewall-bouncer \
           fail2ban alloy clamd auditd rabbitmq-server sshd; do
    status=$(systemctl is-active "$svc" 2>/dev/null || echo "inactive")
    printf "  %-35s %s\n" "$svc" "$status"
done

echo ""
echo "=== Docker Containers ==="
docker ps --format "table {{.Names}}\t{{.Status}}" | head -25

echo ""
echo "=== RAID ==="
cat /proc/mdstat | grep -E 'md[0-9]|blocks'

echo ""
echo "=== Network ==="
ip -4 addr show enp0s31f6 | grep inet
ip -6 addr show enp0s31f6 | grep inet6 | grep -v fe80

echo ""
echo "=== Firewall ==="
firewall-cmd --state

echo ""
echo "=== AppArmor ==="
aa-status 2>/dev/null | head -3

echo ""
echo "=== Web Endpoints (after DNS propagation) ==="
curl -sI -o /dev/null -w "%{http_code} %{url}" https://example.com 2>/dev/null && echo "" || echo " ERROR"
curl -sI -o /dev/null -w "%{http_code} %{url}" https://sync.example.com 2>/dev/null && echo "" || echo " ERROR"
curl -sI -o /dev/null -w "%{http_code} %{url}" https://umami.example.com 2>/dev/null && echo "" || echo " ERROR"

echo ""
echo "=== Mail Ports ==="
timeout 5 bash -c 'echo QUIT | nc -w3 localhost 25' 2>/dev/null | head -1 || echo "SMTP not reachable"

echo ""
echo "=== Timers ==="
systemctl list-timers --no-pager | grep -E 'zypper|rkhunter|dmarc'


# ==========================================================================
# PHASE 11: CLEANUP
# ==========================================================================

# --- 11.1 Remove old packages ---
# After a successful upgrade, orphaned packages can be removed:
zypper packages --orphaned
# Check individually and remove if appropriate:
#   zypper rm <PACKAGENAME>

# --- 11.2 btrfs snapshots (after stable operation) ---
# When everything runs stable (after 1-2 weeks), delete old snapshots:
#   btrfs subvolume delete /@pre-upgrade
#   btrfs subvolume delete /@srv-pre-upgrade
#   btrfs subvolume delete /@home-pre-upgrade

# --- 11.3 Clean package cache ---
zypper clean --all

# --- 11.4 Update rkhunter database ---
rkhunter --update
rkhunter --propupd

echo ""
echo "=========================================="
echo "  Upgrade completed!"
echo "  Please thoroughly test all services."
echo "=========================================="
