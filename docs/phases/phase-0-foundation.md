# Phase 0 — Foundation

> Status: **Draft** · Size: **S** · Depends on: nothing · Specs: [system-base](../specs/system-base.md), [build-and-release](../specs/build-and-release.md), [design-system](../DESIGN-SYSTEM.md) · Decisions: ADR-001, 002, 003, 009, 011, 021

## Goal

Anyone can clone the Lugh repo, run `make iso`, and get a **branded, bootable Lugh ISO** that boots in QEMU (UEFI with Secure Boot on, UEFI without it, and legacy BIOS) to a console login that says "Lugh". CI builds the same ISO on every commit and proves it boots. There is no desktop yet. This phase builds the factory that every later phase uses.

## Scope

**In**
- Monorepo skeleton (layout from [ARCHITECTURE §6](../ARCHITECTURE.md)), license file, contribution rules.
- Rust workspace and a QML/cxx-qt "hello" app that proves the toolchain works (not shipped in the ISO).
- live-build config in `iso/` for Debian 13 trixie with `main contrib non-free non-free-firmware`, backports and Mozilla's APT repo.
- Base package set: minimal system, kernel, firmware, NetworkManager, PipeWire, Btrfs tooling, snapper, Firefox (installed, but not launchable without a desktop; included to prove the repo wiring).
- `lugh-branding` package: os-release, GRUB theme, Plymouth theme, placeholder logo, issue/motd.
- Dev host setup on KDE neon, plus a containerized Debian build environment.
- `make` targets: `iso`, `run-uefi`, `run-uefi-sb`, `run-bios`, `test-boot`, `clean`.
- GitHub Actions: ISO build plus a QEMU boot smoke test using a serial-console marker.
- Lugh apt repo scaffold (aptly, signing key procedure), local only for now.

**Out (deferred)**
- Any graphical session → Phase 1.
- Installer (Calamares) and the Btrfs layout on disk → Phase 1. In Phase 0 we only *plan* the subvolume layout and package snapper and grub-btrfs.
- Public repo hosting → Phase 7 (the domain is an open question).
- Our own kernel or Mesa builds → only when a later phase needs them, Phase 3 at the earliest (gaming).

## Deliverables

| Deliverable | Path | Package |
|---|---|---|
| Repo skeleton, README, LICENSE, CONTRIBUTING | `/` | — |
| Rust workspace with `lugh-common` stub | `crates/` | — |
| QML toolchain smoke app (`lugh-hello`, cxx-qt) | `ui/hello/` | not packaged |
| live-build config | `iso/` | — |
| Branding assets + os-release | `branding/` | `lugh-branding` |
| GRUB theme | `branding/grub/` | `lugh-branding` (sub-package `lugh-grub-theme`) |
| Plymouth theme | `branding/plymouth/` | `lugh-plymouth-theme` |
| Boot marker unit | `iso/config/includes.chroot/etc/systemd/system/lugh-boot-marker.service` | part of ISO only |
| Makefile + scripts | `Makefile`, `scripts/` | — |
| Build container | `scripts/build-env/Containerfile` | — |
| CI workflows | `.github/workflows/iso.yml`, `ci.yml` | — |
| apt repo scaffold | `packaging/repo/` | — |
| Phase release note | `docs/releases/phase-0.md` | — |

## Work breakdown

### 1. Repository & toolchains
- [ ] `git init`; create the directories from ARCHITECTURE §6 with `.gitkeep` where they're empty.
- [ ] Add `LICENSE` (GPL-3.0-or-later, pending ADR-022 confirmation), `CONTRIBUTING.md` (conventional commits, DCO sign-off), `.editorconfig`, `.gitattributes` (LF, binary assets).
- [ ] `Cargo.toml` workspace with `crates/lugh-common` (logging via `tracing`, config loading, and a D-Bus helper stub built on `zbus`). Pin the toolchain in `rust-toolchain.toml` (stable, version pinned).
- [ ] `ui/hello/`: a minimal cxx-qt app showing one QML window, to prove Qt 6 + cxx-qt build on the dev host and in CI. Needs `qt6-base-dev qt6-declarative-dev qml6-module-qtquick-controls cmake`.
- [ ] `ci.yml`: `cargo fmt --check`, `cargo clippy -D warnings`, `cargo test`, and `qmllint` on `ui/**/*.qml`.

### 2. Dev host (KDE neon) & build container
- [ ] Document host setup in `docs/dev/setup.md`:
  `sudo apt install live-build debootstrap qemu-system-x86 qemu-utils ovmf xorriso mtools dosfstools squashfs-tools podman make git`
- [ ] **Build inside a Debian trixie container**, because KDE neon's live-build and debootstrap are Ubuntu-patched versions and may not match Debian's. Write `scripts/build-env/Containerfile` (`FROM debian:trixie`, installs `live-build debootstrap xorriso squashfs-tools mtools dosfstools grub-efi-amd64-bin grub-pc-bin shim-signed`).
- [ ] `scripts/build-iso.sh`: runs `lb build` inside the container with `--privileged` (needed for chroot and mounts), then copies `iso/live-image-amd64.hybrid.iso` to `out/lugh-<version>-amd64.iso` along with a `.sha256` file.

### 3. live-build config (`iso/`)
- [ ] `iso/auto/config`:
  ```sh
  lb config noauto \
    --distribution trixie \
    --archive-areas "main contrib non-free non-free-firmware" \
    --bootloaders "grub-efi,syslinux" \
    --uefi-secure-boot enable \
    --debian-installer none \
    --iso-application "Lugh" --iso-volume "LUGH" \
    --image-name lugh \
    --bootappend-live "boot=live components quiet splash console=tty0 console=ttyS0,115200" \
    "${@}"
  ```
  Also `auto/build` and `auto/clean` (the standard live-build wrappers).
- [ ] Backports: `iso/config/archives/backports.list.chroot` with `deb http://deb.debian.org/debian trixie-backports main contrib non-free non-free-firmware`. Nothing is pulled from it by default; it's enabled for later phases.
- [ ] Mozilla repo (ADR-011): `config/archives/mozilla.list.chroot` with `deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main`, the key in `config/archives/mozilla.key.chroot`, and a pin file `config/includes.chroot/etc/apt/preferences.d/mozilla` (`Pin: origin packages.mozilla.org`, `Pin-Priority: 1000`) so `firefox` wins over `firefox-esr`.
- [ ] Package lists in `config/package-lists/`:
  - `base.list.chroot`: `linux-image-amd64 systemd-sysv sudo locales console-setup keyboard-configuration bash-completion less nano ca-certificates curl wget apt-transport-https plymouth plymouth-themes`
  - `firmware.list.chroot`: `firmware-linux firmware-linux-nonfree firmware-misc-nonfree firmware-iwlwifi firmware-realtek firmware-atheros firmware-brcm80211 firmware-amd-graphics firmware-sof-signed intel-microcode amd64-microcode`
  - `network.list.chroot`: `network-manager wpasupplicant iw`
  - `audio.list.chroot`: `pipewire pipewire-pulse wireplumber`
  - `storage.list.chroot`: `btrfs-progs snapper dosfstools ntfs-3g cryptsetup e2fsprogs`
  - `browser.list.chroot`: `firefox`
  - `live.list.chroot`: `live-boot live-config live-config-systemd`
- [ ] `grub-btrfs`: check whether trixie ships it (`apt-cache policy grub-btrfs` in the container). If not, open a packaging task for `packaging/grub-btrfs/` in the Lugh repo. It is not needed in the ISO until Phase 1.
- [ ] Write `docs/dev/btrfs-layout.md` describing the planned subvolumes (`@`, `@home`, `@var_log`, `@cache`, `@snapshots`, per ADR-009) for the Phase 1 installer to implement.
- [ ] Live user: `live-config` with username `lugh`, hostname `lugh`, and passwordless sudo on the live image only.

### 4. Branding (`lugh-branding`)
- [ ] `branding/os-release`:
  ```
  PRETTY_NAME="Lugh 0.0 (Foundation)"
  NAME="Lugh"
  VERSION_ID="0.0"
  VERSION="0.0 (Foundation)"
  VERSION_CODENAME=foundation
  ID=lugh
  ID_LIKE=debian
  HOME_URL="https://lugh.example"   # placeholder until a domain is chosen
  LOGO=lugh-logo
  ```
  Installed to `/usr/lib/os-release` with a `dpkg-divert` of Debian's file, so `base-files` upgrades don't overwrite it. Also set `/etc/issue` and `/etc/motd`.
- [ ] Placeholder logo: the word "lugh" set in Inter 600 as an SVG in `branding/placeholder/` (DESIGN-SYSTEM §9). Render PNGs at 128/256/512 with `rsvg-convert`.
- [ ] GRUB theme (`branding/grub/theme.txt`): light background `#F7F6F3`, text `#1C1B19`, selected item `#E8962E` with `#1C1B19` text, Inter rendered with `grub-mkfont`. Applied to the live ISO (`config/bootloaders/grub-pc/` and `grub-efi`) and installed systems.
- [ ] Plymouth theme (`branding/plymouth/lugh/`): two-step or script theme with a centered logo, a thin amber progress line and a light background. A dark variant follows later. Set it with `plymouth-set-default-theme lugh` in a chroot hook.
- [ ] Debian package skeleton `packaging/lugh-branding/debian/` (`control`, `rules` with dh, `install`, `postinst` to update GRUB and the Plymouth initramfs).
- [ ] Hook `config/hooks/normal/0100-lugh-branding.hook.chroot` installs the locally built `lugh-branding.deb` (through `config/packages.chroot/`).

### 5. Lugh apt repo scaffold (ADR-003)
- [ ] `packaging/repo/aptly.conf` and `scripts/repo-publish.sh`: create the repo `lugh-trixie`, add `.deb` files from `out/debs/`, and publish to `out/repo/`, signed.
- [ ] Signing key procedure in `docs/dev/signing.md`: an offline primary key, a signing subkey stored as a CI secret (`LUGH_REPO_GPG_KEY`), rotation and revocation steps, and the public key shipped in the ISO at `/etc/apt/keyrings/lugh.asc`. Local builds use a throwaway dev key with a loud warning.
- [ ] The ISO consumes the locally published repo through `config/archives/lugh.list.chroot` (file:// during build). The real URL comes in Phase 7.

### 6. Make targets & QEMU
- [ ] `make iso` → `scripts/build-iso.sh`.
- [ ] `make run-uefi`:
  `qemu-system-x86_64 -enable-kvm -m 4G -smp 4 -machine q35 -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd -drive if=pflash,format=raw,file=out/OVMF_VARS.fd -cdrom out/lugh.iso -serial mon:stdio`
  (VARS is copied from `/usr/share/OVMF/OVMF_VARS_4M.fd` on first run.)
- [ ] `make run-uefi-sb`: same, but with `OVMF_CODE_4M.secboot.fd` and `OVMF_VARS_4M.ms.fd` (Microsoft keys enrolled), so the ISO must boot through Debian's signed `shimx64.efi` → `grubx64.efi` → signed kernel.
- [ ] `make run-bios`: `-machine pc` without pflash.
- [ ] `make test-boot`: headless (`-display none -serial file:out/serial.log`), wait up to 180 s for the marker, then exit 0/1. Runs all three firmware modes.
- [ ] Boot marker: `lugh-boot-marker.service` (oneshot, `After=multi-user.target`) runs `echo "LUGH-BOOT-OK $(cat /etc/os-release | grep VERSION_ID)" > /dev/ttyS0`.

### 7. CI (`.github/workflows/iso.yml`)
- [ ] Trigger on push and PR. Runner `ubuntu-latest`, building in the trixie container with `--privileged`.
- [ ] Cache: apt package cache (`iso/cache/`) keyed on a hash of the package lists.
- [ ] Steps: build the `lugh-branding` deb → publish the local repo → `lb build` → upload the ISO artifact (kept 7 days for PRs, 30 for main).
- [ ] Boot smoke test: install `qemu-system-x86 ovmf` and run `make test-boot`. KVM is available on GitHub-hosted Linux runners; fall back to TCG with longer timeouts if `/dev/kvm` is missing.
- [ ] Record ISO size and boot time as job summary values (the start of the perf history).

## Acceptance criteria

1. `make iso` on a clean checkout (KDE neon host with podman) produces `out/lugh-0.0-amd64.iso` and its `.sha256`.
2. The ISO boots to a console login in QEMU under **UEFI**, **UEFI with Secure Boot on** (Microsoft keys enrolled) and **legacy BIOS**.
3. The GRUB menu and Plymouth splash show Lugh branding using the DESIGN-SYSTEM colors.
4. `cat /etc/os-release` shows `NAME="Lugh"`, `ID=lugh`, `ID_LIKE=debian`.
5. `apt policy firefox` shows the packages.mozilla.org origin with priority 1000, and `firefox --version` runs.
6. `nmcli general status` works. `systemctl --user status pipewire` is active for the live user.
7. `mkfs.btrfs`, `snapper` and `cryptsetup` are present.
8. CI builds the ISO and the boot test passes for all three firmware modes on main.
9. The cxx-qt hello app builds in CI.
10. The local apt repo is published and signed, and the ISO installs `lugh-branding` from it.

## Testing

**Automated**
- `make test-boot` in 3 firmware modes (CI, every commit).
- `ci.yml`: Rust fmt, clippy and tests; qmllint.
- A packaging lint: `lintian` on `lugh-branding`.

**Manual checklist (per release)**
- [ ] Boot the ISO from a USB stick on one real UEFI laptop (Secure Boot on) and one older BIOS machine.
- [ ] Wi-Fi connects with `nmtui` on real hardware (proves the firmware packages).
- [ ] The GRUB theme is readable at 1080p and 4K.

## Performance budget for this phase

| Metric | Budget |
|---|---|
| ISO size | ≤ 1.2 GB |
| Boot to console login, QEMU + KVM, UEFI | ≤ 25 s (ISO boot; the installed-system target comes in Phase 1) |
| CI ISO build time (warm cache) | ≤ 20 min |

## Risks & mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Ubuntu-patched live-build on KDE neon behaves differently | broken or non-reproducible builds | always build in the Debian trixie container; host tools only run QEMU |
| Secure Boot chain breaks with a custom GRUB config or theme | ISO won't boot on SB machines | only use Debian-signed shim, GRUB and kernel; the theme is data, not a binary; `run-uefi-sb` runs in CI |
| GitHub runner lacks KVM or privileged containers | slow or failing CI | TCG fallback; a self-hosted runner as plan B |
| `grub-btrfs` missing in trixie | rollback UX delayed | package it in the Lugh repo (Phase 1 task) |
| Mozilla repo key or URL changes | Firefox install fails | the key lives in the repo, and CI fails loudly; fall back to `firefox-esr` |
| Repo signing key leak | users trust malicious packages | offline primary key, CI-only subkey, documented revocation |
| Non-free firmware licensing | redistribution concerns | use only Debian's `non-free-firmware` packages (redistributable by definition) |

## Exit checklist

- [ ] All acceptance criteria pass.
- [ ] ISO builds in CI from a clean checkout (global DoD 1).
- [ ] Automated QEMU boot test passes in all firmware modes (DoD 2).
- [ ] Branding follows DESIGN-SYSTEM (DoD 3). No new daemons this phase (DoD 4 n/a).
- [ ] Performance budgets met and recorded in the CI summary (DoD 5).
- [ ] `docs/dev/setup.md`, `docs/dev/signing.md` and `docs/dev/btrfs-layout.md` written. Specs `system-base` and `build-and-release` updated with anything learned. New decisions added to DECISIONS.md (DoD 6).
- [ ] `docs/releases/phase-0.md` written (DoD 7).
