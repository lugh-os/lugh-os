# Lugh: Decision Log

Every significant decision is recorded here as a short ADR (Architecture Decision Record). To change a decision, add a new ADR that **supersedes** the old one. Never edit history.

Status values: **Accepted**, **Proposed** (not yet confirmed), **Superseded by ADR-NNN**.

---

## ADR-001: Debian 13 "Trixie" as the base
**Status:** Accepted, 2026-11-08
**Context:** We want a stable, well-supported base, and we don't want to maintain a kernel or a whole distribution.
**Decision:** Lugh is built on Debian 13 (stable), with `main contrib non-free non-free-firmware`, plus `trixie-backports`, plus our own **Lugh apt repository**.
**Consequences:** Stable and predictable. Some components (Mesa, kernel, Hyprland, Wine) are too old for gaming or desktop work, so we ship newer builds in the Lugh repo (ADR-003).

## ADR-002: live-build for the ISO
**Status:** Accepted, 2026-11-08
**Decision:** The ISO is produced by Debian's `live-build`. The config lives in `iso/` and is built in CI.
**Alternatives:** mmdebstrap + custom scripts (more control, more maintenance), or a debian-cd fork (too heavy).
**Consequences:** Reproducible, declarative ISO builds. Package lists and hooks are plain files.

## ADR-003: Our own apt repository (`repo.lugh`)
**Status:** Accepted, 2026-11-08
**Decision:** All Lugh components are shipped as `.deb` packages from our own signed apt repository, managed with `aptly` or `reprepro`. The repo also carries selected newer upstream packages (kernel, Mesa, Wine, Hyprland during the interim).
**Consequences:** Updates come through apt like everything else. We must sign, host and maintain the repo. Hosting is still open (see VISION §15).

## ADR-004: Wayland only
**Status:** Accepted, 2026-11-08
**Decision:** There is no X11 session. X11 apps run through Xwayland.
**Consequences:** Simpler stack, better security (needed for Shield) and better frame pacing. Some old X11-only tools won't work fully, such as global X11 hotkeys and certain screen recorders.

## ADR-005: Compositor written in Rust on Smithay
**Status:** Accepted, 2026-11-08
**Decision:** `lugh-compositor` is written in Rust using the Smithay library.
**Alternatives:** C/C++ on wlroots (mature, but memory-unsafe and with frequent API churn), or forking an existing compositor (inherits its design).
**Consequences:** Memory safety and full control of rendering and frame timing. COSMIC and niri prove the stack works. It's a large engineering effort, so it lands in Phase 5 (ADR-012).

## ADR-006: Qt 6 / QML for all user interfaces
**Status:** Accepted, 2026-11-08
**Decision:** The shell, settings, store, tasks, bridge, shield UI, greeter and installer branding all use Qt 6 + QML. Rust logic is bridged with **cxx-qt**.
**Consequences:** GPU-rendered, fluid animation, one visual language everywhere. Calamares already uses Qt/QML. The team needs both Rust and QML skills.

## ADR-007: Rust system daemons over D-Bus
**Status:** Accepted, 2026-11-08
**Decision:** Each feature has a Rust backend daemon that exposes a D-Bus API (using `zbus`). UIs are thin clients. Privileged operations are authorized through **polkit**.
**Consequences:** Features can be scripted (the CLI and the Lughfile use the same APIs). UIs can crash without losing state. The APIs need to be versioned.

## ADR-008: Calamares as the installer
**Status:** Accepted, 2026-11-08
**Decision:** The ISO installer is Calamares with Lugh branding, custom QML pages and a custom profile module. Unattended mode, used by the Windows Setup, is driven by a preset file.
**Consequences:** A proven, brandable installer with manual partitioning and LUKS. Custom work is needed for unattended mode and profiles.

## ADR-009: Btrfs + snapshots by default
**Status:** Accepted, 2026-11-08
**Decision:** Default filesystem is Btrfs with subvolumes `@`, `@home`, `@var_log`, `@cache` and `@snapshots`. `snapper` takes pre/post snapshots on every apt transaction. `grub-btrfs` makes snapshots bootable. ext4 is available in Advanced.
**Consequences:** A bad update can be rolled back from the boot menu. Snapshots use disk space, so retention limits are set.

## ADR-010: Light theme is the default
**Status:** Accepted, 2026-11-08
**Decision:** Lugh ships with the **light** theme. Dark is one click away, and automatic (sunset/sunrise) is optional.

## ADR-011: Firefox is the default browser
**Status:** Accepted, 2026-11-08
**Decision:** Firefox, installed from **Mozilla's official APT repository** (current release, not ESR), with no added extensions or telemetry changes beyond Mozilla's defaults.
**Consequences:** Users get the current Firefox with fast updates. We add Mozilla's repo and signing key to the base image.

## ADR-012: Shell first on Hyprland, own compositor later
**Status:** Accepted, 2026-11-08
**Decision:** Phases 1–4 run `lugh-shell` on **Hyprland** as an interim compositor. The shell only uses standard Wayland protocols (layer-shell, foreign-toplevel, ext-workspace, session-lock) plus a thin adapter for Hyprland IPC. Phase 5 replaces Hyprland with `lugh-compositor`.
**Consequences:** A usable desktop early, and the shell is never thrown away. Some features (quarantine window borders, mode-specific animations) are limited until Phase 5.

## ADR-013: No office suite shipped by default
**Status:** Accepted, 2026-11-08
**Decision:** No install profile ships an office suite. LibreOffice and OnlyOffice are featured in the Store, and the first-run welcome screen offers them.
**Consequences:** Smaller ISO and lighter installs.

## ADR-014: greetd + our own QML greeter
**Status:** Accepted, 2026-11-08
**Decision:** The login manager is `greetd`, with `lugh-greeter` (QML) as the front end.
**Alternatives:** SDDM (heavier, X11 legacy) or GDM (tied to GNOME).
**Consequences:** Minimal and Wayland-native. Interim (Phase 0–1): `tuigreet` or a basic greeter.

## ADR-015: Every app runs in its own systemd scope
**Status:** Accepted, 2026-11-08
**Decision:** The launcher starts every app as a transient systemd user scope (`app-lugh-<appid>-<rand>.scope`), following the systemd/XDG convention.
**Consequences:** Exact per-app grouping in Lugh Tasks, per-app resource limits, and freeze or network-cut for Shield, all for free.

## ADR-016: One Wine bottle per app; umu for gaming
**Status:** Accepted, 2026-11-08
**Decision:** Lugh Bridge creates an isolated Wine prefix ("bottle") per app or launcher. Gaming bottles run Proton through **umu-launcher**. App bottles use upstream Wine (WineHQ builds in the Lugh repo).
**Consequences:** Fixes for one app never break another. Uses more disk space, which is mitigated by sharing runners and runtimes.

## ADR-017: Sandboxing with bubblewrap + Landlock + seccomp
**Status:** Accepted, 2026-11-08
**Decision:** Shield builds sandboxes from bubblewrap (namespaces), Landlock (filesystem rules), seccomp (syscall filter), overlayfs (throwaway writes), `pasta` (filtered networking), cgroups (limits and freeze) and nftables (per-cgroup network cut).
**Consequences:** No setuid binaries of our own, and it works unprivileged. Window-level isolation (clipboard, screenshots) needs compositor support, so it is full only from Phase 5.

## ADR-018: Lughfile uses TOML in a git repo
**Status:** Accepted, 2026-11-08
**Decision:** User system state lives in `~/.config/lugh/lugh.toml` plus `dotfiles/` and `bridge/`, as a git repository. The `lugh` CLI and Settings read and write it.
**Consequences:** Readable, diff-able and pushable to GitHub. It is declarative-ish, not bit-for-bit reproducible. Secrets are never stored in it.

## ADR-019: Store backends are PackageKit + libflatpak + Bridge
**Status:** Accepted, 2026-11-08
**Decision:** `lugh-stored` uses PackageKit (apt backend) for Debian/Lugh packages, libflatpak for Flathub, and Lugh Bridge recipes for Windows apps. Metadata comes from AppStream.
**Consequences:** We rely on maintained backends instead of reimplementing apt.

## ADR-020: Desktop plumbing choices
**Status:** Accepted, 2026-11-08
**Decision:** PipeWire + WirePlumber (audio and screencast), NetworkManager, BlueZ, power-profiles-daemon, UPower, fwupd, xdg-desktop-portal (with a `xdg-desktop-portal-lugh` backend from Phase 5; `-hyprland` + `-gtk` until then), gnome-keyring (Secret Service), and the shell's own polkit agent.

## ADR-021: Default fonts are Inter and JetBrains Mono
**Status:** Accepted, 2026-11-08
**Decision:** UI font is Inter, monospace is JetBrains Mono, fallback is Noto (wide script coverage plus emoji).

## ADR-022: License
**Status:** Proposed
**Proposal:** GPL-3.0-or-later for Lugh apps and daemons (matches Calamares and Qt GPL usage). Smithay is MIT, which is compatible.
**Open:** waiting for the founder's confirmation.

## ADR-023: firewalld with default-deny inbound
**Status:** Accepted, 2026-11-08
**Decision:** Firewall is `firewalld`. The default zone `lugh-public` denies inbound traffic except DHCPv6 client and mDNS. A "Home" network profile in Settings loosens it for LAN sharing.
**Alternatives:** ufw (simpler, but no D-Bus API for Settings to drive and no per-connection zones).
**Consequences:** Settings and NetworkManager can switch zones per network. Details in [specs/system-base.md](specs/system-base.md).

## ADR-024: Default apps are light Qt apps (interim)
**Status:** Accepted, 2026-11-08
**Decision:** Files = `pcmanfm-qt`, terminal = `foot`, images = `qimgv`, PDF = `qpdfview`, archives = `lxqt-archiver`, text = `featherpad`, calculator = `qalculate-qt`. They're chosen because they match the Qt stack and stay light (no full KDE Frameworks or GNOME stack).
**Consequences:** Low RAM and a consistent toolkit. Open question: build **Lugh Files** (QML) later, because Shield and Bridge integrate best with a file manager we control.
