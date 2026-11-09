# Lugh: Roadmap

Eight phases. **Every phase ends with a bootable ISO** that is better than the last one. Detailed plans live in `phases/`.

## Overview

| Phase | Name | Outcome (the ISO can…) | Size | Doc |
|---|---|---|---|---|
| 0 | Foundation | boot in QEMU into a branded minimal Debian; CI builds it on every commit | S | [phase-0](phases/phase-0-foundation.md) |
| 1 | Desktop v0 | boot into `lugh-shell` on Hyprland, in Lugh mode, with the greeter; install to disk with Calamares and the 4 profiles | L | [phase-1](phases/phase-1-desktop-v0.md) |
| 2 | Core apps | manage the system with Lugh Settings and Lugh Tasks; export, apply and sync a Lughfile | L | [phase-2](phases/phase-2-core-apps.md) |
| 3 | Store + Bridge | install apps from apt, Flathub and Windows recipes in one store; run `.exe` files in isolated bottles; update everything with snapshots | XL | [phase-3](phases/phase-3-store-bridge.md) |
| 4 | Shield | open any app, file, folder or `.exe` in quarantine; freeze or cut network for a running app | L | [phase-4](phases/phase-4-shield.md) |
| 5 | Own compositor | run on `lugh-compositor` with Lugh, Classic and Focus modes, quarantine borders, and the performance targets met | XL | [phase-5](phases/phase-5-compositor.md) |
| 6 | Windows Setup | be installed from inside Windows with one click (dual boot, unattended) | L | [phase-6](phases/phase-6-windows-setup.md) |
| 7 | Beta | be used daily on real hardware by outside testers, with a public repo, updates channel and website | L | [phase-7](phases/phase-7-beta.md) |

Sizes are relative effort (S < M < L < XL), not calendar time. They will be turned into dates once the team size is known.

## Dependency graph

```
Phase 0 ──▶ Phase 1 ──▶ Phase 2 ──▶ Phase 3 ──▶ Phase 4
                │                        │           │
                │                        └─────┬─────┘
                ▼                              ▼
     (compositor R&D can start          Phase 5 (needs Shield for
      in parallel after Phase 1)         window isolation; needs shell)
                                               │
                                               ▼
                                Phase 6 (needs stable installer + ISO)
                                               │
                                               ▼
                                            Phase 7
```

- **Compositor R&D** (Phase 5 prototype: a Smithay skeleton, rendering and input) can start in parallel as soon as Phase 1 is done, if a second contributor is available.
- **Windows Setup R&D** (partition shrink and boot-entry prototype) can also start early. Shipping it depends on a stable unattended installer (Phase 1 + 3).

## Feature to phase map

| VISION feature | Phases |
|---|---|
| Debian base, branding, ISO | 0 |
| Lugh Shell (bar, dock, launcher, notifications, control center, lock, greeter) | 1 (on Hyprland), 5 (full, 3 modes) |
| Desktop modes: Lugh / Classic / Focus | 1 (Lugh), 2 (Classic + Focus layouts on Hyprland, best effort), 5 (complete) |
| Calamares installer + profiles | 1 (profiles), 3 (Lughfile restore), 6 (unattended preset) |
| Lugh Settings | 2 |
| Lugh Tasks (task + service manager) | 2 |
| Lughfile | 2 (CLI + export/apply/sync), 3 (store/bridge entries), 1→3 (installer restore) |
| Lugh Store | 3 |
| Updates + snapshots | 0 (Btrfs layout), 3 (update center) |
| Lugh Bridge (Wine) | 3 |
| Shield (quarantine) | 4 (sandbox), 5 (window isolation + borders) |
| lugh-compositor | 5 |
| Windows Setup (one-click from Windows) | 6 |
| Public beta, hardware matrix, website | 7 |

## Global "definition of done" (applies to every phase)

1. The ISO builds in CI from a clean checkout.
2. Automated QEMU boot test passes (reaches the desktop or login).
3. Every new UI follows [DESIGN-SYSTEM.md](DESIGN-SYSTEM.md) and implements all states (§7).
4. Every new daemon has a D-Bus API doc, a CLI equivalent, polkit actions for privileged calls, and unit tests.
5. Performance budgets for the phase pass (see each phase doc).
6. Docs updated: the phase doc's exit checklist is ticked, the spec is updated if the design changed, and new decisions are added to DECISIONS.md.
7. A short release note is written in `docs/releases/<phase>.md`.
