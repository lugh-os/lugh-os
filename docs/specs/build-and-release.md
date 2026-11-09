# Build & Release — Spec

> Status: **Draft** · Owner phase: **0** (and every phase after it) · Related ADRs: ADR-002, ADR-003, ADR-005, ADR-006, ADR-007, ADR-022

## Purpose

How Lugh goes from source code to a signed ISO and signed apt packages: the build system, packaging, the apt repository, versioning, release channels, CI, the test and performance harness, and the release checklist.

## User stories

- **Windows switcher:** "The ISO I download is official and hasn't been tampered with, and updates arrive by themselves."
- **Linux power user:** "I can rebuild the ISO myself from the repo with one command and get the same result, and I can switch to the beta channel."
- **Contributor:** "Every pull request tells me in minutes whether I broke the build, the boot or the performance budget."

## Requirements

### Functional
- **FR-1** `make iso` in a clean checkout builds a bootable hybrid ISO (UEFI + BIOS, USB + DVD) using live-build (ADR-002).
- **FR-2** Every Lugh component builds into a `.deb` with a proper `debian/` directory, without network access during the build.
- **FR-3** Packages are published to a signed apt repository with three channels: `dev`, `beta`, `stable` (ADR-003).
- **FR-4** CI runs on every pull request: lint, unit tests, package build, and (on changes touching packages or `iso/`) ISO build + QEMU boot tests.
- **FR-5** CI runs the performance harness on `main` and fails on budget violations.
- **FR-6** Releases publish the ISO, a `SHA256SUMS` file, a detached GPG signature, the package manifest and release notes.
- **FR-7** The Windows Setup binary (Phase 6) is built in CI and Authenticode-signed once a certificate exists.

### Non-functional
- **NFR-1** PR feedback (lint + unit tests) in ≤ 10 min. Full ISO + boot tests in ≤ 45 min.
- **NFR-2** ISO size: ≤ 3.5 GB including the offline package pool for the Standard profile.
- **NFR-3** Reproducibility: two builds from the same commit and the same `snapshot.debian.org` timestamp produce identical package manifests. Bit-identical ISOs are a stretch goal.
- **NFR-4** Signing keys never sit unencrypted on a shared machine. The stable signing key requires a human step.

## Design

### Repository build entry points
```
make deps        # install build deps (live-build, debhelper, cargo toolchain via rustup, qt6 dev pkgs)
make debs        # build all .deb packages into out/debs/
make repo-local  # create a local apt repo from out/debs/ (used by the ISO build)
make iso         # build ISO from iso/ using out/debs/ + Debian mirror → out/iso/lugh-<ver>-amd64.iso
make test-boot   # QEMU boot tests against out/iso/*.iso
make perf        # performance harness
```
The builds run inside a container image `lugh-builder:trixie` (Debian 13 + build deps + pinned Rust), so the result doesn't depend on the host (the founder's machine is KDE neon). The Makefile wraps `podman run`.

### live-build configuration (`iso/`)
```
iso/
├── auto/
│   ├── config            # `lb config` invocation (below)
│   ├── build
│   └── clean
├── config/
│   ├── package-lists/
│   │   ├── core.list.chroot          # profile "Core" (see system-base.md)
│   │   ├── live.list.chroot          # calamares, lugh-calamares-config, live-boot, live-config
│   │   └── pool-standard.list.binary # .debs copied into the ISO pool for offline Standard installs
│   ├── archives/
│   │   ├── lugh.list.chroot / lugh.key.chroot
│   │   └── mozilla.list.chroot / mozilla.key.chroot
│   ├── hooks/live/
│   │   ├── 0100-lugh-branding.hook.chroot
│   │   ├── 0200-firefox-pin.hook.chroot
│   │   └── 9900-cleanup.hook.chroot
│   ├── includes.chroot/      # live-only overrides (autologin live user, installer desktop icon)
│   ├── includes.binary/      # README, EFI extras
│   └── bootloaders/          # GRUB (EFI) + ISOLINUX themes from branding/
└── README.md
```
`auto/config`:
```sh
lb config noauto \
  --mode debian --distribution trixie \
  --archive-areas "main contrib non-free non-free-firmware" \
  --parent-mirror-bootstrap "https://snapshot.debian.org/archive/debian/${LUGH_SNAPSHOT}/" \
  --binary-images iso-hybrid --bootloaders "grub-efi,syslinux" \
  --uefi-secure-boot enable --debian-installer none \
  --iso-application "Lugh" --iso-volume "LUGH_${LUGH_VERSION}" \
  --bootappend-live "boot=live components quiet splash" \
  --linux-flavours amd64 \
  "${@}"
```
`LUGH_SNAPSHOT` is pinned per release branch, which makes NFR-3 achievable.

### Packaging
- **Layout:** each component keeps its packaging in `packaging/<pkg>/debian/`. A small script copies it into the source tree when building.
- **Rust** (`crates/`): one cargo workspace with `rust-toolchain.toml` pinned (e.g. `channel = "1.xx.0"`; the exact version is fixed in Phase 0). Dependencies are **vendored** (`cargo vendor` → `vendor/` tarball attached to each source package) and built with `cargo build --release --offline --frozen` from a debhelper override. We don't use `debcargo`, because Lugh is not packaging crates for Debian.
- **QML apps** (`ui/`): CMake + cxx-qt against Debian's Qt 6 (`qt6-base-dev`, `qt6-declarative-dev`, `qt6-wayland-dev`, `layer-shell-qt` dev package). QML is compiled with `qmlcachegen` for faster start-up.
- **Assets** (`branding/`): `lugh-branding`, `lugh-grub-theme`, `lugh-plymouth-theme`, wallpapers. These are `Architecture: all`.
- **Meta-packages:** `lugh-desktop-core`, `lugh-profile-standard`, `lugh-extra-gaming`, `lugh-extra-developer`. Profiles are just dependency lists, which keeps the installer and `lugh profile add` simple ([installer](installer.md)).
- **Quality gates:** `lintian` (no errors), `piuparts` install/remove test for each package in CI on main.

### Versioning
| Thing | Scheme | Example |
|---|---|---|
| Lugh OS release | `<major>.<minor>`. Major follows the Debian base (Lugh 1 = Debian 13, Lugh 2 = Debian 14). Minor is a feature drop | Lugh 1.0, 1.1 |
| Codename | One per major, light/craft theme (to be chosen by the founder) | `lugh1` suite with codename aliases |
| Pre-release ISOs | `0.<phase>.<build>` | `0.1.3` = Phase 1 milestone, 3rd build |
| Components | SemVer per package; D-Bus APIs versioned in the interface name (`…1`) | `lugh-shell 0.4.2` |
| Debian package version | `<semver>-<rev>~lugh1` | `0.4.2-1~lugh1` |

### Apt repository & channels
- Managed with **aptly** (snapshots make promotion atomic).
- Suites: `lugh1-dev` (every merge to main), `lugh1-beta` (promoted weekly after tests), `lugh1` (stable, promoted manually), `lugh1-security` (urgent fixes, can bypass beta).
- Promotion: `aptly snapshot create` from dev → publish to beta → after the beta soak period (≥ 7 days, no blocker bugs) → publish to stable. Same snapshot, same bits.
- The channel is switched in Settings → About → Update channel, which rewrites `Suites:` in `/etc/apt/sources.list.d/lugh.sources` (polkit admin).

### Signing
| Key | Use | Storage |
|---|---|---|
| Lugh archive primary key | certifies subkeys only | offline (encrypted USB + paper backup), held by the founder |
| `dev`/`beta` signing subkey | signs dev and beta repo metadata and nightly ISOs | CI secret, rotated yearly |
| `stable` signing subkey | signs stable metadata and release ISOs | hardware token, manual release step |
| Authenticode certificate | `LughSetup.exe` | cloud HSM or token (Phase 6) |

Key type: RSA 4096 or Ed25519 (apt on trixie verifies both through `sqv`; we pick in Phase 0 after testing). Secure Boot uses Debian's signed chain, so **we hold no Secure Boot key** (see [system-base](system-base.md)).

### CI pipelines (GitHub Actions)
| Workflow | Trigger | Jobs |
|---|---|---|
| `lint.yml` | every PR | `cargo fmt --check`, `cargo clippy -D warnings`, `qmllint`, `shellcheck`, `lintian` on changed packages, markdown lint + link check on `docs/` |
| `test.yml` | every PR | `cargo test --workspace`, QML tests (`qmltestrunner -platform offscreen`), D-Bus integration tests on a private session bus (`dbus-run-session`) |
| `debs.yml` | PR + main | build all debs in `lugh-builder:trixie` and upload as artifacts. On main, publish to `lugh1-dev` |
| `iso.yml` | main nightly, plus PRs touching `iso/`, `branding/` or `packaging/` | `make iso` (privileged container), upload the ISO artifact |
| `boot-test.yml` | after `iso.yml` | QEMU matrix (below) |
| `perf.yml` | main nightly | performance harness (below), comparing against a stored baseline |
| `release.yml` | tag `v*` | build, sign, checksum, draft GitHub release, aptly promotion steps |

Runners: GitHub-hosted Linux runners expose `/dev/kvm`, which QEMU needs to be fast. If that's unavailable or too slow, a self-hosted runner (the founder's machine or a small server) takes the `boot-test` and `perf` jobs.

### QEMU boot tests
Matrix: {UEFI + Secure Boot (`OVMF_CODE_4M.secboot.fd` + MS-enrolled vars), UEFI without SB, BIOS/SeaBIOS} × {live boot, installed system}.

Mechanism:
- The kernel cmdline adds `console=ttyS0` in test builds, and the serial log is captured.
- `lugh-test-markers` (a test-only package) prints these markers to the serial console:
  - `LUGH-MARK: basic.target`
  - `LUGH-MARK: greeter-ready`
  - `LUGH-MARK: session-ready` (shell drew its first frame; the live ISO auto-logs in)
  - `LUGH-MARK: failed-units=<n>`
- The harness (`tests/boot/run.py`) waits for each marker with a timeout, takes a QMP `screendump` at session-ready (archived for humans; no pixel diffing yet), and fails on `failed-units > 0`.
- **Installer test:** boots the ISO with `lugh.preset=` pointing to `tests/presets/*.toml` (unattended mode, [installer](installer.md)) onto a blank 40 GB qcow2, reboots and expects `session-ready` from the installed system. It runs one preset per profile combination.
- **openQA** (visual, scripted UI tests) is adopted in Phase 7.

### Performance harness (`tests/perf/`)
| Metric | Method | Budget source |
|---|---|---|
| Boot to greeter | `systemd-analyze time` + serial marker timestamps in KVM (4 vCPU, 4 GB, virtio disk) | VISION §12 (VM budget is calibrated against the 12 s NVMe target in Phase 0) |
| Idle RAM | 60 s after `session-ready`: `MemTotal − MemAvailable` from `/proc/meminfo`, plus per-unit `MemoryCurrent` of `lugh-session.target` | [system-base](system-base.md) NFR-1 |
| Shell start-up | time from `lugh-shell` exec to first frame (marker) | ≤ 400 ms |
| Compositor frame time | headless backend runs scripted scenes (open 10 windows, workspace switch, mode switch, launcher open). Records per-frame CPU/GPU time and presentation timestamps. Budget is p99 ≤ refresh interval at 144 Hz | [compositor](compositor.md) |
| App start | cold start of Settings, Store, Tasks to first frame | ≤ 600 ms each |

Results are stored as JSON artifacts. The job fails on a budget breach, and warns on a > 10% regression from the 7-day median. Real-hardware numbers come from the Phase 7 hardware lab.

### Reproducibility
- `SOURCE_DATE_EPOCH` is set from the commit time.
- The Debian snapshot is pinned (`LUGH_SNAPSHOT`), the Rust toolchain is pinned, and crates are vendored with checksums.
- Each ISO ships `lugh-<ver>.packages` (name + version list) and `lugh-<ver>.buildinfo` (commit, snapshot, toolchain).

### Release checklist (`docs/releases/CHECKLIST.md` once it exists)
1. Phase exit checklist complete (see the phase doc).
2. `main` green: lint, tests, boot matrix, installer matrix, perf.
3. Version bumped, changelogs generated from conventional commits.
4. Tag `vX.Y.Z` → `release.yml` builds artifacts.
5. Manual smoke test on at least 2 real machines (one Intel, one AMD; NVIDIA once Phase 3+).
6. Sign `SHA256SUMS` with the stable key (manual hardware-token step).
7. Promote the aptly snapshot to the target suite.
8. Publish release notes (`docs/releases/<version>.md`) and update download links.
9. Watch for 72 h. Hotfixes go through `lugh1-security` if they're urgent.

## UX
Mostly for contributors:
- `make help` lists all targets.
- CI comments on PRs with a summary table (build, boot, perf deltas) and a link to the session-ready screenshot.
- Users see channel selection in Settings → About, and download verification instructions on the website (plus automatic verification in the Windows Setup, see [windows-setup](windows-setup.md)).

## Security & privacy
- Build containers have no secrets. Signing happens in a separate job with minimal permissions (`environment: release`, required reviewers).
- Third-party GitHub Actions are pinned by commit SHA.
- Vendored crates are audited with `cargo deny` (licenses + advisories) in `lint.yml`.
- The ISO contains no telemetry endpoints. The download mirrors log nothing beyond standard web server logs (policy to be written with hosting).

## Testing
This spec *is* the testing infrastructure. It validates itself as follows:
- A weekly job rebuilds last week's ISO from its tag and diffs the package manifest (reproducibility check).
- A broken-boot canary (a deliberately failing unit, enabled only in a test flag) confirms the harness catches failures.

## Open questions
- Hosting for the apt repo and ISOs (VISION §16). Mirrors? CDN?
- Ed25519 or RSA 4096 for the archive key?
- Codename theme and the first codename.
- Do we need ARM64 builds before Lugh 1.0, or after?
