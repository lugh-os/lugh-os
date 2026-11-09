# Lugh Shell — Spec

> Status: **Draft** · Owner phases: **1** (on Hyprland, Lugh mode), **2** (Classic + Focus layouts, best effort), **5** (complete on lugh-compositor) · Related ADRs: ADR-004, ADR-006, ADR-010, ADR-012, ADR-014, ADR-015, ADR-020, ADR-021

## Purpose

Everything the user sees on the desktop that isn't an app window: bar, dock or taskbar, launcher and Start menu, notifications, control center, OSDs, polkit dialogs, Alt+Tab, workspace overview, tray, lock screen and greeter. One QML process (`lugh-shell`) renders it, in the three modes defined in [DESIGN-SYSTEM](../DESIGN-SYSTEM.md) §8.

## User stories

- **Windows switcher:** "In Classic mode I press the Windows key and get a Start menu. The taskbar, tray, Alt+Tab and snapping work the way I'm used to. Typing 'control panel' opens Settings."
- **macOS-minded user:** "Lugh mode has a top bar, a centered dock, Spotlight-style search and smooth gestures."
- **Linux power user:** "Focus mode is tiling with a thin bar, fully keyboard-driven, and every shortcut is mine to change in `desktop.toml`."
- **Minimal user:** "The shell uses little memory and nothing in it phones home."

## Requirements

### Functional
- **FR-1** Implements every component in §Components for every mode marked in that table.
- **FR-2** Switching mode (`space.lugh.Settings1.SetMode`) changes the shell layout live in ≤ 300 ms without logout, keeping open windows, notifications and tray items.
- **FR-3** Launcher search covers apps, files, settings, Store, calculator/units, open windows and commands, with Windows-name aliases (§Launcher).
- **FR-4** Implements the freedesktop Notifications spec 1.2 (`org.freedesktop.Notifications`) and StatusNotifierItem (`org.kde.StatusNotifierWatcher` + host).
- **FR-5** Provides the polkit authentication agent for the session.
- **FR-6** The lock screen uses `ext-session-lock-v1`. If the shell crashes while locked, the session stays locked.
- **FR-7** The greeter (`lugh-greeter`) authenticates through greetd and starts `lugh-session` (ADR-014).
- **FR-8** Runs on Hyprland (Phases 1–4) through standard protocols plus a Hyprland adapter, and on lugh-compositor (Phase 5+) through `lugh-shell-v1` (ADR-012).
- **FR-9** Every shell action is reachable through D-Bus (`space.lugh.Shell1`) and the CLI (`lugh shell …`), so keybindings, scripts and other apps can trigger it.
- **FR-10** All shortcuts are configurable in `desktop.toml`. Each mode ships a preset.

### Non-functional
- **NFR-1** Shell process RSS ≤ 120 MB at idle with 10 windows open. Start-up to first frame ≤ 400 ms.
- **NFR-2** Every animation holds the display refresh rate (60–144 Hz) on a mid-range iGPU. Launcher open-to-typing is ≤ 100 ms (the keyboard is focused immediately; results stream in).
- **NFR-3** Search results for apps, settings and windows in ≤ 30 ms per keystroke. Store and file results arrive asynchronously and never block.
- **NFR-4** Accessibility: every component is keyboard-navigable and exposes AT-SPI roles and names. Reduce-motion is respected. AA contrast on glass surfaces (enforced by a minimum opacity behind text).
- **NFR-5** No network access from the shell except Store search, which goes through `lugh-stored` and can be turned off.

## Components

| Component | Lugh | Classic | Focus | Phase |
|---|---|---|---|---|
| Top bar (app menu area, clock, status, tray) | ✓ | — | thin variant | 1 |
| Dock (pinned + running, indicators, magnify optional) | ✓ | — | — | 1 |
| Taskbar (Start button, pinned, running, tray, clock) | — | ✓ | — | 2 |
| Start menu (pinned grid, all apps, search, user, power) | — | ✓ | — | 2 |
| Launcher / Spotlight (centered search) | ✓ | (inside Start) | runner variant | 1 |
| Notification popups + Notification center | ✓ | ✓ | ✓ | 1 |
| Control center (quick settings) | ✓ | ✓ | ✓ | 1 |
| OSDs (volume, brightness, mic mute, caps lock, layout, mode switch) | ✓ | ✓ | ✓ | 1 |
| Polkit agent dialog | ✓ | ✓ | ✓ | 1 |
| Alt+Tab switcher | ✓ | ✓ | ✓ | 1 (icons), 5 (live thumbnails) |
| Workspace overview / Task View | ✓ | ✓ | optional | 2 (grid), 5 (live, gestures) |
| Tray (StatusNotifierItem) | ✓ | ✓ | ✓ | 1 |
| Screenshot / screen record UI | ✓ | ✓ | ✓ | 2 |
| Lock screen | ✓ | ✓ | ✓ | 1 |
| Greeter | ✓ | ✓ | ✓ | 1 |
| Desktop icons | — | optional | — | 5 (open question) |

### Top bar
- Left: logo menu (About, Settings, Store, Lock, Log out, Restart, Shut down), then the active app's name. A global menu is **not** planned: Wayland lacks a standard for it, and most toolkits no longer export menus reliably.
- Center (Focus) or right (Lugh): workspaces indicator.
- Right: tray, keyboard layout (if > 1), network, volume, battery, clock. Clicking any status item opens the control center. Clicking the clock opens the notification center plus a calendar.

### Dock (Lugh mode)
- Pinned apps, a divider, running unpinned apps, a divider, Downloads stack, Trash.
- Running indicator: a dot under the icon (plus a count badge for multiple windows; never color alone).
- Click: launch, focus, or cycle that app's windows. Middle-click: new window. Right-click: windows list, "Keep in Dock", "Quit", desktop actions from the `.desktop` file (e.g. "New Private Window").
- Optional auto-hide and magnify. Minimize animates into the icon (on Phase 5 via `lugh_window_v1.set_minimize_rect`).
- Bridge apps show their Windows icon. Quarantined apps show a shield badge.

### Taskbar + Start menu (Classic mode)
- Taskbar: Start button, search box (opens Start in search state), pinned and running buttons (grouped per app, thumbnail preview on hover from Phase 5), tray, clock + date, notification bell, show desktop corner.
- Start menu: pinned grid (editable), "All apps" A–Z with letter jump, recommended (recent files, toggleable), user avatar menu (Settings, Lock, Sign out), power menu.
- Snap layouts: hovering the maximize button shows layout zones (needs compositor support; a Phase 2 best-effort version uses keyboard Super+Arrows only).

### Launcher
Opens with Super+Space (Lugh, Focus) or by typing in Start (Classic). Results are grouped and ranked by match quality × frequency × recency (local history in `~/.local/state/lugh/launcher.db`, can be cleared).

| Provider | Source | Notes |
|---|---|---|
| Apps | XDG `.desktop` entries (incl. Flatpak exports and Bridge entries) | fuzzy match on name, generic name, keywords and translated names |
| Windows aliases | `/usr/share/lugh/launcher/aliases.toml` | "control panel" → Settings · "task manager" → Tasks · "add or remove programs" → Store › Installed · "cmd"/"powershell" → Terminal · "device manager" → Settings › Devices · "regedit" → help card on `desktop.toml` |
| Settings | page index exported by [settings](settings.md) (`/usr/share/lugh/settings/search-index.json`) | jumps to the exact page |
| Open windows | foreign-toplevel list | "Switch to …" |
| Files | recent files (`recently-used.xbel`) plus name search via `plocate`, restricted to `$HOME` | no content indexing in v1 |
| Store | `space.lugh.Store1.Search` ([store](store.md)), after ≥ 3 chars, debounced 250 ms | "Install X" results. Can be turned off in Settings |
| Calculator & units | built-in expression evaluator (Rust), units table | `= 2^10`, `5 km in mi`, `30 usd in rwf` (currency only if rates are cached; never fetched silently) |
| Commands | `>` prefix runs a command in a terminal. Focus mode can make it the default | |

Keys: ↑/↓ select, Enter open, Ctrl+Enter open the file's location / app details, Tab cycles groups, Esc closes.

### Notifications
- Server: `org.freedesktop.Notifications` with actions, inline reply (`x-kde-reply` style hint when present), images, urgency, `replaces_id`, `resident`, `transient`, sounds via `canberra` events.
- Popups: top-right (Lugh, Focus) or bottom-right (Classic), at most 3 stacked. Critical notifications stay until dismissed; others last 5 s (paused on hover).
- Center: history grouped by app, "Clear all", per-app mute, **Do Not Disturb** (manual, scheduled, or automatic when a fullscreen app/game is focused).
- Per-app rules come from `notifications.per_app` in `desktop.toml`.
- Privacy: content is hidden on the lock screen by default (count only).

### Control center
Tiles: Wi-Fi (list + connect, via NetworkManager), Bluetooth (BlueZ), Airplane mode, Do Not Disturb, Dark mode, Night light, Power profile, Screen record, Keyboard layout. Sliders: volume (with an output device picker; per-app volumes in an expanded view through PipeWire), microphone, brightness (logind `SetBrightness`). Also: battery state, media player (MPRIS) with controls, and a user row (Settings, Lock, Power).

### OSDs
Centered-bottom pill, 1.2 s. Kinds: volume, brightness, mic mute, caps lock, keyboard layout, mode switch ("Classic mode"), airplane mode. Announced to screen readers.

### Polkit agent
Implements `org.freedesktop.PolicyKit1.AuthenticationAgent` (via `polkit-qt6-1`, *verify* in trixie, or a zbus implementation using `polkit-agent-helper-1`). The dialog shows the requesting app's icon and name, the action description, and for `space.lugh.*` actions a plain-language detail ("Lugh Tasks wants to edit the service *nginx.service*"). The password field is focused, and fingerprint auth is offered if fprintd has prints enrolled. The dialog is modal to the requesting window, not the whole desktop.

### Alt+Tab
Alt+Tab / Alt+Shift+Tab across all windows of the current workspace (configurable to all workspaces). Alt+\` cycles windows of the same app. Phase 1 shows icons + titles. Phase 5 shows live thumbnails through `ext-image-copy-capture` (toplevel source).

### Workspace overview
- Lugh: Super+Tab or a 4-finger swipe up gives a Mission Control-style overview of all windows plus a workspace strip. Drag windows between workspaces.
- Classic: Task View (Super+Tab) with the same data in a Windows layout.
- Focus: optional, off by default.
- Phase 2 on Hyprland: static grid built from Hyprland IPC with no thumbnails. Phase 5: live and gesture-driven.

### Tray
StatusNotifierWatcher + Host. Supports menus (`com.canonical.dbusmenu`), activation, scroll, tooltips and attention state. Legacy XEmbed tray icons are not supported (Wayland), which is documented in the FAQ.

### Lock screen
- Triggered by Super+L, logind `Lock`, idle timeout (`ext-idle-notify-v1`, default 5 min screen off + lock), and before suspend (logind delay inhibitor, so the lock surface is drawn before sleep).
- Shows the wallpaper (blurred), clock, date, battery, notification **count**, media controls (optional), and the password field. Authentication goes through PAM (`lugh-shell` helper using the `login` stack), plus fprintd if enrolled.
- If the shell crashes: `ext-session-lock-v1` keeps the screen locked (the compositor draws solid color), systemd restarts the shell, and the shell re-attaches the lock surface.

### Greeter (`lugh-greeter`)
- Runs under greetd in a minimal kiosk compositor session (Phases 1–4: `cage`, *verify*; Phase 5: `lugh-compositor --greeter`).
- Speaks greetd's JSON IPC (`create_session` → `post_auth_message_response` → `start_session ["lugh-session"]`).
- UI: user list with avatars (or a username field if more than 10 users or the admin hides the list), password, keyboard layout, accessibility menu (screen reader, on-screen keyboard, large text, high contrast), power buttons. The session picker is hidden unless more than one session is installed.
- Light theme default, same wallpaper as the desktop (copied to `/var/lib/lugh-greeter/` with the user's consent; otherwise the default wallpaper).

## Design

### Process & code structure
```
ui/shell/
├── src/ (Rust, cxx-qt)
│   ├── main.rs              # QGuiApplication, layer-shell setup, D-Bus server space.lugh.Shell1
│   ├── wm/                  # WindowManagerBackend trait
│   │   ├── hyprland.rs      #   Phases 1–4: Hyprland IPC adapter
│   │   └── lugh.rs          #   Phase 5+: lugh-shell-v1 client
│   ├── services/            # network.rs (NM), bluetooth.rs (BlueZ), power.rs (UPower, PPD),
│   │                        # audio.rs (PipeWire), mpris.rs, notifications.rs, tray.rs,
│   │                        # polkit.rs, brightness.rs, idle.rs, launcher/ (providers)
│   └── models/              # Qt models exposed to QML
└── qml/
    ├── modes/ Lugh.qml Classic.qml Focus.qml   # composition of components per mode
    ├── components/ Bar Dock Taskbar StartMenu Launcher NotificationCenter ControlCenter OSD AltTab Overview LockScreen PolkitDialog
    └── (uses LughUI from ui/components/)
```
Surfaces use LayerShellQt (`layer-shell-qt`): bar/dock/taskbar on the `top` layer with exclusive zones; launcher, control center and overview on `overlay` with keyboard interactivity `exclusive` or `on_demand`.

### Window-manager backend contract (trait `WindowManagerBackend`)
```rust
trait WindowManagerBackend {
    fn toplevels(&self) -> Stream<ToplevelEvent>;        // opened/closed/title/app_id/state/output/workspace
    fn workspaces(&self) -> Stream<WorkspaceEvent>;
    fn activate(&self, w: WindowId);
    fn close(&self, w: WindowId);
    fn minimize(&self, w: WindowId, dock_rect: Option<Rect>);
    fn move_to_workspace(&self, w: WindowId, ws: WorkspaceId);
    fn switch_workspace(&self, ws: WorkspaceId);
    fn apply_mode(&self, mode: Mode) -> Result<()>;      // layout policy, gaps, decorations side, bindings
    fn window_marks(&self) -> Stream<WindowMark>;        // quarantine/bridge marks (Phase 5 only)
}
```
| Capability | Hyprland adapter (Phases 1–4) | lugh-compositor (Phase 5+) |
|---|---|---|
| Toplevels | `wlr-foreign-toplevel-management` + Hyprland event socket (`.socket2.sock`) for workspace/monitor info | `ext-foreign-toplevel-list` + `lugh_window_v1` |
| Workspaces | `hyprctl -j workspaces` + events | `ext-workspace-v1` |
| apply_mode | writes `~/.config/lugh/generated/hyprland-<mode>.conf` (layout, gaps, rounding, animations, binds), then `hyprctl reload` | `lugh_shell_manager_v1.set_mode` |
| Window buttons side | client-side only: sets GTK `gtk-decoration-layout` and the portal Settings key. Qt apps follow where supported. **Not consistent across toolkits (known limit)** | server-side decorations drawn by the compositor, consistent |
| Quarantine marks | not available (Shield shows a notification + tray badge instead) | `lugh_window_v1.quarantine` event, border drawn by compositor |
| Thumbnails | none | `ext-image-copy-capture` |

### Mode switching contract
1. `lugh-settingsd` persists `desktop.mode` and calls `WindowManagerBackend::apply_mode` (via the shell) **before** emitting `ModeChanged` ([settings](settings.md) §Mode switching).
2. On `ModeChanged`, the shell instantiates the new mode's QML composition off-screen, then cross-fades (≤ 300 ms, or 100 ms fade with reduce-motion). Old layer surfaces are destroyed after the fade.
3. State that survives a switch: pinned apps (both mode lists stay separate), notification history, tray registrations, launcher history, open popovers (closed gracefully).
4. Keybinding preset swap happens in the same transaction as `apply_mode`.
5. The switch is atomic from the user's view. If `apply_mode` fails, nothing changes and an error toast explains why.

### D-Bus: `space.lugh.Shell1` (session bus, `/space/lugh/Shell1`)
| Member | Kind | Notes |
|---|---|---|
| `ShowLauncher(s query)` | method | empty query = open blank |
| `ShowStartMenu()` | method | Classic. Other modes map to the launcher |
| `ToggleControlCenter()` / `ToggleNotificationCenter()` | method | |
| `ShowOverview()` | method | |
| `Screenshot(s mode)` | method | `area` \| `window` \| `screen`. Saves to `~/Pictures/Screenshots` and the clipboard |
| `ShowOSD(s kind, d value)` | method | used by media keys through compositor bindings |
| `Notify(…)` | n/a | (use `org.freedesktop.Notifications`) |
| `ModeApplied(s mode)` | signal | |
| `Ready()` | signal | first frame drawn (also prints the CI marker, [build-and-release](build-and-release.md)) |

CLI: `lugh shell launcher [query]`, `lugh shell overview`, `lugh shell screenshot area`, `lugh shell reload`.

### Configuration (`~/.config/lugh/desktop.toml`, owned by settingsd)
The shell reads the keys defined in [settings](settings.md) §Settings schema (`appearance`, `desktop`, `dock`, `taskbar`, `focus`, `notifications`, `accessibility`) plus a `bindings` table:
```toml
[bindings.lugh]
"Super+Space"   = "shell.launcher"
"Super+Tab"     = "shell.overview"
"Super+L"       = "session.lock"
"Super+T"       = "wm.toggle-tiling"
"Super+Q"       = "wm.close"
"Print"         = "shell.screenshot area"

[bindings.focus]
"Super+Return"  = "exec foot"
"Super+H"       = "wm.focus left"

[bindings.user]               # applies on top of the active mode's preset
"Super+E"       = "exec lugh-files"
```
Actions use the namespaces `shell.*`, `wm.*`, `session.*` and `exec`. Phases 1–4 translate them into Hyprland `bind` lines. Phase 5 passes them to the compositor binding engine.

## UX

### Default keyboard shortcuts
| Action | Lugh | Classic | Focus |
|---|---|---|---|
| Search / launcher | Super+Space | Super (tap) | Super+Space |
| Start menu | n/a | Super (tap) / Ctrl+Esc | n/a |
| Overview / Task View | Super+Tab, 4-finger up | Super+Tab | Super+Tab (if on) |
| Switch windows | Alt+Tab | Alt+Tab | Alt+Tab |
| Same-app windows | Alt+\` | n/a | Alt+\` |
| Close window | Super+Q / Alt+F4 | Alt+F4 | Super+Q |
| Minimize | Super+M | Super+↓ | n/a |
| Maximize / fullscreen | Super+↑ / Super+F | Super+↑ / F11 (app) | Super+F |
| Snap left / right | Super+← / → | Super+← / → | move focus (Super+H/J/K/L or arrows) |
| Move window in tiling | Super+Shift+arrows | n/a | Super+Shift+H/J/K/L |
| Toggle tiling on workspace | Super+T | n/a | (always tiling) Super+V float toggle |
| Workspace 1–9 | Ctrl+1..9, 3-finger swipe | Ctrl+Super+←/→ | Super+1..9 |
| Move window to workspace | Ctrl+Shift+1..9 | Ctrl+Super+Shift+←/→ | Super+Shift+1..9 |
| Terminal | Ctrl+Alt+T | Ctrl+Alt+T | Super+Return |
| Files | Super+E | Super+E | Super+E |
| Settings | Super+, | Super+I | Super+, |
| Tasks (task manager) | Ctrl+Shift+Esc | Ctrl+Shift+Esc | Ctrl+Shift+Esc |
| Control center | Super+C | Super+A | Super+C |
| Notification center | Super+N | Super+N | Super+N |
| Lock | Super+L | Super+L | Super+L |
| Screenshot (area / screen / window) | Print / Shift+Print / Alt+Print | Super+Shift+S / Print / Alt+Print | Print / Shift+Print / Alt+Print |
| Quarantine focused app (Phase 4+) | Super+Shift+Q (relaunch in Shield, with confirmation) | same | same |

### States
| Component | Empty | Loading | Error |
|---|---|---|---|
| Launcher | "Type to search apps, files and settings" + recent apps | results stream in per provider. A provider row shows a subtle spinner only after 300 ms | a provider failing hides its group and logs it. Never a modal |
| Notification center | "No notifications" + DND toggle | n/a | n/a |
| Control center Wi-Fi | "Wi-Fi is off" + toggle / "No networks found" + Rescan | scanning shimmer | "Couldn't connect to *Net* — wrong password?" inline, with Retry |
| Dock | (never empty: pinned defaults) | n/a | an app failing to launch gives an inline toast "Firefox couldn't start" + Details (journal excerpt) |
| Tray | hidden when empty | n/a | n/a |

## Security & privacy
- Only the shell (privileged Wayland client on lugh-compositor, see [compositor](compositor.md) §Security) may bind toplevel-management, screencopy, data-control and output management.
- Launcher history, notification history and screenshots stay local. A "Clear history" control exists for each.
- Store search sends queries to `lugh-stored`. Its network behaviour is documented in [store](store.md), and the provider can be turned off.
- The polkit dialog shows the true requesting process (from the polkit subject), which prevents spoofed prompts. Prompts can't be drawn by other clients (overlay layer is reserved for the shell on lugh-compositor).
- Lock screen: no notification content, no media artwork from private browsing (MPRIS `xesam:url` check), and Alt+Tab, overview and shortcuts are disabled while locked.

## Testing
- **QML unit tests** for each component with mocked services (`qmltestrunner -platform offscreen`).
- **Integration:** a headless Hyprland (Phases 1–4) or headless lugh-compositor (Phase 5) session in CI. Scripted: open apps, switch modes ×20, open the launcher and type, send 100 notifications. Assert no leaks (RSS stable ±5%) and frame-time budgets.
- **Mode switch test:** windows keep their positions (floating) or are restored after a Focus round-trip (Phase 5).
- **Accessibility:** Accerciser/AT-SPI tree checks for roles and names. Keyboard-only walkthrough of every component.
- **Crash safety:** kill `lugh-shell` while locked and assert the screen remains locked and the shell recovers in ≤ 2 s.

## Open questions
- Desktop icons in Classic mode: support them (many Windows users expect them) or not?
- Night light on Hyprland: run `hyprsunset` (*verify* packaging) or wait for Phase 5's `gamma-control`?
- Global menu: confirmed out of scope?
- Clipboard history: opt-in shell feature (privacy-sensitive) or leave it to apps?
