# Lugh OS: Documentation

Lugh is a Debian-based desktop OS: easy for people coming from Windows, fast and hackable for Linux people, and with every feature optional.

## Start here
| Doc | What it answers |
|---|---|
| [VISION.md](VISION.md) | What Lugh is, who it's for, and the features at a glance |
| [ROADMAP.md](ROADMAP.md) | The 8 phases, their order and dependencies |
| [ARCHITECTURE.md](ARCHITECTURE.md) | How the pieces fit together, repo layout, D-Bus and Wayland interfaces |
| [DECISIONS.md](DECISIONS.md) | Every major decision and why (ADR log) |
| [DESIGN-SYSTEM.md](DESIGN-SYSTEM.md) | Colors, type, spacing, motion, the 3 desktop modes, brand asset slots |

## Phases (what gets built, in order)
| # | Phase | Doc |
|---|---|---|
| 0 | Foundation: repo, CI, branded bootable ISO | [phases/phase-0-foundation.md](phases/phase-0-foundation.md) |
| 1 | Desktop v0: shell on Hyprland, greeter, installer + profiles | [phases/phase-1-desktop-v0.md](phases/phase-1-desktop-v0.md) |
| 2 | Core apps: Settings, Tasks, Lughfile | [phases/phase-2-core-apps.md](phases/phase-2-core-apps.md) |
| 3 | Store + Bridge + update center | [phases/phase-3-store-bridge.md](phases/phase-3-store-bridge.md) |
| 4 | Shield (quarantine) | [phases/phase-4-shield.md](phases/phase-4-shield.md) |
| 5 | Own compositor + all 3 modes | [phases/phase-5-compositor.md](phases/phase-5-compositor.md) |
| 6 | Windows Setup (one-click install from Windows) | [phases/phase-6-windows-setup.md](phases/phase-6-windows-setup.md) |
| 7 | Public beta | [phases/phase-7-beta.md](phases/phase-7-beta.md) |

## Component specs (how each piece works)
| Spec | Covers |
|---|---|
| [specs/system-base.md](specs/system-base.md) | Debian base, package sets, services, filesystem/snapshots, updates, Secure Boot, security defaults |
| [specs/build-and-release.md](specs/build-and-release.md) | live-build, CI, packaging, apt repo, versioning, release channels, test and perf harness |
| [specs/shell.md](specs/shell.md) | Bar, dock/taskbar, launcher, notifications, control center, lock screen, greeter, mode switching |
| [specs/compositor.md](specs/compositor.md) | lugh-compositor: rendering, input, layouts, protocols, portals, performance |
| [specs/installer.md](specs/installer.md) | Calamares setup, Express/Advanced, profiles, Lughfile restore, unattended mode, drivers |
| [specs/windows-setup.md](specs/windows-setup.md) | LughSetup.exe: checks, partitioning, boot entry, unattended handoff |
| [specs/settings.md](specs/settings.md) | Lugh Settings app and settings daemon |
| [specs/store.md](specs/store.md) | Lugh Store: sources, Windows-aware search, updates |
| [specs/lughfile.md](specs/lughfile.md) | Config-as-code: format, CLI, apply/export/sync semantics |
| [specs/shield.md](specs/shield.md) | Quarantine: sandbox profiles, folder/process quarantine, UX |
| [specs/bridge.md](specs/bridge.md) | Lugh Bridge: bottles, runners, profiles, recipes, launchers and games |
| [specs/tasks.md](specs/tasks.md) | Lugh Tasks: processes, performance, services/systemd editing, logs, startup |

## Conventions
- A doc's status is shown at its top: **Draft**, **Approved** or **Implemented**.
- Decisions go in DECISIONS.md. Specs link to ADRs instead of repeating the reasoning.
- Placeholder names: D-Bus `space.lugh.*`, repo `repo.lugh`. Rename them everywhere once a domain is chosen.
