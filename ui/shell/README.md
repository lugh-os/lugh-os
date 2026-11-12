# lugh-shell (QML)

The Lugh desktop shell: bottom panel, launcher, quick panel (clock, calendar,
controls), notifications, workspace overview, Customize, lock screen and
wallpaper, written in QML (Qt 6.8) and shown as
wlr-layer-shell surfaces on Hyprland. The Rust host (`ui/shell/src`, cxx-qt)
loads `main.qml` and attaches the real backend to `Services`. Spec:
[docs/specs/shell.md](../../docs/specs/shell.md); look and feel:
[docs/DESIGN-SYSTEM.md](../../docs/DESIGN-SYSTEM.md).

## Layout

```
ui/shell/qml/
├── main.qml                 # production root: one layer-shell window per surface
├── preview.qml              # dev desktop preview: the whole desktop in one window
├── preview/                 # preview-only helpers
│   ├── MockWindow.qml       #   app window chrome (Lugh mode: buttons left, 14 px)
│   ├── BrowserContent.qml   #   …browser, terminal and files window contents
│   ├── TerminalContent.qml
│   ├── FilesContent.qml
│   ├── Optional.qml         #   Loader for types that may not exist yet
│   ├── optional.js          #   shared component cache for the above
│   └── Check.qml            #   load-check harness (scripts/qml-check.sh)
├── demos/                   # small demo scenes, one per surface
└── Lugh/Shell/              # the Lugh.Shell QML module
    ├── qmldir
    ├── Services.qml         # system state: mock by default, live after attach(backend)
    ├── ShellState.qml       # which overlay is open, panel/tray rects
    ├── ShellSettings.qml    # user settings (~/.config/lugh/lugh-shell.conf), edited by Customize
    ├── backend/WsBackend.qml  # dev backend over WebSocket (lugh-shell-devd)
    ├── wallpaper/  panel/  launcher/  controlcenter/ (quick panel)
    ├── overview/  customize/  notifications/  lockscreen/
    └── bar/ (Lugh menu)  dock/ (panel app items)
```

Shared components come from `Lugh.UI` in `ui/components/` (contract:
[ui/components/API.md](../components/API.md)). Import paths: `ui/components`
and `ui/shell/qml`. Design language: [docs/design/lugh-mode.md](../../docs/design/lugh-mode.md);
bridge: [docs/specs/shell-bridge.md](../../docs/specs/shell-bridge.md).

## Running

| Command | What it does |
|---|---|
| `make preview` / `scripts/shell-preview.sh` | The whole desktop in one normal window, on any machine. `make preview ARGS="--dark --state launcher"`. |
| `make shots` / `scripts/shell-shots.sh [dir]` | Stills, light + dark × 11 states → `out/shots/<theme>-<state>.png`. |
| `scripts/shell-motion.sh [dir]` | Motion contact sheets → `out/motion/<name>-<theme>.png`. |
| `make qml-check` / `scripts/qml-check.sh` | Loads every demo, every `Lugh.Shell` type, every preview state and `main.qml`; fails on any QML warning. |
| `scripts/shell-run.sh` | `main.qml` as layer-shell surfaces on Hyprland. Refuses on any other desktop. |
| `scripts/shell-run.sh --nested [secs]` | `main.qml` in a headless nested KWin: prints first frame, RSS, idle frames and CPU; fails on QML warnings. Safe on a KDE host. |
| `scripts/shell-run.sh --nested-exec [WxH] -- cmd…` | Any command inside a headless nested KWin (what shots and motion use). |

Nothing here puts a shell surface on the live desktop: shots, motion and the
nested run render in `kwin_wayland --virtual` on the Mesa GPU
(`LUGH_NESTED_GPU=default` for the host's default driver), or with the
software renderer when KWin is not installed.

### Preview args

```
scripts/shell-preview.sh [--width 1440] [--height 900] [--dark]
    [--accent amber|teal|green|blue|red|graphite] [--reduce-motion]
    [--state none|launcher|controlcenter|notifications|menu|lock|osd|toast]
    [--query <text>]                       with --state launcher
    [--page wifi|bluetooth|sound|power]    with --state controlcenter
    [--kind volume|brightness|mic|caps|layout|airplane] [--value 0..1]
                                           with --state osd
    [--backend ws://127.0.0.1:7777]        live services
    [--screenshot <out.png>] [--shot-delay <ms>] [--measure]
    [--motion <state> --motion-out <dir>] [--motion-frames 24]
    [--motion-ms <ms>] [--motion-offset <ms>]
```

Every argument is passed through to `preview.qml`.

- `--state` opens that overlay at start. `toast` posts two notifications;
  `osd` shows the OSD in the panel tray; `lock` locks (password `lugh`
  unlocks on the mock).
- `--screenshot` waits for loads and open animations, saves the PNG and quits.
- `--measure` prints the time from process start to the first frame and quits.
- `--motion` grabs the scene before and after triggering `<state>`; see below.
- `--wallpaper-dir` is added by the scripts when `lugh-branding` isn't
  installed, so the wallpaper comes from `branding/wallpapers/`.

Keys: **Meta+Space** or **Ctrl+Space** launcher · **Ctrl+C** quick panel ·
**Ctrl+N** notifications · **Ctrl+Tab** overview · **Ctrl+,** Customize · **Ctrl+L** lock · **Ctrl+D** toggle dark · **Esc**
closes. Clicking a mock window raises and focuses it; the title bar drags it.
Mock windows stay above the bottom panel.

### Preview on the real backend

```
cargo run -p lugh-shell-devd            # serves ws://127.0.0.1:7777
scripts/shell-preview.sh --backend ws://127.0.0.1:7777
```

The preview loads `Lugh/Shell/backend/WsBackend.qml` by URL, sets its `url`
and calls `Services.attach(it)` once it is connected, so the surfaces show
this machine's Wi-Fi, sound, battery and apps. If the file or QtWebSockets is
missing, or the server does not answer within 1.5 s, it logs one line and
stays on the mock. (Check the devd crate's README for its exact run command.)

### Shots and motion sheets

`scripts/shell-shots.sh` renders light + dark × `none launcher launcher-query
controlcenter controlcenter-wifi controlcenter-sound notifications menu lock
osd toast overview customize customize-panel`. Narrow with `SHOTS_STATES="none lock" SHOTS_THEMES=dark`.

`scripts/shell-motion.sh` shows how the liquid motion looks without a human
at the screen. For each of `launcher controlcenter notifications osd toast`
(also `menu`, `lock`) the preview grabs its scene as fast as it can, frame 0
just before the trigger. One grab takes 35–100 ms, so the script runs
`MOTION_PASSES` (3) passes whose grabs are shifted against each other and
tiles all frames in time order, each labelled with its time since the trigger
(~15–30 ms apart over `MOTION_MS`=900). `MOTION_NAMES`, `MOTION_THEMES`,
`MOTION_CROP=full` narrow or widen it. Needs ImageMagick. The passes are
separate runs: a hitch that only one run had shows as a frame out of step.

## Surface contract (v2)

`main.qml` and `preview.qml` compose the surfaces through these properties
only. Every surface is created by name (`Qt.createComponent("Lugh.Shell",
type)`), so a missing or broken surface logs one warning and the rest of the
shell still runs. There is no `Osd` surface: the panel's tray is the OSD.

| Surface | Root size | Exposes | Layer · anchors · zone · keyboard · namespace |
|---|---|---|---|
| `Wallpaper` | fills parent | `dark`, `blurred`, `source` | background · all 4 · −1 · none · `lugh-wallpaper` (every screen) |
| `Panel` | width = screen (set by the frame), `implicitHeight` includes transparent headroom | `exclusiveZone`, `inputRect`, `inputRects` (preferred), `menuOpen`, `screenHeight` and `publish` (set by the frame), `focusPanel()`; the publishing panel writes `ShellState.logoIsland/centerIsland/statusIsland/panelRect/panelReserved` in screen coordinates | top · bottom+left+right · `exclusiveZone` · on-demand while `menuOpen`, else none · `lugh-dock` (every screen) |
| `LughMenu`, `Launcher`, `ControlCenter`, `NotificationCenter`, `Overview`, `Customize` | fill the screen; the surface draws its panel (scaling up out of what opened it) and closes on outside click via `ShellState` | `shown` (open **or** animating out), `wantsKeyboard` | overlay · all 4 · −1 · exclusive while `wantsKeyboard`, else none · `lugh-menu`, `lugh-launcher`, `lugh-controlcenter`, `lugh-notification-center`, `lugh-overview`, `lugh-customize` (active screen) |
| `NotificationPopups` | `implicitWidth` × `implicitHeight` | `shown`, `inputRects` | overlay · top+right · 0 · none · `lugh-notifications` (active screen); 10 px from the top and the right, as transparent padding inside the window |
| `LockScreen` | fills the screen | `shown`, `wantsKeyboard` | overlay · all 4 · −1 · exclusive · `lugh-lock` (every screen; the primary one takes the keyboard) |

How `main.qml` wires it:

- **Backend.** `if (typeof LughBackend !== "undefined" && LughBackend)
  Services.attach(LughBackend)` runs before any surface is created. With plain
  `qml6` the mock `Services` stays.
- **Start-up.** Wallpaper and Panel are created synchronously; on the
  panel's first `frameSwapped` the frame calls `Services.shell.ready()` once;
  the other surfaces follow one per idle turn (or at once when asked for).
  `--lazy-overlays` creates an overlay on its first open instead. If
  `Services.session.locked` is already true at start, the lock windows are
  created and mapped first and the desktop only after the lock's first frame.
- **Overlays** are mapped only while `shown`. When one maps with
  `wantsKeyboard` the frame activates it; the surface focuses its own field.
- **Input regions.** When the `LughNative` context object exists the frame
  calls `LughNative.setInputRegion(window, [rect, …])` (window coordinates) at
  most once per frame: panel = `inputRects` (else `inputRect`), or the whole
  window while `menuOpen`; toasts = `inputRects` shifted by the padding.
  Without it (qml6) the transparent parts take clicks.
- **Low power.** While `Services.shell.lowPower` is true the frame sets
  `Theme.transparency = false` and `Theme.reduceMotion = true`, and restores
  the user's values when it clears (a change the user makes meanwhile wins).
- **Screens.** Wallpaper, Panel and LockScreen exist per screen, tracked by
  name, so hot-plug adds or removes only that screen's windows; each sits at
  its output's origin (Qt moves a window at (0, 0) to the first screen).
  Overlays and toasts go to the screen the compositor considers active. Only
  the panel on the active output (`Services.wm.activeOutput`; "" or unknown →
  the first screen) publishes `ShellState` geometry, in output-local
  coordinates (each overlay window covers its own output).
- **Keyboard.** Super+B (`space.lugh.Shell1.FocusPanel` →
  `ShellState.focusPanelRequested`): the active output's panel enters
  keyboard mode, its window becomes keyboard-exclusive and is activated, the
  start button takes focus (focus ring). Arrows / Home / End / Tab move,
  Enter / Space activate, Menu / Shift+F10 open the context menu, Esc (or
  activating anything, or an overlay opening) gives the keyboard back and the
  compositor refocuses the previous window. A context menu opened with the
  pointer makes the window keyboard on-demand. The preview binds Ctrl+B.
- **Auto-hide.** `ShellSettings.panelAutohide`: exclusive zone 0, the pill
  slides off while a window overlaps it, a 4 px edge strip takes the pointer.
  `ShellState.panelReserved` stays the panel's height + margin: every overlay
  reveals the panel, so overlays always stand above it.
- **Dev flags** after `--`: `--dark`, `--accent <name>`, `--reduce-motion`,
  `--dev-config`, `--wallpaper-dir <url/>`, `--lazy-overlays`, `--no-media`,
  `--idle-report <s>`. In the source tree the wallpaper dir defaults to the
  repo's `branding/wallpapers/`, set before any image loads.
- **Dev config.** `scripts/shell-preview.sh` (so `shell-shots.sh` and
  `shell-motion.sh`) and `scripts/shell-run.sh --nested` run on a throwaway
  `XDG_CONFIG_HOME` (removed on exit) and pass `--dev-config`: the
  appearance flags are then written into `ShellSettings`, so Customize shows
  what the screen shows (a dark preview says "Dark"), and
  `~/.config/lugh/lugh-shell.conf` is never written. Interactive previews
  start from a copy of it, renders from the defaults; `kdeglobals`,
  fontconfig and GTK settings are copied in. On Hyprland, `shell-run.sh`
  does the same only when an appearance flag is given.
  `LUGH_DEV_CONFIG=keep` uses the real config (flags then only reach Theme).

## LayerShellQt QML API

`main.qml` uses the attached `LayerShell.Window` API (`import
org.kde.layershell 1.0 as LayerShell`).

| | Debian trixie: layer-shell-qt **6.3.4** (Qt 6.8.2) | Dev host: layer-shell-qt 6.8.0 (Qt 6.11) |
|---|---|---|
| QML module `org.kde.layershell` (attached `Window`) | yes (`qml6-module-org-kde-layershell`) | yes |
| `layer`, `anchors`, `exclusionZone`, `keyboardInteractivity`, `scope` | yes | yes |
| `margins` (QMargins) | property exists, but **can't be set from QML on Qt 6.8**: "Unable to assign QJSValue to QMargins" (verified in a trixie container) | settable from a JS object (Qt 6.11 only) |
| `screenConfiguration: ScreenFromCompositor` (compositor picks the output) | yes | deprecated (warns), use `wantsToBeOnActiveScreen` |
| `wantsToBeOnActiveScreen`, `screen`, `activateOnShow` | **no** | yes |
| `exclusiveEdge` | C++ only (no Q_PROPERTY) | C++ only |
| `closeOnDismissed` | C++ only | C++ only |

What `main.qml` does about it:

- Uses only the trixie subset. "Active screen" overlays call
  `wantsToBeOnActiveScreen = true` when the property exists, else set
  `screenConfiguration = ScreenFromCompositor` (feature-detected at runtime, so
  neither version warns).
- No `margins`: the toasts carry their offsets (10 px from the top and the
  right) as transparent padding inside the window, and
  their input region excludes it.
- Per-screen windows set `Window.screen` (LayerShellQt's default
  `ScreenFromQWindow` honours it). Screens are tracked by name, so hot-plugging
  adds/removes that screen's windows without touching the others.

### Gaps (need the Rust/C++ side)

1. **Lock screen.** Production must use `ext-session-lock-v1` (spec FR-6:
   stays locked if the shell crashes). Neither Qt nor LayerShellQt exposes it
   to QML. `LockScreen` is an overlay layer surface with exclusive keyboard on
   every screen: **not secure** on its own (a crash unlocks).
2. **Persistent graphics.** `QQuickWindow::setPersistentGraphics(false)` /
   `setPersistentSceneGraph(false)` on overlay windows (C++ only) would
   release their GPU memory while unmapped.
3. **Real margins.** `LayerShellQt::Window::get(w)->setMargins()` from C++
   would replace the toasts' transparent padding.

## Glass in the preview

On Hyprland, glass surfaces get a real blur (`layerrule = blur` on the
namespaces above). The preview sets `Theme.backdrop` to a pre-blurred copy of
the wallpaper (`Wallpaper { blurred: true }`, a small file scaled up) and
`GlassPanel` draws the part under itself. The frame adds no per-panel
backdrops. App windows are not part of the simulated blur (the compositor
would blur them too). Production never loads the blurred copy.

## Performance

Budget: first frame ≤ 400 ms, RSS ≤ 150 MB, zero CPU when idle. Method,
numbers and hot spots: [docs/dev/shell-performance.md](../../docs/dev/shell-performance.md).
In short (2026-11-11, bottom Panel, Intel UHD 630 under Mesa, headless nested
KWin, heavily loaded dev host): idle is clean (0 frames and ≤ 10 ms CPU in
10 s with nothing playing; 15 frames in 5 s while music plays, the tray's
equalizer stepping every 320 ms), RSS is 213 MB (92 anonymous + 121
file-backed; 171 MB with `--lazy-overlays`; an empty Qt Quick window is
104–118 MB here) and the first frame takes ~1.0 s (empty window: 0.4 s).

```
scripts/shell-run.sh --nested 10 -- --no-media
```
