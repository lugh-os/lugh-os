# lugh-shell (QML)

The Lugh desktop shell: bar, dock, launcher, control center, notifications,
OSD, lock screen and wallpaper, written in QML (Qt 6.8) and shown as
wlr-layer-shell surfaces on Hyprland. A Rust core (`crates/lugh-shell-core`,
bridged with cxx-qt) replaces the mock `Services` later. Spec:
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
│   ├── GlassBackdrop.qml    #   glass simulation (pre-blurred wallpaper, rounded)
│   ├── Optional.qml         #   Loader for types that may not exist yet
│   ├── optional.js          #   shared component cache for the above
│   └── Check.qml            #   load-check harness (scripts/qml-check.sh)
├── demos/                   # small demo scenes
└── Lugh/Shell/              # the Lugh.Shell QML module
    ├── qmldir
    ├── Services.qml         # mock system backend (the Rust core implements the same API)
    ├── ShellState.qml       # which overlay is open
    ├── wallpaper/  bar/  dock/  launcher/  controlcenter/
    └── notifications/  osd/  lockscreen/
```

Shared components come from `Lugh.UI` in `ui/components/` (contract:
[ui/components/API.md](../components/API.md)). Import paths: `ui/components`
and `ui/shell/qml`.

## Running

| Command | What it does |
|---|---|
| `make preview` / `scripts/shell-preview.sh [args]` | Desktop preview in a normal window, on any machine. |
| `make shots` | Renders the preview light + dark × every state into `out/shots/<theme>-<state>.png` (offscreen, ~10 s). This is the visual regression set. |
| `make qml-check` | Loads every demo, every `Lugh.Shell` surface and every preview state headless (`QT_QPA_PLATFORM=offscreen`); fails on any QML warning or error. |
| `scripts/shell-run.sh` | Runs `main.qml` as real layer-shell surfaces. Refuses outside Hyprland. |
| `scripts/shell-run.sh --nested [secs]` | Runs `main.qml` in a headless nested KWin (`kwin_wayland --virtual`) for a few seconds, prints max RSS, fails on QML warnings. Safe on any KDE host. |

Don't run `main.qml` with `--force` on a live KDE/GNOME session: it puts a
second bar and dock on your desktop.

### Preview args

```
scripts/shell-preview.sh [--width 1440] [--height 900] [--dark]
    [--accent amber|teal|green|blue|red|graphite] [--reduce-motion]
    [--state none|launcher|controlcenter|notifications|menu|lock|osd|toast]
    [--query <text>] [--screenshot <out.png>] [--measure]
```

- `--state` opens that overlay at start. `launcher` + `--query` prefills the
  search; `toast` posts two notifications through `Services.notifications.notify`;
  `osd` calls `Services.osd.show("volume", 0.62)`; `lock` calls
  `Services.session.lock()` (password `lugh` unlocks).
- `--screenshot` waits ~1.2 s for loads and open animations, saves the PNG and
  quits. It uses the offscreen platform unless `QT_QPA_PLATFORM` is set (no
  window flashes; offscreen still renders through the GPU RHI, so the glass
  simulation and shadows show).
- `--measure` prints the time from process start to the first frame and quits.
- `--wallpaper-dir` is added by the scripts when `lugh-branding` isn't
  installed, so the wallpaper comes from `branding/wallpapers/`. It needs
  `Services.appearance.wallpaperDir` (proposed; ignored until it exists).

Keys in the preview: **Meta+Space** or **Ctrl+Space** launcher · **Ctrl+C**
control center · **Ctrl+N** notifications · **Ctrl+L** lock · **Ctrl+D** toggle
dark · **Esc** closes. Clicking a mock window raises and focuses it (the bar
follows); the title bar drags it.

## Surface contract

`main.qml` and `preview.qml` compose the surfaces through these properties
only. Every surface is created by name (`Qt.createComponent("Lugh.Shell",
type)`), so a missing or broken surface logs one warning and the rest of the
shell still runs.

| Surface | Root size | Exposes | Layer · anchors · zone · keyboard · namespace |
|---|---|---|---|
| `Wallpaper` | fills parent | props `dark`, `blurred`, `source` | background · all 4 · −1 · none · `lugh-wallpaper` (every screen) |
| `Bar` | width = screen (set by the frame), `implicitHeight: 30` | — | top · top+left+right · 30 · none · `lugh-bar` (every screen) |
| `Dock` | full width, `implicitHeight` includes transparent headroom for its tooltips/menus | `readonly property int exclusiveZone` (0 when auto-hidden), `readonly property rect inputRect` (visible dock, own coords), `readonly property bool menuOpen` | top · bottom+left+right · `exclusiveZone` · on-demand while `menuOpen`, else none · `lugh-dock` (primary screen) |
| `LughMenu`, `Launcher`, `ControlCenter`, `NotificationCenter`, `LockScreen` | fill the whole screen (frame anchors all four edges); the surface draws its own panel and closes on outside click via `ShellState` | `readonly property bool shown` (open **or** animating out), `readonly property bool wantsKeyboard` | overlay · all 4 · −1 · exclusive while `wantsKeyboard`, else none · `lugh-menu`, `lugh-launcher`, `lugh-controlcenter`, `lugh-notification-center`, `lugh-lock` (active screen) |
| `NotificationPopups` | `implicitWidth` × `implicitHeight` | `shown` | overlay · top+right · 0 · none · `lugh-notifications`; 8 px from the right edge and 8 px below the bar (top 30 + 8) |
| `Osd` | `implicitWidth` × `implicitHeight` | `shown` | overlay · bottom · −1 · none, click-through · `lugh-osd`; centred, 96 px above the bottom edge but at least 24 px above the dock's exclusive zone (`max(96, Dock.exclusiveZone + 24)`) |

Overlay windows are mapped only while `shown` (an unmapped window costs no
rendering). When one maps with `wantsKeyboard`, the frame activates it; the
surface must give focus to its own field (`focus: true` inside a `FocusScope`
root). Which overlay is open lives in `ShellState`; the lock state in
`Services.session.locked`; OSD requests come from `Services.osd.requested`.

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
- No `margins`: toasts carry their offsets as transparent padding inside the
  window. Popups use exclusion zone 0, so the compositor already places them
  below the bar's exclusive zone; the 8 px gap is padding. The OSD's 96 px is
  padding too (`max(96, dock zone + 24)`), but the OSD is click-through (`Qt.WindowTransparentForInput`),
  so it costs nothing. If the Rust side wants real margins it can call
  `LayerShellQt::Window::get(w)->setMargins()` from C++.
- Per-screen windows set `Window.screen` (LayerShellQt's default
  `ScreenFromQWindow` honours it). Screens are tracked by name, so hot-plugging
  adds/removes that screen's windows without touching the others.

### Gaps (need the Rust/C++ side)

1. **Input regions.** QML can't call `QWindow::setMask()`. Without it, the
   Dock's transparent headroom and the toasts' 8 px padding take clicks meant
   for the windows below. `main.qml` already computes the regions and calls
   `LughNative.setInputRegion(window, [rect, …])` (rects in window coordinates)
   whenever they change, if a `LughNative` context object exists. The Rust
   binary should provide it: `window->setMask(QRegion(union of rects))`.
2. **Lock screen.** Production must use `ext-session-lock-v1` (spec FR-6:
   stays locked if the shell crashes, covers every output). Neither Qt nor
   LayerShellQt exposes it to QML. For now `LockScreen` is an overlay layer
   surface with exclusive keyboard on the active screen: **not secure** (a
   crash unlocks, other outputs and the bars stay visible). The Rust side has
   to implement the session-lock client and host the `LockScreen` item in its
   lock surfaces.
3. **Persistent graphics.** Hidden overlay windows keep their scene graph by
   default. `QQuickWindow::setPersistentGraphics(false)` /
   `setPersistentSceneGraph(false)` on overlay windows (C++ only) releases GPU
   memory while they're unmapped.

## Glass in the preview

On Hyprland, glass surfaces get a real blur (`layerrule = blur` on the
namespaces above). The preview simulates it without shaders: a pre-blurred
copy of the wallpaper (`Wallpaper { blurred: true }`, small file, scaled up)
sits under the sharp one, and each glass area draws its part of it
(`preview/GlassBackdrop.qml`: one `ShaderEffectSource` used as a Qt 6.8
`ShapePath.fillItem` with a rounded `PathRectangle`). Today the frame does
this under the Bar (rect) and the Dock (`Dock.inputRect`, `Theme.radiusXl`).
If `Theme.backdrop` exists (proposed preview-only hook), the preview sets it
and `GlassPanel` draws the backdrop under every glass panel itself, including
the overlays' panels, and the frame-side fallback turns off. App windows are
not part of the simulated blur (the compositor would blur them too).

## Performance notes

Budget (spec NFR-1, Phase 1 gate): shell RSS ≤ 150 MB, first frame ≤ 400 ms.

- One process, one QML engine, many windows. Only Wallpaper, Bar and Dock are
  mapped at idle; every overlay is an unmapped window until `shown`.
- `scripts/shell-run.sh` sets the recommended environment (copy it into the
  systemd unit): `QSG_RHI_BACKEND=opengl`, `QSG_RENDER_LOOP=threaded`
  (default; `basic` saves a thread + GL context per window at the cost of
  animations sharing the GUI thread), `MALLOC_ARENA_MAX=2` (glibc otherwise
  keeps one malloc arena per render thread), `QT_WAYLAND_DISABLE_WINDOWDECORATION=1`,
  `QML_DISK_CACHE_PATH`.
- The Wallpaper decodes once at screen size; the blurred copy is a small
  960×540 file scaled up. No runtime blur, no `MultiEffect`, no `layer.enabled`
  in production paths. Shadows are 9-patch `BorderImage`s.
- The GPU driver dominates RSS: the NVIDIA proprietary driver adds ~100 MB to
  any GL process. Measure budgets on Mesa (the target iGPUs), e.g.
  `__EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json`.

### Measured (2026-11-10, dev host: Qt 6.11 KDE neon, GTX 1650; headless nested KWin)

All max RSS (`/usr/bin/time`), `MALLOC_ARENA_MAX=2`. "Floor" is an empty Qt
Quick window with one Text item: what any Qt app costs on that stack before a
single line of Lugh QML.

| What | First frame | Max RSS |
|---|---|---|
| Floor, NVIDIA GL / Mesa llvmpipe (generic platform theme) | 360 / 410 ms | 152 / 126–182 MB |
| Preview, light, no overlay, NVIDIA (KDE platform theme) | 880–1040 ms | 260 MB |
| Preview, same, Mesa llvmpipe | 950–1040 ms | 297 MB |
| `main.qml` (all surfaces, idle), NVIDIA threaded / basic loop | — | 266 / 241 MB |
| `main.qml`, Mesa llvmpipe, KDE / generic platform theme | — | 187 / 176 MB |

Readings:

- Lugh's own cost is roughly +50 MB (main.qml over the floor, Mesa) and
  +500–600 ms of QML creation + first render in the preview. The rest is the
  platform: the NVIDIA driver (~+100 MB), KDE's platform theme plugin
  (+10–30 MB, +130 ms), llvmpipe. Budgets must be measured on the target
  (trixie, Mesa iGPU, Hyprland, the Rust binary), not on this host.
- Surface creation cost (offscreen, first use, compile + create): Bar ~105 ms
  (includes first font / icon-font load), ControlCenter ~80, NotificationCenter
  ~75, Dock ~70, LockScreen ~33, Launcher ~21, the rest < 10. Overlays,
  toasts and the OSD are therefore created **asynchronously after the first
  frame** (main.qml and preview), so start-up only pays for Wallpaper, Bar and
  Dock.
- The first frame itself renders in ~200 ms (polish 39, sync 57, render 41,
  swap 59 ms): shader/pipeline set-up and glyph caches. A pipeline cache
  (`QQuickGraphicsConfiguration::setPipelineCacheSaveFile/LoadFile`, C++) and
  ahead-of-time compiled QML (qmlcachegen in the cxx-qt build) are the next
  start-up levers for the Rust binary.

Re-measure with:

```
/usr/bin/time -f '%M KB max RSS' scripts/shell-preview.sh --measure
scripts/shell-run.sh --nested 5      # main.qml, prints max RSS
```
