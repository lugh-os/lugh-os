# Phase 5 — Own compositor (`lugh-compositor`)

> Status: Draft · Size: XL · Depends on: Phase 1 (shell), Phase 4 (Shield) · Specs: [../specs/compositor.md](../specs/compositor.md), [../specs/shell.md](../specs/shell.md), [../specs/shield.md](../specs/shield.md) · ADRs: ADR-004, ADR-005, ADR-012, ADR-017, ADR-020

## Goal

Replace Hyprland with `lugh-compositor`, our Rust/Smithay Wayland compositor. It must run all three desktop modes (Lugh, Classic, Focus) and switch between them live in under 300 ms. It must enforce Shield window isolation and draw quarantine borders, ship the `xdg-desktop-portal-lugh` backend, and meet the VISION §12 performance targets as **release gates**.

R&D (a skeleton that renders and takes input) may start in parallel right after Phase 1 (see [../ROADMAP.md](../ROADMAP.md)). This phase makes it the default.

## Scope

**In**
- DRM/KMS backend (atomic modesetting), libinput, a session through libseat (logind).
- GBM + EGL + GLES 3 renderer. Damage tracking, frame scheduling against vblank, direct scanout for fullscreen surfaces, and VRR (adaptive sync).
- Fractional scaling (`wp-fractional-scale-v1` + `wp-viewporter`), multi-monitor with hotplug, per-output scale and refresh, and mirroring.
- Xwayland, through `xwayland-satellite` (preferred: out-of-process and simpler) or Smithay's built-in Xwayland support. Decided by spike (WS1).
- Layouts: floating (with snap zones and snap layouts), dwindle tiling and master-stack tiling. Per-workspace layout.
- Three modes as **layout policy + shell layout**, switched live.
- Protocols from [../ARCHITECTURE.md](../ARCHITECTURE.md) §5, plus our `lugh-shell-v1`.
- Shield enforcement through `wp-security-context-v1`, and striped quarantine borders.
- `xdg-desktop-portal-lugh`: Screenshot, ScreenCast (PipeWire), GlobalShortcuts and RemoteDesktop (basic).
- An animation engine (spring physics, interruptible) and a config file.
- Nested (winit) and headless backends for development and CI perf tests.
- Migration off Hyprland, with Hyprland kept as a fallback session for **one release**.

**Out (deferred)**
- A Vulkan renderer (later; the GLES path must be solid first).
- HDR and color management (`wp-color-management-v1`), tracked for after 1.0.
- Touch-first tablet mode and gestures beyond 3- and 4-finger swipes.
- Full remote desktop (RDP server). Only the portal basics are in scope.

## Deliverables

| Deliverable | Path in repo | Package |
|---|---|---|
| Compositor binary | `crates/lugh-compositor/` | `lugh-compositor` |
| Private protocol `lugh-shell-v1` | `protocols/lugh-shell-v1.xml` | `lugh-protocols` (dev) |
| Portal backend | `crates/xdg-desktop-portal-lugh/` | `xdg-desktop-portal-lugh` |
| Portal config (`lugh-portals.conf`) | `packaging/compositor/portals/` | `xdg-desktop-portal-lugh` |
| Session files (greetd session, systemd user units) | `packaging/compositor/session/` | `lugh-session` |
| Default config | `packaging/compositor/config/compositor.toml` | `lugh-compositor` |
| Shell adapter switch (Hyprland IPC → lugh-shell-v1) | `ui/shell/backend/` | `lugh-shell` |
| Perf harness (headless replay + frame-time histograms) | `tests/perf/compositor/` | n/a (CI) |
| Fallback Hyprland session | `packaging/session-hyprland/` | `lugh-session-hyprland` (deprecated) |

## Architecture outline (detail in the spec)

```
 libseat ─┐            ┌─ input (libinput) ─▶ keybinds / gestures / focus
 udev ────┼─▶ backend ─┤
 DRM/KMS ─┘            └─ outputs ─▶ frame scheduler (vblank, VRR) ─▶ renderer (GLES)
                                              ▲                        │
 Wayland clients ─▶ protocol handlers ─▶ scene/space ─▶ layout policy ─┘
                    (xdg-shell, layer-shell,   │    (floating | dwindle | master | snap)
                     security-context, …)      └─▶ animation engine (springs)
 lugh-shell ◀── lugh-shell-v1 (modes, marks, hints) ──▶ mode controller
```

## Work breakdown

### 1. Foundations and spikes
- [ ] Crate skeleton on Smithay: winit (nested) backend first, so it can be developed inside Hyprland.
- [ ] Spike A: `xwayland-satellite` versus Smithay Xwayland. Criteria: Steam, Wine games, JetBrains IDE, Electron apps, clipboard and DnD. Record the outcome as an ADR.
- [ ] Spike B: GLES renderer frame timing on Intel iGPU, AMD and NVIDIA (proprietary, GBM). Record the outcome.
- [ ] Logging and tracing (`tracing` crate, Tracy integration behind a feature flag).

### 2. Backend and output
- [ ] udev + libseat session, DRM atomic commit, GBM buffers, cursor plane.
- [ ] Hotplug: add or remove outputs, restore saved layouts per monitor set (EDID hash).
- [ ] Per-output mode, scale (fractional), transform, VRR on/off/auto (auto = fullscreen only).
- [ ] `wlr-output-management` so Settings → Displays works.
- [ ] DPMS, `ext-idle-notify`, and `idle-inhibit`.

### 3. Rendering and frame scheduling
- [ ] Damage tracking per output with buffer age.
- [ ] Frame scheduler: render as late as safely possible before vblank (with predicted render time), and send presentation feedback (`wp-presentation-time`).
- [ ] Direct scanout for fullscreen opaque surfaces, plus overlay planes where available.
- [ ] Tearing control (`wp-tearing-control-v1`) for games, opt-in.
- [ ] Effects: rounded corners, shadows and background blur for layer surfaces (shell glass). Blur is cached and only recomputed on damage.

### 4. Input
- [ ] libinput keyboard, pointer, touchpad, tablet basics; per-device settings from settingsd.
- [ ] Keybinding engine, configurable, with mode-specific default maps (Super+Space, Super+Tab, Super+1..9, Super+T and so on, per DESIGN-SYSTEM §8).
- [ ] Gestures: 3-finger swipe for workspaces, 4-finger for overview.
- [ ] `pointer-constraints`, `relative-pointer` (games), `keyboard-shortcuts-inhibit` (VMs, remote desktop).
- [ ] Text input / input method (`text-input-v3`, `input-method-v2`) for IME users.

### 5. Window management and layouts
- [ ] xdg-shell (toplevel, popup, decorations through `xdg-decoration`, server-side by default in Lugh and Classic modes).
- [ ] Workspaces (`ext-workspace-v1`), per output.
- [ ] Floating policy: placement, snap zones (edges/corners), snap layouts popover on maximize-hover (Classic).
- [ ] Dwindle and master-stack tiling; gaps from config; float toggle per window; fullscreen and maximize.
- [ ] Focus rules (click or follow-mouse), window rules (app ID/title → workspace, floating, size).
- [ ] Overview (Super+Tab) and Alt+Tab switcher.

### 6. Modes (Lugh / Classic / Focus)
- [ ] Mode controller: a mode is a bundle of {layout policy defaults, decoration side, keymap, animation profile, shell layout ID}.
- [ ] `lugh-shell-v1` requests `set_mode`, with events `mode_changed`, `window_mark` and `animation_hint`.
- [ ] Live switch: the compositor re-lays out windows with an animated transition (≤ 300 ms), and the shell swaps bar/dock/taskbar in the same frame budget. No logout, no window loss.
- [ ] Mode persisted in `~/.config/lugh/desktop.toml` (owned by settingsd, included by the Lughfile).

### 7. Animation engine
- [ ] Spring solver (stiffness 400, damping 32 by default; DESIGN-SYSTEM §5), retargetable mid-animation.
- [ ] Window open, close, minimize-to-dock (genie-like), maximize, workspace slide, overview and mode switch.
- [ ] Reduce motion: every animation becomes a 100 ms cross-fade, following settingsd.
- [ ] Animations never block input or commits.

### 8. Shield enforcement
- [ ] `wp-security-context-v1`: lugh-shieldd creates a dedicated listening socket per quarantined session, tagged with app ID and sandbox engine `space.lugh.shield`.
- [ ] Clients on a tagged socket are denied screencopy/image-capture, data-control (clipboard managers), global shortcuts, foreign-toplevel listing, virtual keyboard/pointer, input-method and layer-shell.
- [ ] Clipboard: quarantined clients can paste only if the user pastes into them explicitly (focused paste), and they can't read the selection in the background.
- [ ] A 45° striped border (danger color) plus a titlebar shield icon on all quarantined toplevels, so it's never color-only.
- [ ] The `cage` nested option from Phase 4 is retired, and Shield profiles use native isolation.

### 9. Portals (`xdg-desktop-portal-lugh`)
- [ ] Screenshot (with an interactive area picker drawn by the shell).
- [ ] ScreenCast through PipeWire DMA-BUF streams (output, window, region). Works in Firefox WebRTC, OBS and Discord-style apps.
- [ ] GlobalShortcuts portal.
- [ ] Basic RemoteDesktop (input injection with consent).
- [ ] FileChooser stays with `xdg-desktop-portal-gtk` (or a later Qt-based one). Configured through `lugh-portals.conf`.

### 10. Config
- [ ] `~/.config/lugh/compositor.toml`: outputs, input, keybinds, gaps, layouts, window rules, animation overrides. Hot-reload on save with validation errors shown as notifications.
- [ ] Settings writes the same file through settingsd, so there's one source of truth.

### 11. Shell migration
- [ ] The shell backend gets a `LughCompositorBackend` next to `HyprlandBackend`, selected at runtime.
- [ ] Feature parity checklist (workspaces, toplevels, lock, OSDs, notifications, launcher, polkit agent).
- [ ] greetd session list: **Lugh** (default) and **Lugh (Hyprland fallback)** for one release, then removed in the following release.

### 12. Perf harness and gates
- [ ] Headless backend replay: scripted scenarios (open 20 windows, drag-resize, workspace swipes, mode switch, video playback, blur-heavy launcher) produce frame-time histograms (p50, p99, max) and dropped-frame counts.
- [ ] Input-to-photon measurement on real hardware (a photodiode rig or high-speed camera; documented method), compared against Hyprland and KWin.
- [ ] CI fails if any gate regresses by more than 5%.

## Acceptance criteria

1. Lugh boots by default into `lugh-compositor`, and the greetd session list still offers the Hyprland fallback.
2. Switching Lugh → Classic → Focus → Lugh with 10 open windows takes < 300 ms per switch, with no lost windows and no logout.
3. Fullscreen games use direct scanout (verified through debug overlay or DRM state) with VRR active on a VRR-capable monitor.
4. Fractional scaling at 125% and 150% renders crisp text in Qt, GTK4 and Firefox. Xwayland apps are usable (scaled by policy, configurable).
5. Monitor hotplug (dock and undock a laptop) restores the previous per-monitor layout within 2 s.
6. A quarantined app can't take screenshots, read the clipboard in the background, register global shortcuts or list other windows. Its window has a striped border and a shield icon.
7. Screen sharing works in Firefox (WebRTC) and OBS through the portal.
8. Steam (native), a DXVK game through Bridge, a JetBrains IDE (Xwayland or Wayland), VS Code/Electron and LibreOffice all work.
9. Reduce motion replaces all movement with cross-fades.
10. All VISION §12 targets pass on the reference hardware set (see Performance budget).

## Testing

**Automated**
- Headless perf scenarios (WS12) on every commit to `crates/lugh-compositor`.
- Protocol conformance: a client test suite for xdg-shell, layer-shell, session-lock and security-context denial cases.
- Shield denial tests: a test client on a tagged socket tries screencopy, data-control and global shortcuts, and must be refused.
- Nested-mode smoke test in CI (winit inside a headless Weston or a virtual DRM device).
- QEMU boot to the desktop with virtio-gpu.

**Unit**
- Layout algorithms (dwindle, master, snap) with property-based tests (no overlaps, no off-screen windows).
- Spring solver numeric tests; config parsing and validation; keybind resolution per mode.

**Manual checklist (per reference machine)**
- [ ] Intel iGPU laptop, AMD desktop, NVIDIA (proprietary) desktop, hybrid-graphics laptop.
- [ ] 60 Hz and 144 Hz+ panels; VRR monitor; 4K at 150%; dual and triple monitors.
- [ ] Suspend/resume and lid close with an external monitor.
- [ ] IME (for example fcitx5) in Firefox and a Qt app.
- [ ] Keyboard-only and screen reader pass on the shell under the new compositor.

## Performance budget (release gates; from VISION §12)

| Metric | Gate |
|---|---|
| Dropped frames during animation scenarios | 0 at 60, 120 and 144 Hz on a mid-range iGPU (reference: Intel Iris Xe class) |
| Frame time p99 (compositing) | < 50% of the refresh interval (e.g. < 3.5 ms at 144 Hz) |
| Input-to-photon | ≤ Hyprland and ≤ KWin on the same machine and scenario |
| Mode switch | < 300 ms end to end |
| Compositor idle RSS | ≤ 80 MB (single 4K output) |
| Idle whole-session RAM | Minimal ≤ 450 MB, Standard ≤ 750 MB |
| Fullscreen game overhead | Direct scanout active; no extra copy; frame pacing equal to bare KMS within 2% |
| Idle CPU (static desktop) | ≈ 0% (no redraw without damage) |

## Risks & mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Scope: compositors take years (Hyprland, KWin) | Phase overruns | Start R&D after Phase 1; reuse Smithay and patterns from niri/COSMIC (both Smithay); Hyprland fallback for one release; Vulkan and HDR cut from scope |
| NVIDIA proprietary driver quirks (GBM, explicit sync, VRR) | Black screens, flicker | Explicit sync (`linux-drm-syncobj-v1`) from day one; NVIDIA on the reference matrix; documented fallback to the Hyprland session |
| Xwayland edge cases (games, IDEs, DnD) | App breakage | Spike A decides the approach early; regression list of real apps in CI |
| Smithay API churn | Rework | Pin versions, upgrade deliberately each cycle, contribute fixes upstream |
| Blur and shadows hurt iGPU frame time | Missed gates | Cache blur, render it at reduced resolution, auto-disable on low-end GPUs |
| Live mode switch causes visual glitches | Feels broken | One animated transaction across compositor and shell (`lugh-shell-v1` sync point), tested in headless replay |
| Security-context support missing in some toolkits | Isolation gaps | Isolation is enforced by socket, not by client cooperation; clients need no changes |
| Single-maintainer bus factor | Stalls | Code ownership docs, architecture notes in the spec, recorded design reviews |

## Exit checklist

- [ ] All acceptance criteria pass on the reference hardware set.
- [ ] Performance gates enforced in CI and green; the real-hardware input-latency report is published.
- [ ] Spike outcomes recorded as ADRs (Xwayland approach, renderer notes).
- [ ] Hyprland fallback session shipped and marked deprecated, with a removal release noted.
- [ ] ISO builds in CI from a clean checkout.
- [ ] QEMU boot test passes (reaches the desktop on `lugh-compositor`).
- [ ] Shell and compositor UI follow DESIGN-SYSTEM.md, all states implemented; quarantine never color-only.
- [ ] `lugh-shell-v1` and the portal backend documented, with CLI equivalents where relevant (`lugh desktop mode <name>`), polkit not required (session-only), unit tests present.
- [ ] Spec updated, new decisions added to DECISIONS.md.
- [ ] Release note written in `docs/releases/phase-5.md`.
