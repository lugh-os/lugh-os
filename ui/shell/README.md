# lugh-shell (QML)

The Lugh desktop shell: bar, dock, launcher, control center, notifications,
lock screen and wallpaper, written in QML (Qt 6.8) and shown as
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
    ├── ShellState.qml       # which overlay is open, island rects
    ├── backend/WsBackend.qml  # dev backend over WebSocket (lugh-shell-devd)
    ├── wallpaper/  bar/  dock/  launcher/  controlcenter/
    └── notifications/  lockscreen/
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
  `osd` shows the OSD in the center island; `lock` locks (password `lugh`
  unlocks on the mock).
- `--screenshot` waits for loads and open animations, saves the PNG and quits.
- `--measure` prints the time from process start to the first frame and quits.
- `--motion` grabs the scene before and after triggering `<state>`; see below.
- `--wallpaper-dir` is added by the scripts when `lugh-branding` isn't
  installed, so the wallpaper comes from `branding/wallpapers/`.

Keys: **Meta+Space** or **Ctrl+Space** launcher · **Ctrl+C** control center ·
**Ctrl+N** notifications · **Ctrl+L** lock · **Ctrl+D** toggle dark · **Esc**
closes. Clicking a mock window raises and focuses it; the title bar drags it.
Mock windows stay below the islands' zone (`Theme.barExclusiveZone`) and above
the dock.

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
osd toast`. Narrow with `SHOTS_STATES="none lock" SHOTS_THEMES=dark`.

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
shell still runs. There is no `Osd` surface: the bar's center island is the
OSD.

| Surface | Root size | Exposes | Layer · anchors · zone · keyboard · namespace |
|---|---|---|---|
| `Wallpaper` | fills parent | `dark`, `blurred`, `source` | background · all 4 · −1 · none · `lugh-wallpaper` (every screen) |
| `Bar` | width = screen (set by the frame), `implicitHeight: Theme.barHeight` (52) | `exclusiveZone` (48; `Theme.barExclusiveZone` when absent), `inputRects` (the three islands); publishes `ShellState.logoIsland/centerIsland/statusIsland` in scene coordinates | top · top+left+right · `exclusiveZone` · none · `lugh-bar` (every screen) |
| `Dock` | full width, `implicitHeight` includes transparent headroom | `exclusiveZone`, `inputRect`, `menuOpen` | top · bottom+left+right · `exclusiveZone` · on-demand while `menuOpen`, else none · `lugh-dock` (every screen) |
| `LughMenu`, `Launcher`, `ControlCenter`, `NotificationCenter` | fill the screen; the surface draws a `MorphPanel` growing out of its island and closes on outside click via `ShellState` | `shown` (open **or** animating out), `wantsKeyboard` | overlay · all 4 · −1 · exclusive while `wantsKeyboard`, else none · `lugh-menu`, `lugh-launcher`, `lugh-controlcenter`, `lugh-notification-center` (active screen) |
| `NotificationPopups` | `implicitWidth` × `implicitHeight` | `shown`, `inputRects` | overlay · top+right · 0 · none · `lugh-notifications` (active screen); `Theme.barHeight` from the top and 10 px from the right, as transparent padding inside the window |
| `LockScreen` | fills the screen | `shown`, `wantsKeyboard` | overlay · all 4 · −1 · exclusive · `lugh-lock` (every screen; the primary one takes the keyboard) |

How `main.qml` wires it:

- **Backend.** `if (typeof LughBackend !== "undefined" && LughBackend)
  Services.attach(LughBackend)` runs before any surface is created. With plain
  `qml6` the mock `Services` stays.
- **Start-up.** Wallpaper, Bar and Dock are created synchronously; on the
  bar's first `frameSwapped` the frame calls `Services.shell.ready()` once;
  the other surfaces follow one per idle turn (or at once when asked for).
  `--lazy-overlays` creates an overlay on its first open instead. If
  `Services.session.locked` is already true at start, the lock windows are
  created and mapped first and the desktop only after the lock's first frame.
- **Overlays** are mapped only while `shown`. When one maps with
  `wantsKeyboard` the frame activates it; the surface focuses its own field.
- **Input regions.** When the `LughNative` context object exists the frame
  calls `LughNative.setInputRegion(window, [rect, …])` (window coordinates) at
  most once per frame: bar = `inputRects`; dock = `inputRect`, or the whole
  window while `menuOpen`; toasts = `inputRects` shifted by the padding.
  Without it (qml6) the transparent parts take clicks.
- **Low power.** While `Services.shell.lowPower` is true the frame sets
  `Theme.transparency = false` and `Theme.reduceMotion = true`, and restores
  the user's values when it clears (a change the user makes meanwhile wins).
- **Screens.** Wallpaper, Bar, Dock and LockScreen exist per screen, tracked by
  name, so hot-plug adds or removes only that screen's windows. Overlays and
  toasts go to the screen the compositor considers active.
- **Dev flags** after `--`: `--dark`, `--accent <name>`, `--reduce-motion`,
  `--wallpaper-dir <url/>`, `--lazy-overlays`, `--no-media`, `--idle-report <s>`.

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
- No `margins`: the toasts carry their offsets (`Theme.barHeight` from the
  top, 10 px from the right) as transparent padding inside the window, and
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
In short (2026-11-10, Intel UHD 630 under Mesa, headless nested KWin, loaded
dev host): idle is clean (0 frames and ≤ 10 ms CPU in 10 s with nothing
playing), RSS is 185 MB (67 anonymous + 118 file-backed; an empty Qt Quick
window is 104–118 MB here) and the first frame takes 0.7–1.3 s (empty window:
0.4 s). While music plays the bar's equalizer keeps the bar window at ~57 fps.

```
scripts/shell-run.sh --nested 10 -- --no-media
```
