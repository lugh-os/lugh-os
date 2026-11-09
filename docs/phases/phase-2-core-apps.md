# Phase 2 — Core apps

> Status: **Draft** · Size: **L** · Depends on: Phase 1 · Specs: [settings](../specs/settings.md), [tasks](../specs/tasks.md), [lughfile](../specs/lughfile.md), [shell](../specs/shell.md) · Decisions: ADR-006, 007, 012, 015, 018

## Goal

Users can manage their whole machine from Lugh's own tools. **Lugh Settings** covers appearance, displays, input, sound, network, Bluetooth, power, users, default apps and accessibility, and can switch between **Lugh, Classic and Focus** modes (best effort while we're still on Hyprland). **Lugh Tasks** shows every app and process with live performance graphs, and gives full control of systemd services, including safe in-place editing of unit files with validation, history and one-click revert. The **Lughfile** arrives: `lugh export` captures your setup into `~/.config/lugh/`, `lugh sync` pushes it to GitHub, and `lugh apply` rebuilds it on another machine.

## Scope

**In**
- `lugh-settings` (UI) + `lugh-settingsd` (session daemon, `space.lugh.Settings1`).
- Classic and Focus layouts on Hyprland, best effort, with documented limitations.
- `lugh-tasks` (UI) + `lugh-tasksd` (system daemon for privileged operations plus a user-side collector, `space.lugh.Tasks1`).
- `lugh` CLI + `lugh-configd` (`space.lugh.Config1`): `export`, `apply`, `diff`, `sync`, `status`, and `lugh.toml` schema v1.
- The Welcome app now offers all 3 modes and points to Settings.

**Out (deferred)**
- Store and Bridge sections of the Lughfile → Phase 3.
- Store-driven updates → Phase 3 (Settings → Updates links to a placeholder that runs `pkcon` in this phase).
- Quarantine actions in Tasks → Phase 4.
- Perfect Classic and Focus modes (left/right window buttons, snap layouts, Task View animations) → Phase 5 on `lugh-compositor`.
- Users and parental controls beyond basic account management → later.

## Deliverables

| Deliverable | Path | Package |
|---|---|---|
| Settings UI | `ui/settings/` | `lugh-settings` |
| Settings daemon | `crates/lugh-settingsd/` | `lugh-settingsd` |
| Classic layout (taskbar, Start menu) | `ui/shell/modes/classic/` | `lugh-shell` |
| Focus layout (thin bar, runner) + Hyprland tiling profile | `ui/shell/modes/focus/`, `ui/shell/hypr/focus.conf` | `lugh-shell`, `lugh-hyprland-config` |
| Tasks UI | `ui/tasks/` | `lugh-tasks` |
| Tasks daemon | `crates/lugh-tasksd/` | `lugh-tasksd` |
| Polkit policy | `packaging/polkit/space.lugh.tasks.policy`, `space.lugh.settings.policy`, `space.lugh.config.policy` | in the respective packages |
| `lugh` CLI | `crates/lugh-cli/` | `lugh-cli` |
| Config daemon | `crates/lugh-configd/` | `lugh-configd` |
| `lugh.toml` JSON Schema v1 | `crates/lugh-common/schema/lugh-v1.json` | `lugh-cli` |
| Release note | `docs/releases/phase-2.md` | — |

## Work breakdown

### 1. lugh-settingsd (`space.lugh.Settings1`, session bus)
- [ ] Owns `~/.config/lugh/desktop.toml` (extending v0 from Phase 1 to v1) and emits `Changed(key)` signals so the shell and apps re-theme live.
- [ ] Backends behind traits, so Phase 5 can swap Hyprland for `lugh-compositor`:
  - Displays: `wlr-output-management-unstable-v1` (Hyprland supports it) for resolution, refresh, scale, position, VRR and enable/disable. Hyprland `keyword monitor` IPC is the fallback. Changes the user doesn't confirm revert automatically after 15 s.
  - Input: Hyprland IPC (`input:kb_layout`, `sensitivity`, `natural_scroll`, `tap-to-click`), persisted into `lugh.conf` includes.
  - Sound: same `Audio` trait as the shell (devices, default sink/source, per-app volume).
  - Network and Bluetooth: NetworkManager and BlueZ D-Bus (shared crate with the shell: `lugh-common::net`, `::bt`).
  - Power: power-profiles, UPower, logind (lid action, idle/suspend timeouts written to a `logind.conf.d` drop-in through polkit action `space.lugh.settings.power-system`).
  - Users: AccountsService (`org.freedesktop.Accounts`): create, delete, set avatar, change password, admin toggle (adds to `sudo` group). All go through polkit.
  - Default apps: `mimeapps.list` through `xdg-mime`. Browser, mail, files, terminal, video, music, images, PDF.
  - Date and time: `org.freedesktop.timedate1` (timezone, NTP).
  - Region and language: `org.freedesktop.locale1`.
  - About: os-release, hardware summary (CPU, GPU, RAM, disk), and a "copy system info" button.
  - Accessibility: reduce motion, large text, high contrast, Orca toggle, cursor size, sticky keys (Hyprland input options).
- [ ] D-Bus API documented in `specs/settings.md`. CLI: `lugh settings get|set|list <key>`.

### 2. lugh-settings (UI)
- [ ] LughUI layout: sidebar with search across all settings (indexed keywords, results under 30 ms), content pane, and breadcrumb.
- [ ] Pages: Appearance (theme light/dark/auto, accent, wallpaper, **Desktop mode** picker with live preview cards), Desktop (dock/taskbar options, bar options, hot corners), Displays, Input (keyboard, mouse, touchpad), Sound, Network, Bluetooth, Power, Users, Default apps, Date & time, Region, Accessibility, Lughfile (status, last sync, repo URL, buttons for Export/Sync/Apply), About.
- [ ] Every page has an empty state (e.g. no Bluetooth adapter), a loading skeleton and an error banner with a retry button.
- [ ] Deep links: `lugh-settings --page displays` (used by the shell and control center).

### 3. Classic & Focus on Hyprland (best effort)
- [ ] Mode switch flow: Settings → `Settings1.SetMode(mode)` → the shell swaps its layout (bar, dock, taskbar) and settingsd hot-loads the matching Hyprland profile (`hyprctl keyword source …` / `hyprctl reload`). Target: < 300 ms, no logout.
- [ ] **Classic**: bottom taskbar (44 px) with Start button, pinned and running apps (foreign-toplevel), tray and clock. Start menu (pinned grid, all apps, search, power) on Super. Alt+Tab switcher (QML overlay fed by foreign-toplevel). Hyprland profile: floating, no gaps, rounding 8.
- [ ] **Focus**: 24 px top bar (workspaces 1–9, focused title, clock, tray) or hidden. Super+Space runner. Hyprland profile: dwindle tiling by default, gaps 6/10, 2 px accent border on focus, no blur, Super+1..9 workspaces, Super+H/J/K/L focus.
- [ ] **Documented limitations on Hyprland** (in the release note and the shell spec): window buttons follow each app's client-side decorations (we can't reliably force left vs right placement), no true snap layouts (only keyboard snapping via `movewindow`), no genie minimize, and Task View is a static overview. All of these are fixed in Phase 5.

### 4. lugh-tasksd (`space.lugh.Tasks1`)
- [ ] Split design: a **user collector** (session bus, unprivileged) for the user's processes, and a **system service** (`lugh-tasksd.service`, system bus, D-Bus activated, idle-exit after 60 s) for other users' processes, system units and privileged actions.
- [ ] Processes: read `/proc` (`procfs` crate). Group by cgroup path, so `app-lugh-<appid>-*.scope` (ADR-015) maps to the app's name and icon from its `.desktop` file. Show system services under "System". Per-process CPU %, RSS/PSS (from `smaps_rollup`, sampled less often), disk I/O (`/proc/<pid>/io`, needs privilege for other users), and network per cgroup (eBPF later; Phase 2 uses `/proc/net` per-process sockets for connection counts only and states that limit).
- [ ] GPU: per-process utilization and VRAM from DRM fdinfo (`/proc/<pid>/fdinfo/*`, keys `drm-engine-*`, `drm-memory-*`; works for amdgpu, i915, xe, and recent nouveau/panfrost). NVIDIA proprietary through NVML (`libnvidia-ml.so`, `nvml-wrapper` crate), loaded only if it's present.
- [ ] Performance: CPU per core and frequency, RAM/swap/zram, disks (`/proc/diskstats`, SMART status through `udisks2`), network interfaces, temperatures (`/sys/class/hwmon`), and battery power draw. Ring buffers of 5 min at 1 Hz. Sampling only runs while a client is subscribed.
- [ ] Process actions: end (SIGTERM, then a SIGKILL prompt after 5 s), kill, suspend/resume (`systemctl --user freeze/thaw` for scopes, SIGSTOP otherwise), nice/ionice, open file location, and per-app CPU and memory limits (`SetUnitProperties` `CPUQuota=`, `MemoryHigh=` on the scope).
- [ ] Services through `org.freedesktop.systemd1` (system and user managers): list units, timers, sockets and failed units. Start, stop, restart, reload, enable, disable, mask, unmask. Dependency view (`Requires/Wants/After` properties).
- [ ] **Unit editing (the headline feature)**:
  - Default mode is a **drop-in override**, written to `/etc/systemd/system/<unit>.d/50-lugh.conf` (user units: `~/.config/systemd/user/<unit>.d/`). "Full edit" copies the vendor unit to `/etc/systemd/system/<unit>` and is labeled clearly.
  - Validate before applying: render the merged unit into a staging root (`/run/lugh/tasks/staging/`, mirroring the unit dirs) and run `systemd-analyze verify --root=<staging> <unit>`. Errors are shown inline with line numbers. A prototype task decides between `--root` and `SYSTEMD_UNIT_PATH`.
  - Apply: atomic write (temp file + rename) → `Reload()` (daemon-reload) → optional restart prompt.
  - History: every applied version is stored in `/var/lib/lugh/tasks/history/<unit>/<timestamp>.conf` with metadata (user, diff). Revert in one click restores the previous version and reloads. "Reset to vendor" deletes the overrides.
- [ ] Logs: journald via the `systemd` crate (sd-journal) or `journalctl -o json -f -u <unit>` as a fallback. Live follow, priority filter, time range, text search, boot selector.
- [ ] Startup: user autostart entries (`~/.config/autostart`, `/etc/xdg/autostart`), enabled services, and boot analysis (`org.freedesktop.systemd1.Manager` timestamps plus `systemd-analyze blame` / `critical-chain` output parsed into a chart).
- [ ] **Polkit actions** (`space.lugh.tasks.policy`): `process-signal-other` (auth_admin), `unit-control` (auth_admin_keep), `unit-enable` (auth_admin_keep), `unit-edit` (auth_admin), `unit-revert` (auth_admin), `journal-system-read` (allow for the `adm`/`sudo` groups).
- [ ] CLI: `lugh tasks ps|top|kill|limit`, `lugh service list|status|start|stop|edit|revert|history|logs`.

### 5. lugh-tasks (UI)
- [ ] Tabs: **Apps** (grouped, sortable, expandable to processes), **Performance** (graphs, using a canvas renderer with no per-frame allocations), **Services**, **Startup**, **Logs**.
- [ ] Unit editor: a mono text area with systemd syntax highlighting, key completion (directives list from `systemd.directives(7)`), a validation panel, a diff view vs current, and Apply / Revert / History.
- [ ] Shortcut Ctrl+Shift+Esc opens Tasks (familiar to Windows users), plus a launcher keyword "task manager".
- [ ] Every action that needs privilege shows a lock icon before you click it.

### 6. Lughfile: lugh CLI + lugh-configd (ADR-018)
- [ ] `lugh.toml` **schema v1**:
  ```toml
  schema = 1
  [system]
  hostname = "lugh-laptop"   # optional
  timezone = "Africa/Kigali"
  locale = "en_US.UTF-8"
  [desktop]
  include = "desktop.toml"   # theme, accent, mode, dock pins, wallpaper…
  [packages]
  apt = ["htop", "neovim"]
  remove = ["firefox"]        # explicit removals
  [flatpak]
  remotes = { flathub = "https://dl.flathub.org/repo/flathub.flatpakrepo" }
  apps = ["org.signal.Signal"]
  [services]
  enable = ["sshd.service"]
  disable = ["bluetooth.service"]
  user_enable = ["syncthing.service"]
  [dotfiles]
  link = { "dotfiles/gitconfig" = "~/.gitconfig", "dotfiles/nvim" = "~/.config/nvim" }
  [ignore]
  paths = ["~/.config/**/Cache*"]
  # [store] and [bridge] sections arrive in Phase 3
  ```
- [ ] `lugh export`: collects manually installed apt packages (`apt-mark showmanual` minus the profile's meta-package dependencies), Flatpak apps and remotes, enabled non-default services (diff against presets via `systemctl list-unit-files --state=enabled` + `systemd-analyze cat-config` presets), `desktop.toml`, and the dotfile list the user chooses in Settings. It never exports secrets: a deny-list (`.ssh/id_*`, `.gnupg`, `*token*`, keyrings, browser profiles) plus a secret scanner warning before commit.
- [ ] `lugh diff`: a human-readable plan (`+ install`, `- remove`, `~ enable`, `→ link`), with JSON output via `--json`.
- [ ] `lugh apply [--dry-run] [--yes]`: computes the plan, asks for polkit once (`space.lugh.config.apply-system`), installs through PackageKit and libflatpak, enables services, links dotfiles (backs up conflicting files into `~/.local/state/lugh/backup/<ts>/`). It's idempotent, so a second run makes no changes. With snapper present, it creates a pre/post snapshot.
- [ ] `lugh sync`: plain git in `~/.config/lugh/` (`git2` crate). `lugh sync --init <url>` sets the remote. It commits with a generated message, then pulls with rebase and pushes. Conflicts show a guided resolution in Settings. Auth uses the user's existing git credentials/SSH agent; we never store tokens.
- [ ] `lugh status`: drift between the Lughfile and the live system.
- [ ] Validation: JSON Schema (`schemars`-generated), unknown keys produce warnings, and `schema` is version-checked.
- [ ] Settings → Lughfile page uses `space.lugh.Config1` (methods `Export`, `Plan`, `Apply`, `Sync`, `Status`, with progress signals).

## Acceptance criteria

1. Every Settings page listed above works on real hardware, and changes take effect immediately (no logout), except the language change, which says so.
2. A display change the user doesn't confirm reverts after 15 s.
3. Switching Lugh → Classic → Focus → Lugh in Settings takes under 300 ms each and doesn't close any app windows. The limitations are listed in the release note.
4. Tasks groups every app launched from the shell under its name and icon, matching `systemctl --user list-units 'app-lugh-*'`.
5. GPU usage per process is shown on Intel and AMD iGPUs, and on NVIDIA when the proprietary driver is installed.
6. Editing `ssh.service` with an invalid directive is rejected with the error line shown. A valid override applies, appears in history, and **Revert** restores the previous state, verified with `systemctl cat ssh`.
7. Live logs follow a unit with under 500 ms latency.
8. Boot analysis shows the top 10 slowest units with durations matching `systemd-analyze blame`.
9. `lugh export && lugh sync --init git@github.com:<user>/lughfile.git` creates a valid repo with no secrets (the scanner test passes).
10. On a fresh install, `lugh sync --init <url> && lugh apply --yes` reproduces packages, flatpaks, services, desktop settings and dotfiles, and `lugh status` reports no drift.
11. `lugh apply` run twice in a row: the second run reports "nothing to do".
12. All privileged actions trigger polkit prompts with clear descriptions. Unprivileged users can't edit system units.

## Testing

**Automated**
- Unit tests: plan computation (`lugh-configd`), the export filter, schema validation, the secret scanner, cgroup→app mapping, fdinfo parsing (fixtures for amdgpu/i915/xe), unit-file parser, history and revert.
- Integration (QEMU, installed image): scripted `lugh apply` round-trip from a fixture Lughfile; `busctl` calls against `Tasks1` for unit edit, validate, apply and revert; mode switching through `Settings1.SetMode`, with a check that the shell layout swapped (screenshot diff).
- UI tests: QML test runner for the Settings search and editor validation states.

**Manual checklist**
- [ ] Multi-monitor (laptop + external at a different scale).
- [ ] Touchpad gestures and settings on 2 laptops.
- [ ] Create a second user, log in and log out, delete them.
- [ ] Lughfile round-trip between two different machines.
- [ ] Keyboard-only use of Settings and Tasks; Orca announces graph values as text.

## Performance budget for this phase

| Metric | Budget |
|---|---|
| Settings cold start → interactive | ≤ 400 ms |
| Tasks cold start → first data | ≤ 300 ms |
| Tasks CPU overhead while open (1 Hz sampling, 300 processes) | ≤ 2% of one core |
| `lugh-tasksd` / `lugh-settingsd` idle RSS | ≤ 15 MB each; exit when idle |
| Mode switch | ≤ 300 ms |
| `lugh diff` on a typical Lughfile | ≤ 1 s |
| Idle session RAM (Minimal) | still ≤ 600 MB (no regression from Phase 1) |

## Risks & mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Classic and Focus on Hyprland feel half-done | bad first impression | label them "Preview" in Settings; list the limitations; the full versions are the Phase 5 headline |
| `systemd-analyze verify` doesn't catch every runtime error | broken service after apply | always keep history and offer revert; optionally auto-revert if the unit fails within 10 s of a restart the user asked for |
| Editing units as root through a GUI is a security risk | privilege escalation | polkit `auth_admin` for edits; the daemon validates the unit name and path (no traversal); writes only under the systemd unit dirs |
| `apt-mark showmanual` is noisy (installer-marked packages) | bloated Lughfiles | subtract the profile meta-package dependency closure and a base-image manifest generated at build time |
| Dotfile linking clobbers user files | data loss | always back up first; `--dry-run` by default from the GUI |
| Users push secrets to GitHub | credential leak | deny-list + scanner + a "private repo" recommendation in the UI |
| Per-process network stats need eBPF/root | missing feature | state the limitation; plan an eBPF collector for later |
| NVML not present / driver mismatches | GPU tab errors | optional dynamic loading, with the graph hidden and an explanatory empty state |

## Exit checklist

- [ ] All acceptance criteria pass.
- [ ] ISO builds in CI (DoD 1); boot, install and Lughfile round-trip tests pass (DoD 2).
- [ ] Settings, Tasks and the mode layouts follow DESIGN-SYSTEM with every state (DoD 3).
- [ ] `Settings1`, `Tasks1` and `Config1` APIs documented in the specs, CLI equivalents shipped, polkit policies installed, unit tests green (DoD 4).
- [ ] Performance budgets met (DoD 5).
- [ ] `specs/settings.md`, `specs/tasks.md`, `specs/lughfile.md` and `specs/shell.md` (modes, limitations) updated. ADRs added for any new decisions, e.g. the staging-verify approach (DoD 6).
- [ ] `docs/releases/phase-2.md` written (DoD 7).
