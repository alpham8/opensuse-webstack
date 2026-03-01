# Server Migration: installimage (i7-6700 -> i7-8700)

## Hardware (new server)

| Component  | Details                                                  |
|------------|----------------------------------------------------------|
| Disk 1     | Samsung PM9A1 1 TB (MZVL21T0HCLR), S/N XXXXXXXXXXXX     |
| Disk 2     | Samsung PM9A1 1 TB (MZVL21T0HCLR), S/N XXXXXXXXXXXX     |
| Firmware   | GXA7801Q                                                 |
| Interface  | NVMe 1.3, LBA 512 Bytes                                 |

Capacity doubled: 2x 1 TB instead of previously 2x 512 GB.

## Before installimage

List available openSUSE images:

```bash
ls /root/.oldroot/nfs/images/ | grep -i suse
```

## Start installimage

```bash
installimage
```

Set the following configuration in the editor:

```
## Drives
DRIVE1 /dev/nvme0n1
DRIVE2 /dev/nvme1n1

## Software RAID 1 (mirroring)
SWRAID 1
SWRAIDLEVEL 1

## Bootloader
BOOTLOADER grub

## Hostname
HOSTNAME example.com

## Partitions
PART  swap   swap  32G
PART  /boot  ext4  1G
PART  btrfs.1 btrfs all

## btrfs subvolumes
SUBVOL btrfs.1 @      /
SUBVOL btrfs.1 @home  /home
SUBVOL btrfs.1 @srv   /srv

## Image
IMAGE /root/.oldroot/nfs/images/Opensuse-1600-amd64-base.tar.gz
```

## Target Layout

| Array | Partitions                    | Size       | Mount                    | Filesystem                                    |
|-------|-------------------------------|------------|--------------------------|-----------------------------------------------|
| md0   | nvme0n1p1 + nvme1n1p1         | 32 GB      | swap                     | swap                                          |
| md1   | nvme0n1p2 + nvme1n1p2         | 1 GB       | /boot                    | ext4                                          |
| md2   | nvme0n1p3 + nvme1n1p3         | ~920 GB    | /, /home, /srv           | btrfs (subvolumes @, @home, @srv)             |

Partition table: MBR (dos), partition type `fd` (Linux RAID autodetect).

## Checklist after installimage + reboot

1. Test SSH access (rescue sets root password, port 22)
2. `cat /proc/mdstat` -- all arrays `[UU]`?
3. `btrfs subvolume list /` -- verify subvolumes
4. `smartctl -a /dev/nvme0` and `nvme1` -- check SSD health of the new disks
5. Only then begin with server configuration (SSH port 2424, keys, etc.)
