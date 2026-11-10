# Hyprland: the interim compositor

Phases 1–4 run `lugh-shell` on Hyprland (ADR-012). This page covers which
Hyprland we target, how the Lugh config is laid out and installed, the
keybindings, the performance choices, the session plumbing, how to test it
nested, and known limitations.

Sources: `ui/shell/hypr/` (compositor config) and `ui/shell/session/`
(session start-up and systemd units).

## 1. Version

| Suite | `hyprland` | Notes |
|---|---|---|
| trixie (main) | **none** | Hyprland is not in Debian 13 itself |
| **trixie-backports** | **0.55.2+ds-1~bpo13+1** | **Lugh's target.** Backports are enabled in Lugh (ADR-001) |
| sid | 0.57.0+ds-1 | the next one backports will get |

Companion packages in trixie-backports: `xdg-desktop-portal-hyprland` 1.4.1,
`hyprland-guiutils` 0.2.2, `hyprcursor-util` 0.1.13. Checked on 2026-11-10 with
`apt-cache policy` in `debian:trixie` and `debian:sid` containers.

0.55.2 has what the shell needs: `wlr-layer-shell`, `ext-session-lock-v1`,
`wlr-foreign-toplevel-management`, `ext-idle-notify-v1` and the IPC sockets.
No Lugh repo rebuild is needed for Phase 1 (`packaging/hyprland/` stays empty).
If the Lugh repo ever ships a newer Hyprland (ADR-003), re-run
`scripts/verify-config.sh sid` first.

### The config is Lua

Since **0.55**, Hyprland's main config language is **Lua** (`hyprland.lua`, an
`hl.*` API: `hl.config{}`, `hl.bind()`, `hl.window_rule{}`, `hl.on()`, …). The
old hyprlang `.conf` format is "legacy" in 0.55 and **removed in 0.57** (0.57
parses a `.conf` file as Lua and fails). Lugh's config is therefore Lua. It is
verified on 0.55.2 and 0.57.0.

What changed compared with older Hyprland guides (and with what our specs
assumed when they were written):

| Topic | Old (≤ 0.52, hyprlang) | 0.55 Lua (what we use) |
|---|---|---|
| Config file | `hyprland.conf`, `source = …` | `lugh.lua`, `dofile()` / `require()` |
| Window rules | `windowrulev2 = float, class:.*` (v1 removed in 0.48, v2 deprecated in 0.53) | `hl.window_rule({ name = …, match = { class = ".*" }, float = true })` |
| Layer rules | `layerrule = blur, lugh-bar` | `hl.layer_rule({ match = { namespace = "^lugh-bar$" }, blur = true, ignore_alpha = 0.3 })` |
| Gestures | `gestures { workspace_swipe = true }` (removed in 0.51) | `hl.gesture({ fingers = 3, direction = "horizontal", action = "workspace" })` |
| Shadows | `drop_shadow = true` (removed in 0.45) | `decoration.shadow = { enabled, range, render_power, color }` |
| VFR | `misc:vfr` | `debug.vfr` |
| Binds | `bind = SUPER, Q, killactive` | `hl.bind("SUPER + Q", hl.dsp.window.close())`, or a Lua function |
| `hyprctl dispatch` | `hyprctl dispatch killactive` | the argument is Lua: `hyprctl dispatch 'hl.dsp.window.close()'`, or a function such as `hyprctl dispatch 'lugh.tiling.toggle'` |
| `hyprctl keyword` | sets any option | not how Lugh changes the config at runtime (see §5) |
| `hyprctl eval '<lua>'` | n/a | 0.57+ only |
| Launching | `Hyprland` | `start-hyprland -- --config …` (watchdog; launching `Hyprland` directly logs a warning) |

0.55 → 0.57 differences that matter to us: 0.57 adds `hyprctl eval`, a
`layers.*` section and more blur variants. The spring curve field was renamed
from `dampening` to `damping` (Lugh uses only bezier curves for now, see §4).
`hl.timer()` called while the config loads crashes 0.57 in `--verify-config`
mode, so don't call it at the top level.

**Consequences for the shell's Hyprland adapter** (`docs/specs/shell.md`):
mode presets written by the shell or `lugh-settingsd` must be **Lua**, at
`~/.config/lugh/generated/hyprland-mode.lua` and
`~/.config/lugh/generated/hyprland-bindings.lua`, followed by
`hyprctl reload config-only`. They replace `hyprland-<mode>.conf` from the
spec. Dispatches over IPC use Lua syntax. Socket2 events and `hyprctl -j` JSON
work as before.

## 2. Layout and installation

```
ui/shell/hypr/                      ->  /usr/share/lugh/hypr/
├── lugh.lua                        entry point: sets up paths, loads the parts in order
├── conf.d/
│   ├── 00-env.lua                  toolkit environment (Qt, GTK, cursor, Firefox, Electron)
│   ├── 10-look.lua                 monitors, gaps, rounding, shadow, blur
│   ├── 20-animations.lua           curve + animation leaves
│   ├── 30-performance.lua          vfr, scanout, cursor, XWayland, misc
│   ├── 40-input.lua                keyboard (/etc/default/keyboard), touchpad, gestures
│   ├── 50-rules.lua                window rules (floating-first), layer rules (glass)
│   ├── 60-binds.lua                keybindings (§3)
│   ├── 70-session.lua              starts lugh-session.target when Hyprland is up
│   └── low-power.lua               NOT loaded by default (§5)
├── lugh/                           Lua modules (require "lugh.x")
│   ├── shell.lua                   D-Bus calls to space.lugh.Shell1 via busctl
│   ├── tiling.lua                  per-workspace tiling (Super+T)
│   └── window.lua                  snap halves, minimize, Alt+Tab, Alt+`
├── scripts/
│   ├── media-key.sh                volume / mic / brightness / media / caps lock + OSD
│   ├── launch.sh                   start an app in app-lugh-<id>-<rand>.scope (ADR-015)
│   ├── toggle-tiling.sh            the shell's way to toggle tiling
│   ├── low-power.sh                low-power profile on|off|toggle|status
│   └── verify-config.sh            `Hyprland --verify-config` (local or in a container)
└── lugh-portals.conf               ->  /usr/share/xdg-desktop-portal/lugh-portals.conf

ui/shell/session/
├── lugh.desktop                    ->  /usr/share/wayland-sessions/lugh.desktop
├── lugh-session                    ->  /usr/bin/lugh-session
├── space.lugh.Shell1.service       ->  /usr/share/dbus-1/services/space.lugh.Shell1.service
└── systemd/
    ├── lugh-session.target         ->  /usr/lib/systemd/user/lugh-session.target
    └── lugh-shell.service          ->  /usr/lib/systemd/user/lugh-shell.service
```

Packages (Phase 1 deliverables table): `lugh-hyprland-config` ships
`/usr/share/lugh/hypr/` and the portals file. `lugh-session` ships the session
files and units. No `systemctl enable` is needed: the target pulls the shell
in with `Wants=`.

Load order in `lugh.lua`: `conf.d/00…70` → `low-power.lua` (if the flag is set) →
`~/.config/lugh/generated/hyprland-mode.lua` → `…/hyprland-bindings.lua` →
**`~/.config/lugh/hypr/user.lua`** (user overrides, last, full `hl` API). Every
optional file is skipped when it doesn't exist. Errors in them show up in
Hyprland's error bar with file and line, like any config error.

`lugh.lua` works out its own directory, so the same files run from
`/usr/share/lugh/hypr` and from a git checkout.

A global table `lugh` holds the helpers: `lugh.apps` (terminal, files, settings,
tasks: override in `user.lua`, e.g. `lugh.apps.terminal = "kitty"`),
`lugh.tiling`, `lugh.window`, `lugh.rules.shell_noanim`, `lugh.low_power`,
`lugh.session`.

### Layer-shell namespaces expected from the shell

| Namespace | Blur | Notes |
|---|---|---|
| `lugh-bar`, `lugh-dock`, `lugh-launcher`, `lugh-controlcenter`, `lugh-notifications`, `lugh-notification-center`, `lugh-menu`, `lugh-osd` | yes, `ignore_alpha 0.3` | glass; pixels below 30 % alpha (margins, QML shadows) aren't blurred |
| `lugh-wallpaper` | no | `no_anim` (no fade in/out during shell restarts) |
| `lugh-lock` | no | `no_anim`; the lock itself is `ext-session-lock` |

## 3. Keybindings (Lugh mode)

The Lugh column of the shell spec's shortcut table. "D-Bus" means
`busctl --user --expect-reply=no call space.lugh.Shell1 /space/lugh/Shell1 space.lugh.Shell1 <Method> …`.

| Keys | Action | How |
|---|---|---|
| Super+Space | Launcher | D-Bus `ShowLauncher s ""` |
| Super+Tab, 4-finger swipe up | Overview | D-Bus `ShowOverview` |
| Super+C | Control center | D-Bus `ToggleControlCenter` |
| Super+N | Notification center | D-Bus `ToggleNotificationCenter` |
| Super+L | Lock | `loginctl lock-session` → the shell handles logind's `Lock` signal |
| Print / Shift+Print / Alt+Print | Screenshot area / screen / window | D-Bus `Screenshot s area\|screen\|window` |
| Alt+Tab / Alt+Shift+Tab | Next / previous window (raised) | `cycle_next` + `bring_to_top` |
| Alt+\` | Next window of the same app | `lugh.window.cycle_same_app` |
| Super+Q, Alt+F4 | Close window | `hl.dsp.window.close()` |
| Super+M | Minimize | move to `special:minimized` without following |
| Super+↑ | Maximize (toggle) | fullscreen mode `maximized` |
| Super+F | Fullscreen (toggle) | fullscreen mode `fullscreen` |
| Super+← / → | Snap to left / right half (floating); move focus (tiled) | `lugh.window.snap` |
| Super+Shift+arrows | Move window | `hl.dsp.window.move{direction}` |
| Super+T | Toggle tiling on this workspace | `lugh.tiling.toggle` |
| Ctrl+1…9 / 3-finger swipe | Workspace 1…9 / previous–next | `hl.dsp.focus{workspace}` / gesture |
| Ctrl+Shift+1…9 | Move window to workspace | `hl.dsp.window.move{workspace}` |
| Super+scroll | Next / previous workspace | |
| Ctrl+Alt+T | Terminal | `xdg-terminal-exec`, else `foot` (in a scope) |
| Super+E | Files | `pcmanfm-qt` (in a scope) |
| Super+, | Settings | `lugh-settings` if installed (Phase 2), else the control center |
| Ctrl+Shift+Esc | Tasks | `lugh-tasks` if installed, else the launcher with "Tasks" |
| Super+drag (left / right button) | Move / resize window | |
| Volume, mic, brightness, keyboard backlight, media keys | change the value, then OSD | `scripts/media-key.sh`; work on the lock screen too |
| Caps Lock | OSD | `scripts/media-key.sh caps-lock` on key release |

Super+Shift+Q (quarantine) arrives in Phase 4.

### D-Bus methods the binds call (the shell must implement them)

`space.lugh.Shell1` at `/space/lugh/Shell1`, session bus:

- `ShowLauncher(s query)`: `""` from Super+Space, `"Tasks"` as the Tasks fallback
- `ShowOverview()`
- `ToggleControlCenter()`
- `ToggleNotificationCenter()`
- `Screenshot(s mode)`: `area` | `screen` | `window`
- `ShowOSD(s kind, d value)` with these kinds: `volume` (0.0–1.5),
  `volume-muted` (the level while muted), `microphone` (1 live / 0 muted),
  `brightness` (0–1), `kbd-brightness` (0–1), `caps-lock` (1 on / 0 off)

Also: lock comes from logind's `Lock` signal (`loginctl lock-session`).
Tiling changes are announced on Hyprland's socket2 as
`custom>>lugh-tiling,<workspace id>,<0|1>`. Minimized windows sit in
`special:minimized`: to restore one, the dock moves it back to the current
workspace and focuses it.

## 4. Look and motion

- Gaps: inner 6, outer 10 (DESIGN-SYSTEM §4). Rounding 14. Border 0 in Lugh
  mode. The accent `#E8962E` is already set as the active border color for
  Focus mode, which turns on a 2 px border through its preset.
- Shadow: range 24, render_power 3, `rgba(0,0,0,0.18)` active / 0.10 inactive,
  offset 0 4.
- Blur: on for **layer surfaces only**. Every window gets `no_blur` by rule.
  Settings: size 8, 2 passes (reads like the 30 px `shell-glass` blur),
  `new_optimizations`, `xray false`, `ignore_opacity true`, noise 0.01,
  vibrancy 0.12, and no blur for popups, special workspaces or input methods.
- Floating by default: every window floats, centered, at the size the app
  asks for (`lugh-float-by-default`). Apps can't maximize themselves on open.
  Picture-in-picture windows are pinned at the bottom right.
- Animations: one bezier, `lugh` = `cubic-bezier(0.2, 0, 0, 1)`. Speeds are in
  deciseconds (3 = 300 ms):

| Leaf | Speed | Style |
|---|---|---|
| windowsIn / windowsOut | 3 | popin 94 % / popin 96 % |
| windowsMove, fadeIn, fadeOut | 3 | |
| layersIn / fadeLayersIn | 2.4 | fade |
| layersOut / fadeLayersOut | 1.8 | fade |
| workspaces | 3 | slide |
| specialWorkspace | 3 | slidevert |
| fadeSwitch, fadeShadow, fadeDim | 1.8 | |
| fadePopups, border | 1.2 | |

  Springs (DESIGN-SYSTEM's stiffness 400 / damping 32) aren't used yet, because
  their Lua field name changed between 0.55 and 0.57.
- The shell owns the motion of its own surfaces (QML liquid motion): the
  rule `lugh.rules.shell_noanim` turns compositor animations off for the
  `lugh-*` layers. `lugh.rules.shell_noanim:set_enabled(false)` in `user.lua`
  brings the compositor fades back.

## 5. Performance

Every choice is commented in `conf.d/30-performance.lua`.

| Setting | Why |
|---|---|
| `debug.vfr = true` | render only on damage: an idle desktop draws 0 frames |
| `debug.damage_tracking = 2` | full damage tracking: redraw only what changed |
| `render.direct_scanout = 2` | fullscreen games skip composition (auto: content type "game" only, to avoid flicker elsewhere) |
| `misc.vrr = 2` | VRR for fullscreen only |
| `misc.disable_hyprland_logo`, `disable_splash_rendering`, `force_default_wallpaper = 0` | no wallpaper or logo rendering of our own; the shell draws `lugh-wallpaper` |
| `misc.background_color = #F7F6F3` | Theme `bg` shows before the wallpaper maps or during a shell restart, so there's no black flash |
| `misc.animate_manual_resizes = false`, `animate_mouse_windowdragging = false` | drags and resizes follow the pointer 1:1, with no extra frames |
| `decoration.blur.new_optimizations = true` | the wallpaper blur is cached; re-blurring happens only on damage |
| `decoration.blur.popups/special/input_methods = false` | blur only where the design needs it |
| `no_blur` rule on all windows | translucent apps never trigger blur |
| `cursor.no_hardware_cursors = 2` | hardware cursor planes (moving the cursor redraws nothing), with auto-fallback on drivers known to break |
| `xwayland.force_zero_scaling = true` | crisp, not blurry, XWayland apps on HiDPI |
| `opengl.nvidia_anti_flicker = true` | NVIDIA only |
| `misc.allow_session_lock_restore = true` | a restarted shell can take over the lock |

**Expected GPU cost** (1080p60, Intel Xe iGPU class; rough numbers, to be
measured in Phase 1 testing): idle ≈ 0. Rounding + shadows cost ~0.1–0.3 ms per
frame while windows redraw. Blur under the bar and dock costs ~0.3–0.8 ms per
frame, and only when what is behind them changes. A large launcher or control
center open over a playing video costs ~1–2 ms per frame. Animations cost only
while they run. Older iGPUs (Gen9 and earlier) and software rendering should use
low-power.

### Low-power profile

`conf.d/low-power.lua` turns off blur, shadows and animations. Rounding stays,
because it is nearly free. It's applied when the flag file
`$XDG_RUNTIME_DIR/lugh/hypr-low-power` exists (or `LUGH_LOW_POWER=1`).

The shell switches it with `scripts/low-power.sh on|off|toggle|status`, which
creates or removes the flag, then runs `hyprctl reload config-only`. That
re-runs the Lua config in a few milliseconds without touching monitors, and
turning it off restores every default exactly.

Why not `hyprctl keyword`: with the Lua config manager the config is a program.
A reload keeps one source of truth, and keywords set at runtime would be lost
on the next reload anyway.

**Software rendering turns it on automatically.** When Hyprland is up,
`lugh-session --ready` looks for a software rasterizer (llvmpipe, softpipe) in
Hyprland's log. If it finds one it sets the flag, reloads the config, exports
`LUGH_LOW_POWER=1` to the user manager (the shell starts with
`Services.shell.lowPower`: opaque panels, reduced motion) and lifts
`lugh-shell.service`'s memory limits for this login, because a software
rasterizer keeps all textures in the shell's own memory (300–550 MB).
`LUGH_LOW_POWER=0` in the session environment turns the detection off.

Other expected triggers: power-profiles-daemon switching to `power-saver`, low
battery, or a GPU known to be weak. The flag is per login: the shell sets it
again at start-up. When blur is off, glass surfaces should switch to an opaque
fill. The shell can check with `hyprctl getoption decoration:blur:enabled`.

### Per-workspace tiling

Super+T (or `scripts/toggle-tiling.sh` → `hyprctl dispatch 'lugh.tiling.toggle'`)
does four things:

1. Enables a rule `lugh-tile-ws-<id>` (`float = false` for that workspace,
   modal dialogs excluded). It is created after the float-by-default rule, so
   it wins for new windows.
2. Tiles the windows already on the workspace.
3. Saves the workspace id to `$XDG_RUNTIME_DIR/lugh/hypr-tiled-workspaces`, so
   it survives reloads.
4. Emits `custom>>lugh-tiling,<id>,<0|1>`.

Toggling back floats and centers the windows again.

## 6. Session plumbing

```
greetd / DM ─► lugh-session                       (wayland-sessions/lugh.desktop)
                ├─ exports XDG_SESSION_TYPE=wayland, XDG_CURRENT_DESKTOP=Lugh:Hyprland,
                │  XDG_SESSION_DESKTOP=lugh, DESKTOP_SESSION=lugh, LUGH_SESSION=1
                ├─ stops a leftover lugh-session.target (after a crash)
                ├─ runs: systemd-cat -t lugh-hyprland start-hyprland -- --config /usr/share/lugh/hypr/lugh.lua
                │        └─ Hyprland is up ─► (70-session.lua) lugh-session --ready
                │              ├─ dbus-update-activation-environment --systemd <explicit list>
                │              └─ systemctl --user start lugh-session.target
                │                    ├─ BindsTo graphical-session.target  (portals, PartOf units)
                │                    ├─ Wants lugh-shell.service
                │                    └─ Wants xdg-desktop-autostart.target
                └─ compositor exits (logout = hl.dsp.exit(), or SIGTERM from greetd, forwarded)
                     └─ stop lugh-session.target, stop app-lugh-*.scope,
                        unset WAYLAND_DISPLAY/DISPLAY/HYPRLAND_INSTANCE_SIGNATURE in the user manager
```

Decisions:

- **`XDG_CURRENT_DESKTOP=Lugh:Hyprland`**: our name comes first, so
  xdg-desktop-portal reads `lugh-portals.conf` and `OnlyShowIn=Lugh` works.
  `Hyprland` comes second for tools that look for it. `misc.disable_xdg_env_checks`
  silences Hyprland's warning about it.
- **Portals** (`lugh-portals.conf`, ADR-020): `hyprland` handles ScreenCast,
  Screenshot and GlobalShortcuts. `gtk` handles FileChooser, AppChooser,
  Settings and the rest. `gnome-keyring` handles Secret. Portals are D-Bus
  activated. They start with the right environment because it is imported
  before the target starts, and they stop with `graphical-session.target`.
- **Environment import is an explicit list** (see `SESSION_VARS` in
  `lugh-session`), not `--all`. Shell junk (`PWD`, `SHLVL`, …) doesn't leak into
  every user service, and the display variables are removed again at logout.
  Toolkit variables are set in `00-env.lua` (so nested sessions get them too)
  and imported from the compositor's environment by `--ready`.
- **The compositor is not a systemd unit** (the phase plan listed a
  `lugh-compositor.service`). `lugh-session` runs it directly and waits for it,
  which keeps VT and seat handling with the login session and makes teardown
  simple. Its output goes to the journal as `lugh-hyprland`, and Hyprland keeps
  its own log in `$XDG_RUNTIME_DIR/hypr/<instance>/hyprland.log`.
- **`lugh-shell.service`**: `Type=dbus` (ready when it owns `space.lugh.Shell1`),
  `Restart=always` with `RestartSec=200ms`. `always` and not `on-failure`,
  because a plain `kill` (SIGTERM) counts as a clean exit and would not restart
  it (Phase 1 acceptance #13). It runs in `Slice=session.slice` with
  `CPUWeight=200` / `IOWeight=200` (apps get 100). `MemoryHigh=300M` makes the
  kernel reclaim hard from the shell above 300 MB, and `MemoryMax=450M` gets it
  OOM-killed and restarted (a leak tripwire). `Nice` isn't used, because a user
  manager can't lower it. Crash loops stop after 10 starts in 60 s.
  `Requisite=lugh-session.target` stops it from starting outside a session.
- **D-Bus activation** (`space.lugh.Shell1.service` → `SystemdService=lugh-shell.service`):
  a keybind pressed while the shell is restarting is queued, not lost.
- **Polkit agent**: inside the shell, so there's no separate unit.
- If there is no systemd user manager, `--ready` starts `lugh-shell` directly.

## 7. Packages the config needs

| Package | For |
|---|---|
| `hyprland` (trixie-backports), `hyprland-guiutils` (ANR dialog) | compositor |
| `xdg-desktop-portal`, `xdg-desktop-portal-hyprland` (backports), `xdg-desktop-portal-gtk`, `gnome-keyring` | portals (ADR-020) |
| `systemd` (`busctl`, `systemd-run`, `systemd-cat`, `loginctl`), `dbus-user-session`, `dbus-bin` (`dbus-update-activation-environment`) | session, D-Bus calls, scopes |
| `wireplumber` (`wpctl`), `pipewire-pulse` | volume / mic keys |
| `brightnessctl` | brightness keys (uses logind, no root) |
| `playerctl` | media keys (optional: skipped if missing) |
| `adwaita-icon-theme` | cursor theme |
| `qt6-wayland` | Qt apps and the shell on Wayland |
| `xdg-terminal-exec`, `foot`, `pcmanfm-qt` | default terminal and Files |

## 8. Testing

### Validate the syntax

```sh
ui/shell/hypr/scripts/verify-config.sh                     # local Hyprland if installed, else trixie-backports in a container
ui/shell/hypr/scripts/verify-config.sh sid                 # Hyprland 0.57 from sid
```

This prints Hyprland's "Config parsing result" and exits non-zero on any
error, including unknown option names, unknown window/layer rule fields,
unknown animation leaves or curves, and bad key names. It doesn't run bind or
event callbacks: those only run in a live session.

### Nested session inside KDE (or any Wayland desktop)

From a terminal in a Wayland session, `Hyprland` opens as a window:

```sh
sudo apt install -t trixie-backports hyprland   # on Debian; elsewhere your distro's Hyprland >= 0.55
Hyprland --config "$PWD/ui/shell/hypr/lugh.lua"
```

Without `LUGH_SESSION=1`, the config doesn't touch your desktop's systemd or
D-Bus environment and doesn't start `lugh-session.target`. Start the shell
yourself from a terminal inside the nested session (`foot` with Ctrl+Alt+T),
e.g. `lugh-shell` or `qml …`.

Keybindings that use Super may be grabbed by the host desktop. Click into the
nested window first; KDE passes Super through to focused Wayland windows.
`hyprctl` inside the nested session talks to it, because
`HYPRLAND_INSTANCE_SIGNATURE` is set there.

Useful checks inside: `hyprctl layers` (shell namespaces), `hyprctl binds`
(descriptions), `hyprctl getoption decoration:blur:enabled`,
`ui/shell/hypr/scripts/low-power.sh on`, Super+T, then `hyprctl clients`.

A full session (greeter → `lugh-session`) is tested in QEMU from the ISO.

## 9. Known limitations

- **Not run live yet.** Syntax and option names are verified on 0.55.2 and
  0.57.0, but the bind callbacks (snap, minimize, tiling, Alt+\`) and the
  session start-up haven't run in a real session, because no headless parent
  compositor in the build containers supports the `xdg_wm_base` v6 that 0.55
  needs. The first nested run should check them.
- **Snap halves** compute the usable area from the `lugh-bar` / `lugh-dock`
  layer geometry, because the 0.55 Lua API exposes no reserved area. It
  assumes the bar is at the top.
- **Minimize** is a special workspace: Hyprland has no minimized state. The
  dock must restore windows by moving them back.
- **Ctrl+1…9** (workspace switching, per the spec) shadows apps' own Ctrl+number
  shortcuts (browser tabs). This is a spec decision to revisit with user
  testing.
- Window buttons and decorations are client-side (shell spec: not consistent
  across toolkits until Phase 5).
- `xwayland.force_zero_scaling` makes XWayland apps crisp but small on HiDPI,
  unless they honor `GDK_SCALE` / `QT_SCALE_FACTOR`.
- `desktop-file-validate` flags `DesktopNames` in `lugh.desktop`. That key is
  the standard one display managers read from session files (Hyprland's own
  session file uses it), so it stays.
