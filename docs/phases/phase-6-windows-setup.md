# Phase 6 — Windows Setup (`LughSetup.exe`)

> Status: Draft · Size: L · Depends on: Phase 1 (installer), Phase 3 (stable ISO + Lughfile restore); R&D may start earlier · Specs: [../specs/windows-setup.md](../specs/windows-setup.md), [../specs/installer.md](../specs/installer.md), [../specs/system-base.md](../specs/system-base.md) · ADRs: ADR-008, ADR-009

## Goal

A Windows user downloads `LughSetup.exe`, clicks **Install Lugh**, picks how much space to give it, and the PC reboots into an unattended install. It then comes back to a working dual-boot system (a GRUB menu offering Lugh and Windows) with no USB stick, no BIOS menus and no manual partitioning. Advanced users can set sizes manually, replace Windows entirely, or write a USB stick instead.

## Scope

**In**
- A signed Windows app (Rust + QML via cxx-qt, ADR-006) for Windows 10 22H2 and Windows 11, x64.
- Pre-flight checks: UEFI, Secure Boot state, BitLocker, Fast Startup/hibernation, free and shrinkable space, Windows version, power source, and pending Windows updates.
- Download with resume, SHA256 + signature verification, or use a local ISO.
- Shrinking the Windows partition, creating a temporary installer partition, placing boot files on the ESP, and a one-time boot entry.
- Handoff to an **unattended Calamares preset** (answers file).
- Post-install cleanup: remove the installer partition, extend the Lugh root, and set up a GRUB dual-boot menu with Windows (os-prober).
- Rollback/uninstall path from Windows (a "Remove Lugh" tool).
- Advanced mode: manual sizes, replace Windows entirely, or write a bootable USB.
- No telemetry. Not even anonymous counts unless the user opts in during Phase 7 crash reporting, and never from Setup itself.

**Out (deferred)**
- Legacy BIOS/MBR systems (Setup refuses and points to the USB route).
- ARM64 Windows devices.
- Installing onto a second physical disk automatically (it's offered only in Advanced, as a target choice).
- Migrating Windows user files or settings into Lugh (a future "Bring my files" feature).

## User flow (Express)

```
Welcome ─▶ Checks (auto-fix offers) ─▶ Space slider (default: 64 GB or 30% free, min 40 GB)
        ─▶ Profile (Minimal/Standard/Gaming/Developer) + user name + password + optional Lughfile URL
        ─▶ Summary + "Your BitLocker recovery key" confirmation (if BitLocker is on)
        ─▶ Download/verify ─▶ Prepare disk ─▶ Reboot ─▶ Unattended install (progress UI) ─▶ Lugh first boot
```

## Deliverables

| Deliverable | Path in repo | Package / artifact |
|---|---|---|
| Setup app (UI + engine) | `windows-setup/app/` | `LughSetup.exe` (signed) |
| Disk/boot engine (Rust library: checks, shrink, partition, ESP, bcdedit) | `windows-setup/engine/` | linked into `LughSetup.exe` |
| Remove-Lugh tool | `windows-setup/uninstall/` | `LughRemove.exe` (signed) or a mode of Setup |
| Answers preset format and writer | `windows-setup/engine/src/answers.rs` + `installer/presets/schema.toml` | n/a |
| Calamares unattended module and preset loader | `installer/modules/lughpreset/` | `lugh-calamares-config` |
| Post-install cleanup service (remove installer partition, grow root) | `packaging/installer/lugh-firstboot-cleanup.service` + script | `lugh-installer-firstboot` |
| GRUB dual-boot config (os-prober enabled, Windows entry naming) | `packaging/installer/grub.d/` | `lugh-branding` |
| Code-signing and release pipeline | `.github/workflows/windows-setup.yml` | CI |

## Work breakdown

### 1. Pre-flight checks (`engine/checks`)
- [ ] **Firmware**: UEFI versus legacy (`GetFirmwareType`). Legacy → refuse with USB guidance.
- [ ] **Secure Boot**: read state (`Confirm-SecureBootUEFI` / registry). On or off are both fine, since Debian's signed shim is used. Record it for the summary.
- [ ] **BitLocker**: query WMI `Win32_EncryptableVolume` (`root\CIMV2\Security\MicrosoftVolumeEncryption`), with a fallback to `manage-bde -status`. If it's on: require the user to confirm they have their recovery key (show where to find it: account.microsoft.com/devices/recoverykey, or a printout). Plan `Suspend-BitLocker -RebootCount 2` before rebooting.
- [ ] **Fast Startup / hibernation**: detect `HiberbootEnabled` and the hiberfile. Offer a one-click fix (`powercfg /h off`) and explain that NTFS must be cleanly closed.
- [ ] **Space**: free space on C:, and `Get-PartitionSupportedSize` for the real shrink limit (unmovable files). If the limit is too small, suggest Disk Cleanup, disabling the pagefile or System Restore temporarily, then re-check.
- [ ] **Windows version**: Windows 10 22H2+ or Windows 11. Show S-mode and Windows-on-ARM as unsupported.
- [ ] **Power**: laptops must be on AC (re-checked right before disk operations).
- [ ] **Pending updates / reboot required**: ask the user to finish Windows Update first (Windows rewrites boot entries during updates).
- [ ] **Disk health**: SMART status via `MSFT_PhysicalDisk` HealthStatus. Refuse on "Unhealthy".
- [ ] **Storage controller**: detect Intel RST/VMD RAID mode (Linux can't see the disk). Refuse with a guide.

### 2. Image acquisition
- [ ] HTTPS download from the release mirror list, chunked with resume (HTTP Range).
- [ ] Verify SHA256 against a signed manifest (minisign or GPG; key pinned in Setup) before anything touches the disk.
- [ ] "Use an ISO I already have": same verification.
- [ ] Cache in `%ProgramData%\Lugh\` and delete it after success.

### 3. Disk preparation (`engine/disk`)
- [ ] Create a System Restore point (if enabled), and log every planned operation to `%ProgramData%\Lugh\setup.log` before executing.
- [ ] Shrink C: through the Windows Storage Management API (`MSFT_Partition.Resize`, the same backend as the PowerShell `Resize-Partition` cmdlet), with VDS as a fallback.
- [ ] In the freed space, create:
  - the **installer partition** (FAT32, about 6 GB, label `LUGH-SETUP`), containing the extracted ISO + `lugh-answers.toml`;
  - leave the rest **unallocated**. Calamares creates the Btrfs root (ADR-009) in it during the unattended install.
- [ ] Mount the ESP (`mountvol S: /s`), copy `shimx64.efi`, `grubx64.efi`, `mmx64.efi` and a small `grub.cfg` that chain-loads the installer partition into `\EFI\lugh\`. Never touch `\EFI\Microsoft\`.
- [ ] Boot entry: `bcdedit /copy {bootmgr} /d "Lugh Setup"` → `bcdedit /set {new} path \EFI\lugh\shimx64.efi` → `bcdedit /set {fwbootmgr} bootsequence {new}` (one-time boot). Windows stays the default.
- [ ] `Suspend-BitLocker -MountPoint C: -RebootCount 2` (when BitLocker is on), right before the reboot.
- [ ] Every step is undoable. Keep an operation journal so a failure at step N rolls back steps N-1…1.

### 4. Answers preset and unattended install
- [ ] `lugh-answers.toml` schema: target (unallocated region by disk GUID + offset), filesystem, profile, locale, keyboard, timezone (from Windows), user name, **password hash** (yescrypt, never plaintext), hostname, optional Lughfile URL, encryption choice, and a "dual-boot" flag.
- [ ] The answers file is deleted from the installer partition as soon as Calamares reads it.
- [ ] `installer/modules/lughpreset`: loads the preset, pre-fills every Calamares module, skips the UI pages, and shows a single progress screen with the Lugh branding.
- [ ] Partition module: create the Btrfs root (and optional LUKS) in the unallocated region only. The installer partition is left untouched during the install.
- [ ] Bootloader: install GRUB to `\EFI\lugh\` (replacing the Setup chainloader), enable `os-prober`, name the entry "Windows" (not "Windows Boot Manager (on /dev/nvme0n1p1)"), and set the GRUB timeout to 5 s.
- [ ] Firmware boot order: put `Lugh` first (efibootmgr). Windows is reachable through GRUB.
- [ ] On failure: write logs to the installer partition, restore the firmware boot order so Windows boots next, and show "Installation failed — your Windows is untouched" with a log link. Setup reads the logs when Windows starts again.

### 5. First boot cleanup (`lugh-firstboot-cleanup.service`)
- [ ] Delete the `LUGH-SETUP` partition.
- [ ] Grow the Lugh root over the freed space (when adjacent; otherwise add it as a Btrfs device or leave it, documented).
- [ ] Remove the leftover `Lugh Setup` BCD entry through a tiny Windows-side scheduled task created by Setup that runs once at the next Windows logon (Linux doesn't edit BCD).
- [ ] Show a Welcome notification: "Windows is still here — pick it from the boot menu."

### 6. Remove Lugh (rollback/uninstall)
- [ ] From Windows: delete the Lugh partitions, extend C: back, remove `\EFI\lugh\` and the firmware/BCD entries, and make Windows Boot Manager first again.
- [ ] Refuse if a Lugh partition holds the only copy of user data without an explicit confirmation (show its size).
- [ ] Before the reboot, the "Undo setup" path reverts the operation journal.

### 7. Advanced mode
- [ ] Manual sizes for the Lugh root (and an optional separate `/home`), filesystem choice (Btrfs/ext4), and LUKS encryption.
- [ ] Choose a target disk (a second internal disk).
- [ ] **Replace Windows entirely**: needs typing the disk name plus a 10-second hold-to-confirm, and shows exactly what will be erased. BitLocker keys warning again.
- [ ] **Write a bootable USB instead**: raw-write the ISO to a selected removable drive (with verification read-back).
- [ ] "Just reboot into the live session" (try without installing).

### 8. App, signing and distribution
- [ ] UI in QML with LughUI components (DESIGN-SYSTEM), light theme default, keyboard-accessible, and screen reader support through Qt UIA.
- [ ] Runs elevated (manifest `requireAdministrator`), explaining up front why admin is needed.
- [ ] Authenticode signing with an EV or OV code-signing certificate (to reduce SmartScreen warnings). Timestamped.
- [ ] Single-file distribution, with a size target ≤ 40 MB (Qt static or deploy-bundled).
- [ ] Localized from day one (en, rw, fr, sw), using the same string pipeline as Phase 7.

## Acceptance criteria

1. On a Windows 11 laptop with BitLocker on, Secure Boot on and Fast Startup on: Setup detects all three, fixes Fast Startup with consent, suspends BitLocker, and finishes a dual-boot install without a BitLocker recovery prompt on the next Windows boot.
2. From clicking **Install** to the Lugh desktop takes ≤ 20 minutes on an NVMe SSD with a 100 Mbps connection (≤ 12 minutes with a local ISO).
3. After install, GRUB shows "Lugh" and "Windows", and Windows boots and works normally (Windows Update, BitLocker resumed).
4. The installer partition is gone and its space has been merged into Lugh after first boot.
5. Pulling the power during the "Prepare disk" step, then restarting, still leaves a bootable Windows. Setup offers to resume or undo.
6. A failed unattended install returns to Windows with logs and a clear message. The Windows partition is untouched.
7. **Remove Lugh** restores the original partition size and boot order, and leaves no `\EFI\lugh\` behind.
8. A tampered ISO (one byte changed) is rejected before any disk change.
9. Systems with legacy BIOS, RST RAID mode, S-mode, ARM64 or unhealthy disks are refused with a specific, readable reason and a next step.
10. Setup sends no network requests except to the release mirrors (verified with a packet capture).

## Testing

**Automated**
- Windows VMs (Hyper-V Gen2 and QEMU/OVMF with `swtpm` for TPM + Secure Boot) in CI: Windows 10 22H2 and 11, BitLocker on/off, Fast Startup on/off. Full Express flow, scripted through UI Automation.
- Fault injection: kill Setup or reset the VM at every journal step, then assert Windows still boots and the rollback succeeds.
- Answers-preset round trip: generate → Calamares loads → install in QEMU → assert profile packages, user, locale and timezone.

**Unit**
- Check logic with mocked WMI/registry results; the size-calculation rules; the BCD command builder; the operation journal and rollback ordering; the answers schema validation (no plaintext password ever serialized).

**Manual checklist (real hardware, including OEM firmware quirks)**
- [ ] Dell, HP, Lenovo and ASUS laptops, plus one desktop with an MSI/Gigabyte board.
- [ ] A machine whose firmware ignores `bootsequence` (see risks), and confirm the fallback works.
- [ ] A Windows update installed after Lugh: GRUB is still reachable, or the recovery guidance works.
- [ ] SmartScreen behavior with the signed binary.
- [ ] Narrator/NVDA pass through the Setup UI.

## Performance budget

| Metric | Budget |
|---|---|
| Setup cold start | ≤ 2 s to the first screen |
| Pre-flight checks | ≤ 10 s total |
| Disk preparation (shrink + partition + copy 6 GB) | ≤ 4 min on SSD |
| Unattended install (Standard profile, local media) | ≤ 8 min on NVMe |
| Setup binary size | ≤ 40 MB |
| Setup memory use | ≤ 250 MB |

## Risks & mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| OEM firmware ignores `bootsequence` / BCD `{fwbootmgr}` changes | Reboots straight back into Windows | Detect on the next Windows logon (Setup still installed, flag file present). Retry by setting Lugh first in `bootorder` temporarily (restored after install). Last resort: a guided "press F12 / F9" screen with a per-vendor key table |
| BitLocker recovery prompt after boot changes | Locked-out, scared user | Mandatory recovery-key confirmation, `Suspend-BitLocker -RebootCount 2`, never modify `\EFI\Microsoft\`, and test on TPM-only and TPM+PIN setups |
| Unmovable NTFS files limit the shrink | Not enough space | Show the real limit, guide through pagefile/hibernation/restore-point cleanup, and offer a second disk |
| Windows updates rewrite the boot order (Windows Boot Manager first again) | Lugh "disappears" | Lugh first-boot service re-asserts order on each Lugh boot. Optional small Windows-side task to restore it. Document the F-key menu |
| Data loss from a partitioning bug | Catastrophic for trust | Operation journal + rollback, a restore point, fault-injection CI, staged rollout (beta channel first), and Express never deletes partitions |
| SmartScreen and antivirus flag an unsigned or new binary | Users can't run Setup | EV certificate, consistent publisher name, submit to Microsoft for analysis before release |
| Secure Boot with a non-Debian-signed kernel | Boot failure | Only use Debian's signed shim/GRUB/kernel in Setup paths. Custom kernels need MOK enrollment, which is a USB/advanced flow ([../specs/system-base.md](../specs/system-base.md)) |
| RST/VMD RAID mode | Linux can't see the disk | Detect and refuse with a guide; don't switch AHCI automatically (that can break Windows boot) |

## Exit checklist

- [ ] All acceptance criteria pass in the VM matrix and on at least four real OEM machines.
- [ ] Fault-injection suite green in CI.
- [ ] Signed release artifact published along with the signed manifest and checksums.
- [ ] ISO builds in CI from a clean checkout, and the unattended preset path is covered by the QEMU boot test.
- [ ] Setup UI follows DESIGN-SYSTEM.md, all states implemented (including every refusal and error state).
- [ ] Engine and preset formats documented in [../specs/windows-setup.md](../specs/windows-setup.md). The Calamares preset module has unit tests.
- [ ] Performance budgets above pass.
- [ ] New decisions (signing provider, mirror host) added to DECISIONS.md.
- [ ] Release note written in `docs/releases/phase-6.md`.
