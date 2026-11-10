# Lugh 0.0 "Foundation" — Phase 0 release note

> Date: 2026-11-09 · Phase doc: [phase-0-foundation](../phases/phase-0-foundation.md) · Status: **gate passed locally; CI not yet run**

## What Phase 0 delivers

The factory every later phase builds on: `make iso` on a clean checkout gives a branded, bootable Lugh live ISO (Debian 13 trixie). It boots in QEMU under UEFI, UEFI with Secure Boot and legacy BIOS, reaching a console login that says "Lugh". There is no desktop yet.

- **Repo skeleton:** README, GPL-3.0-or-later `LICENSE` (pending ADR-022), CONTRIBUTING (Conventional Commits, DCO), `.editorconfig`, `.gitattributes`, `VERSION` = `0.0`.
- **Rust workspace:** toolchain pinned to 1.99.0, and the `lugh-common` crate (`tracing` logging, XDG/TOML config, zbus D-Bus helpers).
- **`ui/hello`:** a cxx-qt 0.10 + QML smoke app, styled to DESIGN-SYSTEM. It is not shipped in the ISO.
- **Branding (`branding/`):**
  - cleaned-up logo with light, dark and mono variants, plus wordmark and lockup;
  - hicolor icons and PNG renders;
  - GRUB theme (Inter, amber selection) and Plymouth theme (centred logo, thin amber progress line);
  - os-release, issue and motd.
- **`lugh-branding` package (0.0.1):** replaces os-release, issue and motd through config-package-dev displace, and installs the GRUB/Plymouth themes and icons.
- **apt repo scaffold:** aptly config, plus `scripts/build-debs.sh` and `scripts/repo-publish.sh`. The repo is signed with Ed25519, using a throwaway dev key locally and `LUGH_REPO_GPG_KEY` in CI. `docs/dev/signing.md` covers the procedure.
- **live-build config (`iso/`):**
  - trixie with `main contrib non-free non-free-firmware`, plus backports (enabled, nothing pulled);
  - Mozilla's repo, pinned to 1000 with `signed-by` in the image;
  - the package lists from the phase doc and the local Lugh repo;
  - live user `lugh` with passwordless sudo on the live image only;
  - serial console and boot marker.
- **Build container:** `scripts/build-env/Containerfile`, used by `scripts/build-iso.sh` and `scripts/lib/container.sh`.
- **Make targets:** `iso`, `debs`, `repo`, `check`, `hello`, `run-uefi`, `run-uefi-sb`, `run-bios`, `test-boot[-mode]`, `clean`.
- **QEMU scripts:** `scripts/qemu-run.sh` and `scripts/test-boot.sh`. The test writes `out/boot-times.json`.
- **CI:** `.github/workflows/ci.yml` (fmt, clippy, tests, cxx-qt hello, qmllint, shellcheck) and `iso.yml` (debs → repo → ISO → boot test in three modes → size check and job summary).
- **Docs:** `docs/dev/setup.md`, `signing.md` and `btrfs-layout.md`.

## Measured numbers

Host: KDE neon, 8 CPUs, KVM, Docker as the container engine. QEMU: 4 GB RAM, 4 vCPUs. All numbers are for the final ISO (`out/lugh-0.0-amd64.iso`).

| Metric | Budget | Measured |
|---|---|---|
| ISO size | ≤ 1.2 GB | **977,272,832 bytes (0.98 GB, 932 MiB)** |
| `make iso` (includes `debs` + `repo`), warm `.deb` cache | ≤ 20 min (CI) | **9m52s** (10m03s wall); other runs 9m28s and 14m09s |
| Boot to `LUGH-BOOT-OK`, UEFI + KVM | ≤ 25 s | **17.1–19.2 s** (3 runs) |
| Boot to `LUGH-BOOT-OK`, UEFI + Secure Boot + KVM | — | **17.1–20.2 s** (3 runs) |
| Boot to `LUGH-BOOT-OK`, BIOS + KVM | — | **27.7–28.3 s** (3 runs) |

The boot times count from QEMU start to the serial marker, so they include firmware and the 3 s boot-menu countdown. One earlier UEFI run on the previous ISO took 32.6 s; it was the first boot right after a build, with the host's load average around 18. It did not happen again in 6 further UEFI runs (17.1–19.2 s).

## Acceptance criteria

| # | Criterion | Status | Evidence |
|---|---|---|---|
| 1 | `make iso` on a clean checkout (KDE neon + podman) produces the ISO and `.sha256` | **Pass (with Docker); podman not verified** | `make iso` → `out/lugh-0.0-amd64.iso` and `.sha256` (`sha256sum -c` OK). Built with Docker, because podman isn't installed on the dev host. The checkout was not a fresh clone: the `iso/cache` .deb cache was warm. |
| 2 | Boots to a console login under UEFI, UEFI + Secure Boot (MS keys) and BIOS | **Pass** | `make test-boot`: all three modes pass. Serial shows `lugh login:`; tty1 autologs in as `lugh` ("Welcome to Lugh."). Secure Boot runs use `OVMF_CODE_4M.secboot.fd` with `OVMF_VARS_4M.ms.fd` (shim → GRUB → signed kernel). |
| 3 | GRUB menu and Plymouth splash show Lugh branding in DESIGN-SYSTEM colours | **Pass with caveats** | Screenshots: UEFI shows the GRUB theme (light `#F7F6F3`, amber selection, logo, Inter), then the Plymouth logo with the amber progress line. Under Secure Boot the GRUB theme renders in Unifont, not Inter (see known issues). BIOS shows the branded ISOLINUX menu and splash, but no Plymouth splash. |
| 4 | `/etc/os-release` shows `NAME="Lugh"`, `ID=lugh`, `ID_LIKE=debian` | **Pass** | Checked in the booted ISO over serial. The boot marker reads `VERSION_ID="0.0"`. |
| 5 | `apt policy firefox`: packages.mozilla.org at 1000; `firefox --version` runs | **Pass** | In the booted ISO: `1000 https://packages.mozilla.org/apt mozilla/main`, and `Mozilla Firefox 159.0.1`. |
| 6 | `nmcli general status` works; `systemctl --user status pipewire` is active for the live user | **Pass** | `connected  full`; `pipewire`, `pipewire.socket` and `wireplumber` are active for `lugh`. |
| 7 | `mkfs.btrfs`, `snapper`, `cryptsetup` present | **Pass** | btrfs-progs 6.14, snapper 0.10.6 and cryptsetup 2.7.5 are installed. Binaries: `/usr/sbin/mkfs.btrfs`, `/usr/bin/snapper`, `/usr/sbin/cryptsetup`. |
| 8 | CI builds the ISO and the boot test passes in all three modes on main | **Not verified** | The workflows pass actionlint, but nothing has been pushed and no CI run exists yet. |
| 9 | cxx-qt hello app builds in CI | **Not verified in CI; passes locally** | `make hello` builds in a trixie container and qmllint is clean. |
| 10 | Local apt repo published and signed; ISO installs `lugh-branding` from it | **Pass** | `make debs repo`: lintian reports no findings, and `InRelease` verifies against `out/repo/lugh.asc`. The ISO build fetches from `http://127.0.0.1:8099`, and `dpkg-query` in the booted ISO shows `lugh-branding 0.0.1`. |

Other checks:
- `make check`: `cargo fmt --check`, `clippy -D warnings` and 13 tests all pass.
- shellcheck (`koalaman/shellcheck:stable -x`) is clean on all 16 shell scripts and hooks.
- actionlint is clean on both workflows.
- `grub-script-check` passes on the GRUB configs.

## Fixes made at the Phase 0 gate

1. **`lb installer` failed with `cp: cannot stat 'cache/bootstrap'`.**
   - Cause: live-build 20250505 needs a bootstrap stage cache, even without debian-installer.
   - Fix: `iso/auto/config` now uses `--cache-stages bootstrap`, and `scripts/build-iso.sh` deletes the root-owned `cache/bootstrap` in the container, before the build and on exit, so the host `iso/cache/` only ever holds .debs.
2. **`lb installer` failed with "packages.mozilla.org … is not signed".**
   - Cause: live-build writes `*.list.binary` into the bare bootstrap chroot it uses for the installer, where `/etc/apt/keyrings/packages.mozilla.org.asc` doesn't exist.
   - Fix: removed `iso/config/archives/mozilla.list.binary`. The image's signed-by source now ships as `iso/config/includes.chroot/etc/apt/sources.list.d/mozilla.sources` (deb822). `iso/README.md` is updated.
3. **The live image's `/etc/os-release` said Debian 13.**
   - Cause: live-build's bootstrap snapshots Debian's file into a regular `/etc/os-release`, so the diversion of `/usr/lib/os-release` never reached it.
   - Fix: hook `0100-lugh-branding` rebuilds it from Lugh's file and keeps live-build's `IMAGE_ID`/`BUILD_ID`.
4. **No Plymouth splash.**
   - Cause: with `console=ttyS0` on the command line, Plymouth falls back to text mode.
   - Fix: added `plymouth.ignore-serial-consoles` to the live boot options.
5. **"error: prohibited by secure boot policy" ×3 under Secure Boot.**
   - Cause: signed GRUB refuses unsigned `.pf2` fonts.
   - Fix: `theme.cfg` skips `loadfont` when `lockdown=y`, and the theme falls back to Unifont.

## Known issues and follow-ups

- **GRUB theme without Inter under Secure Boot.** Debian's signed GRUB won't load external font files, so on SB machines the menu is in Unifont; this also affects installed systems. Options: accept it, or ship a GRUB build with the fonts in its signed memdisk (needs our own signing; see ADR-001/002). Owner: branding (w5) and the lead.
- **No Plymouth splash in BIOS mode (QEMU std-vga).** The ISOLINUX splash stays on screen until the text console appears. This was not investigated, and real BIOS hardware is untested.
- **Large initrd (134 MB).** The kernel and initrd load takes about 5 s in GRUB (a black screen after the menu). Trimming the firmware in the initramfs (e.g. `MODULES=dep`, or dropping non-boot firmware) would cut boot time. Phase 1 performance work.
- **Secure Boot is verified only in QEMU with OVMF's Microsoft keys**, not on real hardware (part of the manual checklist).
- **podman path not run:** the host has no podman. `CONTAINER_ENGINE=docker` was used, and CI uses Docker too.
- **CI not run yet:** the first push needs to confirm the GitHub runner has KVM, privileged Docker and the `rust-toolchain` 1.99.0 download, and that the job summary records size and boot time.
- **`grub-btrfs` is not in trixie or trixie-backports:** it needs a `packaging/grub-btrfs/` task in Phase 1 (recorded in `docs/dev/btrfs-layout.md`).
- **Not covered by `lugh-branding` yet:**
  - the dark Plymouth variant;
  - `/etc/issue.net`, which still says Debian;
  - a licence statement for the logo;
  - a dark/symbolic app icon.
- **ADR-022 (licence) is still Proposed**, and the `LICENSE` file assumes GPL-3.0-or-later.
- **Encrypted root with an unencrypted `/boot`:** GRUB can't read `/usr/share/grub/themes/lugh`. The Phase 1 installer should copy the theme to `/boot/grub/themes/`.
- **Manual checklist not done:** booting real hardware from USB, Wi-Fi via `nmtui`, and the GRUB theme at 1080p/4K on a real screen.
- **Dev builds only:** local ISOs are signed with the throwaway dev key ("Lugh DEV KEY - NOT FOR RELEASE") and must not be published.
