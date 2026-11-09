# Btrfs layout (planned for the Phase 1 installer)

> Status: **Plan** · Written in Phase 0, implemented by the installer in Phase 1 · Decision: [ADR-009](../DECISIONS.md) · Spec: [system-base §Filesystem layout](../specs/system-base.md)

Phase 0 only packages the tools (`btrfs-progs`, `snapper` in the live ISO). Nothing here is created on disk yet. This page is what the Phase 1 installer (Calamares `partition` + `mount` + `fstab` modules and our post-install job) must produce, and why.

## Partitions

| Partition | Size | Filesystem | Mount point | Notes |
|---|---|---|---|---|
| ESP | ≥ 300 MB on new installs (an existing ESP ≥ 100 MB is reused when dual-booting) | FAT32 | `/boot/efi` | Holds shim, GRUB and the MOK tools only. Kernels stay in `/boot` on Btrfs, so they roll back with `@` |
| Lugh | rest of the disk (or the chosen free space) | Btrfs (optionally inside LUKS2/Argon2id) | top-level subvolume (id 5) is **not** mounted in normal operation | |

There is no swap partition: swap is zram (system-base FR-5). BIOS installs (Advanced only) add a 1 MB `bios_grub` partition on GPT disks.

## Subvolumes

All subvolumes are created flat, directly under the top-level subvolume (id 5), not nested inside `@`. Flat subvolumes can be renamed and swapped during a rollback without touching each other.

| Subvolume | Mount point | Snapshotted | Why it is separate |
|---|---|---|---|
| `@` | `/` | yes, snapper config `root` | The system. Includes `/boot`, so a rollback brings the matching kernel and initramfs back too |
| `@home` | `/home` | opt-in, snapper config `home` (off by default) | User data must never roll back with the system |
| `@snapshots` | `/.snapshots` | n/a | Snapper's snapshot store for `root`. Keeping it outside `@` means snapshots don't contain each other, and a rolled-back `@` still sees every snapshot |
| `@var_log` | `/var/log` | no | Logs survive a rollback, so you can still read why the broken system broke |
| `@cache` | `/var/cache` | no | apt's `.deb` cache and other caches: large, rebuildable, pointless to snapshot |

ADR-009 fixes these five. The system-base spec adds two more that the installer should create alongside them:

| Subvolume | Mount point | Snapshotted | Why |
|---|---|---|---|
| `@var_tmp` | `/var/tmp` | no | Temporary files that survive reboots; they shouldn't pin space in snapshots |
| `@bridge` | `~/.local/share/lugh/bridge` (nested inside `@home`, created by Bridge on first use) | no | Wine prefixes are large and change all the time |

Directories that need no subvolume of their own: `/tmp` is a tmpfs (systemd default); `/var/lib/flatpak`, `/var/lib/apt` and `/var/lib/dpkg` stay inside `@`, because package state must roll back together with the files it describes.

## Mount options

```
noatime,compress=zstd:1
```

- `noatime`: no metadata write on every read. This matters on Btrfs, where an atime update means copy-on-write metadata, and it makes snapshots diverge for no reason.
- `compress=zstd:1`: transparent compression at the cheapest zstd level. It saves about 30–50 % on system files at negligible CPU cost, and on most SSDs it is faster than not compressing.
- `discard=async` and `space_cache=v2` are already the kernel defaults on trixie (6.12) and are not written to fstab.
- `ssd` is auto-detected.

Example `/etc/fstab` written by the installer (UUIDs filled in):

```fstab
UUID=<btrfs-uuid>  /             btrfs  subvol=/@,noatime,compress=zstd:1           0 0
UUID=<btrfs-uuid>  /home         btrfs  subvol=/@home,noatime,compress=zstd:1       0 0
UUID=<btrfs-uuid>  /.snapshots   btrfs  subvol=/@snapshots,noatime,compress=zstd:1  0 0
UUID=<btrfs-uuid>  /var/log      btrfs  subvol=/@var_log,noatime,compress=zstd:1    0 0
UUID=<btrfs-uuid>  /var/cache    btrfs  subvol=/@cache,noatime,compress=zstd:1      0 0
UUID=<btrfs-uuid>  /var/tmp      btrfs  subvol=/@var_tmp,noatime,compress=zstd:1    0 0
UUID=<esp-uuid>    /boot/efi     vfat   umask=0077                                  0 1
```

Mounts use `subvol=/@` (by name) rather than `subvolid=`. After a rollback the new `@` has a different id but the same name, so neither fstab nor the kernel command line has to change. For the same reason the Btrfs **default subvolume is left at 5**: GRUB's `rootflags=subvol=@` selects the root.

## snapper

The installer creates the `root` config after the first boot-ready system is in place. `snapper create-config` would create its own nested `/.snapshots` subvolume inside `@`, which we don't want, so the installer does this:

```sh
umount /.snapshots
rmdir /.snapshots
snapper --no-dbus -c root create-config /
btrfs subvolume delete /.snapshots     # the nested one snapper just made
mkdir /.snapshots
mount /.snapshots                      # @snapshots, from fstab
chmod 750 /.snapshots
```

`/etc/snapper/configs/root` (values from system-base):

```ini
SUBVOLUME="/"
FSTYPE="btrfs"
TIMELINE_CREATE="no"
NUMBER_CLEANUP="yes"
NUMBER_LIMIT="12"
NUMBER_LIMIT_IMPORTANT="6"
SPACE_LIMIT="0.3"
FREE_LIMIT="0.2"
ALLOW_GROUPS="sudo"
SYNC_ACL="yes"
```

- **No timeline snapshots.** Snapshots are taken around changes (apt transactions, Lugh updates), not hourly. That keeps the list short enough to read in the boot menu and in the Store's update history.
- **Number cleanup with limits.** We keep at most 12 snapshots (6 marked important), never use more than 30 % of the filesystem, and always leave 20 % free. `snapper-cleanup.timer` enforces this.
- `ALLOW_GROUPS="sudo"` lets the first user list snapshots without root (the Store still goes through polkit to restore).
- `home` config: created but with `TIMELINE_CREATE="no"` and no apt hook; it is off until the user turns it on in Settings (open question in system-base: on by default for Standard?).

apt integration: trixie's `snapper` package (0.10.6) ships `/etc/apt/apt.conf.d/80snapper` (checked in Phase 0), which creates a pre/post pair around each dpkg run. Its description format still has to be checked on an installed system in Phase 1; if it doesn't read `apt: <command>`, `lugh-base-files` overrides the hook.

## Rollback

Debian mounts `/` by name (`subvol=@`), so `snapper rollback`, which switches the *default* subvolume, does nothing useful here. `lugh rollback <n>` renames subvolumes instead (from the top-level, mounted at a temporary path):

1. `btrfs subvolume snapshot /.snapshots/<n>/snapshot /mnt/top/@rollback-<date>` (read-write copy),
2. `mv /mnt/top/@ /mnt/top/@broken-<date>` (kept until cleanup),
3. `mv /mnt/top/@rollback-<date> /mnt/top/@`, then regenerate GRUB from the new root,
4. ask for a reboot.

`/home`, `/var/log` and `/var/cache` are separate subvolumes, so they are untouched by this.

## grub-btrfs

`grub-btrfs` (bootable snapshot entries in a "Lugh snapshots" submenu, plus `grub-btrfsd` to refresh them) is **not in Debian 13 trixie**, nor in trixie-backports (checked 2026-11-09: `apt-cache policy grub-btrfs` in the trixie build container finds no candidate). It has to be packaged in the Lugh repo (`packaging/grub-btrfs/`) as a Phase 1 task. It isn't needed in the live ISO.

Snapshot boot entries boot read-only. live-boot isn't involved; an `overlayfs` on `/` (grub-btrfs's `grub-btrfs-overlayfs` initramfs hook) makes the read-only snapshot usable enough to log in and choose "Restore".
