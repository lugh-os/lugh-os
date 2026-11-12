# Shell performance: start-up, memory, idle

Budget (spec NFR-1): first frame ≤ 400 ms, RSS ≤ 150 MB (target 120), zero
CPU when idle. This page records how the shell composed by
`ui/shell/qml/main.qml` is measured, what it measures today and where the
rest goes.

**Status (2026-11-11, dev host, bottom Panel): idle is met, RSS and first
frame are not.**
Both misses are dominated by the platform floor of this host (an empty Qt
Quick window already costs 104–118 MB and ~400 ms here), so they have to be
re-measured on the target (trixie, Qt 6.8, the Rust host) before more work is
spent on them.

## Method

```
scripts/shell-run.sh --nested 10 -- --no-media   # the reference run
scripts/shell-run.sh --nested 5                  # mock media playing
scripts/shell-run.sh --nested 3 -- --lazy-overlays
LUGH_NESTED_GPU=default scripts/shell-run.sh --nested 3   # host's default GPU
LUGH_SHELL_BIN=target/release/lugh-shell scripts/shell-run.sh --nested 10
```

`--nested` starts a headless `kwin_wayland --virtual` (nothing appears on the
live desktop), runs `main.qml` in it with the production environment, lets it
settle 3 s, watches it idle for the given seconds and prints:

- **first frame**: ms from `exec` to the panel window's first `frameSwapped`
  (the moment `Services.shell.ready()` is called);
- **RSS** at idle and peak, split into anonymous / file-backed / shmem, and
  the thread count (`/proc/<pid>/status`);
- **idle frames**: `main.qml --idle-report <s>` counts `frameSwapped` per
  layer window for `s` seconds once settled
  (`lugh-shell: idle-frames total=… lugh-dock@…=…`; the bottom Panel's
  window keeps the namespace `lugh-dock`);
- **idle CPU**: user+system time of the process over the same window;
- QML warnings (any warning fails the run; `make qml-check` includes it).

GPU: the nested KWin and its clients run on **Mesa** through
`__EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json`
(default, `LUGH_NESTED_GPU=mesa`). On the dev laptop that is
`Mesa Intel(R) UHD Graphics 630 (CFL GT2)`; without it glvnd picks the NVIDIA
driver, which adds 25–100 MB to every GL process.

Floor: an empty transparent `Window` with a 2 s timer, run the same way
(`scripts/shell-run.sh --nested-exec -- <script>`), is what Qt + Mesa cost
before any Lugh QML.

The dev host runs Qt 6.11 / KDE neon and was under load (load average 6–10,
other builds running) for every number below, so first-frame times are a
range, not a figure. RSS is stable to ±2 MB.

## Numbers

Intel UHD 630 (Mesa), 1440×900, one output, `MALLOC_ARENA_MAX=2`, threaded
render loop, OpenGL RHI, warm QML disk cache.

### 2026-11-11: the bottom Panel (no top bar, no separate dock)

Load average 10–20 during these runs (eight agents building and rendering),
so first-frame times are noise; RSS ±2 MB; frames and CPU are exact.

| What | First frame | RSS at idle (anon + file) | Idle frames / CPU |
|---|---|---|---|
| **`main.qml`, nothing playing** (`--no-media`), round start | ~1030 ms | 198 MB (75 + 122)¹ | **0 frames, 0 ms CPU in 10 s** |
| **`main.qml`, nothing playing**, after this round | 1030–3130 ms | **213 MB (92 + 121)** | **0 frames, 0–10 ms CPU in 10 s**² |
| `main.qml`, mock media playing | ~1080 ms | 214 MB | 15 frames in 5 s, all in `lugh-dock` (MediaBars steps every 320 ms); 30 ms CPU |
| `main.qml --lazy-overlays` | ~990 ms | 171 MB (53 + 118) | 0 |
| `main.qml`, two outputs (`LUGH_NESTED_OUTPUTS=2`) | 690–1160 ms | 243 MB (121 + 122), 26 threads | 0 |

¹ At the start of the round Customize failed to compile and was never
created; it loads now. The +15 MB over that run are the overlays (all created
eagerly after the first frame): `--lazy-overlays` is 171 MB, i.e. the six
overlays cost ~40 MB together, up from 12 MB in the round-2 frame. The panel
itself adds nothing at idle.
² 1 frame when the clock's minute turns inside the window (the tray
repaints once a minute).

Idle did not regress: the panel and its tray draw nothing while nothing
changes (the MediaBars equalizer, the only looping thing in the tray, ticks
at ~3 fps while music plays and stops otherwise — it was ~57 fps in the top
bar). Two outputs: before this round every per-screen window of the second
output was mapped on the first one (see "What the frame does about it").

### 2026-11-10: the round-2 frame (top bar + dock)

| What | First frame | RSS at idle (anon + file) | Idle frames / CPU |
|---|---|---|---|
| Floor: empty Qt Quick window, generic platform theme | 390–470 ms | 104 MB (20 + 84) | — |
| Floor, KDE platform theme (the host's default) | ~400 ms | 118 MB (24 + 94) | — |
| **`main.qml`, nothing playing** (`--no-media`) | 710–1300 ms (typically ~980) | **185–186 MB** (67 + 118) | **0 frames, 0–10 ms CPU in 10 s** |
| `main.qml`, mock media playing | same | 186 MB | 288 frames in 5 s, all in `lugh-bar` (~57 fps); 330–430 ms CPU |
| `main.qml --lazy-overlays` | same | 173–174 MB (57 + 117) | 0 |
| `main.qml`, generic platform theme | 750–1300 ms | 171–172 MB (62 + 110) | 0 |
| `main.qml`, `QSG_RENDER_LOOP=basic` | ~1080 ms | 182 MB, 20 threads (23 threaded) | — |
| `main.qml`, `QSG_RHI_BACKEND=vulkan` | ~1530 ms | 215 MB | — |
| `main.qml`, `QT_QUICK_BACKEND=software` | ~1010 ms | 128 MB (38 + 72 + 17 shmem), 13 threads | — |
| `main.qml`, NVIDIA (`LUGH_NESTED_GPU=default`) | ~1220 ms | 270 MB | — |

Before (round 2 frame, `ui/shell/README.md` of that round; max RSS, llvmpipe
or NVIDIA, never on the Intel GPU): `main.qml` 187 MB on llvmpipe / 266 MB on
NVIDIA, bar animating whenever idle was not checked, no first-frame figure for
`main.qml`. The v2 frame carries more surface code (islands, morph panels,
drawers) at the same RSS, and idle is now measured and clean.

One surface alone in a window (`preview/Check.qml --type <T>`, same GPU, KDE
theme; floor 118 MB):

| Surface | RSS | Surface | RSS |
|---|---|---|---|
| LockScreen | 159 MB | NotificationPopups | 139 MB |
| Dock | 154 MB | LughMenu | 132 MB |
| Bar | 150 MB | NotificationCenter | 130 MB |
| Wallpaper | 149 MB | Launcher | 145 MB |

(ControlCenter could not be measured that way while it was being rewritten.)

QML disk cache (`QML_DISK_CACHE_PATH=~/.cache/lugh-shell/qmlcache`, 79 files):
it is written and used, but the gain is inside the noise of this host —
`QML_DISABLE_DISK_CACHE=1` gave 717–1014 ms, warm cache 921–1338 ms over three
runs each. Compile time is not what the first frame waits for.

Allocator knobs (`MALLOC_ARENA_MAX=1|8`, `MALLOC_MMAP_THRESHOLD_`,
`MALLOC_TRIM_THRESHOLD_`, `MALLOC_TOP_PAD_`) moved RSS by ≤ 3 MB: not worth
carrying beyond `MALLOC_ARENA_MAX=2`.

## What the frame does about it

- **Start-up order.** Wallpaper and Panel are the only surfaces created
  synchronously. `Services.shell.ready()` fires on the panel's first
  `frameSwapped`. Everything else (toasts, launcher, control center,
  notification center, menu, lock) is created afterwards, one surface per
  idle turn, or at once when it is asked for before its turn.
  `--lazy-overlays` creates an overlay only on its first open (−12 MB until
  then, first open pays the creation).
- **Locked at start** (restart while locked): the lock windows are created and
  mapped first; the desktop behind them only after the lock's first frame.
- **Unmapped means free of rendering.** Overlay windows are mapped only while
  the surface's `shown` is true. The idle report shows them as `(unmapped)`
  with 0 frames.
- **One wallpaper texture.** Production creates one `Wallpaper` per screen,
  decoded at screen size, never the blurred copy (the compositor blurs). Only
  the preview loads the small pre-blurred file for `Theme.backdrop`.
- **Input regions at most once per frame** (`LughNative.setInputRegion`),
  so island width animations do not flood the compositor.
- **Per-screen windows sit at their output's origin** (`x`/`y` =
  the screen's `virtualX`/`virtualY`). Qt re-assigns a shown window to the
  screen its geometry lies on, so at (0, 0) the second output's wallpaper and
  panel went to the first output (seen in the idle report as two
  `lugh-dock@Virtual-0`).
- **Low power.** While `Services.shell.lowPower` is true the frame forces
  `Theme.transparency = false` and `Theme.reduceMotion = true` and restores
  the user's own values when it clears (changes the user makes meanwhile are
  kept).
- **Environment** (set by `scripts/shell-run.sh`; copy into the session unit):
  `QSG_RHI_BACKEND=opengl`, `QSG_RENDER_LOOP=threaded`, `MALLOC_ARENA_MAX=2`,
  `QT_WAYLAND_DISABLE_WINDOWDECORATION=1`, `QML_DISK_CACHE_PATH`.

Documented options, not defaults:

- `QT_QUICK_BACKEND=software`: 128 MB, no GPU driver in the process. This is
  the low-power / no-GPU fallback; glass and shadows still draw, animation
  cost moves to the CPU.
- `QSG_RENDER_LOOP=basic`: three threads fewer, same RSS here, animations
  share the GUI thread. Not worth it.
- `QSG_RHI_BACKEND=vulkan`: +30 MB and a slower start on this driver. No.
- `QT_QPA_PLATFORMTHEME=generic` (or anything but `kde`): −10 to −14 MB. The
  Lugh session should not load KDE's platform theme plugin at all.

## Where the rest goes (hot spots)

1. **File-backed memory: 118 of 186 MB.** Qt 6, Mesa's iris driver and LLVM
   mapped into the process; the floor already has 84–94 MB of it. It is shared
   with every other Qt/Mesa process on the desktop, so RSS overstates the
   shell's real cost. The budget should be checked as PSS or as anonymous
   memory (67 MB today, floor 20–24). Not measured yet: PSS
   (`/proc/<pid>/smaps_rollup`).
2. **Anonymous memory: +43 MB over the floor.** Three mapped windows each
   with a GL context and render thread (threaded loop), the screen-sized
   wallpaper texture (~5 MB at 1440×900, ~33 MB at 4K), glyph caches, the QML
   engine with all surfaces instantiated. Eagerly created overlays are 10–12
   MB of it (`--lazy-overlays`).
3. **First frame: ~300–600 ms over the floor on a loaded host.** Creating
   Wallpaper + Bar + Dock and their first render (shader/pipeline set-up,
   glyph caches). The disk cache does not help measurably. Next levers, all
   on the Rust/C++ side: ahead-of-time compiled QML (qmlcachegen / QML type
   compiler in the cxx-qt build), a pipeline cache
   (`QQuickGraphicsConfiguration::setPipelineCacheSaveFile`), and
   `QQuickWindow::setPersistentGraphics(false)` /
   `setPersistentSceneGraph(false)` on overlay windows so their GPU memory is
   released while unmapped.
4. **Overlays created eagerly: ~40 MB** (171 MB with `--lazy-overlays`,
   213 MB without). Customize is the newest and largest; see Open.
5. ~~The bar renders at ~57 fps while music plays~~: fixed, MediaBars in the
   panel's tray steps every 320 ms (15 frames / 5 s, 30 ms CPU).

## Open

- Re-measure on the target: trixie container or the ISO in QEMU with
  `LUGH_SHELL_BIN` (Qt 6.8.2, no KDE platform theme, the Rust host instead of
  `qml6`). The dev host's floor makes the 400 ms / 150 MB verdict unreliable.
- Decide whether RSS or PSS/anonymous is the budget figure (see 1).
- Decide whether `--lazy-overlays` becomes the default on low-memory machines
  (`Services.shell.lowPower`), or at least for Customize (opened rarely,
  ~40 MB for all six overlays now).
