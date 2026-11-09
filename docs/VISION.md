# Lugh OS: Vision & Requirements

> Status: **Approved v0.2**, 2026-11-08. This is the source of truth for *what* Lugh is. Decisions are logged in [DECISIONS.md](DECISIONS.md), the build order in [ROADMAP.md](ROADMAP.md), and the full index in [README.md](README.md).

## 1. What Lugh is

Lugh is a Debian-based desktop OS that is:

- **Easy for people coming from Windows.** Installing it, installing apps and running Windows software should all feel familiar.
- **Respected by Linux people.** It's fast, keyboard-friendly, declarative and hackable, and it doesn't fight you.
- **Optional by default.** Every big feature can be switched off. A minimal install is literally *desktop + browser + VLC*.

Lugh is the Irish god of light and of all crafts, so the brand is warm, bright and well-made.

## 2. Principles

1. **Fast and fluid first.** Every animation holds the display's refresh rate, and every feature is measured (see §12).
2. **Light by default.** Nothing heavy runs unless the user asked for it.
3. **One click for the common case, full control in Advanced.** This applies to the installer, partitioning, the store, Wine and services.
4. **Everything is optional.** Profiles decide what ships. Nothing is forced.
5. **Your setup is a file.** The whole system state can be exported, versioned in git and restored.
6. **Safe to try things.** Untrusted apps and folders can be opened in quarantine with one click.

## 3. Base system

| Item | Decision |
|---|---|
| Base | Debian 13 "Trixie" (stable) |
| Fresher stack | Debian backports + our own **Lugh apt repo** for our packages, a newer kernel and newer Mesa (gaming needs them) |
| Arch | x86_64 (arm64 later) |
| Firmware | `non-free-firmware` included, so Wi-Fi and GPUs work out of the box |
| Display | Wayland only (X11 apps through Xwayland) |
| Boot | UEFI + Secure Boot through Debian's signed shim/GRUB/kernel. Legacy BIOS supported in Advanced |
| Filesystem | **Btrfs** by default with automatic snapshots (rollback after bad updates). ext4 available in Advanced |
| ISO build | `live-build`, config in this repo, reproducible builds in CI |

## 4. Desktop: Lugh Shell

Built from scratch. It has three **modes**, and the user switches between them live in Settings without logging out.

### 4.1 Modes

| Mode | Look & feel | Who it's for |
|---|---|---|
| **Lugh** (default) | macOS-inspired: slim top bar, centered floating dock, rounded corners, soft blur, spring animations. Floating windows with optional Hyprland-style tiling and workspace gestures. Modern but restrained ("the middle ground") | Everyone |
| **Classic** | Windows-like: bottom taskbar, Start menu, window buttons on the right, Win key, Alt+Tab, snap layouts | People coming from Windows |
| **Focus** | Ultra-minimal, Hyprland-style: tiling with gaps, a thin bar or none, keyboard-driven, animated workspaces | Power users |

### 4.2 Components
- **Compositor** (`lugh-compositor`): Wayland compositor that supports floating and tiling, VRR, direct scanout for games, fractional scaling, HDR later.
- **Shell** (`lugh-shell`): bar, dock/taskbar, launcher (Spotlight-like search for apps, files, settings and the store), notifications, control center (Wi-Fi, Bluetooth, sound, brightness, power), lock screen, workspace overview.
- **Settings** (`lugh-settings`): one app for everything, with mode switching, themes, displays, input, users and updates.
- **Greeter**: the login screen, matching the shell.

### 4.3 Look
- **Light theme by default** (ADR-010). Dark is one click away. The accent color can be changed.
- Brand palette in §11. Logo is designed by the founder.
- Type: **Inter** for UI and **JetBrains Mono** for terminals and code (ADR-021). Full system in [DESIGN-SYSTEM.md](DESIGN-SYSTEM.md).
- Motion: 150–300 ms, spring-based, interruptible. A "reduce motion" switch turns it off.

## 5. Installer

### 5.1 One-click from Windows: `Lugh Setup.exe`
A normal Windows app. You download it, click **Install Lugh**, and it does this:
1. Checks the PC: UEFI, disk space, BitLocker, Fast Startup, Secure Boot.
2. Shrinks the Windows partition safely and creates Lugh partitions (dual boot). It can also replace Windows entirely.
3. Downloads or verifies the image and adds a boot entry.
4. Reboots into an **unattended** install with the choices already made, then boots straight into Lugh.

The hard cases it must handle:
- **BitLocker**: suspend it, and make sure the user has their recovery key.
- **Fast Startup / hibernation**: turn them off, because NTFS can't be shrunk safely otherwise.
- **Secure Boot**: works through the signed shim.
- **Low disk space** or an unusual layout: explain clearly and refuse rather than risk data.

There's also an **Advanced** button that offers manual partitioning or writing a bootable USB.

### 5.2 ISO / USB installer
**Calamares**, branded as Lugh. Express mode is a handful of screens. Advanced mode adds manual partitioning, encryption (LUKS) and the filesystem choice.

### 5.3 Install profiles
Picked during install and changeable later in Settings:

| Profile | Ships with |
|---|---|
| **Minimal** | Desktop, Firefox, VLC. Nothing else |
| **Standard** | Plus image viewer, PDF reader, archive manager, Lugh Store, Lugh Bridge (Wine). **No office suite** (ADR-013); LibreOffice and OnlyOffice are one click away in the Store |
| **Gaming** | Plus Steam, GameMode, MangoHud, gaming Wine profiles, controller support |
| **Developer** | Plus an IDE (VS Code / Codium or Zed), git, Docker/Podman, language toolchains (selectable), terminal extras |

The installer also offers **Restore from my Lughfile**: paste a git URL and get your whole setup back (§7).

## 6. Lugh Store

Inspired by the Pop!_OS store, but built to be friendly to Windows users.

- **One store, several sources**: Debian/Lugh apt, Flatpak (Flathub) and **Windows apps** (through Lugh Bridge recipes). The best source is chosen automatically, and you can override it.
- **Windows-aware search.** Search "Photoshop", "Notepad++" or "WinRAR" and the store shows:
  - the native Linux version if one exists,
  - the best alternatives ("Use Krita or GIMP"),
  - or "Run the Windows version", which installs it through a tested Wine recipe.
- **Double-clicking an `.exe` or `.msi`** opens Lugh Bridge instead of an error.
- Updates for the system, apps and firmware (fwupd) all in one place. Each update takes an automatic snapshot first.
- Curated categories, screenshots and ratings.

## 7. Lughfile: your whole setup as code

Inspired by declarative distros like NixOS, but on Debian and much simpler.

```
~/.config/lugh/            (a git repo)
├── lugh.toml              # packages, flatpaks, Windows apps, services, desktop mode, theme
├── dotfiles/              # app configs to link in
└── wine/                  # Bridge bottles to recreate
```

Commands, each with a GUI equivalent in Settings:
- `lugh export`: snapshots the current system into the Lughfile.
- `lugh apply`: makes the system match the Lughfile (install, remove, configure).
- `lugh diff`: shows what would change.
- `lugh sync`: pushes to or pulls from your GitHub/GitLab repo.

**Limit to state up front:** this is *declarative-ish*, not bit-for-bit reproducible like Nix. It reliably restores packages, settings, dotfiles and services.

## 8. Quarantine (`lugh-shield`)

Open untrusted things safely with one click.

| Action | What happens |
|---|---|
| **Open in Quarantine** (right-click any app, file, `.exe` or folder) | It runs in a sandbox: no access to your home folder, no network by default, and file changes go into a throwaway layer you can review, keep or discard |
| **Quarantine a folder** | Everything inside can only open sandboxed. Good for downloads, USB sticks and cloned repos |
| **Quarantine a running process** | Freeze it, cut its network, limit CPU and memory, or kill it. Note: a process that is *already running* can't be fully re-sandboxed after the fact. That needs a relaunch in quarantine, which we offer |
| **Auto-quarantine downloads** (optional) | Downloaded files get marked, like Windows' "Mark of the Web" and macOS Gatekeeper, and open quarantined until trusted |

Quarantined windows get a distinct **striped border and a shield icon** drawn by the compositor, so they're never marked by color alone. They're also blocked from screenshots, the clipboard and global hotkeys.

Tech: bubblewrap namespaces + Landlock + seccomp + overlayfs + cgroups + nftables, plus Wayland security-context, which our compositor enforces.

## 9. Lugh Bridge: first-class Windows apps & games

Built in and integrated with the store.

- **One bottle per app.** Every app gets its own isolated Wine prefix, so installing one app can never break another. This fixes the "one fix breaks the others" problem.
- **Profiles** pre-tune each bottle:
  - *Gaming*: Proton-based runtime (via umu), DXVK, VKD3D-Proton, fsync, GameMode, MangoHud
  - *Apps*: stable Wine, fonts, .NET and VC++ runtimes
  - *Legacy*: 32-bit, older Windows version, quirks
  - *Custom*: pick the runner, version, DLL overrides, env vars and winetricks
- **Recipes.** Community, versioned install scripts for popular apps and launchers (Epic, GOG, EA, Ubisoft, Battle.net and so on) apply the right fixes automatically. Users can write their own recipe and share it.
- **Launchers & games.** Native Steam with Proton. Non-Steam launchers through recipes. All games show up in one library.
- **Integration.** Start menu and launcher entries, file associations, tray icons, and per-bottle backup in your Lughfile.
- Any bottle can be **launched in Quarantine**.

## 10. Lugh Tasks: task manager + service manager

An "insane" system tool, like Windows Task Manager, Process Explorer and a systemd GUI combined.

- **Apps & processes**, grouped by app. Every app runs in its own systemd scope, so the grouping is exact. Per-process CPU, RAM, GPU, disk, network and energy use.
- **Performance**: live graphs for CPU per core, GPU, RAM, swap, disks, network and temperatures.
- **Services**: every systemd unit (system and user). Start, stop, restart, enable, disable and mask.
  - **Edit unit files directly** with syntax highlighting. Saves as safe drop-in overrides, is validated with `systemd-analyze verify` before applying, and can be reverted in one click.
  - Live **logs** (journald) per unit, with filters.
  - Timers, sockets, failed units, dependency view.
- **Startup**: startup apps and services, plus boot-time analysis (`systemd-analyze blame`).
- Actions from here: quarantine, freeze, set priority and limit resources for any process.
- Privileged actions go through polkit with clear prompts.

## 11. Brand palette (draft)

Warm neutrals with one deliberate accent, **Lugh Amber** (sunlight). All text pairs below pass WCAG AA (contrast ratio in brackets).

**Light**
| Token | Hex | Use |
|---|---|---|
| bg | `#F7F6F3` | desktop surfaces |
| surface | `#FFFFFF` | windows, cards |
| surface-2 | `#EEECE7` | sidebars, inputs |
| border | `#DEDAD2` | dividers |
| text | `#1C1B19` | body (15.9:1) |
| text-muted | `#5F5B54` | secondary (6.3:1) |
| accent | `#E8962E` | fills, focus rings (dark text on top: 7.2:1) |
| accent-text | `#9A5800` | links and accent text (5.2:1) |

**Dark**
| Token | Hex | Use |
|---|---|---|
| bg | `#141413` | |
| surface | `#1C1B19` | |
| surface-2 | `#262522` | |
| border | `#34322E` | |
| text | `#EDEBE6` | (15.5:1) |
| text-muted | `#A29D94` | (6.8:1) |
| accent | `#F2A93B` | fills and text (9.2:1) |

**Semantic (light / dark)**: success `#1F7A4A` / `#4CC38A`, danger `#B4322A` / `#F06A5F`, info `#1E6A8C` / `#5BB4DA`. Quarantine uses danger plus a stripe pattern and an icon.

## 12. Performance targets (proposed; verified in CI)

| Metric | Target |
|---|---|
| Animations | No dropped frames at 60, 120 and 144 Hz on mid-range iGPUs |
| Input to photon | No slower than Hyprland or KWin on the same hardware |
| Idle RAM, whole session (Minimal profile) | ≤ 450 MB |
| Idle RAM, whole session (Standard profile) | ≤ 750 MB |
| Boot to desktop (NVMe) | ≤ 12 s |
| Mode switch (Lugh, Classic, Focus) | < 300 ms, no logout |
| Fullscreen games | Direct scanout, VRR, and no compositor overhead |

Benchmarks run on every commit: a headless compositor for frame-timing tests and QEMU for boot and RAM.

## 13. Tech stack (confirmed)

| Part | Choice | Why |
|---|---|---|
| Compositor | **Rust + Smithay** | Memory-safe, the same base COSMIC and niri use, fine control over frame timing |
| Shell & apps UI | **Qt 6 / QML** | GPU-rendered, made for fluid animation, Wayland layer-shell support, and Calamares already uses it |
| System services | **Rust daemons over D-Bus** (zbus) | One backend per feature (store, shield, bridge, tasks, lughfile), and the UIs stay thin |
| Privileges | polkit | |
| Windows installer | Rust + a small native UI | Same language as the rest |
| ISO | live-build + GitHub Actions | |

## 14. Roadmap

Each phase ends with a bootable ISO.

| Phase | Goal |
|---|---|
| **0. Foundation** | Repo and CI, a live-build ISO that boots Debian minimal in QEMU, Lugh branding (os-release, GRUB, Plymouth) |
| **1. Desktop v0** | `lugh-shell` (bar, dock, launcher, notifications, control center) running on an **existing** compositor (Hyprland) so we can dogfood early. Calamares with the 4 profiles |
| **2. Core apps** | Lugh Tasks, Lugh Settings, Lughfile CLI |
| **3. Store + Bridge** | Lugh Store (apt + Flatpak), Lugh Bridge with bottles, profiles and first recipes, `.exe` handling |
| **4. Shield** | Quarantine for apps, files, folders and processes |
| **5. Own compositor** | `lugh-compositor` replaces Hyprland, with the 3 modes, quarantine borders and performance targets |
| **6. Windows Setup** | `Lugh Setup.exe` one-click dual-boot installer |
| **7. Beta** | Real-hardware testing, the Lugh apt repo, an update channel, a website |

Why the compositor comes in Phase 5: writing one is the hardest single piece. Building the shell on standard Wayland protocols lets it run on Hyprland now and on ours later, so nothing gets thrown away.

## 15. Decisions made (2026-11-08)
- Default theme: **light** (ADR-010)
- Default browser: **Firefox** from Mozilla's official APT repo (ADR-011)
- Office suite: **none shipped**, available in the Store (ADR-013)
- Stack: **Rust + Qt6/QML** confirmed (ADR-005, ADR-006, ADR-007)

## 16. Open questions
- Hosting and domain for the Lugh apt repo, recipes and downloads (this also decides the D-Bus namespace, which is a `space.lugh.*` placeholder for now).
- License: GPL-3.0-or-later is proposed (ADR-022).
- Developer profile IDE: VSCodium, VS Code (Microsoft repo) or Zed, or let the user pick at install?
- NVIDIA proprietary driver: offer at install (with Secure Boot MOK enrollment) or post-install only?
- File manager: keep `pcmanfm-qt` or build our own **Lugh Files** in QML (ADR-024)?
