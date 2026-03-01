#!/usr/bin/env bash

# Kernel hardening + log noise + network security
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

# dmesg only for root
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
EOF
sysctl --system

# --- SSH hardening ---
# /etc/ssh/sshd_config should already contain the following settings:
#   Port 2424
#   PermitRootLogin prohibit-password
#   PasswordAuthentication no
#   PubkeyAuthentication yes
#   MaxAuthTries 3
#   LoginGraceTime 20
#   ClientAliveInterval 300
#   ClientAliveCountMax 2
#   AllowTcpForwarding no
#   X11Forwarding no
#   AllowAgentForwarding no

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
#   etc/php8/fpm/php-fpm.d/example.com.conf        -> /etc/php8/fpm/php-fpm.d/
#   etc/php8/fpm/php-fpm.d/myproject.example.net.conf -> /etc/php8/fpm/php-fpm.d/
#   etc/php8/fpm/php-fpm.d/another-app.example.org.conf -> /etc/php8/fpm/php-fpm.d/
#   etc/php8/fpm/php-fpm.d/nextcloud.conf           -> /etc/php8/fpm/php-fpm.d/
mkdir /run/php-fpm && chown -R nginx:nginx /run/php-fpm
systemctl restart php-fpm
