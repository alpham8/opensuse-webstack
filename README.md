# Server Setup

Reproducible Linux server configuration for a dedicated server running openSUSE Leap 16.0. Configuration files mirror the actual server filesystem layout, making it straightforward to compare, deploy, and restore settings.

> **Note:** All IP addresses, domains, and credentials in this repository are placeholders.
> IPv4 addresses use the RFC 5737 documentation range (`203.0.113.1`), IPv6 uses the
> documentation prefix (`2001:db8::1`), and domains use `example.com`. Replace them with
> your own values before deploying.

## Stack Summary

| Component        | Details                                                               |
|------------------|-----------------------------------------------------------------------|
| OS               | openSUSE Leap 16.0                                                    |
| Web server       | nginx (with Brotli module)                                            |
| PHP              | PHP 8 (FPM, per-app pools, Unix sockets under `/run/php-fpm/`)        |
| Database         | MariaDB                                                               |
| Mail (Docker)    | Mailcow                                                               |
| Mail relay       | Postfix (satellite / relay-only for system notifications)             |
| Message queue    | RabbitMQ (localhost only, AMQP + AMQPS + Management UI)               |
| Containers       | Docker with native Compose                                            |
| Certificates     | Let's Encrypt via Certbot + DNS challenge (wildcard certs)            |
| Firewall         | firewalld with nftables backend                                       |
| IDS/IPS          | CrowdSec + nftables bouncer, fail2ban (migration in progress)         |
| Security audits  | rkhunter, Lynis, AppArmor                                             |
| SSH tarpit       | endlessh-go on port 22 (Docker)                                       |
| Monitoring       | Grafana Cloud Free via Alloy (metrics + logs)                         |
| Web analytics    | Umami (Docker)                                                        |
| Blog comments    | Remark42 (Docker)                                                     |

## Directory Structure

This repository mirrors the Linux filesystem hierarchy. Each path in the repo corresponds to the same path on the server:

```
.
├── etc/
│   ├── alloy/              # Grafana Alloy config (monitoring agent)
│   ├── crowdsec/           # CrowdSec acquisition + whitelist
│   ├── fail2ban/           # fail2ban jails and filters
│   ├── firewalld/          # firewalld zone and service definitions
│   ├── logrotate.d/        # Logrotate configs (nginx, MariaDB, fail2ban, rsync)
│   ├── modprobe.d/         # Disabled kernel protocols (dccp, sctp, rds, tipc)
│   ├── nginx/              # nginx main config + vhosts + global includes
│   │   └── vhosts.d/
│   │       ├── *.conf                  # Virtual host configs
│   │       ├── *.conf.example          # Example vhosts (Nextcloud, Umami, Remark42, Mailcow, ...)
│   │       ├── compression.global      # Centralized gzip/Brotli settings
│   │       ├── security-headers.global # Centralized security headers
│   │       ├── static-cache.global     # Cache headers for static assets
│   │       └── sf-common.global        # Symfony common rules
│   ├── php8/               # PHP 8 config (FPM pools, php.ini)
│   │   └── fpm/php-fpm.d/  # One pool per app (clear_env=yes, incl. Nextcloud pool)
│   ├── postfix/            # Postfix satellite relay config
│   ├── rabbitmq/           # RabbitMQ config (localhost-only binding)
│   ├── ssh/                # sshd_config (hardened)
│   ├── sysctl.d/           # Kernel hardening + network security
│   └── systemd/            # Systemd service overrides and custom units
│       └── system/         # compose-*.service (Docker Compose), timers, overrides
├── infos/                  # Setup scripts, upgrade guides, reference docs
├── opt/
│   ├── remark42/           # Remark42 Docker Compose + env
│   └── umami/              # Umami Docker Compose + env
├── root/                   # Scripts and configs from /root on the server
│   ├── cert-post-renew.sh  # Certbot deploy-hook (certs -> nginx, Mailcow, RabbitMQ)
│   ├── endlessh-go/        # endlessh-go Docker Compose (SSH tarpit)
│   ├── mailcow-dockerized/ # Mailcow example config
│   └── scripts/            # Backup scripts, RabbitMQ helpers
```

## SSH Hardening

SSH is configured on a non-standard port with strict authentication:

- **Port 2424** (non-standard; port 22 runs the endlessh-go tarpit)
- `PermitRootLogin without-password` (key-only)
- `PasswordAuthentication no`
- `MaxAuthTries 3`, `MaxSessions 2`
- `ClientAliveInterval 300`, `ClientAliveCountMax 2`
- `AllowTcpForwarding yes` (for SSH tunnels, e.g., RabbitMQ Management UI)
- `X11Forwarding no`, `AllowAgentForwarding no`
- `LogLevel VERBOSE`
- Protocol 2 only

Connect with:

```bash
ssh -p 2424 root@203.0.113.1
```

Configuration: `etc/ssh/sshd_config`

## Firewall

firewalld with nftables backend:

- Default zone: `public`
- `LogDenied=unicast` (denied connections visible in journal)
- Open services: dhcpv6-client, http, http3, https, imap, imaps, ssh (port 22 for endlessh)
- Open ports: 2424/tcp (SSH), mail ports (25, 465, 587, 993, 995)
- RabbitMQ management and distribution ports blocked via IPv6 rich rules

Configuration: `etc/firewalld/`

## nginx

nginx serves as the web server and reverse proxy for all hosted applications:

- **TLS hardening**: TLS 1.2 and 1.3 only, modern cipher suite, session tickets disabled
- **Rate limiting**: `limit_req_zone` at 10 requests/second per IP
- **Compression**: gzip + Brotli (centralized in `compression.global`)
- **Security headers**: HSTS (2 years), X-Content-Type-Options, X-Frame-Options, Permissions-Policy (centralized in `security-headers.global`)
- **Static asset caching**: `Cache-Control: public, immutable`, 1-year expiry (`static-cache.global`)
- **Catch-all server block**: returns 444 for unknown hostnames, rejects TLS handshake for unknown SNI
- **Exploit blocking**: common attack paths (ThinkPHP, shell_exec, etc.) and non-standard HTTP methods
- `server_tokens off` globally
- Open file cache for static files
- FastCGI buffering tuned for PHP-FPM

Configuration: `etc/nginx/nginx.conf`, `etc/nginx/vhosts.d/`

## PHP-FPM

Each application runs in its own PHP-FPM pool with `clear_env = yes` for environment isolation:

| Pool            | Socket                          | Application             |
|-----------------|---------------------------------|-------------------------|
| `app`           | `/run/php-fpm/app.sock`         | Main application        |
| `app2`          | `/run/php-fpm/app2.sock`        | Secondary application   |
| `nextcloud`     | `/run/php-fpm/nextcloud.sock`   | Nextcloud               |
| `www` (default) | `/run/php-fpm/www.sock`         | Fallback / legacy apps  |

The Nextcloud pool has elevated limits: `memory_limit = 1024M`, `upload_max_filesize = 16384M`, `max_execution_time = 3600`.

Configuration: `etc/php8/fpm/php-fpm.d/*.conf`

## Mail

### Mailcow (Docker)

Full-featured mail server running as a Docker Compose stack:

- SMTP: ports 25, 465 (SMTPS), 587 (Submission)
- IMAP: ports 143, 993 (IMAPS)
- Web UI: ports 8080 (HTTP), 4443 (HTTPS) -- behind nginx reverse proxy
- Autodiscover/Autoconfig endpoints proxied through nginx

Configuration: `root/mailcow-dockerized/`

### Postfix Relay

Postfix is configured as a satellite system (relay-only) for system notifications:

- Listens on loopback only (`inet_interfaces = loopback-only`)
- Relays outgoing mail via the Mailcow server on port 587 (SASL auth)
- Used for cron notifications, fail2ban alerts, etc.
- SMTP smuggling mitigation (CVE-2023-51764) enabled

Configuration: `etc/postfix/main.cf`

## Monitoring (Alloy to Grafana Cloud)

Grafana Alloy collects metrics and logs and ships them to Grafana Cloud Free:

- **Metrics**: built-in `prometheus.exporter.unix` (no separate node_exporter needed), endlessh-go Prometheus endpoint
- **Logs**: systemd journal, nginx access/error logs, rkhunter warnings, DMARC aggregate reports
- **Dashboards**: Linux Node, Node Exporter Full (ID 1860), Endlessh (ID 15156), Alloy self-monitoring, nginx logs, DMARC reports
- **Alerts**: disk > 85%, RAM > 90%, systemd service down, SSL cert expiring < 14 days, Alloy heartbeat missing

Configuration: `etc/alloy/config.alloy`

## Security

### CrowdSec

Replaces psad (deinstalled) and will gradually replace fail2ban:

- Engine + nftables bouncer for host-level IP blocking
- LAPI on port 8083 (to avoid conflict with Mailcow on 8080)
- Acquisition sources: nginx logs, sshd (journald), Mailcow containers (Docker)
- Whitelist: own IPs + Docker networks
- Collections: linux, nginx, sshd, postfix, dovecot, http-cve

Configuration: `etc/crowdsec/`

### fail2ban

Active jails (being migrated to CrowdSec):

- `sshd` -- SSH brute-force protection
- `nextcloud` -- Nextcloud login failures
- `nginx-http-auth` -- nginx basic auth failures
- `nginx-botsearch` -- bot/scanner detection
- `nginx-badreq` -- malformed HTTP requests
- `nginx-exploit` -- exploit attempt patterns
- Custom application jails

Configuration: `etc/fail2ban/`

### Kernel and Network Hardening

Sysctl parameters in `etc/sysctl.d/90-custom.conf`:

- IP spoofing protection (`rp_filter`)
- ICMP redirects blocked (MitM protection)
- Source routing disabled
- SYN flood protection (`tcp_syncookies`, `tcp_max_syn_backlog`)
- Martian packet logging
- ASLR maximized (`randomize_va_space = 2`)
- Core dumps restricted (`suid_dumpable = 0`)
- Kernel pointers hidden (`kptr_restrict = 2`)
- dmesg restricted to root (`dmesg_restrict = 1`)
- Symlink/hardlink protection

### Disabled Kernel Protocols

Unused protocols disabled via `etc/modprobe.d/`: dccp, sctp, rds, tipc.

### Hardening Script

`root/hardening.sh` applies sysctl parameters, disables unused kernel modules, and configures additional security settings in a single run.

## Docker Services

### endlessh-go (SSH Tarpit)

Runs on port 22 and poses as an SSH server, sending an endless banner to trap scanners and bots. Exposes Prometheus metrics on `127.0.0.1:2112/metrics` (scraped by Alloy).

Configuration: `root/endlessh-go/docker-compose.yml`

### Umami (Web Analytics)

Cookieless, privacy-friendly web analytics. No cookie banner required (GDPR-compliant).

Configuration: `opt/umami/docker-compose.yml`

### Remark42 (Blog Comments)

Self-hosted comment engine. Supports anonymous comments, admin email notifications via SMTP, and lazy-loading. Data stored in BoltDB (no external database needed).

Configuration: `opt/remark42/docker-compose.yml`

### Systemd Integration

All Docker Compose projects are managed via `Type=oneshot` + `RemainAfterExit=yes` systemd units. Start order: docker -> mailcow -> endlessh + umami + remark42 (parallel). The existing Docker restart policy `unless-stopped` is retained as crash safety.

Configuration: `etc/systemd/system/compose-*.service`

## Backups

### Automated Daily Backup

A PHP backup script (`/root/scripts/backup-all.php`) runs daily at 04:00 via cron. It uses `pcntl_fork()` to create backup archives in parallel:

1. `/home/` (tarball)
2. `/etc/nginx/` (tarball)
3. `/srv/repo/` (tarball)
4. `/etc/php8/` (tarball)
5. `/srv/www/vhosts/` (tarball, Nextcloud enters maintenance mode)
6. All databases via mysqldump
7. Mailcow backup via its built-in helper script

After all tasks succeed, archives are synced to a Hetzner Storage Box via rsync over SSH.

A dry-run mode is available:

```bash
php /root/scripts/backup-all.php --dry-run
```

Configuration: `root/scripts/`

### Local Backup

A manual script (`infos/local-backup.sh`) downloads backups from the server to a local machine or external drive.

## SSL Certificates

A single wildcard certificate covers all hosted domains, obtained via Certbot with a DNS challenge plugin:

```bash
certbot certonly -a dns-plugin --expand --cert-name "example.com" \
  -d "example.com" -d "*.example.com"
```

Upon renewal, a deploy-hook script (`root/cert-post-renew.sh`) handles:

1. Reloading nginx
2. Copying certificates to the Mailcow SSL directory and restarting Mailcow containers
3. Copying certificates to the RabbitMQ SSL directory and restarting RabbitMQ

## Maintenance

### Certificate Renewal

```bash
certbot certificates                   # Check expiry dates
certbot renew --dry-run                # Test renewal
```

Automatic renewal runs daily at 03:00 via cron.

### Backups

```bash
ls -lh /root/backup/                             # Check latest backups
php /root/scripts/backup-all.php --dry-run        # Dry run
```

### CrowdSec Updates

```bash
cscli hub update
cscli hub upgrade
cscli metrics
cscli decisions list
```

### System Updates

```bash
zypper refresh
zypper update
rkhunter --propupd    # Update rkhunter file hashes after package updates
```

Automatic security patches are applied daily at 05:00 via a systemd timer.

### Major Upgrade (Leap 15.6 to 16.0)

A comprehensive upgrade guide and script are available in `infos/`:

- `infos/upgrade-leap-15.6-to-16.0.md` -- detailed guide with experience report and lessons learned
- `infos/upgrade-leap-15.6-to-16.0.sh` -- step-by-step reference script (11 phases)
- `infos/install-all-services.sh` -- complete fresh installation script for Leap 16.0

### Docker Service Updates

```bash
# endlessh-go
cd /root/endlessh-go && docker compose pull && docker compose up -d

# Umami
cd /opt/umami && docker compose pull && docker compose up -d

# Remark42
cd /opt/remark42 && docker compose pull && docker compose up -d

# Mailcow
cd /root/mailcow-dockerized && docker compose pull && docker compose up -d
```

### Grafana Alloy

```bash
systemctl status alloy
alloy fmt /etc/alloy/config.alloy      # Check formatting
systemctl reload alloy                 # Reload without restart
```

## RabbitMQ

- AMQP and AMQPS bound to localhost only
- Management UI on `127.0.0.1:15672` (access via SSH tunnel)
- TLS certificates from Let's Encrypt (updated via deploy-hook)

Access the Management UI:

```bash
ssh -p 2424 -N -L 8080:127.0.0.1:15672 root@203.0.113.1
```

Configuration: `etc/rabbitmq/rabbitmq.conf`

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.
