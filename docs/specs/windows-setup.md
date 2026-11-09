# Windows Setup (`LughSetup.exe`) — Spec

> Status: **Draft** · Owner phase: **6** (R&D can start after Phase 1) · Related ADRs: ADR-006, ADR-008, ADR-009, ADR-022

## Purpose

A normal Windows app that installs Lugh next to Windows (or instead of it) **without a USB stick, without BIOS menus, and without the user ever seeing a partition editor**. It prepares the disk from inside Windows, hands off to Lugh's [unattended installer](installer.md), and the PC restarts straight into Lugh.

## User stories

- **Windows switcher:** "I download an app, click Install, choose how much space to give Lugh, type my name and password, restart, and I'm in Lugh. Windows is still there."
- **Careful user:** "Before anything changes, it tells me exactly what will happen, makes me save my BitLocker key, and gives me an Undo if I change my mind."
- **Power user:** "Advanced lets me pick the disk, use an ISO I already downloaded, make a bootable USB instead, or replace Windows completely."

## Requirements

### Functional
- **FR-1** Runs on Windows 10 22H2 and Windows 11 (x64), elevated (manifest `requireAdministrator`).
- **FR-2** The pre-flight checks in §Checks pass or are explained, and are resolved with consent before any change.
- **FR-3** Shrinks the Windows (C:) partition through the Windows Storage Management API, never by writing raw NTFS ourselves.
- **FR-4** Creates a temporary **LUGH-SETUP** FAT32 partition holding the live system and a preset, and leaves the Lugh target space unallocated.
- **FR-5** Installs a one-time UEFI boot entry so the next restart boots the Lugh installer. Following restarts go back to normal.
- **FR-6** Writes a preset ([installer](installer.md) §Unattended preset) with locale, account (password **hash**), profile, target region and boot preferences.
- **FR-7** After a successful install, Lugh removes LUGH-SETUP at first boot, grows its own partition into that space, and removes the setup boot entry.
- **FR-8** Every step before the restart is **reversible** from the app (Undo). Failure in the installer leaves Windows untouched and returns to Windows with a clear message.
- **FR-9** Advanced: choose the disk and size manually, use a local ISO, replace Windows entirely (erase), write a bootable USB, or just download the ISO.
- **FR-10** Downloads are resumable and verified (SHA-256 + Lugh signature) before use.

### Non-functional
- **NFR-1** Time from clicking Install to the restart prompt: ≤ 10 min on a 50 Mbit/s connection (download-bound), ≤ 2 min with a local ISO.
- **NFR-2** Size: ≤ 40 MB executable bundle.
- **NFR-3** Zero data loss: the app refuses rather than guesses (unknown layouts, RAID, dynamic disks, Storage Spaces).
- **NFR-4** Accessible: works with Narrator, full keyboard operation, AA contrast, follows Windows text scaling.
- **NFR-5** Localized like the installer (en, rw, fr, sw first).

## Design

### Technology
Rust core + Qt 6/QML UI through cxx-qt (ADR-006), bundled with the needed Qt DLLs (windeployqt). Windows APIs are called through the `windows` crate:
- WMI / CIM `root\Microsoft\Windows\Storage`: `MSFT_Disk`, `MSFT_Partition` (`GetSupportedSize`, `Resize`, `CreatePartition`), `MSFT_Volume` (`Format`)
- `root\CIMV2\Security\MicrosoftVolumeEncryption`: `Win32_EncryptableVolume` (BitLocker)
- `GetFirmwareType`, `GetSystemPowerStatus`, registry reads, and `bcdedit.exe` (invoked with full path and checked exit codes)

### Pipeline
```
[Checks] → [Plan] → [Consent] → (Journal begins)
  1 BitLocker: back up key, suspend (RebootCount=2)
  2 Fast Startup/hibernation off
  3 Download + verify image (or verify local ISO)
  4 Shrink C:            ← reversible: extend C: back
  5 Create LUGH-SETUP    ← reversible: delete partition
  6 Copy live files + write preset.toml
  7 Copy boot files to ESP \EFI\lugh-setup\
  8 Create BCD firmware entry + one-time BootNext
→ [Restart prompt] → Lugh unattended install → first boot cleanup
```
Each completed step is appended to `C:\ProgramData\LughSetup\journal.json`:
```json
{ "session_id": "6f1c…", "version": "1.0.0",
  "steps": [
    {"id":"bitlocker_suspend","done":true,"undo":{"resume":"C:"}},
    {"id":"hibernate_off","done":true,"undo":{"hibernate":"on"}},
    {"id":"shrink","done":true,"undo":{"extend_to_bytes":512110190592,"partition":"{guid}"}},
    {"id":"setup_partition","done":true,"undo":{"delete":"{guid}"}},
    {"id":"esp_files","done":true,"undo":{"delete_dir":"\\EFI\\lugh-setup"}},
    {"id":"bcd_entry","done":true,"undo":{"bcd_delete":"{guid}"}}
  ] }
```
**Undo** replays the undo actions in reverse order.

### Checks
| Check | How | Outcome |
|---|---|---|
| UEFI firmware | `GetFirmwareType` | Legacy BIOS → one-click path blocked. Offer Advanced → bootable USB |
| GPT system disk | `MSFT_Disk.PartitionStyle` | MBR → block (same as above) |
| Free space | `MSFT_Partition.GetSupportedSize` on C: | need ≥ 25 GB shrinkable (40 GB recommended) plus image size for LUGH-SETUP. Otherwise explain what to free |
| BitLocker / Device Encryption | `Win32_EncryptableVolume.GetProtectionStatus` | On → key backup screen, then `SuspendKeyProtectors(2)` |
| Fast Startup / hibernation | registry `HiberbootEnabled`, `powercfg /a` | On → turned off with consent (`powercfg /h off`), recorded for undo |
| Pending Windows Update restart | registry `RebootRequired` keys | ask the user to restart first |
| Storage controller in RAID/RST mode | `Win32_SCSIController` / PnP IDs for Intel RST VMD | block with a guide: Linux can't see the NVMe disk in this mode, and switching to AHCI needs a Windows safe-mode step |
| Dynamic disk / Storage Spaces | `MSFT_Disk`, `MSFT_StoragePool` | block |
| Laptop on battery | `GetSystemPowerStatus` | require AC power |
| Secure Boot | `Confirm-SecureBootUEFI` equivalent (registry `UEFISecureBootEnabled`) | info only. Lugh boots with Secure Boot on |
| ESP free space | mount ESP (`mountvol S: /S`), check free | need ≥ 10 MB (shim + GRUB ≈ 3 MB) |
| Disk health | `MSFT_PhysicalDisk.HealthStatus` | warn if not Healthy |
| Windows S mode | `Get-WindowsEdition`/registry | block (can't run unsigned-store apps or bcdedit) |

### Partition plan
Typical Windows 11 layout: `[ESP][MSR][C: Windows][Recovery]`. After Setup:
```
[ESP][MSR][C: Windows (shrunk)][ unallocated → Lugh root ][LUGH-SETUP 5 GB][Recovery]
```
- LUGH-SETUP is placed **at the end** of the freed region, immediately after the future Lugh root, so Lugh can absorb it later.
- The Windows Recovery partition is **never moved or resized** (known Windows update failures come from tampering with it).
- LUGH-SETUP: FAT32, label `LUGH-SETUP`, size = image size + 1 GB (≈ 5 GB). Contents: the ISO's `live/` (squashfs, kernel, initrd), the `pool/` needed for the chosen profile, `boot/grub/`, `preset.toml`, `lugh-setup.json` (session metadata).

### Boot entry
1. Copy `shimx64.efi`, `grubx64.efi`, `mmx64.efi` and a minimal `grub.cfg` to `S:\EFI\lugh-setup\`.
2. That `grub.cfg` does: `search --label LUGH-SETUP --set=root`, then `linux /live/vmlinuz boot=live live-media=/dev/disk/by-label/LUGH-SETUP lugh.preset=LABEL=LUGH-SETUP:/preset.toml quiet splash` and `initrd /live/initrd.img`.
3. Run `bcdedit /copy {bootmgr} /d "Lugh Setup"` and capture the new `{guid}`.
4. Run `bcdedit /set {guid} path \EFI\lugh-setup\shimx64.efi`.
5. Run `bcdedit /set {fwbootmgr} bootsequence {guid}`. This is a **one-time** next boot. The permanent boot order is unchanged.
6. Fallback if the firmware ignores BootNext (some do): the restart screen tells the user which key opens the boot menu, based on a manufacturer lookup table (F12 Dell/Lenovo, F9 HP, Esc ASUS…), and to choose "Lugh Setup".

### Download & verify
- Source: an HTTPS mirror list from `https://lugh.example/releases/stable.json` (placeholder domain) containing the version, size, SHA-256 and signature URL.
- Resumable download (HTTP Range) to `C:\ProgramData\LughSetup\cache\`.
- Verify the SHA-256, then verify the detached signature over `SHA256SUMS` with the **embedded** Lugh release public key (rpgp crate). On mismatch: delete and retry once, then stop with an error.
- The image is read with Windows' `Mount-DiskImage` equivalent (`AttachVirtualDisk`), or with a built-in ISO 9660 reader if mounting is blocked by policy.

### Handoff to the installer
- `preset.toml` follows [installer](installer.md) §Unattended preset. Setup fills in:
  - `locale`: from the Windows display language. `keyboard`: mapped from the active input layout (KLID → XKB table). `timezone`: Windows TZ → IANA (CLDR `windowsZones.xml` table bundled).
  - `account.password_hash`: sha512-crypt computed locally. The plaintext is wiped from memory right after.
  - `disk`: serial and the exact byte range of the unallocated region, measured **after** the shrink.
  - `boot.default_os`: user choice (default Lugh, 5 s menu showing Windows).
- The installer writes `/result.json` back to LUGH-SETUP on failure (see below).

### Post-install cleanup (in Lugh, first boot)
`lugh-setup-cleanup.service` (oneshot, system, runs only if `/etc/lugh/setup-session` exists):
1. Confirm the session id matches the LUGH-SETUP partition's `lugh-setup.json`.
2. Delete the LUGH-SETUP partition (`sfdisk --delete`).
3. If it is directly after the Lugh root, grow root into the space (`growpart` → `btrfs filesystem resize max /`). Otherwise leave the space unallocated and log it.
4. Remove `\EFI\lugh-setup\` from the ESP and delete the "Lugh Setup" firmware entry (`efibootmgr -b XXXX -B`).
5. Remove `/etc/lugh/setup-session` and write a success note shown in Welcome.

### Failure & rollback
| When | What happens |
|---|---|
| Any step before restart fails | automatic Undo of completed steps. Explain and offer Retry |
| User clicks **Undo** before restarting | full Undo, back to the original state (BitLocker protectors resumed, hibernation restored) |
| Installer aborts before writing to disk (preset validation, hardware issue) | writes `result.json`, reboots. BootNext was one-time, so Windows starts. Setup (registered as a `RunOnce` entry for the user) opens and offers **Retry** or **Undo** |
| Installer fails after creating Lugh partitions | Windows partitions untouched. Same flow; Undo also deletes the Lugh partitions inside the recorded region only |
| Power loss during shrink | Windows' own resize is transactional at the NTFS level. Setup detects the incomplete journal on next launch and reconciles (re-reads the layout and offers Undo/Retry) |

### Advanced modes
| Mode | Behaviour |
|---|---|
| Custom size / disk | choose the target disk (any GPT disk with free or shrinkable space) and a size slider with min/recommended marks |
| Use local ISO | skip the download and verify the signature anyway (warn, and require an extra confirmation if it's unsigned) |
| Replace Windows | erase the whole disk. Three confirmations, typing `ERASE`, a BitLocker key reminder and a backup reminder. The preset uses `mode = "erase-disk"` |
| Create bootable USB | raw-write the ISO to a selected removable drive (with a "this will erase <drive name, size>" confirmation) |
| Download only | save and verify the ISO |

### Signing & distribution
- `LughSetup.exe` is Authenticode-signed (OV/EV certificate, ADR pending with Phase 6). **Until a certificate with reputation exists, SmartScreen will warn.** The download page explains this honestly.
- The build is reproducible in CI ([build-and-release](build-and-release.md)), and the SHA-256 is published next to the download.
- Setup checks `stable.json` for a newer Setup version and prompts to update itself.

## UX

### Screens
1. **Welcome:** logo, one sentence ("Install Lugh next to Windows. Your files stay where they are."), **Get started**, and an Advanced link.
2. **Checking your PC:** a checklist that animates in. Each item is ✓ / ⚠ / ✕ with a plain-language fix.
3. **Space:** a disk bar showing Windows | Lugh with a draggable split and labels ("Windows keeps 180 GB, 62 GB used · Lugh gets 120 GB").
4. **You:** full name, username (auto-suggested), password + confirm, setup type (Minimal / Standard + Gaming / Developer), and "Start Lugh by default" toggle.
5. **BitLocker** (only if needed): shows the recovery key, offers Save to file / Print / "I've written it down", and requires a checkbox before continuing.
6. **Summary:** "Here's what will happen", a numbered list of every change, plus "Nothing has changed yet." Buttons: **Install** / Back.
7. **Preparing:** download progress with speed and ETA, then verify, then the disk steps. Cancel is always available and runs Undo.
8. **Ready to restart:** "Restart now" / "Later". Also shows the boot-menu key fallback for this PC model.
9. (In Lugh) **Unattended progress**, then **Welcome**.

### States
- Empty/blocked: when a hard check fails, the screen shows only that problem, its cause, and the guide link or Advanced alternative.
- Loading: skeleton checklist. The disk bar shows a shimmer until `GetSupportedSize` returns (it can take 10–30 s on large disks; show "Measuring how much space Windows can free…").
- Error: plain language with a "Copy details" button for support (the journal plus the last 200 log lines from `C:\ProgramData\LughSetup\logs\`).

## Security & privacy
- Runs elevated, so the attack surface is kept small: no plugins, no web view, no remote code. Only signed images are used.
- Downloads are over HTTPS and signature-verified with the embedded key, so a compromised mirror can't deliver a bad image.
- The password is hashed locally. The preset sits on a FAT partition readable by anyone with physical access until first boot, so it contains only a salted hash. The partition is deleted at first boot.
- The BitLocker recovery key is never sent anywhere. It is displayed or saved only where the user chooses.
- No telemetry. An optional "send anonymous install result" is off by default (a decision for Phase 7).

## Testing
- **VM matrix** (QEMU + OVMF + swtpm, Windows 11 evaluation images): BitLocker on/off × Secure Boot on/off × recovery partition after C: × small ESP (100 MB) × Fast Startup on.
- **Fault injection:** kill the process after each journal step, then relaunch and verify reconciliation and Undo restore the exact original layout (compare `Get-Partition` snapshots).
- **Installer abort paths:** preset with a mismatched serial, so the PC must return to Windows with Retry/Undo offered.
- **Real hardware** before release: at least 5 OEM laptops (Dell, HP, Lenovo, ASUS, Acer), including one with Intel RST VMD enabled (must block correctly).
- Narrator walkthrough of all screens.

## Open questions
- Should we offer "Remove Lugh" later from Windows Setup (deletes Lugh partitions, extends C:, removes GRUB from the boot order)?
- Code-signing certificate: OV vs EV, and which vendor.
- Use the ISO as-is on LUGH-SETUP (needs a FAT-compatible layout) or a dedicated "setup image" format?
- Minimum Windows 10 build to support (22H2 is end-of-life since October 2025; do we support it anyway for switchers?).
