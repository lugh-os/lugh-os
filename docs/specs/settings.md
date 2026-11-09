# Lugh Settings — Spec

> Status: **Draft** · Owner phase: **2** (mode switching completed in Phase 5) · Related ADRs: ADR-006, ADR-007, ADR-010, ADR-018, ADR-020, ADR-021

## Purpose

One app to configure everything on Lugh, laid out the way people coming from Windows and macOS expect, and backed by a daemon so that every setting can also be scripted and stored in the Lughfile.

- **UI:** `lugh-settings` (QML + Rust/cxx-qt)
- **Daemon:** `lugh-settingsd`, on the session bus as `space.lugh.Settings1`. It owns `~/.config/lugh/desktop.toml`.

## User stories

- **Windows switcher:** "I want to change my wallpaper, make the taskbar look like Windows, and connect to Wi-Fi without opening a terminal."
- **Linux power user:** "I want every toggle to be a key in a text file that I can diff, script with `lugh settings set`, and keep in git."
- **Minimal user:** "I want the app to open instantly, and I don't want settings for things I didn't install, like Bridge pages when Bridge isn't installed."

## Requirements

### Functional
| ID | Requirement |
|---|---|
| FR-1 | Provides the pages listed in §UX, each with a stable ID so it can be deep-linked (`lugh-settings appearance`, `lugh-settings://network/wifi`). |
| FR-2 | **Appearance:** theme Light (default, ADR-010) / Dark / Auto (sunset–sunrise or fixed times); accent from the six presets in DESIGN-SYSTEM §2.3; wallpaper (bundled, folder, or slideshow); **desktop mode Lugh / Classic / Focus**; icon theme; cursor; fonts; window button side override; transparency on/off. |
| FR-3 | Changes apply **live**, with no logout, including the mode switch (≤ 300 ms; VISION §12). |
| FR-4 | Built-in search across every page, setting label, keyword and synonym. Windows terms map too: "Control Panel", "taskbar", "default programs" and "Wi-Fi password" all find the right setting. |
| FR-5 | Every setting is readable and writable through D-Bus and `lugh settings get/set/list/reset`. |
| FR-6 | Every user-level setting persists in `desktop.toml`, which the Lughfile includes (see [lughfile](lughfile.md)). |
| FR-7 | Pages appear only when their backing component is present: Bluetooth only with an adapter, Bridge only if installed, Battery only on battery-powered machines. |
| FR-8 | "Reset this page" and "Reset all to Lugh defaults" are available, with confirmation and undo for 10 s. |
| FR-9 | System-wide settings (users, time zone, hostname, update policy) require polkit, and clearly say "requires administrator". |

### Non-functional
| ID | Requirement |
|---|---|
| NFR-1 | Cold start to first page visible in ≤ 400 ms on reference hardware (see [build-and-release](build-and-release.md) §Performance). |
| NFR-2 | `lugh-settingsd` uses ≤ 15 MB RSS, is D-Bus activated, and exits after 60 s idle. |
| NFR-3 | Fully keyboard-operable. Every control has an accessible name and description (AT-SPI). WCAG 2.2 AA. |
| NFR-4 | Layout works from 640 px wide (the sidebar collapses to a list → page stack) up to 4K. |
| NFR-5 | A write to `desktop.toml` is atomic (temp file + rename). A corrupt file falls back to defaults and keeps a `.bak`. |

## Design

### Architecture
```
lugh-settings (UI) ──D-Bus──▶ lugh-settingsd (session) ──▶ desktop.toml
                                  │  emits Changed(key, value)
                                  ├──▶ lugh-shell / compositor (subscribe, live-apply)
                                  ├──▶ NetworkManager, BlueZ, UPower, power-profiles-daemon,
                                  │    PipeWire (WirePlumber), localed, timedated, hostnamed,
                                  │    AccountsService  (direct D-Bus to the system services)
                                  └──▶ lugh-configd (records changes into the Lughfile)
```
- Pages that wrap existing system services (Network, Bluetooth, Sound, Power, Users, Date & Time) talk to those services directly through Rust D-Bus proxies. `lugh-settingsd` stores only Lugh's own desktop settings.
- The shell and compositor **subscribe** to `Changed`. They never read `desktop.toml` themselves, so there is a single writer.
- A GTK and Qt theme bridge: on theme or accent change, settingsd writes `gtk-3.0/settings.ini`, `gtk-4.0/settings.ini`, the `org.gnome.desktop.interface color-scheme` (through dconf, for GTK/libadwaita/Flatpak apps), `kdeglobals` color hints for Qt apps, and the `org.freedesktop.appearance` keys of the xdg settings portal.

### D-Bus interface `space.lugh.Settings1` (object `/space/lugh/Settings1`)
| Member | Signature | Notes |
|---|---|---|
| `Get(key s) → v` | method | Dotted key, e.g. `appearance.theme`. |
| `Set(key s, value v)` | method | Validates against the schema. Errors: `space.lugh.Settings1.Error.InvalidValue`, `.UnknownKey`. |
| `Reset(key s)` | method | `key` may be a prefix (`appearance`). |
| `List(prefix s) → a{sv}` | method | |
| `Describe(key s) → (s type, v default, s summary, as allowed)` | method | Powers the UI and the CLI help. |
| `SetMode(mode s)` | method | `lugh` \| `classic` \| `focus`. Orchestrates shell and compositor together (see §Mode switching). |
| `Changed(key s, value v)` | signal | |
| `ModeChanged(mode s)` | signal | |
| `SchemaVersion` | property `u` | |

### Settings schema (excerpt) — `desktop.toml`
```toml
schema = 1

[appearance]
theme = "light"            # light | dark | auto
auto_dark = { mode = "sun", start = "19:00", end = "07:00" }  # sun | fixed
accent = "amber"           # amber | teal | green | blue | red | graphite
wallpaper = "lugh://wallpapers/dawn"   # or a file/folder path
wallpaper_slideshow_minutes = 0
transparency = true
icon_theme = "lugh"
cursor_theme = "lugh"
cursor_size = 24
font_ui = "Inter 10.5"
font_mono = "JetBrains Mono 10"

[desktop]
mode = "lugh"              # lugh | classic | focus
window_buttons = "auto"    # auto (per mode) | left | right
hot_corners = { top_left = "overview" }

[dock]                     # Lugh mode
autohide = false
magnify = false
icon_size = 56
pinned = ["firefox", "lugh-files", "lugh-store", "lugh-settings"]

[taskbar]                  # Classic mode
position = "bottom"
alignment = "left"         # left | center
pinned = ["firefox", "lugh-files"]

[focus]                    # Focus mode
layout = "dwindle"         # dwindle | master
gaps_inner = 6
gaps_outer = 10
bar = "thin"               # thin | hidden

[input]
keyboard_layouts = ["us"]
repeat_delay_ms = 300
repeat_rate = 30
touchpad = { tap_to_click = true, natural_scroll = true, three_finger_swipe = "workspaces" }

[notifications]
do_not_disturb = false
per_app = { "org.telegram.desktop" = { banners = false } }

[accessibility]
reduce_motion = "system"   # system | on | off
high_contrast = false
text_scale = 1.0
screen_reader = false

[privacy]
location = false
recent_files = true
shield_auto_quarantine_downloads = false   # see shield.md
```
Unknown keys are preserved on write, so newer configs survive older software. Schema migrations are numbered functions in `lugh-settingsd`, and `schema` is bumped after each one.

### Mode switching
`SetMode("classic")` does the following:
1. Persists `desktop.mode`.
2. Tells the compositor to change its layout policy and decoration side (Phase 5: through `lugh-shell-v1`; Phases 1–4: through the Hyprland adapter, applying the mode's Hyprland config fragment through `hyprctl keyword`/reload).
3. Emits `ModeChanged`. The shell cross-fades its layout (bar+dock → taskbar, or → thin bar) in 300 ms.
4. Keybindings switch to the mode's preset (Super opens the Start menu in Classic and the launcher in Lugh/Focus).

Phases 1–4 are best-effort for Classic and Focus (see [phase-2](../phases/phase-2-core-apps.md)). They are complete in Phase 5 ([compositor](compositor.md)).

### CLI
```
lugh settings list [prefix]
lugh settings get appearance.theme
lugh settings set appearance.theme dark
lugh settings reset dock
lugh settings mode classic
lugh-settings <page-id>        # open the UI at a page
```

### polkit actions
| Action ID | Used for | Default |
|---|---|---|
| `space.lugh.settings.system-time` | time zone, NTP | admin, keep auth |
| `space.lugh.settings.hostname` | hostname | admin |
| `space.lugh.settings.users` | add/remove users, change account type | admin |
| `space.lugh.settings.login` | greeter options, auto-login | admin |

Network, Bluetooth and power use the system services' own polkit actions.

## UX

### Layout
A sidebar (grouped, with search at the top) and a content pane. Each page uses cards of grouped rows. Window: 960×680 by default, minimum 640×480.

### Pages
| Group | Page (ID) | Contents |
|---|---|---|
| Personalize | **Appearance** (`appearance`) | theme cards (Light / Dark / Auto with live preview thumbnails), accent swatches with names, wallpaper grid, transparency |
| | **Desktop & Dock** (`desktop`) | three large **mode cards** (Lugh / Classic / Focus) with an animated preview; mode-specific options below (dock, taskbar or tiling) |
| | **Fonts** (`fonts`) | UI and mono font, scaling, hinting |
| Devices | **Displays** (`displays`) | arrangement canvas, resolution, refresh rate, scale (fractional), VRR, night light, HDR (later). A "Keep changes?" 15 s revert dialog |
| | **Input** (`input`) | keyboard layouts and shortcuts, mouse, touchpad gestures, tablet |
| | **Sound** (`sound`) | output/input device, volume, per-app volume, test sound |
| | **Bluetooth** (`bluetooth`) | pair, connect, battery levels |
| | **Printers** (`printers`) | CUPS: add printer, queue |
| Connectivity | **Network** (`network`) | Wi-Fi, Ethernet, VPN (WireGuard/OpenVPN), proxy, hotspot, "show Wi-Fi password" (polkit) |
| System | **Power** (`power`) | profile (power-saver / balanced / performance), screen off, suspend, lid behavior, battery health |
| | **Notifications** (`notifications`) | DND schedule, per-app banners/sounds |
| | **Default apps** (`default-apps`) | browser, mail, files, music, video, images, terminal, `.exe` handler (Bridge / ask / off) |
| | **Users** (`users`) | accounts, avatar, password, auto-login, fingerprint (if supported) |
| | **Date & language** (`region`) | language, formats, time zone, input methods |
| | **Accessibility** (`accessibility`) | reduce motion, high contrast, text size, screen reader (Orca), sticky keys, zoom |
| | **Privacy & Security** (`privacy`) | location, recent files, camera/mic indicators, **Shield defaults** (auto-quarantine downloads, default profile; see [shield](shield.md)), Secure Boot status, firewall toggle |
| | **Updates** (`updates`) | summary + "Open Update Center" (Store, [store](store.md) §Update center), automatic security updates, snapshot retention |
| | **Lughfile** (`lughfile`) | repo URL, status (clean / N changes), Sync now, Export, Apply, history (see [lughfile](lughfile.md)) |
| | **About** (`about`) | logo, `PRETTY_NAME` and version from `/etc/os-release`, hardware summary, kernel, desktop mode, "Copy system info" for bug reports |

### States
- **Loading:** skeleton rows (fetching Wi-Fi networks, for example). Never an empty page.
- **Empty:** "No Bluetooth devices yet — Pair a device"; "No printers — Add printer".
- **Error:** inline under the row, e.g. "Couldn't connect to NetworkManager. Network settings are unavailable. [Retry]".
- **Requires admin:** a lock icon on the card plus an "Unlock" button (polkit). Rows stay read-only until unlocked.
- **Disabled:** shows its reason, e.g. "Night light needs a display that supports gamma control".

### Keyboard
| Shortcut | Action |
|---|---|
| Ctrl+F or just start typing | search |
| Ctrl+1..9 | jump to sidebar group |
| Alt+← | back (narrow layout) |
| Ctrl+W / Ctrl+Q | close |

## Security & privacy
- settingsd runs as the user and has no privileges. System changes go through system services + polkit.
- "Show Wi-Fi password" requires polkit every time (no cached auth).
- No telemetry. "Copy system info" builds the text locally, shows it, and copies it only when the user clicks.

## Testing
- Unit: schema validation, migrations (every `schema` N → N+1 with fixtures), atomic write and corrupt-file recovery.
- Integration (headless session in CI): `Set` → `Changed` → shell picks it up (asserted via the shell's test hook); the mode switch completes in < 300 ms (timed).
- UI: Qt Quick Test for each page; screenshot tests in light, dark and high contrast; accessibility tree check (every control named).
- Manual matrix: multi-monitor, HiDPI + fractional, laptops with and without battery, Bluetooth present or absent.

## Open questions
- Should Lugh ship its own file manager (`lugh-files`) or adopt an existing Qt one (Dolphin is heavy with KDE deps)? This affects Default apps and Shield's right-click integration.
- Fingerprint (fprintd) support level at launch.
- Per-monitor different modes (e.g. Focus on the external display): out of scope for v1?
