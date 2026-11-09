# Installer — Spec

> Status: **Draft** · Owner phases: **1** (Calamares + profiles), **3** (Lughfile restore), **6** (unattended preset for Windows Setup) · Related ADRs: ADR-008, ADR-009, ADR-010, ADR-011, ADR-013, ADR-014, ADR-018

## Purpose

The installer that runs from the Lugh ISO/USB. It is Calamares with Lugh branding, custom QML pages and custom modules. It has three ways in:
1. **Express**: a handful of screens for most people.
2. **Advanced**: manual partitioning, encryption, filesystem, drivers and Lughfile restore.
3. **Unattended**: driven by a preset file. Used by [Windows Setup](windows-setup.md) and by CI.

## User stories

- **Windows switcher:** "I pick my language, the kind of setup I want, which disk, my name and password, and it does the rest."
- **Linux power user:** "I can lay out partitions myself, choose LUKS, ext4 or Btrfs, and restore my whole setup from my Lughfile repo."
- **Minimal user:** "I choose Minimal and get desktop + Firefox + VLC. Nothing else gets installed behind my back."
- **Gamer with an NVIDIA card:** "The installer offers the right driver and tells me clearly what the blue Secure Boot screen will ask."

## Requirements

### Functional
- **FR-1** Express mode has at most 6 screens before installing: Welcome, Region & keyboard, Setup type (profile), Disk, Account, Summary.
- **FR-2** Disk choices in Express: **Erase disk**, **Install alongside** (uses free space or shrinks an existing partition, with a slider), **Replace a partition**. Advanced adds manual partitioning.
- **FR-3** Btrfs is the default filesystem with the subvolume layout from [system-base](system-base.md). ext4 is available in Advanced.
- **FR-4** LUKS2 full-disk encryption is optional (an Express checkbox "Encrypt this disk", and an Advanced option).
- **FR-5** Profiles: choose **Minimal** or **Standard**, plus the optional extras **Gaming** and **Developer** (combinable).
- **FR-6** Drivers: if an NVIDIA GPU is detected, offer "NVIDIA driver (recommended for gaming)" with Secure Boot MOK handling (§Drivers).
- **FR-7** Lughfile restore: accept a git URL (https or ssh). Install the system packages it lists during installation, then apply the user-level parts at first login.
- **FR-8** Unattended mode reads a preset file (§Unattended preset) and installs without UI except a progress screen. It must never modify partitions outside the region the preset allows.
- **FR-9** Offline install works for Minimal and Standard (packages from the ISO pool). Gaming and Developer extras need a network connection, which is detected up front and explained.
- **FR-10** After install, the first boot opens **Welcome** ([settings](settings.md) owns the Welcome flow content; the installer only schedules it).
- **FR-11** OEM mode (preinstall, then the user creates the account on first boot) is designed for, but not shipped before Phase 7.

### Non-functional
- **NFR-1 Speed:** Minimal install on NVMe completes in ≤ 6 min. Standard (offline) in ≤ 9 min.
- **NFR-2 Safety:** no destructive disk action without a final summary that lists each change in plain language. Erasing requires an explicit confirmation.
- **NFR-3 Accessibility:** fully keyboard-operable. Orca can be started from the live session (Super+Alt+S). All text meets AA. Usable at 1280×720.
- **NFR-4 Localization:** all Lugh pages are translatable (Qt `.ts`). Calamares' own translations are used for stock modules. Kinyarwanda (rw), English, French and Swahili are the first translation targets.

## Design

### Components
| Package | Contents |
|---|---|
| `calamares` (Debian) | the framework |
| `lugh-calamares-config` (Lugh repo) | `/etc/calamares/settings.conf`, module configs, branding (`/etc/calamares/branding/lugh/`), QML pages, custom modules |
| `lugh-calamares-unattended` (Lugh repo) | `/etc/calamares-unattended/` (alternate config dir used with `calamares -c`) |

### Module sequence (`settings.conf`)
```yaml
sequence:
  - show:
      - welcome          # Lugh QML page: language, "Try Lugh" vs "Install", network status, requirements check
      - locale           # region + time zone (map), auto-detected via GeoIP only if online and the user allows it
      - keyboard
      - lughprofiles     # custom QML view module (Setup type + extras + drivers)
      - partition        # Express choices; Advanced exposes manual
      - users            # name, username, password, hostname (Advanced), autologin (Advanced)
      - lughadvanced     # custom: Lughfile URL, kernel (backports), filesystem, IDE choice — only in Advanced
      - summary
  - exec:
      - partition
      - mount
      - unpackfs         # copies the live squashfs (= Core profile + live bits)
      - machineid
      - fstab
      - locale
      - keyboard
      - localecfg
      - luksbootkeyfile
      - users
      - displaymanager   # greetd + lugh-greeter
      - networkcfg
      - hwclock
      - lughbtrfs        # custom shellprocess: subvolumes, snapper config, grub-btrfs (system-base.md)
      - packages         # remove live-only pkgs; install profile meta-packages from ISO pool / network
      - lughdrivers      # custom: NVIDIA + MOK, firmware extras detected via modalias
      - lughlughfile     # custom: clone Lughfile, install its apt packages, schedule first-boot apply
      - services-systemd
      - initramfscfg
      - initramfs
      - bootloader       # GRUB EFI via shim; os-prober enabled when other OSes are found
      - grubcfg
      - lughfirstboot    # custom: enable lugh-welcome for the new user
      - umount
  - show:
      - finished         # "Restart now" (+ MOK instructions if queued)
```
Custom modules are Python jobs (`/usr/lib/calamares/modules/lugh*`) and QML view modules for pages. They share state through Calamares **GlobalStorage** keys prefixed `lugh.` (for example `lugh.profile`, `lugh.extras`, `lugh.lughfileUrl`, `lugh.nvidia`).

### Profiles (`lughprofiles`)
Data file `/etc/calamares/modules/lughprofiles.conf`:
```yaml
base:
  - id: minimal
    name: tr("Minimal")
    description: tr("Desktop, Firefox and VLC. Add anything later from the Store.")
    packages: [lugh-desktop-core]
  - id: standard
    default: true
    name: tr("Standard")
    description: tr("Everyday apps: images, PDFs, archives, printing, Store and Windows app support.")
    packages: [lugh-desktop-core, lugh-profile-standard]
extras:
  - id: gaming
    name: tr("Gaming")
    description: tr("Steam, game tuning, Windows game support.")
    packages: [lugh-extra-gaming]
    needsNetwork: true
    enablesMultiarch: [i386]
  - id: developer
    name: tr("Developer")
    description: tr("Code editor, Git, containers and language tools.")
    packages: [lugh-extra-developer]
    needsNetwork: true
    options:
      ide: [vscodium, vscode, zed, none]     # VISION §16 open question decides the default
```
Profiles are meta-packages ([build-and-release](build-and-release.md) §Packaging), so the same choice can be made later with `lugh profile add gaming`.

### Partitioning defaults
| Choice | Result |
|---|---|
| Erase disk (UEFI) | GPT: ESP 512 MB FAT32 · root Btrfs (rest) · no swap partition (zram) |
| Erase disk + encrypt | ESP · LUKS2 (Argon2id) → Btrfs. GRUB unlocks nothing; `/boot` lives inside the encrypted root with a keyfile in the initramfs (`luksbootkeyfile`), so the passphrase is asked once by Plymouth |
| Alongside | reuses the existing ESP if ≥ 100 MB (warns if < 256 MB and the NVIDIA extra is chosen), and creates Btrfs in free space |
| BIOS (Advanced only) | MBR or GPT with `bios_grub` 1 MB partition |

> Encryption note: Debian's signed GRUB can read LUKS2 only with PBKDF2, not Argon2id. To avoid weakening LUKS, we keep `/boot` **inside** the encrypted root using the Calamares keyfile approach, and GRUB asks for the passphrase. If this proves fragile, the fallback is a separate unencrypted `/boot` (decided in Phase 1 testing; record as an ADR).

### Drivers (`lughdrivers`)
1. Detect GPUs via `/sys/bus/pci/devices/*/vendor` (`0x10de` = NVIDIA).
2. If NVIDIA is present and the GPU is supported by the current `nvidia-driver` series, offer the driver (pre-checked when the Gaming extra is chosen).
3. If Secure Boot is enabled (`mokutil --sb-state`):
   - ensure the DKMS MOK exists (`/var/lib/dkms/mok.key`, `mok.pub`),
   - generate an 8-digit one-time password and run `mokutil --import mok.pub` with it,
   - show it on the **Finished** page with an illustrated walkthrough: *"After restart you'll see a blue screen: choose Enroll MOK → Continue → Yes → type 12345678 → Reboot."*
4. If enrollment is skipped or fails, the system still boots on Nouveau/NVK. Settings → Drivers can retry.
5. Other detected hardware gets packages from a modalias map (`lugh-hwdb`), e.g. Broadcom `broadcom-sta-dkms` (also MOK) or specific firmware.

### Lughfile restore (`lughlughfile`)
1. In Advanced (and via an Express link "Restore my setup from a Lughfile"), the user enters a git URL. For private repos: an HTTPS token (kept only in memory, used for this clone only) or a generated SSH deploy key shown for copying.
2. Clone into the target as `/home/<user>/.config/lugh/` (owned by the user).
3. Run `lugh check` in the target chroot. It validates `lugh.toml` (schema in [lughfile](lughfile.md)). Errors are shown and the user can continue without restoring.
4. During install, run `lugh apply --system-only` in the chroot (apt packages, system services, `/etc/lugh/system.toml`). Profile selection is shown as "From your Lughfile" and is locked.
5. Install `lugh-firstboot-apply.service` (a user unit, runs once) to do `lugh apply --user` at first login (Flatpaks, Bridge bottles, dotfiles, desktop settings), with progress shown in Welcome.

### Unattended preset (used by Windows Setup and CI)
Located by the kernel parameter `lugh.preset=<device>:<path>`, e.g. `lugh.preset=LABEL=LUGH-SETUP:/preset.toml`. The live session's `lugh-unattended.service` reads it and starts `calamares -c /etc/calamares-unattended`. That config dir has the same `exec` sequence and a `show` sequence of only a branded progress page and Finished.

```toml
version = 1
source = "windows-setup"            # windows-setup | ci | oem
session_id = "6f1c…"                # matches the Windows Setup journal

[locale]
language = "en_US.UTF-8"
timezone = "Africa/Kigali"
keyboard = { layout = "us", variant = "" }

[profile]
base = "standard"
extras = ["gaming"]
developer_ide = "none"

[account]
full_name = "Amani Uwase"
username = "amani"
password_hash = "$6$rounds=656000$…"   # sha512-crypt; never plaintext
autologin = false
hostname = "lugh-laptop"

[disk]
mode = "free-region"                # free-region | erase-disk (CI only)
disk_serial = "S4EVNX0N123456"
region_start_bytes = 256060514304
region_end_bytes  = 512110190592
filesystem = "btrfs"
encrypt = false                     # if true: a passphrase screen is shown (secrets never go in presets)

[boot]
default_os = "lugh"                 # lugh | windows
timeout_seconds = 5

[drivers]
nvidia = "auto"                     # auto | yes | no

[lughfile]
url = ""                            # optional

[after]
cleanup_setup_partition = true      # see windows-setup.md §Cleanup
reboot = true
```
Safety rules enforced by the `lughpreset` module before any write:
- The disk is matched by **serial and size**. Abort if there's no exact match.
- The region must be **unallocated** and within the disk, and must not overlap any partition. Otherwise abort.
- On abort: write a reason to `/lugh-setup/result.json` on the setup partition, set no boot changes, and reboot. Windows Setup reads that file and offers Retry or Undo ([windows-setup](windows-setup.md)).

### First boot
- `lughfirstboot` enables `lugh-welcome` autostart for the new user (Welcome: theme light/dark, desktop mode Lugh/Classic/Focus, Lughfile sync setup, featured apps including the LibreOffice/OnlyOffice suggestion per ADR-013, Bridge introduction).
- Live-only packages (`calamares`, `live-boot`, `live-config`, `lugh-live-session`) are removed by the `packages` job.

## UX

### Express flow
```
[Welcome] → [Region & keyboard] → [Setup type] → [Disk] → [Account] → [Summary] → (Installing…) → [Done]
  Try / Install   map + layout test   Minimal|Standard    Erase|Alongside   name/user/pw   plain-language list
                                      + Gaming + Dev        |Replace         + encrypt?     of every change
                                      + NVIDIA (if found)
```
- An **Advanced** toggle sits at the bottom left of every page. Switching it on adds the `lughadvanced` page and manual partitioning, and never loses what was entered.
- **Installing** shows a branded slideshow (what's in Lugh: modes, Store, Bridge, Shield, Lughfile), a real progress bar with the current step, and "Show details" for the log.
- **Done:** "Restart now", plus MOK instructions if they apply.

### States
| State | Behaviour |
|---|---|
| Loading | disk scan with a skeleton list (< 2 s typical) |
| Empty | no disk found: explains RAID/RST mode (*"Your disk may be in Intel RST/RAID mode. Switch to AHCI in firmware settings."*) with a link to the guide |
| Error (requirements) | blocks only for hard failures (no disk ≥ 25 GB, < 2 GB RAM). Warnings (no network, battery, BIOS mode) can be dismissed |
| Error (during install) | stops, shows the failed step in plain language, "Save log to USB" and "Copy log". The disk state is described honestly ("Your Windows partition was not changed" / "The new partition was created but is empty") |
| No network | the Gaming and Developer extras are greyed out with "Connect to the internet to add this", plus a network button that opens the shell's Wi-Fi panel |

### Keyboard
Enter = Next, Esc = Back (with confirmation if it would discard input), Alt+A toggles Advanced, Tab moves through controls, and the focus ring is always visible.

## Security & privacy
- Passwords are passed to the `users` module in memory only. Presets contain only a hash.
- Lughfile tokens are never written to disk. SSH deploy keys are generated in the target user's `~/.ssh` with 0600 permissions, so the user can keep using them.
- GeoIP time zone lookup is opt-in (a privacy toggle on the Region page) and goes to a Lugh-hosted endpoint, not a third party.
- The installer log is scrubbed of passwords and tokens before saving (Calamares already masks the `users` job; the Lugh modules must do the same).

## Testing
- **CI:** unattended installs for each profile combination, plus encrypt=true with the passphrase injected through a test-only stdin hook ([build-and-release](build-and-release.md) §QEMU boot tests).
- **Safety tests:** presets with a wrong serial, an overlapping region, or a region beyond the disk end must abort before any write. Verified by comparing partition tables before and after (`sfdisk -d`).
- **Manual matrix (each phase release):** erase/alongside/replace × UEFI/BIOS × encrypt on/off × Btrfs/ext4. Dual boot with Windows 11 (BitLocker on and off).
- **NVIDIA:** MOK flow on at least one real Secure Boot laptop before Phase 3 ships the Gaming extra broadly.
- **Accessibility:** full keyboard-only pass, plus an Orca run-through of Express.

## Open questions
- `/boot` inside LUKS vs a separate `/boot` (decide in Phase 1).
- Default IDE for the Developer extra (VISION §16).
- Should Express show the Lughfile link, or only Advanced?
- OEM mode scope and timing (Phase 7?).
