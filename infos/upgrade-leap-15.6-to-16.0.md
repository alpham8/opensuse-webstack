# In-Place Upgrade: openSUSE Leap 15.6 → 16.0

This file describes the log of the real world upgrade test.

| key                     | data value                                                            |
|-------------------------|-----------------------------------------------------------------------|
| **Former test server:** | 203.0.113.1 (Hetzner Dedicated, i7-6700, 2x 512 GB NVMe RAID1, btrfs) |
| **Performed:**          | 28th February 2026                                                    |
| **Method:**             | Manual `zypper dup` (based on `opensuse-migration-tool` steps)        |
| **Script:**             | `infos/upgrade-156-160.sh`                                            |

---

## Summary

The in-place upgrade from Leap 15.6 to 16.0 was **technically successful** but required
significant post-upgrade work. The actual `zypper dup` ran without issues (1242 packages);
the difficulties were in:

1. **Network/SSH** — Three rescue system interventions needed because NetworkManager is not
   automatically installed and OpenSSH 10.x disables ssh-rsa
2. **Docker/Firewall** — Boot race condition and missing Masquerade
3. **Service adjustments** — Nearly every service needed post-upgrade fixes

**Estimated vs. actual duration:** Planned 1-2h, actual approx. 4-5h (incl. troubleshooting)

---

## Upgrade Method: Manual zypper dup

### Why not opensuse-migration-tool?

The `opensuse-migration-tool` is officially recommended but has a critical drawback:
**It uses `dialog` (ncurses TUI) and therefore cannot be run remotely via SSH without
a TTY.** The tool fails with exit code 1 on `--dry-run` and shows no output when no
terminal is available.

Internally, the tool performs these steps:
1. Disable third-party repos
2. Install `openSUSE-repos-Leap` for 16.0 (update repo definitions)
3. `zypper refresh-services`
4. `zypper --releasever 16.0 dup` with appropriate parameters
5. Optional: Choose AppArmor or SELinux
6. Optional: `wicked2nm` for network migration (not available as a package in 15.6!)

**Recommendation: Perform these steps manually** (see `upgrade-156-160.sh`, Phase 3).

Source: https://en.opensuse.org/SDB:System_upgrade_to_Leap_16.0

---

## Critical Changes in Leap 16.0

### 1. Network: wicked → NetworkManager (HIGHEST RISK)

**This is the most dangerous change for remote servers.**

- `wicked` no longer exists in Leap 16.0
- `NetworkManager` is the only network stack
- **WARNING: `wicked2nm` is NOT available as a package in Leap 15.6!**
- **WARNING: `NetworkManager` is NOT automatically installed during `zypper dup`!**
- The NM connection file must be created manually BEFORE the upgrade

**Order of operations (BEFORE the reboot!):**
1. Install `zypper -n in NetworkManager`
2. Create NM connection file under `/etc/NetworkManager/system-connections/`
3. `systemctl disable wicked.service && systemctl enable NetworkManager.service`
4. Only then reboot

**Current wicked configuration (Leap 15.6):**
```
# /etc/sysconfig/network/ifcfg-enp0s31f6
STARTMODE="auto"
IPADDR="203.0.113.1/32"
REMOTE_IPADDR="203.0.113.129"
IPADDR6=2001:db8::1/64
ZONE=public

# /etc/sysconfig/network/routes
default 203.0.113.129 - enp0s31f6
default fe80::1 - enp0s31f6
```

**NetworkManager configuration (create manually):**
```ini
# /etc/NetworkManager/system-connections/enp0s31f6.nmconnection
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
```
**Important:** The file must have `chmod 0600`, otherwise NM will ignore it!

### 2. SSH: OpenSSH 10.x Breaking Changes (CRITICAL!)

OpenSSH 10.x has several breaking changes that can **completely prevent SSH access**.
All changes MUST be made **BEFORE the reboot!**

**a) `PrintLastLog` removed:**
- `PrintLastLog yes/no` is no longer supported
- Solution: Remove/comment out the line in `/etc/ssh/sshd_config`

**b) `ssh-rsa` (SHA-1) disabled by default:**
- OpenSSH 10.x no longer accepts `ssh-rsa` public keys
- **This affects ALL RSA keys**, not just weak ones!
- Solution: `PubkeyAcceptedAlgorithms +ssh-rsa` in sshd_config
- **Long-term: Replace RSA key with Ed25519!**
  ```bash
  ssh-keygen -t ed25519 -C "root@server"
  ```

**c) `MaxAuthTries` too low:**
- When an SSH agent offers multiple keys, each attempt counts
- With `MaxAuthTries 3`, the connection is terminated before the correct key is tried
- Solution: Set `MaxAuthTries 6` (or on the client: `-o IdentitiesOnly=yes`)

```bash
# Summary of required sshd_config changes:
sed -i 's/^PrintLastLog/#PrintLastLog/' /etc/ssh/sshd_config
echo "PubkeyAcceptedAlgorithms +ssh-rsa" >> /etc/ssh/sshd_config
sed -i 's/^MaxAuthTries [1-3]$/MaxAuthTries 6/' /etc/ssh/sshd_config
sshd -t  # Check syntax!
```

### 3. Security: AppArmor → SELinux (Default)

- SELinux is the new default, but AppArmor remains available
- During upgrade: **Keep AppArmor**
- AppArmor version goes from 3.1 to 4.1 (new `priority=` syntax)

### 4. Miscellaneous

- **YaST** completely removed (replacements: Cockpit, Myrlyn — irrelevant for this server)
- **nscd** removed (`systemd-resolved` as replacement, not needed for this server)
- **/tmp is tmpfs** (cleared after reboot)
- **Hostname handling**: FQDNs are no longer silently truncated
- **CPU requirement**: x86-64-v2 (server has all features)

---

## Software Version Changes

| Software       | Leap 15.6           | Leap 16.0 (actual)    | Impact                                                                |
|----------------|---------------------|-----------------------|-----------------------------------------------------------------------|
| Kernel         | 6.4.0               | 6.12.x                | New kernel, reboot required                                           |
| PHP            | 8.2                 | 8.4                   | pecl extensions must be recompiled! (amqp manually due to config.sub) |
| Python         | 3.11                | 3.13                  | Recreate certbot venv (shebang!)                                      |
| nginx          | ~1.21               | 1.27                  | http2 directive, push preload                                         |
| MariaDB        | 10.x                | 11.8                  | Check grants, compatibility                                           |
| Docker         | ~24.x               | ~28.x                 | docker-compose as plugin, boot race                                   |
| fail2ban       | ~1.0                | 1.1.0                 | Strict `<HOST>` validation                                            |
| Dovecot (Host) | 2.3                 | 2.4                   | Only relevant if host Dovecot                                         |
| RabbitMQ       | Erlang/OTP ~26      | Erlang/OTP 27         | NODENAME + /etc/hosts + Mnesia reset                                  |
| AppArmor       | 3.1                 | 4.1                   | priority= syntax                                                      |
| OpenSSH        | 9.x                 | 10.x                  | PrintLastLog, ssh-rsa, MaxAuthTries                                   |
| Network        | wicked              | NetworkManager        | Full migration required                                               |

---

## Affected Services and Required Adjustments

### nginx
- `listen ... http2` → `http2 on;` directive (deprecated in 1.27)
- `http2_push_preload` → remove (obsolete)

### PHP-FPM
- PHP 8.2 → 8.4: Configuration should be compatible
- **pecl extensions must be recompiled** (redis, amqp, imagick)
- Build dependencies: php8-devel, php8-pear, librabbitmq-devel, ImageMagick-devel

### PHP pecl
- `pecl install -f amqp` fails: `config.sub: too many arguments`
- Cause: The bundled `config.sub` does not recognize the Leap 16.0 build type
- **Workaround:** Manual build with `phpize`, then copy `config.sub`/`config.guess`
  from `/usr/share/automake-*/` into the `build/` directory

### Postfix
- `tlsmgr` in `/etc/postfix/master.cf` is commented out by default
- **Must be uncommented**, otherwise no TLS → Mailcow rejects connections

### MariaDB
- 10.x → 11.8: Grant format has changed
- **Run mysql_upgrade** after the upgrade

### RabbitMQ
- `epmd` listens only on 127.0.0.1 in Leap 16.0
- `NODENAME=rabbit@localhost` in `/etc/rabbitmq/rabbitmq-env.conf` required
  - **WARNING:** The SUSE default has the line commented out — uncomment it, do not append!
- Short hostname (e.g. `example`) must be in `/etc/hosts`
  (otherwise DNS resolution points to wrong IP)
- Mnesia DB is incompatible after major upgrade
  (`classic_mirrored_queue_version`) → may need to be deleted

### Docker + firewalld
- `docker-compose` is replaced by `docker compose` (plugin)
- **Three problems after the upgrade:**
  1. Masquerade missing in Docker zone → containers have no internet access
  2. Boot race: Docker starts before firewalld → first start fails
  3. `firewall-cmd --reload` destroys Docker's dynamic NAT rules
- Solutions: see section "Created Systemd Drop-Ins" below

### CrowdSec
- `Requires=docker.service` → `Wants=docker.service`
  (otherwise CrowdSec stays inactive when Docker transiently fails to start)

### Certbot
- Python 3.11 → 3.13: **venv must be recreated**
- Without rebuild: Cron error `cannot execute: required file not found`
  (shebang points to python3.11)
```bash
rm -rf /opt/certbot/venv
python3 -m venv /opt/certbot/venv
/opt/certbot/venv/bin/pip install --upgrade pip
/opt/certbot/venv/bin/pip install certbot certbot-dns-inwx
ln -sf /opt/certbot/venv/bin/certbot /usr/local/bin/certbot
```

### fail2ban
- Version 1.1.0 requires `<HOST>` in **all** failregex patterns
- Check/adjust `nginx-exploit` and `nginx-badreq` filters

### Logrotate
- Leap 16.0 reads both `/usr/etc/logrotate.d/` (RPM vendor) and `/etc/logrotate.d/`
- RPM configs use wildcards (e.g. `/var/log/mysql/*.log`)
- **Custom configs that rotate individual files matching those wildcards must be removed!**
- `logrotate-all` aborts COMPLETELY on duplicates (no logs get rotated)

---

## Order of Steps

1. **Preparation** (15-30 min)
   - Fully update the system
   - Create btrfs snapshot (manually, as there is no Snapper)
   - Stop Docker containers
   - Stop non-essential services
   - Disable third-party repos
   - Back up network configuration

2. **Migration** (30-60 min)
   - Install NetworkManager + create NM config (CRITICAL!)
   - Switch repos to 16.0 (`openSUSE-repos-Leap`)
   - Run `zypper --releasever 16.0 dup`
   - **Adjust sshd_config BEFORE the reboot!** (PrintLastLog, ssh-rsa, MaxAuthTries)
   - Reboot

3. **Post-upgrade work** (60-90 min, realistically!)
   - Verify network
   - Verify SSH
   - Set up third-party repos for 16.0
   - Service-specific adjustments (nginx, PHP, Postfix, RabbitMQ)
   - Docker zone: Enable Masquerade
   - Systemd drop-ins: Boot race condition (Docker, firewalld, CrowdSec)
   - Recompile pecl extensions (amqp manually due to config.sub!)
   - Recreate certbot venv (Python 3.13)
   - RabbitMQ: NODENAME, /etc/hosts, possibly Mnesia reset
   - Logrotate: Remove duplicate configs
   - sshd: PrintMotd no
   - Start Docker containers
   - Nextcloud cron: Increase memory limit

4. **Verification** (15 min)
   - Check all services
   - Check all Docker containers
   - Test web endpoints
   - Test mail

---

## Rollback Plan

### Option A: btrfs Snapshot (preferred)
A btrfs snapshot of the root subvolume is created before the upgrade.
If the upgrade fails:
1. Boot into Hetzner Rescue System
2. Mount the btrfs subvolume
3. Set the snapshot as the new root subvolume
4. Reboot

```bash
# Rollback in the rescue system:
mount /dev/md2 /mnt -o subvol=/
mv /mnt/@  /mnt/@broken
mv /mnt/@pre-upgrade  /mnt/@
reboot
```

### Option B: Hetzner KVM Console
If the server is unreachable after the upgrade but still running:
1. Hetzner Robot → Request KVM console
2. Log in as root
3. Manually configure network (see Network section above)

### Option C: Rescue System
If the server no longer boots:
1. Hetzner Robot → Activate rescue system
2. SSH into the rescue system
3. Assemble RAID, mount btrfs, repair

---

## Experience Report: Test Upgrade on 28.02.2026

The upgrade was tested on server 203.0.113.1 (old Hetzner Dedicated).

### Sequence of Events

1. **Preparation** went smoothly: System updated, snapshots created,
   services and Docker containers stopped, third-party repos disabled.
2. **opensuse-migration-tool** failed: The tool uses `dialog` (ncurses)
   and does not work via SSH without a TTY. Therefore, manual migration was used.
3. **zypper dup** ran successfully: 1242 packages were updated.
4. **First reboot**: Server unreachable! Cause: **NetworkManager was not installed.**
   `zypper dup` does not install NM automatically, and `wicked` no longer exists
   in 16.0 → no network.
5. **Rescue #1**: Installed NM, created NM config, disabled wicked, enabled NM.
6. **Second reboot**: Server still unreachable! Cause: Rescue system was still
   activated in Hetzner Robot → server booted into rescue again.
7. **After rescue deactivation + reset**: Still unreachable! Cause: Server WAS
   online (network was working!), but SSH rejected all keys.
8. **Rescue #2**: Journal logs showed SSH connection attempts with key rejection.
   Three problems in sshd_config:
   - `PrintLastLog` → unsupported in OpenSSH 10.x
   - `ssh-rsa` → disabled by default in OpenSSH 10.x
   - `MaxAuthTries 3` → too low when SSH agent offers multiple keys
9. **Fixed sshd_config, reboot**: **Success!** Server reachable with Leap 16.0.

### Post-upgrade Work After First Successful Boot

After the successful boot, numerous services needed to be repaired:

**Docker + Firewall:**
- Containers could not reach the internet (Unbound unhealthy).
  Cause: **Masquerade was missing in the Docker zone**.
- Docker did not start reliably at boot: **Boot race condition** —
  Docker starts before firewalld, nftables chains do not exist yet.
- `firewall-cmd --reload` destroys Docker's dynamic NAT rules.

**CrowdSec:**
- Remained inactive after boot. `Requires=docker.service` pulled CrowdSec
  down when Docker's first start attempt failed.

**RabbitMQ (3 problems in sequence):**
- Crashloop `{epmd_error,"example",timeout}`: Short hostname was resolved
  via DNS to the new server IP instead of localhost.
- `NODENAME=rabbit@localhost` was commented out in the SUSE default file.
  A simple `grep -q` also matches comments — trap!
- `{disabled_required_feature_flag, classic_mirrored_queue_version}`:
  Old Mnesia DB incompatible. Delete and start fresh.

**PHP / AMQP:**
- `pecl install -f amqp` fails: `config.sub: too many arguments`.
  Manual build with system `config.sub` required.

**Certbot:**
- `cannot execute: required file not found`: Venv shebang points to
  python3.11, which no longer exists. Rebuild venv completely.

**Logrotate:**
- Aborted completely (exit 1). Duplicate entries: Custom configs
  conflicted with RPM wildcard configs.

**Miscellaneous:**
- motd displayed twice: `PrintMotd no` in sshd_config.
- Nextcloud cron OOM: PHP CLI default 128M → `-d memory_limit=1024M`.

### Lessons Learned

| Problem | Cause | Solution |
|---------|-------|----------|
| No network after reboot | NM not installed | Install NM BEFORE the reboot |
| SSH key auth fails | ssh-rsa disabled in OpenSSH 10.x | `PubkeyAcceptedAlgorithms +ssh-rsa` |
| SSH connection drops | MaxAuthTries too low | Increase to 6 or use `-o IdentitiesOnly=yes` |
| sshd warning | PrintLastLog unsupported | Remove from sshd_config |
| Server "offline" despite network | firewalld DROP blocks ICMP | This is correct; only ping is not possible |
| opensuse-migration-tool fails | dialog requires TTY | Perform steps manually |
| wicked2nm not available | No package in 15.6 | Create NM config manually |
| Docker no internet | Masquerade missing in Docker zone | `firewall-cmd --zone=docker --add-masquerade` |
| Docker boot race | Starts before firewalld | `ExecStartPre` waits for `firewall-cmd --state` |
| firewall reload kills Docker NAT | Chains are rebuilt | firewalld drop-in restarts Docker on reload |
| CrowdSec inactive after boot | `Requires=docker.service` | `Wants=docker.service` |
| RabbitMQ crashloop | Short hostname + NODENAME + Mnesia | `/etc/hosts` + uncomment + DB reset |
| pecl amqp build error | Outdated `config.sub` | Manual build with system config.sub |
| Certbot "not found" | Venv has Python 3.11 shebang | Rebuild venv completely |
| Logrotate aborts | Duplicate log entries | Remove custom configs |
| motd displayed twice | PrintMotd + pam_motd.so | `PrintMotd no` |
| Nextcloud OOM in cron | PHP CLI default 128M | `-d memory_limit=1024M` |

---

## Created Systemd Drop-Ins

These drop-ins fix the boot race condition and are stored in the repo under
`etc/systemd/system/`:

### `firewalld.service.d/restart-docker.conf`
```ini
[Service]
ExecStartPost=/usr/bin/systemctl restart docker
ExecReload=
ExecReload=/bin/kill -HUP $MAINPID
ExecReload=/usr/bin/systemctl restart docker
```
- `ExecStartPost`: Restart Docker after firewalld starts (NAT rules)
- `ExecReload=` (empty): Clears the original ExecReload
- Then: HUP to firewalld + Docker restart in sequence

### `docker.service.d/override.conf`
```ini
[Service]
ExecStartPre=/bin/sh -c "until /usr/bin/firewall-cmd --state >/dev/null 2>&1; do sleep 1; done"
```
- Waits until firewalld is ready before Docker starts

### `crowdsec.service.d/override.conf`
```ini
[Unit]
After=docker.service
Wants=docker.service
```
- `Wants` instead of `Requires`: CrowdSec survives transient Docker failures

---

## Checklist for Future Upgrades

Before the reboot:
- [ ] NetworkManager installed and NM config created
- [ ] sshd_config: PrintLastLog removed, ssh-rsa allowed, MaxAuthTries >= 6
- [ ] sshd -t successful

After the reboot:
- [ ] SSH reachable
- [ ] Network: IPv4 + IPv6 + DNS
- [ ] firewalld: Docker zone Masquerade active
- [ ] Systemd drop-ins deployed (firewalld, docker, crowdsec)
- [ ] Docker containers start and have internet access
- [ ] RabbitMQ: NODENAME, /etc/hosts, possibly Mnesia reset
- [ ] pecl extensions: redis, amqp (manual!), imagick
- [ ] Certbot venv rebuilt
- [ ] Logrotate: No duplicate configs
- [ ] sshd: PrintMotd no
- [ ] Nextcloud cron: memory_limit
- [ ] All services active, no failed units
- [ ] All 22 Docker containers UP

---

## Tips for Hetzner Rescue

- **Deactivate** the rescue system in Robot after repairs, otherwise the
  server will boot into rescue again instead of the normal system.
- `sshpass` and `expect` are not available in rescue. For password auth
  via scripts, use the SSH_ASKPASS trick:
  ```bash
  echo 'echo "PASSWORD"' > /tmp/ssh_askpass.sh && chmod +x /tmp/ssh_askpass.sh
  SSH_ASKPASS_REQUIRE=force SSH_ASKPASS=/tmp/ssh_askpass.sh \
      ssh -o StrictHostKeyChecking=no root@203.0.113.1
  ```
- In rescue: Assemble RAID and chroot:
  ```bash
  mdadm --assemble /dev/md0 /dev/nvme0n1p2 /dev/nvme1n1p2  # /boot
  mdadm --assemble /dev/md2 /dev/nvme0n1p3 /dev/nvme1n1p3  # /
  mount /dev/md2 /mnt -o subvol=@
  mount /dev/md0 /mnt/boot
  mount --bind /dev /mnt/dev
  mount --bind /proc /mnt/proc
  mount --bind /sys /mnt/sys
  # resolv.conf may be a symlink → rm + rewrite:
  rm -f /mnt/etc/resolv.conf
  echo "nameserver 198.51.100.2" > /mnt/etc/resolv.conf
  chroot /mnt
  ```
- Fallback NM config (if network does not work):
  ```bash
  cp /root/nm-fallback-enp0s31f6.nmconnection /etc/NetworkManager/system-connections/
  chmod 0600 /etc/NetworkManager/system-connections/nm-fallback-enp0s31f6.nmconnection
  nmcli con reload
  nmcli con up enp0s31f6
  ```
- Read journal logs from the last boot in rescue:
  ```bash
  journalctl -D /mnt/var/log/journal/ --list-boots  # Boot IDs
  journalctl -D /mnt/var/log/journal/ -b -1 --no-pager  # last boot
  ```

---

## Conclusion

The upgrade is feasible but **not trivial**. The biggest risks:

1. **Network migration** (wicked → NM): Without preparation, the server is
   unreachable after the reboot. Plan for Hetzner Rescue System as a fallback!

2. **SSH breaking changes** (OpenSSH 10.x): ssh-rsa deactivation locks out all
   RSA key users. MUST be fixed before the reboot!

3. **Docker+firewalld boot race**: Affects every server running Docker + firewalld.
   Without the three systemd drop-ins, Docker does not start reliably at boot.

4. **Service post-upgrade work**: Practically every service needs adjustments.
   The upgrade script (`upgrade-156-160.sh`) documents all required steps.

**Recommendation:** Perform the upgrade on a test/standby server first,
identify and resolve all problems, then upgrade the production system.
This is exactly the approach taken here — the findings from the test upgrade
on the old server (203.0.113.1) were directly applied to the new server (203.0.113.2).

---

## References

- https://en.opensuse.org/SDB:System_upgrade_to_Leap_16.0
- https://news.opensuse.org/2025/10/01/migrating-to-leap-16-with-opensuse-migration-tool/
- https://doc.opensuse.org/release-notes/x86_64/openSUSE/Leap/16.0/
- https://github.com/openSUSE/wicked2nm
- https://en.opensuse.org/openSUSE:Known_bugs_16.0
- https://en.opensuse.org/How_to_switch_from_SELinux_to_AppArmor_in_Leap_16
