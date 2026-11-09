# Lugh: System Architecture

How the pieces of Lugh fit together. For *why* each choice was made, see [DECISIONS.md](DECISIONS.md). For detail on each piece, see `specs/`.

## 1. Layer view

```
┌──────────────────────────────────────────────────────────────────────────┐
│  Apps (QML + Rust/cxx-qt)                                                │
│  Settings · Store · Tasks · Bridge · Shield · Welcome · (3rd-party apps) │
├──────────────────────────────────────────────────────────────────────────┤
│  lugh-shell (QML)            lugh-greeter (QML)       Calamares + Lugh   │
│  bar · dock/taskbar · launcher · notifications · control center · lock   │
├──────────────────────────────────────────────────────────────────────────┤
│  Wayland compositor: Hyprland (Phases 1–4)  →  lugh-compositor (Phase 5+)│
│  + xdg-desktop-portal-(hyprland|lugh) · Xwayland                         │
├──────────────────────────────────────────────────────────────────────────┤
│  Lugh daemons (Rust, D-Bus, polkit)                                      │
│  lugh-stored · lugh-bridged · lugh-shieldd · lugh-tasksd · lugh-configd  │
│  lugh-settingsd · lugh-updated                                           │
├──────────────────────────────────────────────────────────────────────────┤
│  Desktop plumbing                                                        │
│  systemd · PipeWire/WirePlumber · NetworkManager · BlueZ · UPower ·      │
│  power-profiles-daemon · PackageKit · Flatpak · fwupd · snapper · greetd │
├──────────────────────────────────────────────────────────────────────────┤
│  Debian 13 base · Lugh kernel/Mesa (from the Lugh repo) · Btrfs          │
└──────────────────────────────────────────────────────────────────────────┘
```

## 2. Components

| Component | Kind | Language | Bus name / binary | Spec | First phase |
|---|---|---|---|---|---|
| ISO & base system | build config | shell, live-build | n/a | [system-base](specs/system-base.md), [build-and-release](specs/build-and-release.md) | 0 |
| Branding | assets | SVG, GRUB/Plymouth scripts | `lugh-branding` (.deb) | [design-system](DESIGN-SYSTEM.md) | 0 |
| Shell | UI | QML + Rust | `lugh-shell` | [shell](specs/shell.md) | 1 |
| Greeter | UI | QML | `lugh-greeter` | [shell](specs/shell.md) §Greeter | 1 |
| Installer | UI | Calamares + QML + Python modules | `calamares` + `lugh-calamares-config` | [installer](specs/installer.md) | 1 |
| Settings | UI + daemon | QML / Rust | `lugh-settings`, `space.lugh.Settings1` | [settings](specs/settings.md) | 2 |
| Tasks | UI + daemon | QML / Rust | `lugh-tasks`, `space.lugh.Tasks1` | [tasks](specs/tasks.md) | 2 |
| Lughfile | CLI + daemon | Rust | `lugh`, `space.lugh.Config1` | [lughfile](specs/lughfile.md) | 2 |
| Store | UI + daemon | QML / Rust | `lugh-store`, `space.lugh.Store1` | [store](specs/store.md) | 3 |
| Bridge | UI + daemon | QML / Rust | `lugh-bridge`, `space.lugh.Bridge1` | [bridge](specs/bridge.md) | 3 |
| Updates | daemon | Rust | `space.lugh.Update1` | [system-base](specs/system-base.md) §Updates | 3 |
| Shield | UI + daemon + CLI | QML / Rust | `lugh-shield`, `space.lugh.Shield1` | [shield](specs/shield.md) | 4 |
| Compositor | compositor | Rust (Smithay) | `lugh-compositor` | [compositor](specs/compositor.md) | 5 |
| Portal backend | daemon | Rust | `xdg-desktop-portal-lugh` | [compositor](specs/compositor.md) §Portals | 5 |
| Windows Setup | Windows app | Rust + QML | `LughSetup.exe` | [windows-setup](specs/windows-setup.md) | 6 |

> The D-Bus namespace `space.lugh.*` is a placeholder until a domain is chosen. Rename it everywhere when that happens. APIs carry a version suffix (`…1`), and breaking changes bump it.

## 3. Communication

```
 lugh-store (UI) ──D-Bus──▶ lugh-stored ──▶ PackageKit / libflatpak / lugh-bridged
 lugh-tasks (UI) ──D-Bus──▶ lugh-tasksd ──▶ /proc, DRM fdinfo, systemd1, journald
 Shield UI / file manager / shell ──D-Bus──▶ lugh-shieldd ──▶ bwrap, systemd scopes, nftables
 lugh (CLI) / Settings ──D-Bus──▶ lugh-configd ──▶ stored, bridged, settingsd, systemd1
 lugh-shell ──Wayland──▶ compositor (layer-shell, foreign-toplevel, ext-workspace, lugh-shell-v1)
 lugh-shell ──D-Bus──▶ NetworkManager, BlueZ, UPower, PipeWire (via WirePlumber), Notifications
```

Rules:
1. **UIs never touch the system directly.** They call a daemon.
2. **Privileged actions go through polkit**, with an action ID per operation (e.g. `space.lugh.tasks.unit-edit`). The polkit agent lives in the shell.
3. **System daemons** (root, D-Bus system bus) are `stored`, `tasksd` (privileged parts), `updated` and `configd` (system part). **User daemons** (session bus) are `bridged`, `shieldd` (user sandboxes), `settingsd` and `configd` (user part).
4. Daemons are **systemd-activated** on first D-Bus call and exit when idle. This is what keeps idle RAM low (VISION §12).
5. Every daemon API has a CLI equivalent: `lugh store …`, `lugh tasks …`, `lugh shield …`, `lugh bridge …`, `lugh apply …`.

## 4. Process & session model

- greetd starts `lugh-session`, which brings up a systemd user target: `lugh-session.target`.
- The compositor is a systemd user service. The shell and its helpers are services bound to the session target.
- Every app launched by the shell, the store or a file association runs in a transient systemd **scope** (ADR-015): `app-lugh-<appid>-<id>.scope`.
- Quarantined apps run in `app-lugh-shield-<appid>-<id>.scope`, inside `lugh-shield.slice` (with resource limits and an nftables match).
- Wine bottles run in `app-lugh-bridge-<bottle>-<id>.scope`.

## 5. Wayland protocols

| Protocol | Used by | Hyprland interim | lugh-compositor |
|---|---|---|---|
| `wlr-layer-shell-unstable-v1` | bar, dock, notifications, launcher, OSDs | yes | yes |
| `wlr-foreign-toplevel-management` / `ext-foreign-toplevel-list` | taskbar, dock, Alt+Tab | yes | yes |
| `ext-workspace-v1` | workspace indicator and overview | via Hyprland IPC adapter | yes |
| `ext-session-lock-v1` | lock screen | yes | yes |
| `wp-security-context-v1` | Shield window isolation | partial / unverified | yes (enforced) |
| `wlr-screencopy` / `ext-image-copy-capture` | screenshots | yes | yes (blocked for quarantined clients) |
| `lugh-shell-v1` (ours) | mode switching, window marks, animation hints, quarantine borders | n/a | yes |

`lugh-shell-v1` is a private protocol, defined in `protocols/lugh-shell-v1.xml` and versioned.

## 6. Repository layout (monorepo)

```
lugh/
├── docs/                  # this documentation
├── iso/                   # live-build config (package lists, hooks, includes)
├── branding/              # logo slots, wallpapers, GRUB theme, Plymouth, os-release, icons
├── protocols/             # lugh-shell-v1.xml and other private protocols
├── crates/                # Rust workspace
│   ├── lugh-common/       #   shared types, D-Bus helpers, config, logging
│   ├── lugh-compositor/
│   ├── lugh-stored/ lugh-bridged/ lugh-shieldd/ lugh-tasksd/
│   ├── lugh-configd/ lugh-settingsd/ lugh-updated/
│   └── lugh-cli/          #   `lugh` command
├── ui/                    # QML apps (each with a small Rust/cxx-qt core)
│   ├── components/        #   shared QML design-system components (LughUI)
│   ├── shell/ greeter/ settings/ store/ tasks/ bridge/ shield/ welcome/
├── installer/             # Calamares branding, settings, custom modules, profiles
├── windows-setup/         # LughSetup.exe
├── recipes/               # Bridge recipes (may move to its own repo)
├── packaging/             # debian/ dirs, repo scripts, signing docs
├── tests/                 # QEMU boot tests, perf harness, integration tests
└── .github/workflows/     # CI: build, test, ISO, perf, release
```

## 7. Data locations

| What | Where |
|---|---|
| Lughfile (user) | `~/.config/lugh/` (git repo) |
| Lughfile (system, optional) | `/etc/lugh/system.toml` |
| Shell and desktop settings | `~/.config/lugh/desktop.toml` (managed by settingsd, included by the Lughfile) |
| Bridge bottles | `~/.local/share/lugh/bridge/bottles/<bottle>/` |
| Bridge runners and runtimes | `~/.local/share/lugh/bridge/runners/` (shared across bottles) |
| Shield overlays | `~/.local/share/lugh/shield/sessions/<id>/` |
| Unit-edit history (Tasks) | `/var/lib/lugh/tasks/history/` |
| Daemon logs | journald (`journalctl --user -u lugh-*`) |

## 8. Security model (summary)

- No custom setuid binaries. Privilege comes only through polkit and system daemons.
- Secure Boot is supported through Debian's signed shim, GRUB and kernel. Lugh's own kernel builds (if used) need our own MOK, documented in [system-base](specs/system-base.md).
- Signed apt repo. Bridge recipes in the official catalog are signed.
- Shield (Phase 4/5) provides user-facing isolation. Flatpak apps keep their own sandbox.
- Wayland only, so apps can't read each other's input or screen without portals.

## 9. Performance architecture

- Daemons are socket- or D-Bus-activated and exit when idle.
- The shell is one QML process using the threaded render loop. No web views anywhere in the core desktop.
- The compositor targets direct scanout, damage tracking, frame scheduling against vblank, and VRR (see [compositor](specs/compositor.md)).
- Every phase has performance budgets checked in CI (see [build-and-release](specs/build-and-release.md) §Performance).
