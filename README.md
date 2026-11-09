<p align="center">
  <img src="branding/logo/lugh-logo.svg" width="96" alt="Lugh">
</p>

# Lugh OS

Lugh is a Debian-based desktop OS: easy for people coming from Windows, fast and hackable for Linux people, and with every feature optional.

- **Easy for people coming from Windows.** Installing it, installing apps and running Windows software should all feel familiar.
- **Respected by Linux people.** Fast, keyboard-friendly, declarative and hackable.
- **Optional by default.** Every big feature can be switched off. A minimal install is literally *desktop + browser + VLC*.

It is built on Debian 13 "trixie", Wayland only, Btrfs with automatic snapshots, and UEFI + Secure Boot through Debian's signed boot chain. Read the full [vision](docs/VISION.md).

> **Status: Phase 0 — Foundation.** There is no desktop yet. This phase builds the factory: a branded, bootable ISO that boots to a console login in QEMU (UEFI, UEFI + Secure Boot, legacy BIOS), built and boot-tested in CI. See the [roadmap](docs/ROADMAP.md) and [Phase 0 plan](docs/phases/phase-0-foundation.md).

## Quick start

Host setup (KDE neon / Debian / Ubuntu, with podman) is in [docs/dev/setup.md](docs/dev/setup.md). The ISO is always built inside a Debian trixie container, so host tools only need to run QEMU.

```sh
make help         # list every target
make iso          # build out/lugh-<version>-amd64.iso (+ .sha256)
make run-uefi     # boot it in QEMU with UEFI firmware
make test-boot    # headless boot test in UEFI, UEFI + Secure Boot and BIOS modes
```

`make run-uefi-sb` and `make run-bios` boot the other firmware modes interactively. The version comes from [`VERSION`](VERSION).

## Repository layout

| Path | What lives there |
|---|---|
| [`docs/`](docs/) | Vision, roadmap, architecture, decisions (ADRs), design system, phase plans, component specs |
| `iso/` | live-build config: package lists, hooks, includes |
| `branding/` | Logo slots, wallpapers, GRUB theme, Plymouth theme, os-release, icons |
| `protocols/` | `lugh-shell-v1.xml` and other private Wayland protocols |
| `crates/` | Rust workspace: `lugh-common`, and later the compositor, daemons and `lugh` CLI |
| `ui/` | QML apps, each with a small Rust/cxx-qt core; `ui/components/` holds the shared design-system components (LughUI) |
| `installer/` | Calamares branding, settings, custom modules, profiles |
| `windows-setup/` | `LughSetup.exe`, the one-click installer from Windows |
| `recipes/` | Lugh Bridge recipes for Windows apps and games |
| `packaging/` | Debian packaging, apt repo scripts, signing docs |
| `scripts/` | Build scripts and the Debian build container |
| `tests/` | QEMU boot tests, perf harness, integration tests |
| `.github/workflows/` | CI: build, test, ISO, boot test, release |

The full picture is in [ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Documentation

Everything is in [`docs/`](docs/README.md): start with [VISION](docs/VISION.md), [ROADMAP](docs/ROADMAP.md), [ARCHITECTURE](docs/ARCHITECTURE.md), [DECISIONS](docs/DECISIONS.md) and [DESIGN-SYSTEM](docs/DESIGN-SYSTEM.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md): conventional commits, DCO sign-off, and the code style and design rules.

## License

Lugh is free software, licensed under the [GNU General Public License v3.0 or later](LICENSE) (GPL-3.0-or-later). The license choice is recorded as ADR-022 in [DECISIONS.md](docs/DECISIONS.md) and awaits final confirmation.
