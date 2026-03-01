# Information Files

Reference documentation, setup scripts, and maintenance guides.

## Setup Scripts

### `install-all-services.sh`
Complete setup script for a fresh openSUSE Leap 16.0 installation on Hetzner Dedicated.
Covers everything from base packages to Docker services, CrowdSec, Grafana Alloy, and more.
**Not meant to be run as a whole** -- copy the commands you need.

## Upgrade Guides

### `upgrade-leap-15.6-to-16.0.md`
Comprehensive guide for in-place upgrading from openSUSE Leap 15.6 to 16.0. Covers critical
changes (wicked to NetworkManager, OpenSSH 10.x breaking changes, Docker+firewalld boot race),
a detailed experience report, lessons learned, and rollback strategies.

### `upgrade-leap-15.6-to-16.0.sh`
Step-by-step upgrade script implementing the manual migration (11 phases). Intended as a
reference -- execute each phase individually and verify the results.

### `hetzner-installimage.md`
Hetzner installimage configuration for 2x NVMe RAID1 with btrfs subvolumes.

## Other Files

### `root_crontab.txt`
Documents the active root crontab entries (certbot renewal, Nextcloud cron, daily backup).

### `grafana.md`
Grafana Cloud dashboard and alerting setup documentation.

### `local-backup.sh`
Script to download the latest server backups to a local external drive via SCP/rsync.
