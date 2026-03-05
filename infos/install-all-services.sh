#!/usr/bin/env bash
# ==========================================================================
# Server fresh install: openSUSE Leap 16.0 on Hetzner Dedicated
# All commands in logical order for a fresh system.
# ==========================================================================

# ==========================================================================
# 1. REPOS + SYSTEM PACKAGES
# ==========================================================================

zypper --gpg-auto-import-keys refresh

# Base packages + services
zypper -n in -y --no-recommends \
  git vim jq \
  net-tools-deprecated \
  docker \
  nginx nginx-module-brotli \
  mariadb mariadb-client mariadb-errormessages \
  certbot \
  fail2ban rkhunter clamav lynis \
  cyrus-sasl cyrus-sasl-plain \
  python311 python311-pip

# PHP 8 (from repo-sle-update for redis/imagick)
zypper in -y --from repo-sle-update \
  php8 php8-APCu php8-bcmath php8-cli php8-ctype php8-curl php8-dom \
  php8-exif php8-fastcgi php8-fileinfo php8-fpm php8-gd php8-gmp \
  php8-iconv php8-intl php8-mbstring php8-mysql php8-opcache php8-openssl \
  php8-pcntl php8-pdo php8-phar php8-posix php8-readline php8-soap \
  php8-sodium php8-sqlite php8-sysvsem php8-tokenizer \
  php8-xmlreader php8-xmlwriter php8-zip php8-zlib \
  php8-redis php8-imagick

# pecl extension: AMQP (for RabbitMQ)
zypper in -y php8-devel php8-pear librabbitmq-devel gcc make
pecl install amqp
# NOTE: On PHP minor/major version change (e.g. 8.1 -> 8.2) recompile:
#   pecl install amqp && systemctl restart php-fpm


# ==========================================================================
# 2. NFTABLES + FIREWALLD
# ==========================================================================

# Set nftables as iptables backend
update-alternatives --install /usr/sbin/iptables iptables /usr/sbin/xtables-nft-multi 20
update-alternatives --set iptables /usr/sbin/xtables-nft-multi

# Copy firewalld config from repo:
#   etc/firewalld/firewalld.conf -> /etc/firewalld/firewalld.conf
# Contains: FirewallBackend=nftables, FlushAllOnReload=yes, LogDenied=unicast

systemctl enable --now firewalld

# Firewall rules: services + ports
firewall-cmd --permanent --set-target=DROP --zone=public
firewall-cmd --permanent --add-service={http,https,ssh,imap,imaps,smtp}
firewall-cmd --permanent --add-port=2424/tcp     # SSH (actual port)
firewall-cmd --permanent --add-port=465/tcp      # SMTPS (Mailcow)
firewall-cmd --permanent --add-port=587/tcp      # Submission (Mailcow)
firewall-cmd --permanent --add-port=4190/tcp     # ManageSieve (Mailcow/Dovecot)
firewall-cmd --permanent --add-port=4443/tcp     # Mailcow Web-UI (HTTPS)
firewall-cmd --permanent --add-port=8080/tcp     # Mailcow Web-UI (HTTP)
firewall-cmd --permanent --add-port=9987/udp     # TeamSpeak Voice
firewall-cmd --permanent --add-port=30033/tcp    # TeamSpeak Filetransfer
firewall-cmd --permanent --add-port=10022/tcp    # TeamSpeak ServerQuery
firewall-cmd --permanent --add-port=25565/tcp    # Minecraft
firewall-cmd --permanent --add-port=25565/udp    # Minecraft
# Custom service for Nextcloud App Calls:
#   etc/firewalld/nextcloud-app-call.xml -> /etc/firewalld/services/
firewall-cmd --reload


# ==========================================================================
# 3. CONFIGURE SYSTEM SERVICES
# ==========================================================================

# Local Postfix as satellite relay (loopback only, relayed to Mailcow)
# Copy configs from repo:
#   etc/postfix/main.cf            -> /etc/postfix/main.cf
#   etc/postfix/master.cf          -> /etc/postfix/master.cf
#   etc/postfix/sasl_passwd        -> /etc/postfix/sasl_passwd
#   etc/postfix/sender_canonical   -> /etc/postfix/sender_canonical
#   etc/aliases                    -> /etc/aliases
postmap lmdb:/etc/postfix/sasl_passwd
chmod 0600 /etc/postfix/sasl_passwd /etc/postfix/sasl_passwd.lmdb
newaliases
systemctl enable --now postfix

# Docker
usermod -a -G docker root
# Copy /etc/docker/daemon.json from repo (log-level: warn, json-file with rotation, SELinux)
systemctl enable --now docker
# Docker zone: enable forwarding.
# Mailcow egress NAT is handled by nftables-mailcow-net.service (targeted: iif br-mailcow -> oif eno1),
# so real client IPs are preserved for incoming SMTP/IMAP.
# Docker manages the zone assignment of its bridge interfaces itself.
firewall-cmd --permanent --zone=docker --add-forward
firewall-cmd --permanent --zone=docker --remove-masquerade || true
firewall-cmd --reload

# Docker restart drop-in: restart Docker after firewalld restart,
# so Docker re-creates its network rules (port mappings, NAT).
#   etc/systemd/system/firewalld.service.d/restart-docker.conf -> /etc/systemd/system/firewalld.service.d/
systemctl daemon-reload

# nftables: Mailcow DNAT + restricted egress NAT (preserve real client IPs)
# Copy from repo:
#   etc/systemd/system/nftables-mailcow-net.service -> /etc/systemd/system/nftables-mailcow-net.service
#   usr/local/sbin/nft-mailcow-net.sh               -> /usr/local/sbin/nft-mailcow-net.sh
chmod 0750 /usr/local/sbin/nft-mailcow-net.sh
systemctl daemon-reload
systemctl enable --now nftables-mailcow-net.service

# MariaDB
systemctl enable --now mariadb
# .my.cnf for root (update password!):
cat > /root/.my.cnf <<'EOF'
[mysqldump]
host="localhost"
port="3306"
user="root"
password="changeme"
EOF
chmod 0600 /root/.my.cnf

# Enable MariaDB slow query log
mkdir -p /var/log/mysql && chown mysql:mysql /var/log/mysql
sed -i 's/^# slow_query_log=1/slow_query_log=1/' /etc/my.cnf
sed -i 's/^# slow_query_log_file = \/var\/log\/mysql\/mysqld_slow.log/slow_query_log_file = \/var\/log\/mysql\/mysqld_slow.log/' /etc/my.cnf

# Logrotate for slow query log: not needed!
# The mariadb RPM package ships /etc/logrotate.d/mariadb,
# which covers /var/log/mysql/*.log via wildcard.

# Redis runs inside Mailcow (Docker) — no system-level Redis needed.
# php8-redis extension connects via the Docker network.

# nginx
mkdir -p /var/lib/nginx/fcgi_tmp
install -d -m 0750 /var/lib/nginx/fcgi_tmp
chown -R nginx:nginx /var/lib/nginx/fcgi_tmp
mkdir -p /var/log/php
chown nginx:nginx /var/log/php/

# nginx systemd override (restart on failure)
mkdir -p /etc/systemd/system/nginx.service.d
cat > /etc/systemd/system/nginx.service.d/override.conf <<'EOF'
[Service]
Restart=on-failure
RestartSec=20s
StartLimitIntervalSec=0
EOF

# nginx logrotate: not needed!
# The nginx RPM package ships /etc/logrotate.d/nginx,
# which covers /var/log/nginx/*.log via wildcard.

systemctl enable --now nginx

# PHP-FPM — copy configs from repo, then start
# php-fpm.conf:     user/group = nginx
# php-fpm.d/www.conf: same
systemctl enable --now php-fpm

# ClamAV
freshclam
systemctl enable --now clamd

# rkhunter
rkhunter --update
rkhunter --propupd


# ==========================================================================
# 4. CERTBOT + INWX DNS PLUGIN (Python 3.11 venv)
# ==========================================================================

python3.11 -m venv /opt/certbot/venv
/opt/certbot/venv/bin/pip install certbot certbot-dns-inwx
ln -sf /opt/certbot/venv/bin/certbot /usr/local/bin/certbot

# Create credentials file (fill in your credentials!):
cat > /etc/letsencrypt/inwx.cfg <<'EOF'
dns_inwx_url           = https://api.domrobot.com/xmlrpc/
dns_inwx_username      = changeme
dns_inwx_password      = changeme
dns_inwx_shared_secret = your_shared_secret optional
EOF
chmod 0600 /etc/letsencrypt/inwx.cfg

# Create wildcard certificate (all domains in one cert):
/usr/local/bin/certbot certonly -a dns-inwx --expand \
  --cert-name "example.com" \
  -d "example.com" -d "*.example.com" \
  -d "myproject.example.net"     -d "*.myproject.example.net" \
  -d "another-app.example.org"    -d "*.another-app.example.org"

# Copy deploy hook script from repo:
#   root/cert-post-renew.sh -> /root/cert-post-renew.sh
chmod +x /root/cert-post-renew.sh

# Remove zypper certbot (only use the venv version):
zypper remove -y certbot


# ==========================================================================
# 5. MAILCOW (Docker Compose)
# ==========================================================================

mkdir -p /root/mailcow-dockerized
# Restore backup (from local machine):
#   rsync -aHhP --numeric-ids --delete /home/thomas/mailcow-backup/ mailcow:/root/mailcow-dockerized/

cd /root/mailcow-dockerized
docker compose pull

# Systemd service for Mailcow (clean start/stop on server boot/shutdown)
#   etc/systemd/system/compose-mailcow.service -> /etc/systemd/system/
systemctl daemon-reload
systemctl enable compose-mailcow
# Start containers and mark service as "active":
systemctl start compose-mailcow

# Postfix master.cf override (rate limit on 465/587) for Mailcow:
#   root/mailcow-dockerized/data/conf/postfix/master.cf -> /root/mailcow-dockerized/data/conf/postfix/master.cf

# Provide certificates for Mailcow:
cp /etc/letsencrypt/live/example.com/fullchain.pem /root/mailcow-dockerized/data/assets/ssl/cert.pem
cp /etc/letsencrypt/live/example.com/privkey.pem /root/mailcow-dockerized/data/assets/ssl/key.pem
docker compose restart nginx-mailcow dovecot-mailcow postfix-mailcow


# ==========================================================================
# 6. SECURITY: endlessh-go + CrowdSec + rkhunter timer
# ==========================================================================

# --- endlessh-go (SSH tarpit on port 22) ---
# Docker Compose from repo: root/endlessh-go/docker-compose.yml -> /root/endlessh-go/
# Systemd service for endlessh-go:
#   etc/systemd/system/compose-endlessh.service -> /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now compose-endlessh

# --- CrowdSec + nftables bouncer ---
curl -s https://install.crowdsec.net | bash
zypper install -y crowdsec crowdsec-firewall-bouncer-nftables

# Change LAPI port (default 8080 conflicts with Mailcow nginx):
sed -i 's|listen_uri: 127.0.0.1:8080|listen_uri: 127.0.0.1:8083|' /etc/crowdsec/config.yaml
sed -i 's|http://127.0.0.1:8080|http://127.0.0.1:8083|' /etc/crowdsec/local_api_credentials.yaml
sed -i 's|http://127.0.0.1:8080/|http://127.0.0.1:8083/|' /etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml

# Copy acquisition configs from repo:
#   etc/crowdsec/acquis.d/*.yaml -> /etc/crowdsec/acquis.d/
# Copy whitelist from repo:
#   etc/crowdsec/parsers/s02-enrich/custom-whitelist.yaml -> /etc/crowdsec/parsers/s02-enrich/

# Install collections:
cscli collections install \
  crowdsecurity/linux \
  crowdsecurity/nginx \
  crowdsecurity/sshd \
  crowdsecurity/postfix \
  crowdsecurity/dovecot \
  crowdsecurity/http-cve \
  crowdsecurity/iptables

# Register with community console:
# Get enrollment key from https://app.crowdsec.net, then:
cscli console enroll changeme

systemctl enable --now crowdsec
systemctl enable --now crowdsec-firewall-bouncer

# NOTE: firewalld and fail2ban must be started separately
# (fail2ban takes longer and causes conflicts during parallel restart).
# This will resolve itself with full CrowdSec migration.

# --- rkhunter systemd timer ---
# Copy service + timer from repo:
#   etc/systemd/system/rkhunter-check.service -> /etc/systemd/system/
#   etc/systemd/system/rkhunter-check.timer   -> /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now rkhunter-check.timer


# ==========================================================================
# 7. GRAFANA CLOUD + ALLOY (Monitoring)
# ==========================================================================

# Set up Grafana RPM repository
rpm --import https://rpm.grafana.com/gpg.key
cat > /etc/zypp/repos.d/grafana.repo <<'REPOEOF'
[grafana]
name=Grafana
baseurl=https://rpm.grafana.com
repo_gpgcheck=1
enabled=1
gpgcheck=1
gpgkey=https://rpm.grafana.com/gpg.key
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt
REPOEOF

zypper --gpg-auto-import-keys refresh
zypper install -y alloy

# Copy Alloy config from repo (credentials are filled in there):
#   etc/alloy/config.alloy -> /etc/alloy/config.alloy
usermod -a -G nginx alloy

# Ensure data directory is owned by alloy
# (prevents "permission denied" for positions.yml after manual test as root)
chown -R alloy:alloy /var/lib/alloy/data/

systemctl enable --now alloy

# NOTE: After any change to /etc/alloy/config.alloy:
#   systemctl reload alloy


# ==========================================================================
# 8. UMAMI WEB ANALYTICS
# ==========================================================================

# Copy files from repo:
#   opt/umami/docker-compose.yml -> /opt/umami/docker-compose.yml
#   opt/umami/.env               -> /opt/umami/.env

# Generate a secure DB password and fill it in .env:
openssl rand -base64 24

# Systemd service for Umami:
#   etc/systemd/system/compose-umami.service -> /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now compose-umami

# Copy nginx vHost from repo:
#   etc/nginx/vhosts.d/umami.example.com.conf -> /etc/nginx/vhosts.d/
nginx -t && systemctl reload nginx
# Default login: admin / umami — change password IMMEDIATELY!


# ==========================================================================
# 9. REMARK42 (Blog comment system, Docker Compose)
# ==========================================================================

# Copy files from repo:
#   opt/remark42/docker-compose.yml -> /opt/remark42/docker-compose.yml
#   opt/remark42/.env               -> /opt/remark42/.env

# Generate secret and fill it in .env:
openssl rand -hex 32

# Systemd service for Remark42 (depends on compose-mailcow for SMTP):
#   etc/systemd/system/compose-remark42.service -> /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now compose-remark42

# Copy nginx vHost from repo:
#   etc/nginx/vhosts.d/comments.example.com.conf -> /etc/nginx/vhosts.d/
nginx -t && systemctl reload nginx


# ==========================================================================
# 10. DMARC REPORT PARSER
# ==========================================================================

# Composer (PHP Dependency Manager)
php -r "copy('https://getcomposer.org/installer', '/tmp/composer-setup.php');"
php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
rm /tmp/composer-setup.php

# Install Composer dependencies (webklex/php-imap — pure PHP, no extensions needed)
mkdir -p /root/scripts/dmarc
# Copy files from repo:
#   root/scripts/dmarc/composer.json     -> /root/scripts/dmarc/composer.json
#   root/scripts/dmarc/parse-reports.php -> /root/scripts/dmarc/parse-reports.php
cd /root/scripts/dmarc && composer install --no-dev

# Fill in IMAP password in parse-reports.php!
# vim /root/scripts/dmarc/parse-reports.php  (IMAP_PASS constant)

# Create log directory
install -d -m 0750 /var/log/dmarc

# Copy systemd timer + service from repo:
#   etc/systemd/system/dmarc-report-parser.service -> /etc/systemd/system/
#   etc/systemd/system/dmarc-report-parser.timer   -> /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now dmarc-report-parser.timer


# ==========================================================================
# 11. SYSTEM TUNING
# ==========================================================================

# Set editor to vim (systemctl edit, crontab -e, etc.)
cat > /etc/profile.d/99-editor-vim.sh <<'EOF'
export SYSTEMD_EDITOR=vim
export EDITOR=vim
export VISUAL=vim
EOF
chmod 0644 /etc/profile.d/99-editor-vim.sh

# Server prompt (hostname, directory, time, red # for root, exit code on failure)
#   etc/profile.d/99-prompt.sh -> /etc/profile.d/99-prompt.sh
chmod 0644 /etc/profile.d/99-prompt.sh

# Security info at login (failed SSH logins, active bans)
#   etc/profile.d/99-security-info.sh -> /etc/profile.d/99-security-info.sh
chmod 0644 /etc/profile.d/99-security-info.sh

# Kernel hardening + log noise reduction + network security
cat > /etc/sysctl.d/90-custom.conf <<'EOF'
# Reduce log noise (only warning and above on console)
kernel.printk = 4 4 1 7

# Suppress Docker bridge log messages
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1

# --- Network hardening ---
# IP Spoofing Protection
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Reject ICMP redirects (MitM protection)
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# Disable source routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0

# SYN Flood Protection
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_synack_retries = 2

# Prevent smurf attacks
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Ignore bogus ICMP responses
net.ipv4.icmp_ignore_bogus_error_responses = 1

# IP forwarding (required for Docker)
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

# --- Kernel hardening ---
# ASLR (Address Space Layout Randomization) maximum
kernel.randomize_va_space = 2

# Restrict core dumps
fs.suid_dumpable = 0

# Hide kernel pointers from unprivileged users
kernel.kptr_restrict = 2

# dmesg restricted to root only
kernel.dmesg_restrict = 1

# Disable unprivileged BPF
kernel.unprivileged_bpf_disabled = 1

# Restrict perf_event for unprivileged users
kernel.perf_event_paranoid = 3

# Symlink/Hardlink Protection
fs.protected_symlinks = 1
fs.protected_hardlinks = 1

# --- Performance tuning (TCP) ---
net.core.somaxconn = 4096
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.core.netdev_max_backlog = 5000

# Log martian packets (Lynis KRNL-6000)
net.ipv4.conf.default.log_martians = 1
net.ipv4.conf.all.log_martians = 1
EOF
sysctl --system

# --- Disable unused kernel protocols (Lynis NETW-3200) ---
#   etc/modprobe.d/disable-unused-protocols.conf -> /etc/modprobe.d/disable-unused-protocols.conf

# --- SSH hardening (Lynis SSH-7408) ---
# Copy sshd_config from repo:
#   etc/ssh/sshd_config -> /etc/ssh/sshd_config
# Hardened settings (at the end of the file):
#   Port 2424
#   PermitRootLogin without-password
#   PasswordAuthentication no
#   MaxAuthTries 3
#   MaxSessions 2
#   ClientAliveInterval 300
#   ClientAliveCountMax 2
#   AllowTcpForwarding yes  (for SSH tunnels, e.g. RabbitMQ Management)
#   X11Forwarding no
#   AllowAgentForwarding no
#   LogLevel VERBOSE

# --- Automatic security updates ---
zypper install -y unattended-upgrades || true
# openSUSE Leap: automatic zypper patches via systemd timer
cat > /etc/systemd/system/zypper-patch.service <<'EOF'
[Unit]
Description=Apply zypper security patches
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/zypper --non-interactive patch --category security
EOF

cat > /etc/systemd/system/zypper-patch.timer <<'EOF'
[Unit]
Description=Daily zypper security patches

[Timer]
OnCalendar=*-*-* 05:00:00
RandomizedDelaySec=1800
Persistent=true

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now zypper-patch.timer

# --- Filesystem hardening: mount /tmp with noexec ---
# NOTE: Only run this if /tmp is a separate partition.
# If not, tmpfs can be used:
#   echo "tmpfs /tmp tmpfs defaults,noexec,nosuid,nodev,size=2G 0 0" >> /etc/fstab
#   mount -o remount /tmp

# --- Audit logging ---
zypper install -y audit
systemctl enable --now auditd

# --- PHP-FPM pools: separate pool per app ---
# Copy pool configs from repo:
#   etc/php8/fpm/php-fpm.d/example.conf          -> /etc/php8/fpm/php-fpm.d/
#   etc/php8/fpm/php-fpm.d/myproject.conf         -> /etc/php8/fpm/php-fpm.d/
#   etc/php8/fpm/php-fpm.d/another-app.conf       -> /etc/php8/fpm/php-fpm.d/
#   etc/php8/fpm/php-fpm.d/nextcloud.conf         -> /etc/php8/fpm/php-fpm.d/
systemctl restart php-fpm

# NOTE: After system updates (zypper up) always run:
#   rkhunter --propupd


# ==========================================================================
# 12. CRONTAB (crontab -e)
# ==========================================================================
# 0  3  *  *  *  /usr/local/bin/certbot renew --quiet --deploy-hook "/root/cert-post-renew.sh"
# */5 *  *  *  *  sudo -u nginx /usr/bin/php -d memory_limit=1024M -f /srv/www/vhosts/example.com/sync.example.com/cron.php
# 0  4  *  *  *  /usr/bin/php /root/scripts/backup-all.php
