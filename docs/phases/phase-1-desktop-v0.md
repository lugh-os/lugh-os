# Phase 1 — Desktop v0

> Status: **Draft** · Size: **L** · Depends on: Phase 0 · Specs: [shell](../specs/shell.md), [installer](../specs/installer.md), [system-base](../specs/system-base.md), [design-system](../DESIGN-SYSTEM.md) · Decisions: ADR-004, 006, 008, 009, 010, 011, 012, 013, 014, 015, 020, 021

## Goal

The ISO boots to a **Lugh login screen**, then into the **Lugh desktop in Lugh mode**: a slim glass top bar, a centered dock, Spotlight-style search, notifications, a control center (Wi-Fi, Bluetooth, sound, brightness, power) and a lock screen, all in the light theme and running smoothly on Hyprland. From the live session, the user can **install Lugh to disk** with Calamares (Express or Advanced) and pick one of four profiles: Minimal, Standard, Gaming or Developer. The installed system boots on a Btrfs layout with snapshots and greets the user with a short Welcome app. This is the first ISO a person could actually use day to day.

## Scope

**In**
- Hyprland as the interim compositor (ADR-012), with a Lugh-tuned config.
- Session plumbing: `lugh-session`, `lugh-session.target`, user services.
- **LughUI** QML component library (tokens and every state from DESIGN-SYSTEM §7).
- `lugh-shell`, **Lugh mode only**: bar, dock, launcher, notifications, control center, OSDs, polkit agent, lock screen, workspace indicator (through a Hyprland IPC adapter).
- App launching through systemd scopes (ADR-015).
- `lugh-greeter` on greetd (ADR-014).
- Calamares, branded: Express and Advanced, 4 profiles, Btrfs + snapper layout, LUKS option.
- `lugh-welcome` first-run app: theme (light default, dark option), accent, a short tour, and an office-suite offer (ADR-013).
- Base desktop apps per profile (file manager, terminal, text editor, VLC, Firefox).

**Out (deferred)**
- Classic and Focus modes → Phase 2 (best effort on Hyprland), Phase 5 (complete).
- Lugh Settings app → Phase 2. Phase 1 uses the control center plus Welcome. Anything beyond that falls back to config files (documented).
- Store → Phase 3. Phase 1 profiles install packages at install time only.
- Lughfile restore in the installer → Phase 3. Unattended install → Phase 6.
- Quarantine borders and window isolation → Phase 4/5.

## Deliverables

| Deliverable | Path | Package |
|---|---|---|
| Hyprland (verified version) + Lugh config | `packaging/hyprland/` (if rebuilt), `ui/shell/hypr/lugh.conf` | `hyprland` (Debian or Lugh repo), `lugh-hyprland-config` |
| Session files | `ui/shell/session/` | `lugh-session` |
| LughUI component library | `ui/components/` | `lugh-ui` (QML module `Lugh.UI`) |
| Shell | `ui/shell/` + `crates/lugh-shell-core/` | `lugh-shell` |
| Greeter | `ui/greeter/` | `lugh-greeter` |
| Calamares config, branding, profile module | `installer/` | `lugh-calamares-config` |
| Welcome app | `ui/welcome/` | `lugh-welcome` |
| Profile meta-packages | `packaging/lugh-profiles/` | `lugh-desktop-minimal`, `lugh-desktop-standard`, `lugh-desktop-gaming`, `lugh-desktop-developer` |
| Default wallpapers (placeholder) | `branding/wallpapers/` | `lugh-branding` |
| Release note | `docs/releases/phase-1.md` | — |

## Work breakdown

### 1. Interim compositor: Hyprland
- [ ] Check what trixie ships (`apt-cache policy hyprland`). If the version is missing, or too old for `ext-session-lock`, `wlr-foreign-toplevel` and stable IPC, package a pinned upstream release with its deps (`aquamarine`, `hyprutils`, `hyprlang`, `hyprcursor`, `hyprwayland-scanner`) in the Lugh repo under `packaging/hyprland/`. Record the decision as an ADR.
- [ ] `lugh.conf`: gaps (inner 6 / outer 10 px, per DESIGN-SYSTEM §4), rounding 14, soft shadow, blur on layer surfaces only (`layerrule = blur, lugh-bar`, etc.), animations tuned to the DESIGN-SYSTEM §5 durations and bezier, floating by default (`windowrulev2 = float, class:.*` except for explicit tiles), Super+T toggling tiling for a workspace, and keybinds (Super+Space launcher, Super+L lock, Super+Tab overview stub, Super+Q close).
- [ ] Set `xdg-desktop-portal-hyprland` + `xdg-desktop-portal-gtk` as portal backends (ADR-020), with a `portals.conf` for `Lugh`.
- [ ] Xwayland enabled. Set `XCURSOR_THEME`, `QT_QPA_PLATFORM=wayland`, `GDK_BACKEND=wayland,x11` and `MOZ_ENABLE_WAYLAND=1` (redundant on current Firefox but harmless).

### 2. Session plumbing
- [ ] `/usr/share/wayland-sessions/lugh.desktop` → `Exec=lugh-session`.
- [ ] `lugh-session` (shell script) imports the environment into systemd (`systemctl --user import-environment`, `dbus-update-activation-environment --systemd`) and starts `lugh-session.target`.
- [ ] User units: `lugh-compositor.service` (Hyprland for now), `lugh-shell.service` (`PartOf=lugh-session.target`, `Restart=on-failure`), `lugh-polkit-agent` (inside the shell), and `xdg-desktop-portal` activation.
- [ ] Session teardown on logout: stop the target and make sure scopes are cleaned up.

### 3. LughUI component library (`ui/components/`)
- [ ] `Theme.qml` singleton with every DESIGN-SYSTEM token (light and dark, accent variants), the type scale, spacing, radii and motion constants. It honors a system reduce-motion flag.
- [ ] Components: `Button` (primary/secondary/ghost/danger), `IconButton`, `Toggle`, `Slider`, `TextField`, `SearchField`, `ListRow`, `Card`, `Popover`, `Menu`, `Tooltip`, `Badge`, `Spinner`, `Skeleton`, `EmptyState`, `ErrorBanner`, `Dialog`, `Tabs`, `SegmentedControl`.
- [ ] Each component implements **hover, pressed, focus, selected, disabled, loading, empty and error** where they apply, as tested states.
- [ ] Fonts: bundle Inter and JetBrains Mono through Debian's `fonts-inter` and `fonts-jetbrains-mono` (check they're in trixie; vendor them in `lugh-branding` if not).
- [ ] `ui/components/gallery/`: a dev app that renders every component in every state, light and dark, used for screenshot tests.

### 4. lugh-shell (Lugh mode)
Architecture: one QML process (`lugh-shell`) with a Rust core (`crates/lugh-shell-core`, cxx-qt) for D-Bus, Wayland and IPC. Layer surfaces come from **LayerShellQt** (`layer-shell-qt`, check the Qt 6 build in trixie).
- [ ] **Top bar** (30 px, glass): Lugh menu (About, Settings placeholder, Lock, Log out, Restart, Shut down), focused-app name, workspace dots, tray (StatusNotifierItem host: `org.kde.StatusNotifierWatcher`), clock and date, control-center button, notification indicator.
- [ ] **Dock** (bottom center, floating): pinned apps plus running apps, using `wlr-foreign-toplevel-management` from Hyprland. Running indicator dot (shape plus color, never color alone). Left click focuses or launches. Right click opens a menu (new window, pin/unpin, quit). Optional auto-hide. Pinned list stored in `~/.config/lugh/desktop.toml`.
- [ ] **Launcher** (Super+Space): fuzzy search over `.desktop` entries (XDG dirs, Flatpak export dirs), calculator, and "open file" through `xdg-open`. Keyboard first: arrows, Enter, Esc. Shows results in under 50 ms.
- [ ] **App launching (ADR-015)**: the Rust core spawns the app, then calls `org.freedesktop.systemd1.Manager.StartTransientUnit` on the user bus with name `app-lugh-<appid>-<rand>.scope` and `PIDs=[pid]`. Honors `DBusActivatable` and `Terminal=true` (opens in the default terminal).
- [ ] **Notifications**: implement `org.freedesktop.Notifications` (spec 1.2: actions, urgency, replaces-id, icons, body markup subset). Toasts top-right, a history list in the control center, and Do Not Disturb.
- [ ] **Control center**: Wi-Fi (NetworkManager D-Bus: list, connect, enter password, toggle), Bluetooth (BlueZ `org.bluez`: power, paired devices, connect), volume and output device (PipeWire: through `pipewire-pulse` + libpulse at first, behind an `Audio` trait so native WirePlumber can replace it later), microphone mute, brightness (`org.freedesktop.login1.Session.SetBrightness`, no root needed), power profiles (`org.freedesktop.UPower.PowerProfiles`), battery (UPower), dark-mode toggle, DND.
- [ ] **OSDs**: volume, brightness, mic mute and caps lock overlays (layer surface, 180 ms fade). Keys bound in Hyprland call `lugh-shell` through D-Bus (`space.lugh.Shell1.Osd`).
- [ ] **Polkit agent**: polkit-qt (`libpolkit-qt6-1-dev`) registered as the session agent, with a LughUI dialog showing the action description, the requesting app and a password field.
- [ ] **Lock screen**: `ext-session-lock-v1`, a password field through PAM (`pam_unix`, via a small Rust helper using the `pam` crate), clock, blurred wallpaper, and auto-lock on suspend (logind `PrepareForSleep`) and on idle (`ext-idle-notify-v1`, default 10 min).
- [ ] **Workspaces**: a Hyprland IPC adapter reading `$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock` events (`workspace`, `openwindow`, `closewindow`, `activewindow`), behind a `CompositorAdapter` trait. Phase 5 swaps in `ext-workspace-v1` / `lugh-shell-v1`.
- [ ] **Wallpaper**: a background layer surface, with light and dark placeholder wallpapers.
- [ ] Crash safety: when the shell dies, systemd restarts it in under 1 s, and apps keep running.

### 5. lugh-greeter (greetd)
- [ ] Packages: `greetd`, plus `cage` as the greeter kiosk compositor (or Hyprland with a minimal greeter config), running the `lugh-greeter` QML app.
- [ ] `/etc/greetd/config.toml`: `command = "cage -s -- lugh-greeter"`, user `_greetd`.
- [ ] UI: user list with avatars (AccountsService `org.freedesktop.Accounts`), password field, session picker (hidden when only one session exists), keyboard layout indicator, and power actions. Speaks the greetd IPC protocol (JSON over `$GREETD_SOCK`) from Rust.
- [ ] Fallback: if `lugh-greeter` fails to start 3 times, greetd uses `tuigreet` (installed as a safety net).

### 6. Installer: Calamares (ADR-008)
- [ ] Packages: `calamares` plus our `lugh-calamares-config`, using `calamares-settings-debian` as a reference only (not installed).
- [ ] `installer/settings.conf` sequence: `welcome → locale → keyboard → packagechooser@profile → partition → users → summary → [exec] partition, mount, unpackfs, machineid, fstab, locale, keyboard, localecfg, users, displaymanager, networkcfg, hwclock, shellprocess@btrfs, packages, shellprocess@profile, grubcfg, bootloader, umount → finished`.
- [ ] **Branding** (`installer/branding/lugh/`): `branding.desc` with DESIGN-SYSTEM colors, the placeholder logo, a QML slideshow (4 slides: Welcome, Modes preview, Store coming soon, Privacy), and Inter fonts.
- [ ] **Express vs Advanced**: Express is a welcome-page choice that preselects "Erase disk" or "Install alongside" (when another OS is detected), Btrfs, and swap as a file. Advanced exposes manual partitioning, ext4/Btrfs choice, LUKS and swap options.
- [ ] **Profiles** (`packagechooser` module, `method: packages`), mapped to meta-packages:
  - `lugh-desktop-minimal`: shell, greeter, `pcmanfm-qt` (shown as **Files**), `foot` (terminal), **Firefox**, **VLC** (ADR-024; exact list in [system-base](../specs/system-base.md)).
  - `lugh-desktop-standard`: minimal + `qimgv` (images), `qpdfview` (PDF), `lxqt-archiver` (archives), `featherpad` (text editor), `qalculate-qt`, printing, `flatpak` (ADR-024). Store and Bridge come in Phase 3. **No office suite.**
  - `lugh-desktop-gaming`: standard + `steam-installer` (contrib; needs `dpkg --add-architecture i386`), `gamemode`, `mangohud`, `mesa-vulkan-drivers:i386`, `libvulkan1:i386`.
  - `lugh-desktop-developer`: standard + `git`, `build-essential`, `podman`, `distrobox`, `vim`, an IDE (open question, VISION §16; Phase 1 ships **VSCodium** from its official apt repo as a placeholder).
- [ ] **Btrfs layout** (ADR-009, `docs/dev/btrfs-layout.md`): a `shellprocess@btrfs` job creates the subvolumes `@`, `@home`, `@var_log`, `@cache` and `@snapshots` (mounted at `/.snapshots`), fstab with `compress=zstd:1,noatime`, then `snapper -c root create-config /`, timeline limits (hourly 5, daily 7, weekly 0) and the apt pre/post hook. Packaging and enabling `grub-btrfs` is completed in the Phase 3 update-center work.
- [ ] Offline install: the ISO's squashfs is unpacked (`unpackfs`). The profile's extra packages come from an on-ISO pool (`config/packages.chroot` + a local repo in `/live/pool`), with a network fallback, so Minimal and Standard install offline.
- [ ] Bootloader: GRUB with signed shim (`grub-efi-amd64-signed`, `shim-signed`) and the Lugh GRUB theme. BIOS goes through `grub-pc`.
- [ ] A "Install Lugh" launcher icon in the live session's dock, plus an autostarted welcome prompt (Try or Install).

### 7. lugh-welcome (first run)
- [ ] Runs once per user (flag at `~/.config/lugh/welcome-done`).
- [ ] Pages: Welcome → Appearance (Light, the default; Dark; accent) → Desktop mode (Lugh only in this phase; Classic and Focus shown as "coming soon") → Office suite offer (LibreOffice or OnlyOffice; installs through `pkcon` in Phase 1, the Store in Phase 3) → Done.
- [ ] Every page is skippable. Writes to `~/.config/lugh/desktop.toml`.

### 8. Config format seed
- [ ] Define `~/.config/lugh/desktop.toml` v0 (theme, accent, dock pins, bar options, wallpaper). This becomes part of the Lughfile in Phase 2. Document it in the shell spec.

## Acceptance criteria

1. The ISO boots in QEMU (UEFI, UEFI+SB, BIOS) to `lugh-greeter`, and the live session autologins to the Lugh desktop.
2. The bar, dock, launcher, notifications, control center, OSDs and lock screen all work using only the keyboard (Tab/arrows/Enter/Esc) and with a mouse.
3. `notify-send "Hi" "Test"` shows a Lugh toast. It appears in history and respects DND.
4. Wi-Fi connect (with a password), Bluetooth pairing, volume, output switching, brightness and power-profile switching all work on one real laptop.
5. Every launched app appears in `systemctl --user list-units 'app-lugh-*'` as its own scope.
6. A polkit action (e.g. `pkexec true`) shows the Lugh polkit dialog.
7. Calamares installs each of the 4 profiles in QEMU (UEFI and BIOS), offline for Minimal and Standard. The installed system boots to the greeter.
8. The installed system uses the Btrfs subvolumes above. `snapper list` shows pre/post snapshots after `apt install hello`.
9. Advanced mode: manual partitioning and LUKS full-disk encryption both install and boot.
10. Minimal profile contains no office suite, no Store, no games: `dpkg -l | grep -i libreoffice` is empty, and Firefox and VLC are present.
11. Welcome runs on first login. Theme and accent changes apply live without restarting the shell.
12. All shell surfaces pass WCAG AA contrast in light and dark (automated check on gallery screenshots), with a visible focus ring everywhere.
13. Killing `lugh-shell` restarts it in under 1 s, and open apps are unaffected.

## Testing

**Automated**
- QEMU boot to the greeter (screenshot diff against a reference via the QMP `screendump` command, plus a marker in the journal over serial).
- QEMU install tests: Calamares in automated mode (a test preset that drives the same modules) for each profile × {UEFI, BIOS}. The installed disk is rebooted and the greeter is reached.
- `cargo test` for `lugh-shell-core` (scope naming, desktop-entry parsing, fuzzy search ranking, notification spec handling).
- QML tests (`qmltestrunner`) for LughUI component states. Gallery screenshot tests in light and dark.
- A contrast checker script run over the gallery tokens.

**Manual checklist**
- [ ] Real hardware: 1 Intel iGPU laptop, 1 AMD laptop, 1 desktop with NVIDIA (nouveau acceptable in this phase; note issues).
- [ ] HiDPI (200%) and fractional (125%) displays render crisply.
- [ ] Suspend/resume locks the screen and Wi-Fi returns.
- [ ] Keyboard-only walkthrough of every shell surface.
- [ ] Orca reads bar items, dock items and launcher results.

## Performance budget for this phase

| Metric | Budget |
|---|---|
| Idle RAM, whole session after login (Minimal profile, no apps open) | ≤ 600 MB (Phase 5 target is 450 MB) |
| `lugh-shell` RSS idle | ≤ 150 MB |
| Launcher open → first frame | ≤ 80 ms; search results ≤ 50 ms |
| Shell animations | 0 dropped frames at 60 Hz on an Intel UHD 620 class iGPU (measured with Hyprland's `debug:overlay` + QML frame timing) |
| Boot to greeter (installed, NVMe, real HW) | ≤ 15 s |
| Login → desktop usable | ≤ 2 s |
| ISO size | ≤ 2.5 GB (includes the offline profile pool) |

## Risks & mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Hyprland in trixie is too old, or upstream deps churn | packaging burden, breakage | pin one upstream release in the Lugh repo; keep the shell compositor-agnostic through the `CompositorAdapter` trait |
| LayerShellQt Qt 6 build missing or buggy in trixie | no bar or dock | backport in the Lugh repo; fallback is our own minimal layer-shell binding through cxx-qt |
| Glass and blur cost too much GPU on weak iGPUs | dropped frames | blur only on shell surfaces; auto-disable blur when the frame budget is exceeded; a setting to turn it off |
| Calamares packagechooser and offline pool complexity | failing installs | start with network installs for Gaming and Developer only; CI install tests per profile |
| Btrfs + snapper layout differs from what Calamares expects | broken rollbacks | document the layout once (`btrfs-layout.md`); integration test boots a snapshot in Phase 3 |
| Steam requires i386 multiarch | larger Gaming installs | only the Gaming profile enables i386 |
| Building a polkit agent and PAM lock screen ourselves is security-sensitive | lock bypass or credential leak | use PAM through a minimal, audited helper; fuzz the greetd IPC parsing; get a security review before the Phase 7 beta |
| Scope that is too large for one phase | slip | Lugh mode only; Settings app deferred; pick the file manager and terminal from existing apps (no custom ones) |

## Exit checklist

- [ ] All acceptance criteria pass.
- [ ] ISO builds in CI from a clean checkout (DoD 1). Boot and install tests pass (DoD 2).
- [ ] All new UI follows DESIGN-SYSTEM with every state implemented, verified in the gallery (DoD 3).
- [ ] `space.lugh.Shell1` D-Bus API documented, CLI equivalents (`lugh shell osd|lock|launcher`) exist, and polkit is used for privileged calls (DoD 4).
- [ ] Performance budgets met (DoD 5).
- [ ] `specs/shell.md` and `specs/installer.md` updated with final choices (file manager, terminal, Hyprland version). New ADRs logged (DoD 6).
- [ ] `docs/releases/phase-1.md` written, with known limitations (DoD 7).
