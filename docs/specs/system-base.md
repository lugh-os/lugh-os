# System Base — Spec

> Status: **Draft** · Owner phases: **0** (base, Btrfs layout, branding), **1** (profiles), **3** (update center) · Related ADRs: ADR-001, ADR-003, ADR-004, ADR-009, ADR-011, ADR-013, ADR-014, ADR-020, ADR-021

## Purpose

Defines what is on disk when Lugh is installed: the Debian base, package sets per profile, enabled services, filesystem layout and snapshots, kernel and drivers, apt sources, updates, and security defaults. Everything else in Lugh sits on top of this.

## User stories

- **Windows switcher:** "My Wi-Fi, sound, touchpad and graphics just work after install, and if an update breaks something I can go back from the boot menu."
- **Linux power user:** "It's plain Debian underneath: deb822 sources, systemd, Btrfs with snapper. Nothing proprietary or magic that I can't inspect."
- **Minimal user:** "The Minimal profile really is minimal: desktop, Firefox and VLC, with low RAM use and no background junk."

## Requirements

### Functional
- **FR-1** The base is Debian 13 "Trixie", amd64, with components `main contrib non-free non-free-firmware` (ADR-001).
- **FR-2** Four install profiles are available: **Minimal** and **Standard** (choose one), plus the optional extras **Gaming** and **Developer**, which can be combined with either (see [installer](installer.md) §Profiles).
- **FR-3** Firmware for common Wi-Fi, Bluetooth, GPU and audio hardware, plus CPU microcode, is installed by default.
- **FR-4** Default filesystem is Btrfs with the subvolume layout in §Design, automatic pre/post snapshots on every apt transaction, and bootable snapshots (ADR-009).
- **FR-5** Swap uses zram. There is no disk swap by default.
- **FR-6** Firefox comes from Mozilla's APT repository and has priority over `firefox-esr` (ADR-011).
- **FR-7** No office suite is installed in any profile (ADR-013).
- **FR-8** Security updates from `Debian-Security` are applied automatically with a snapshot taken first. Other updates are offered through the Store's update center ([store](store.md)).
- **FR-9** Inbound connections are denied by default, AppArmor is enforcing, and no SSH server runs by default.
- **FR-10** Secure Boot works out of the box with Debian's signed shim, GRUB and kernel. Third-party DKMS modules (e.g. NVIDIA) are signed with a machine-owner key (MOK) enrolled at install.
- **FR-11** `/etc/os-release` identifies the system as Lugh while keeping `ID_LIKE=debian`, so tooling that checks for Debian still works.
- **FR-12** No telemetry. `popularity-contest` is not installed.

### Non-functional
- **NFR-1 Idle RAM** (whole session, measured after 60 s idle in QEMU with 4 GB RAM): Minimal ≤ 450 MB, Standard ≤ 750 MB (VISION §12).
- **NFR-2 Boot** to the greeter: ≤ 12 s on NVMe. No unit may add more than 1 s to the critical chain (`systemd-analyze critical-chain`) without a recorded reason.
- **NFR-3 Disk footprint** after install: Minimal ≤ 6 GB, Standard ≤ 9 GB (excluding snapshots).
- **NFR-4 Hardware floor:** x86-64-v2 CPU, 4 GB RAM (8 GB recommended), 40 GB disk, UEFI recommended (legacy BIOS only in Advanced).
- **NFR-5 Accessibility:** Orca and an on-screen keyboard are installed in every profile but off by default, so a blind or motor-impaired user can turn them on from the greeter.

## Design

### Package sets

Package names are Debian 13 names unless marked **(Lugh repo)**. Packages marked *verify* must be confirmed as present in trixie during Phase 0, and are moved to the Lugh repo if they aren't.

**Core (every profile)**
| Area | Packages |
|---|---|
| Kernel & boot | `linux-image-amd64`, `grub-efi-amd64-signed`, `shim-signed`, `efibootmgr`, `grub-btrfs` (*verify*), `plymouth`, `lugh-plymouth-theme` (Lugh repo), `lugh-grub-theme` (Lugh repo) |
| Firmware & microcode | `firmware-linux`, `firmware-misc-nonfree`, `firmware-iwlwifi`, `firmware-realtek`, `firmware-atheros`, `firmware-brcm80211`, `firmware-amd-graphics`, `firmware-sof-signed`, `intel-microcode`, `amd64-microcode` |
| Graphics | `mesa-vulkan-drivers`, `libgl1-mesa-dri`, `libegl1`, `vulkan-tools` (newer Mesa from the Lugh repo, see §Kernel & graphics) |
| Session | `greetd`, `lugh-greeter`, `lugh-session`, `lugh-shell`, `hyprland` (interim, Phases 1–4), `xwayland`, `lugh-branding`, `lugh-base-files` (os-release, defaults) — all Lugh repo except greetd and xwayland |
| Plumbing (ADR-020) | `pipewire`, `pipewire-pulse`, `pipewire-alsa`, `wireplumber`, `libspa-0.2-bluetooth`, `network-manager`, `bluez`, `upower`, `power-profiles-daemon`, `polkitd`, `gnome-keyring`, `libpam-gnome-keyring`, `xdg-desktop-portal`, `xdg-desktop-portal-gtk`, `xdg-desktop-portal-hyprland` (interim), `fwupd`, `flatpak`, `packagekit` |
| Filesystem | `btrfs-progs`, `snapper`, `dosfstools`, `ntfs-3g`, `exfatprogs`, `udisks2` |
| Memory | `zram-tools`, `systemd-oomd` |
| Security | `apparmor`, `apparmor-profiles`, `firewalld`, `unattended-upgrades` |
| Fonts (ADR-021) | `fonts-inter`, `fonts-jetbrains-mono`, `fonts-noto-core`, `fonts-noto-color-emoji` |
| Accessibility | `orca`, `onboard` (or the Lugh on-screen keyboard once it exists) |
| Apps | `firefox` (Mozilla repo), `vlc`, `foot` (terminal), `pcmanfm-qt` (file manager, launched as **Files** via the `lugh-files.desktop` wrapper) |

**Minimal** = Core. Nothing else.

**Standard** = Core +
| Purpose | Package | Why this one |
|---|---|---|
| Image viewer | `qimgv` | Qt, fast and light; Gwenview pulls in many KDE Frameworks |
| PDF viewer | `qpdfview` | Qt, small, tabs and search; Okular is heavier |
| Archive manager | `lxqt-archiver` | Qt, light, handles zip/7z/rar via `7zip`, `unrar-free` |
| Text editor | `featherpad` | Qt, light, readable defaults |
| Calculator | `qalculate-qt` *verify* | familiar calculator with unit conversion |
| Printing | `cups`, `cups-browsed`, `ipp-usb`, `avahi-daemon`, `printer-driver-gutenprint`, `system-config-printer-common` | driverless IPP printers work out of the box |
| Lugh apps | `lugh-store`, `lugh-bridge`, `lugh-tasks`, `lugh-settings`, `lugh-welcome` (Lugh repo) | |
| Thumbnails & codecs | `ffmpegthumbnailer`, `gstreamer1.0-plugins-good`, `gstreamer1.0-plugins-bad`, `gstreamer1.0-libav` | |

> Lugh Settings, Tasks and the Lughfile CLI are also installed in **Minimal**, because they are part of the desktop rather than "apps". Minimal leaves out only the Store and Bridge UIs, and adding them later is one command (`lugh profile add standard`).

**Gaming extra** = `steam-installer` (contrib, enables `i386` multiarch), `mesa-vulkan-drivers:i386`, `libgl1-mesa-dri:i386`, `gamemode`, `mangohud`, `lugh-bridge-gaming` (umu runtime + profiles, Lugh repo), `game-devices-udev` *verify* (controller rules).

**Developer extra** = `git`, `build-essential`, `curl`, `podman`, `podman-docker`, `distrobox`, `openssh-server` (installed **disabled**), `lugh-dev-toolchains` (meta-package with selectable toolchains: rustup, nodejs, python3-venv, golang, openjdk), plus the IDE chosen in the installer (VISION §16 open question: VSCodium, VS Code or Zed).

### Services

| Enabled by default | Notes |
|---|---|
| `greetd`, `NetworkManager`, `bluetooth`, `upower`, `power-profiles-daemon` | `bluetooth` starts only when an adapter exists (ConditionPathExists) |
| `firewalld`, `apparmor` | |
| `systemd-timesyncd`, `systemd-oomd`, `zramswap` | |
| `snapper-cleanup.timer`, `grub-btrfsd` | |
| `fwupd-refresh.timer`, `apt-daily.timer`, `apt-daily-upgrade.timer` (security only, see §Updates) | |
| `cups`, `avahi-daemon` | Standard only, **socket-activated** |
| User: `pipewire`, `wireplumber`, `pipewire-pulse`, `lugh-session.target` | |

Disabled or absent: `ssh`, `ModemManager` (installed only if a WWAN modem is detected at install), `cups-browsed` until the first printer is added, `NetworkManager-wait-online` (it slows boot). Lugh daemons are D-Bus-activated, never always-on (ARCHITECTURE §3).

### Filesystem layout (Btrfs, ADR-009)

| Subvolume | Mount point | Snapshotted | Notes |
|---|---|---|---|
| `@` | `/` | yes (snapper `root`) | includes `/boot`, so kernels roll back with the system |
| `@home` | `/home` | opt-in (snapper `home`, off by default) | |
| `@snapshots` | `/.snapshots` | n/a | |
| `@var_log` | `/var/log` | no | logs survive rollback, which helps debugging |
| `@cache` | `/var/cache` | no | apt cache excluded |
| `@var_tmp` | `/var/tmp` | no | |
| `@bridge` | `/home/<user>/.local/share/lugh/bridge` (created at first use, nested subvolume) | no | Wine bottles are large and change constantly |

Mount options: `noatime,compress=zstd:1`. The ESP is `/boot/efi` (FAT32, ≥ 300 MB on new installs; an existing ESP of ≥ 100 MB is reused when dual-booting).

**snapper `root` config** (`/etc/snapper/configs/root`):
```ini
TIMELINE_CREATE="no"
NUMBER_CLEANUP="yes"
NUMBER_LIMIT="12"
NUMBER_LIMIT_IMPORTANT="6"
SPACE_LIMIT="0.3"
FREE_LIMIT="0.2"
```
apt hooks (`snapper` ships `/etc/apt/apt.conf.d/80snapper`, *verify*; otherwise `lugh-base-files` provides it) create a pre/post pair per transaction, described as `apt: <command>`.

**Rollback.** `grub-btrfs` lists snapshots in a "Lugh snapshots" submenu, and they boot read-only. `lugh rollback <n>` (or the Store's update center → History → Restore) then:
1. creates a read-write snapshot of snapshot *n* named `@rollback-<date>`,
2. renames the current `@` to `@broken-<date>` (kept until cleaned up),
3. renames `@rollback-<date>` to `@` and regenerates GRUB,
4. asks for a reboot.

> Limit: Debian mounts `/` by subvolume name (`subvol=@`), so `snapper rollback` (which switches the *default* subvolume) is not used. Our rename approach does the same job. `/home` is never rolled back by this.

### Memory
- `zram-tools`: `ALGO=zstd`, `PERCENT=50`, priority 100.
- **No hibernation by default.** It needs a disk swap area equal to RAM, and the kernel lockdown under Secure Boot blocks it anyway. Suspend (s2idle or deep, whichever the firmware prefers) is the supported sleep mode.
- `systemd-oomd` is enabled with the user slice under memory-pressure kill, so a runaway app gets killed instead of the whole desktop freezing.

### Kernel & graphics
| Layer | Default | Option |
|---|---|---|
| Kernel | Debian `linux-image-amd64` (signed) | `trixie-backports` kernel (also Debian-signed). Chosen at install for very new hardware, or later in Settings → About → Kernel |
| Mesa | trixie-backports if it's recent enough, otherwise a **Lugh repo** build (userspace only, so no Secure Boot impact) | |
| NVIDIA | Nouveau/NVK (in-tree, signed, fine for desktop use) | `nvidia-driver` (non-free, DKMS) selected in the installer or Settings, with a MOK (see below) |

**Rule: Lugh does not ship its own kernel builds.** A Lugh-built kernel would need our own Secure Boot key and a MOK enrollment for every user. If backports can't cover some hardware, we revisit this with a new ADR.

### Secure Boot & MOK
- The boot chain is `shimx64.efi` (Microsoft-signed) → `grubx64.efi` (Debian-signed) → `vmlinuz` (Debian-signed).
- DKMS modules (NVIDIA, VirtualBox and so on) are signed with the Debian DKMS MOK (`/var/lib/dkms/mok.key`). The installer queues enrollment with `mokutil --import` and a one-time password, which the user enters in MokManager at the next boot (see [installer](installer.md) §Drivers).
- With Secure Boot on, the kernel runs in lockdown (integrity) mode. This is documented as expected (no hibernation, no unsigned modules).

### apt sources (deb822)

```
/etc/apt/sources.list.d/debian.sources     # trixie, trixie-updates, trixie-security (+ trixie-backports, disabled per-package via pinning)
/etc/apt/sources.list.d/lugh.sources       # repo.lugh  Suites: lugh1  (or lugh1-beta / lugh1-dev by channel)
/etc/apt/sources.list.d/mozilla.sources    # https://packages.mozilla.org/apt  Suites: mozilla
/etc/apt/keyrings/{lugh,mozilla}.asc
/etc/apt/preferences.d/
    10-mozilla      # Package: firefox*  Pin: origin packages.mozilla.org  Pin-Priority: 1000
    20-lugh         # Pin: origin repo.lugh  Pin-Priority: 600  (only lugh-* and packages we deliberately override)
    30-backports    # Pin: release a=trixie-backports  Pin-Priority: 100 (opt-in per package)
```
Example `lugh.sources`:
```
Types: deb
URIs: https://repo.lugh/debian
Suites: lugh1
Components: main
Signed-By: /etc/apt/keyrings/lugh.asc
```

### Updates (`lugh-updated`, `space.lugh.Update1`)
| Kind | Policy |
|---|---|
| Debian security | Downloaded and installed automatically (unattended-upgrades restricted to `origin=Debian,label=Debian-Security` + `lugh1-security`), with a snapper pre/post pair. If a reboot is needed (kernel, libc), the user gets a notification and **no forced reboot** |
| Everything else (apt) | Checked daily and downloaded in the background (skipped on metered connections), applied by the user in Store → Updates or at shutdown ("Update and shut down", like Windows) |
| Flatpak | Updated automatically once a day (`flatpak update --noninteractive`) |
| Firmware | `fwupd` checks weekly, and the user installs from the update center |
| Lugh components | Ordinary apt packages from the Lugh repo, following the channel (stable / beta / dev, see [build-and-release](build-and-release.md)) |

D-Bus (system bus, `/space/lugh/Update1`):
| Member | Kind | Notes |
|---|---|---|
| `Check() → (u count, b reboot_required)` | method | |
| `ListUpdates() → a(sssst)` | method | (id, source apt/flatpak/fwupd, name, version, size) |
| `Apply(as ids, b offline)` | method | polkit `space.lugh.update.apply`. `offline=true` means apply at the next shutdown |
| `ListSnapshots() → a(utss)` | method | (number, time, description, type) |
| `Rollback(u number)` | method | polkit `space.lugh.update.rollback` (admin) |
| `Progress(s id, d fraction, s stage)` | signal | |
| `RebootRequired(s reason)` | signal | |

### Security defaults
- **Firewall:** `firewalld`, default zone `lugh-public`: inbound denied except DHCPv6 client and mDNS. The "Home" network profile in Settings also allows KDE Connect/LocalSend-style ports on demand. Proposed new ADR: *firewalld over ufw, because it has a D-Bus API and NetworkManager zone integration that Settings can use.*
- **AppArmor:** enforcing (Debian default), plus `apparmor-profiles`. Shield uses its own mechanisms ([shield](shield.md)).
- **Accounts:** the first user is in `sudo`, root is locked, and the password hash is yescrypt (Debian default).
- **No listening services** on a fresh install apart from avahi (Standard). Verified in CI with `ss -tulpn` in the boot test.
- **Disk encryption:** LUKS2 with Argon2id, optional at install ([installer](installer.md)).
- **Kernel:** Debian defaults (mitigations on). `kernel.unprivileged_userns_clone=1` stays enabled because Shield, Flatpak and Steam need it.

### Locale, time, power
- Locale, keyboard and time zone are set by the installer. `systemd-timesyncd` is on. Automatic time zone (GeoClue) is opt-in under Settings → Privacy, matching `privacy.location = false` in [settings](settings.md).
- Power: `power-profiles-daemon` (Balanced by default, Power Saver on battery below 20%), and logind lid switch suspends. TLP is not installed because it conflicts with power-profiles-daemon.

### os-release (`lugh-base-files`)
```ini
PRETTY_NAME="Lugh 1"
NAME="Lugh"
VERSION_ID="1"
VERSION="1 (<codename>)"
VERSION_CODENAME=<codename>
ID=lugh
ID_LIKE=debian
HOME_URL="https://lugh.example/"   # placeholder until a domain exists
LOGO=lugh-logo
DEBIAN_VERSION=13
```
`/etc/debian_version` is left untouched.

## UX
The base system has little UI of its own. Its user-facing surfaces are:
- **Boot:** a Lugh-themed GRUB menu, hidden unless Shift/Esc is held or the last boot failed (`GRUB_RECORDFAIL`, timeout 0 on success). The menu shows "Lugh", "Lugh snapshots ›" and "Windows Boot Manager" when dual-booting.
- **Plymouth splash:** the logo with a subtle progress bar, light and dark variants following the theme, and LUKS passphrase entry styled the same way.
- **Update notifications and the rollback flow** live in the Store's update center ([store](store.md)).
- **Error state:** if the last boot failed, the GRUB menu appears with a "Start from last good snapshot" entry first.

## Security & privacy
- Signed apt sources only. The installer and `lugh-base-files` never add unsigned repos.
- No telemetry, no crash upload by default. Crash reports (`systemd-coredump`) stay local, and the user can choose to attach them to bug reports.
- Snapshots can contain deleted secrets. This is documented in Settings → Privacy, with a "Delete all snapshots" button.

## Testing
- **CI boot test** (see [build-and-release](build-and-release.md)): UEFI + Secure Boot (OVMF secboot vars) and BIOS. Checks that the greeter is reached, no failed units (`systemctl --failed`), no listening ports except the allowed list, and `/etc/os-release` is correct.
- **Snapshot test:** install a package in a VM, roll back with `lugh rollback`, reboot, and assert the package is gone and `/var/log` persisted.
- **Profile tests:** install each profile combination in QEMU, then measure disk footprint and idle RAM against NFR-1 and NFR-3.
- **Hardware smoke matrix** (Phase 7): Intel iGPU, AMD iGPU/dGPU, NVIDIA (NVK and proprietary), Wi-Fi chipsets (Intel, Realtek, MediaTek, Broadcom), and SOF laptop audio.

## Open questions
- Is `grub-btrfs` packaged in trixie, or do we carry it in the Lugh repo?
- File manager: keep `pcmanfm-qt` long-term or build **Lugh Files** in QML? (Shield and Bridge integrate best with a file manager we control.)
- Terminal: `foot` (fast, minimal) is the interim choice. Do we want a Lugh-styled terminal later?
- Should `@home` snapshots be on by default for the Standard profile?
