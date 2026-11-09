# lugh-compositor — Spec

> Status: **Draft** · Owner phase: **5** (prototype R&D may start after Phase 1) · Related ADRs: ADR-004, ADR-005, ADR-012, ADR-015, ADR-017, ADR-020

## Purpose

The Wayland compositor that replaces Hyprland in Phase 5. It owns the screen, input, window layout, animations and the security boundary between apps. It must make Lugh feel **faster and smoother than Hyprland** while supporting floating (Lugh, Classic) and tiling (Focus) modes, and enforcing Shield's window isolation.

## User stories

- **Windows switcher:** "Windows snap, maximize and minimize like I expect, every app's titlebar looks the same, and games run fullscreen without stutter."
- **macOS-minded user:** "Opening, closing and minimizing feel physical, and trackpad gestures follow my fingers 1:1."
- **Linux power user:** "Tiling with gaps, a keyboard for everything, per-monitor refresh rates, VRR, and a debug overlay that shows real frame timings."
- **Security-minded user:** "A quarantined app can't read my clipboard, take screenshots or grab global shortcuts, and its window is clearly marked."

## Requirements

### Functional
- **FR-1** Backends: DRM/KMS on hardware (with libseat/logind), nested (winit) for development, headless for CI.
- **FR-2** Floating and tiling layout policies, selectable per workspace, with mode presets (Lugh, Classic, Focus).
- **FR-3** Server-side decorations (titlebar, buttons left or right per mode) through `xdg-decoration`, plus CSD clients supported.
- **FR-4** Implements the protocol set in §Protocols, including `lugh-shell-v1`.
- **FR-5** Restricted protocols are available only to privileged clients (shell, portal, settings, greeter). Sandboxed clients (`wp-security-context-v1`) get the reduced set and isolation in §Security.
- **FR-6** Direct scanout for fullscreen surfaces and overlay/cursor planes where the hardware allows.
- **FR-7** VRR per output (off / fullscreen-only default / always), `tearing-control` for games that opt in.
- **FR-8** Multi-monitor with hotplug, per-output scale (fractional), refresh rate, rotation and mirroring.
- **FR-9** Input: libinput (pointer, touchpad, touch, tablet), xkbcommon layouts, 1:1 gestures, keybinding engine fed by `desktop.toml`.
- **FR-10** Xwayland for X11 apps and games, with HiDPI handling options.
- **FR-11** IPC socket + `lugh wm` CLI for inspection and scripting.
- **FR-12** Greeter mode (`--greeter`): single fullscreen client, no shell.

### Non-functional
| ID | Target |
|---|---|
| NFR-1 | p99 frame time ≤ refresh interval during all animations at 60/120/144 Hz on Intel Xe / AMD RDNA2 iGPUs |
| NFR-2 | Input-to-present latency: no worse than Hyprland or KWin on the same machine (measured, §Performance) |
| NFR-3 | Idle CPU ≈ 0% (no repaint without damage). Idle RSS ≤ 80 MB with 10 windows |
| NFR-4 | Direct scanout hit rate 100% for fullscreen games with compatible buffers (verified by the debug overlay) |
| NFR-5 | Crash-free: fuzzed config and protocol parsing, no `unwrap()` on client input, panic = abort with coredump |
| NFR-6 | Accessibility: reduce-motion honored, AT-SPI keyboard grabs allowed for Orca, zoom (screen magnifier) in Phase 5.x |

## Design

### Architecture (Smithay)
```
crates/lugh-compositor/
├── main.rs            # arg parsing, logging (tracing → journald), calloop EventLoop
├── state.rs           # LughState: Smithay handler impls (compositor, xdg_shell, seat, output, dmabuf…)
├── backend/
│   ├── udev.rs        # DRM/KMS + GBM + EGL, libseat session, multi-GPU (GpuManager)
│   ├── winit.rs       # nested dev window
│   └── headless.rs    # offscreen GBM (or pixman) for CI
├── render/            # GlesRenderer pipeline, elements (windows, decorations, layer surfaces, effects)
├── frame/             # frame scheduler, presentation feedback, VRR
├── wm/
│   ├── space.rs       # workspaces, outputs, focus stack
│   ├── floating.rs    # placement, snapping, snap layouts (Classic)
│   ├── tiling.rs      # dwindle, master-stack
│   ├── decorations.rs # SSD titlebars (cosmic-text for text, resvg for icons; cached textures)
│   └── policy.rs      # Mode → policy bundle
├── anim/              # springs, curves, snapshot-based close/resize, gesture-driven timelines
├── input/             # libinput, xkb, bindings engine, gestures, pointer constraints
├── protocols/         # lugh-shell-v1 + restricted-global gating
├── security.rs        # client classes: privileged / normal / sandboxed
├── xwayland.rs        # Smithay X11Wm integration
├── ipc.rs             # $XDG_RUNTIME_DIR/lugh/compositor.sock (JSON lines)
└── config.rs          # desktop.toml [compositor], [input], [outputs], [bindings]; live reload
```

### Rendering & frame scheduling
- **Renderer:** Smithay `GlesRenderer` (OpenGL ES 3). Pixman fallback for VMs without GPU acceleration. Vulkan renderer is a later research item, not committed.
- **Damage tracking** per output (`OutputDamageTracker`). Nothing renders without damage or an active animation.
- **Late-latching scheduler:** after each vblank, predict this frame's render time (EWMA of the last N GPU timings + a safety margin), then start compositing at `next_vblank − predicted − margin`. Frame callbacks are sent to clients early enough for them to submit. This approach (used by Mutter and KWin) minimizes latency without missing frames.
- **Presentation-time** feedback is sent to clients, and the same timestamps feed the animation clock (animations are evaluated at the *predicted presentation time*, not render time, so motion is smooth).
- **Direct scanout & planes:** Smithay `DrmCompositor` assigns the primary/overlay/cursor planes. Fullscreen surfaces with scanout-capable dmabufs bypass composition. With `linux-dmabuf` v4 feedback, clients are told which formats and modifiers allow scanout.
- **Explicit sync:** `linux-drm-syncobj-v1`, required for NVIDIA proprietary (driver ≥ 560 assumed) and beneficial everywhere.
- **VRR:** the DRM `VRR_ENABLED` property is toggled per output policy. In fullscreen-only mode it's enabled when a fullscreen surface is focused and scanned out.
- **HDR / color management:** `wp-color-management-v1` is a stretch goal after Phase 5 (it depends on Mesa/kernel maturity). It isn't promised for 1.0.
- **Multi-GPU:** render on the GPU driving each output, with cross-GPU copies for hybrid laptops. Apps are offered the integrated GPU by default; the dGPU is chosen via `DRI_PRIME` or a per-app setting (exposed in Settings and Bridge).

### Input
- libinput via Smithay. Settings come from `[input]` (see [settings](settings.md) schema).
- **Gestures** (`pointer-gestures-v1` to clients when not consumed): 3-finger horizontal = workspace switch, 4-finger up = overview (Lugh), pinch = overview (configurable). Gesture timelines drive animations 1:1. On release, a spring settles with the finger's velocity.
- **Bindings engine:** compiled from `[bindings.<mode>]` + `[bindings.user]`. Actions: `wm.*` handled internally, `shell.*` forwarded to the shell over `lugh_shell_manager_v1.action` (no D-Bus round-trip on the hot path), `session.*`, `exec` (spawned in a systemd scope, ADR-015).
- `keyboard-shortcuts-inhibit` is honored for games, VMs and remote desktops (with an escape chord Super+Esc that can't be inhibited).
- Pointer constraints + relative pointer for games. `text-input-v3` / `input-method-v2` for IME (fcitx5).

### Layout policies per mode
| Policy bundle | Lugh | Classic | Focus |
|---|---|---|---|
| Default layout | floating | floating | tiling (dwindle) |
| Tiling available | per workspace (Super+T) | snap only | always (float toggle per window) |
| Placement | centered cascade, remembers per-app size | Windows-like cascade, remembers maximized state | n/a |
| Snapping | edges + quarters | edges + **snap layouts** (zones shown on maximize-hover, via `lugh_shell_manager_v1` overlay) | n/a |
| Decorations | SSD, buttons left, 14 px radius | SSD, buttons right, 8 px radius | none (border only), 2 px accent border on focus |
| Gaps | n/a (floating) / 8 px when tiled | n/a | inner 6 / outer 10 (configurable) |
| Focus | click-to-focus | click-to-focus | click-to-focus (focus-follows-mouse optional) |
| Animations profile | full (genie-like minimize, spring open/close) | standard (scale/fade, slide minimize to taskbar) | snappy (short slides, no scale) |

Switching mode re-applies the bundle. Floating geometry is stored per window, so Focus → Lugh restores each window's previous floating position and size.

### Animation engine
- Primitives: spring (stiffness, damping, mass, initial velocity) and cubic-bezier, with durations from [DESIGN-SYSTEM](../DESIGN-SYSTEM.md) §5.
- **Snapshot-based** close and resize: the last client buffer is kept as a texture so close animations play after the client is gone, and resize cross-fades old and new buffers while the client catches up (no stretched or janky frames).
- All animations are interruptible (retargeted mid-flight with velocity preserved).
- `reduce_motion` replaces transforms with 100 ms opacity fades.

### Protocols
| Protocol | Access |
|---|---|
| `wl_compositor`, `wl_subcompositor`, `wl_shm`, `wl_seat`, `wl_output`, `wl_data_device_manager` | all |
| `xdg-shell`, `xdg-decoration`, `xdg-activation-v1`, `xdg-foreign-v2`, `xdg-output`, `xdg-toplevel-icon-v1`, `xdg-dialog-v1` | all (activation is limited for sandboxed clients) |
| `linux-dmabuf-v1` (v4), `linux-drm-syncobj-v1`, `presentation-time`, `viewporter`, `fractional-scale-v1`, `single-pixel-buffer-v1`, `alpha-modifier-v1`, `content-type-v1`, `tearing-control-v1` | all |
| `cursor-shape-v1`, `pointer-constraints-v1`, `relative-pointer-v1`, `pointer-gestures-v1`, `tablet-v2`, `text-input-v3`, `primary-selection-v1` | all (primary selection is off for sandboxed clients) |
| `idle-inhibit-v1`, `keyboard-shortcuts-inhibit-v1` | normal + privileged |
| `ext-idle-notify-v1`, `ext-session-lock-v1`, `wlr-layer-shell-v1` | privileged (layer-shell is also allowed to normal clients on the `bottom`/`background` layers only: wallpapers, widgets) |
| `ext-foreign-toplevel-list-v1`, `wlr-foreign-toplevel-management-v1`, `ext-workspace-v1` | privileged |
| `ext-image-copy-capture-v1`, `ext-image-capture-source-v1`, `wlr-screencopy-v1` (compat) | privileged (portal, shell) |
| `ext-data-control-v1` / `wlr-data-control-v1` | privileged (clipboard managers must be approved in Settings) |
| `wlr-output-management-v1`, `wlr-gamma-control-v1` | privileged (settings, shell night light) |
| `input-method-v2`, `virtual-keyboard-v1` | privileged (IME and on-screen keyboard registered in Settings) |
| `wp-security-context-v1` | privileged (Shield daemon, Flatpak) |
| `lugh-shell-v1` | privileged (shell only) |

**Client classes.** The compositor creates the public socket (`WAYLAND_DISPLAY=wayland-1`) for normal apps. The shell, portal backend, settings daemon and greeter are **spawned by the compositor** with a pre-connected socket (`WAYLAND_SOCKET`) marked privileged. The list of privileged executables is fixed in config (`/usr/share/lugh/compositor/privileged.toml`) and is not user-writable without admin rights. Sandboxed clients arrive through security-context sockets.

### `lugh-shell-v1` (draft, `protocols/lugh-shell-v1.xml`)
```
lugh_shell_manager_v1 (global, privileged, version 1)
  requests:
    set_mode(mode: enum{lugh, classic, focus})
    action(name: string, arg: string)                   # wm.* actions triggered from shell UI
    get_window(toplevel: ext_foreign_toplevel_handle_v1, id: new_id lugh_window_v1)
    show_snap_zones(output, layout_set: string)         # Classic snap layouts overlay
    set_reduce_motion(enabled: uint)
    destroy()
  events:
    mode_changed(mode)
    shell_action(name: string, arg: string)              # compositor → shell (bindings for shell.*)
    gesture(kind: enum{workspace, overview}, phase: enum{begin, update, end, cancel}, progress: fixed, velocity: fixed)
    overview_state(open: uint)

lugh_window_v1 (version 1)
  requests:
    set_minimize_rect(surface: wl_surface, x, y, w, h)  # dock/taskbar icon target for minimize animation
    request_attention()
    destroy()
  events:
    marks(quarantined: uint, shield_profile: string, bridge_bottle: string, verified_app_id: string)
    workspace(workspace_handle)
    closed()
```
Versioning follows Wayland rules (additive within a version, a new interface for breaking changes).

### Security: Shield enforcement (ADR-017)
Clients connected through a `wp-security-context-v1` socket with `sandbox_engine = "space.lugh.shield"` (or `org.flatpak`) get:
| Capability | Sandboxed rule |
|---|---|
| Restricted globals (table above) | not advertised |
| Clipboard read | only on an explicit user paste (Ctrl+V / middle-click is disabled) into the focused quarantined window. Per-session toggle "Allow clipboard" in the Shield UI |
| Clipboard write | allowed. Content copied out is tagged, and the shell shows a toast "Copied from a quarantined app" |
| Focus stealing | `xdg-activation` tokens from sandboxed clients are ignored unless user-initiated in that window |
| Global shortcuts / shortcut inhibit | denied |
| Screen capture of the sandboxed window by others | allowed (the user may screenshot it). The sandboxed client itself can't capture |
| Marking | border: 3 px 45° diagonal stripes in `danger` color + shield badge in the titlebar/corner. Title prefix in the taskbar via `lugh_window_v1.marks`. Never color alone |

Flatpak apps get the same treatment, minus the visual quarantine marking (they get a small "sandboxed" badge only if the user enables it).

### Portals (`xdg-desktop-portal-lugh`)
Rust daemon (`crates/xdg-desktop-portal-lugh`) implementing:
- `Screenshot`, `ScreenCast` (PipeWire streams from `ext-image-copy-capture`; window, output or region choice in a QML picker), `RemoteDesktop` (later)
- `GlobalShortcuts` (registered into the bindings engine after user approval, listed in Settings → Keyboard)
- `Settings` (`org.freedesktop.appearance` `color-scheme`, `accent-color`, `contrast`), `Access`, `Inhibit`, `Background`
- `FileChooser`: delegated to `xdg-desktop-portal-gtk` at first. A QML file chooser is an open question.

`/usr/share/xdg-desktop-portal/lugh-portals.conf` routes interfaces to `lugh`, then `gtk`.

### Xwayland
- Smithay `X11Wm` with on-demand Xwayland start (first X11 client) to save memory.
- HiDPI: default "scaled" (X11 apps rendered at 1× and upscaled, crisp for games at native res when fullscreen). Per-app "native resolution" override in Settings (`[xwayland] force_zero_scaling = ["steam"]`).
- Fullscreen Xwayland games are eligible for direct scanout. Wine/Proton mostly use X11 today, so this path is performance-critical for [Bridge](bridge.md).

### Configuration
Same file as the shell, `~/.config/lugh/desktop.toml`, written by settingsd. Compositor sections:
```toml
[compositor]
vrr = "fullscreen"          # off | fullscreen | always
allow_tearing = true        # only for clients requesting it via tearing-control
debug_overlay = false

[outputs."DP-1"]
mode = "2560x1440@165"
scale = 1.25
position = [0, 0]

[outputs."eDP-1"]
scale = 1.5
vrr = "off"

[xwayland]
enabled = true
force_zero_scaling = []
```
Reloaded live on file change (debounced 200 ms). Invalid config keeps the last good config and posts a notification with the line/key at fault.

### IPC & CLI
- Socket `$XDG_RUNTIME_DIR/lugh/compositor.sock`, JSON lines, same-UID only (checked via `SO_PEERCRED`).
- `lugh wm windows` · `lugh wm workspaces` · `lugh wm focus <id>` · `lugh wm workspace 2` · `lugh wm mode focus` (calls settingsd) · `lugh wm outputs` · `lugh wm reload` · `lugh wm stats` (frame timings, scanout state per output) · `lugh wm debug damage on`.
- Events stream (`lugh wm events`) for scripting (window opened/closed, workspace changed).

### Robustness
- A compositor crash ends the Wayland session. Mitigations: panic=abort + `systemd-coredump`, fuzzing, protocol tests, and a **safe session** entry at the greeter (software rendering, default config) after two crashes in 10 minutes.
- Qt apps can survive a compositor restart with `QT_WAYLAND_RECONNECT=1` (Qt ≥ 6.6). The shell and Lugh apps set it. Full session survival is a research item, not promised.

## UX
The compositor's direct UX: window behaviour (§Layout policies), animations, the snap-zones overlay, the quarantine marking, and a **debug overlay** (Super+Shift+F12, or `debug_overlay = true`) showing a per-output frame-time graph, render/scanout state, VRR state and damage rectangles. Error UX: config errors as notifications. A GPU reset or lost output shows a toast "Display reset" and the compositor recovers without logout where the driver allows.

Default bindings per mode are listed in [shell](shell.md) §Default keyboard shortcuts. The compositor implements all `wm.*` actions there.

## Security & privacy
- Privileged-client model (§Protocols): unlike many wlroots compositors, screencopy, toplevel management, data-control and virtual input are **not** exposed to every client.
- Sandboxed clients isolated per §Security.
- IPC socket same-UID only. No network listeners.
- No logging of window titles at default log level (they can contain private data). Debug level is opt-in.

## Testing
- **Unit:** layout algorithms (property tests: tiling never overlaps, gaps respected), spring math, config parsing (fuzzed with `cargo fuzz`).
- **Protocol conformance:** run **WLCS** (Wayland Conformance Test Suite) where applicable, plus our own client tests for restricted-global gating (a normal client must not see screencopy, and a sandboxed client must not read the clipboard).
- **Headless perf scenes** in CI ([build-and-release](build-and-release.md) §Performance harness): 10 windows open/close, workspace switch ×50, mode switch ×20, launcher open. p99 frame time must be ≤ 6.9 ms (144 Hz budget) on the reference runner, and regressions > 10% fail.
- **Latency:** internal metric = evdev timestamp → presentation timestamp of the first frame containing the response. Compared against Hyprland and KWin on the Phase 7 hardware lab with the same test app. External validation with a photodiode/high-speed camera rig in Phase 7.
- **Hardware matrix:** Intel (Gen 9+ / Xe), AMD (GCN5 / RDNA2 / RDNA3), NVIDIA (proprietary ≥ 560 with explicit sync, and NVK), hybrid laptops, mixed-DPI multi-monitor, 60/144/240 Hz + VRR panels.
- **Games:** Proton titles via Bridge/Steam (DX11 via DXVK, DX12 via VKD3D). Check scanout hit, VRR active, and no added latency versus a bare KMS game session.

## Open questions
- Vulkan renderer: research spike in Phase 5 or after 1.0?
- Minimum NVIDIA driver version (≥ 560 proposed, for explicit sync).
- Our own QML file chooser portal vs `xdg-desktop-portal-gtk` long-term.
- Screen magnifier/zoom: Phase 5 or 5.x?
- Should normal clients get layer-shell `top`/`overlay` access (needed by some third-party docks/bars), or only privileged ones?
