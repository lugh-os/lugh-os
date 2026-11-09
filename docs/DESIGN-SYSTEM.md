# Lugh: Design System

The visual and interaction language for every Lugh surface: the shell, apps, installer, greeter, boot and the Windows Setup. It is implemented as the shared QML module **LughUI** (`ui/components/`).

## 1. Personality

**Warm, bright, crafted, calm.** Lugh is the god of light and of craft. Surfaces are clean and quiet. One amber accent marks what matters. Motion feels physical, never showy.

Rules of thumb:
- One accent per screen. Amber means action, focus or selection, never decoration.
- Hierarchy comes from type and spacing first, color second.
- Use blur and translucency only on the shell (bar, dock, launcher, control center), never inside app content.
- No gradients as fills. The only exception is the default wallpaper.

## 2. Color

Default theme: **Light** (ADR-010). All text pairs meet WCAG AA, with measured ratios in brackets.

### 2.1 Light
| Token | Hex | Use |
|---|---|---|
| `bg` | `#F7F6F3` | window backgrounds |
| `surface` | `#FFFFFF` | cards, popovers, menus |
| `surface-2` | `#EEECE7` | sidebars, inputs, hovered rows |
| `surface-3` | `#E4E1DA` | pressed rows, selected rows without focus |
| `border` | `#DEDAD2` | dividers, input borders |
| `text` | `#1C1B19` | primary text (15.9:1 on bg) |
| `text-muted` | `#5F5B54` | secondary text (6.3:1) |
| `accent` | `#E8962E` | primary buttons, toggles, focus ring, selection |
| `on-accent` | `#1C1B19` | text on accent (7.2:1) |
| `accent-text` | `#9A5800` | links, accent-colored text (5.2:1 on bg, 5.6:1 on white) |
| `shell-glass` | `rgba(255,255,255,0.72)` + 30 px blur | bar, dock, launcher |

### 2.2 Dark
| Token | Hex | Use |
|---|---|---|
| `bg` | `#141413` | |
| `surface` | `#1C1B19` | |
| `surface-2` | `#262522` | |
| `surface-3` | `#302E2A` | |
| `border` | `#34322E` | |
| `text` | `#EDEBE6` | (15.5:1) |
| `text-muted` | `#A29D94` | (6.8:1) |
| `accent` | `#F2A93B` | fills and accent text (9.2:1) |
| `on-accent` | `#141413` | (9.2:1) |
| `accent-text` | `#F2A93B` | |
| `shell-glass` | `rgba(28,27,25,0.70)` + 30 px blur | |

### 2.3 Semantic
| Token | Light | Dark | Notes |
|---|---|---|---|
| `success` | `#1F7A4A` | `#4CC38A` | always paired with a check icon |
| `danger` | `#B4322A` | `#F06A5F` | always paired with an icon or label |
| `info` | `#1E6A8C` | `#5BB4DA` | |
| `warning` | `#8A6100` (text) / `#F5C04A` (fill) | `#F5C04A` | used rarely, since it sits close to the accent; always has an icon |
| `quarantine` | `danger` + 45° stripes + shield icon | same | never conveyed by color alone |

The user-selectable accent offers Amber (default), plus Teal `#0F8B8D`, Green `#2F8F4E`, Blue `#2F6FDB`, Red `#D0453A` and Graphite `#5F5B54`. Each has a computed `accent-text` and `on-accent` that pass AA. No purples (house rule).

## 3. Typography

- UI: **Inter** (variable). Monospace: **JetBrains Mono**. Fallback: Noto Sans / Noto Color Emoji.
- Base size 14 px at 100% scale. Line height 1.45 for body, 1.2 for headings.

| Style | Size / weight | Use |
|---|---|---|
| `display` | 34 / 600 | welcome, installer hero |
| `title-1` | 26 / 600 | page titles |
| `title-2` | 20 / 600 | section titles |
| `title-3` | 16 / 600 | card titles, dialog titles |
| `body` | 14 / 400 | default |
| `body-strong` | 14 / 550 | emphasis, labels |
| `caption` | 12 / 450 | metadata, timestamps |
| `mono` | 13 / 400 | terminal, unit files, logs |

Tabular numerals (`tnum`) are used in Tasks, clocks and anywhere numbers update live.

## 4. Space, size, shape

- **Spacing scale (px):** 2, 4, 8, 12, 16, 20, 24, 32, 40, 48, 64.
- **Radius:** 6 (inputs, small buttons), 10 (cards, menus), 14 (windows, popovers), 20 (dock, launcher), full (pills, toggles).
- **Hit targets:** at least 32 px for pointer controls, 44 px in touch mode.
- **Elevation:** 3 shadow levels (menu, popover, window). Shadows stay soft and neutral, never colored.
- **Window gaps (Focus mode):** inner 6 px, outer 10 px, both configurable.

## 5. Motion

- Spring-based, interruptible, and never blocking input.
- Durations: micro 120 ms (hover, press), small 180 ms (toggles, menus), medium 240 ms (popovers, launcher), large 300 ms (window open/close, mode switch, workspace change).
- Easing: spring (stiffness 400, damping 32) for movement, `cubic-bezier(0.2, 0, 0, 1)` for fades.
- Window open scales from 0.94 to 1 with a fade. Close scales to 0.96 with a fade. Minimizing to the dock uses a short genie-like motion. All of this is configurable per mode.
- **Reduce motion** (Settings → Accessibility, and also follows the system flag) replaces movement with 100 ms cross-fades.
- Animations must hold full refresh rate. A dropped frame counts as a bug (VISION §12).

## 6. Iconography

- App icons: rounded-square (squircle) silhouette, consistent across the dock and launcher. Third-party icons are shown as-is, on a subtle plate if they aren't square.
- Symbolic icons: 16/20/24 px, 1.5 px stroke, rounded caps. Base set: **Phosphor** or **Lucide** (open licenses), extended with Lugh glyphs (shield, bridge, lughfile).
- The logo is supplied by the founder. Slots are listed in §9.

## 7. States (every interactive component must implement all of these)

| State | Treatment |
|---|---|
| hover | `surface-2` background or +4% overlay, 120 ms |
| pressed | `surface-3`, scale 0.98 for buttons |
| focus (keyboard) | 2 px `accent` ring with a 2 px offset; never removed |
| selected | `accent` at 16% background + `accent-text` label, plus a check or indicator |
| disabled | 40% opacity, no hover, `cursor: default`, with a tooltip explaining why |
| loading | skeleton shimmer for content (≤ 1.2 s loop), spinner only for actions |
| empty | illustration-free message + one primary action ("No bottles yet — Install a Windows app") |
| error | inline message with `danger` icon, plain-language cause, and a recovery action |

## 8. The three desktop modes (visual spec)

| | **Lugh** (default) | **Classic** | **Focus** |
|---|---|---|---|
| Bar | top, 30 px, glass; app menu left, status right | none (merged into the taskbar) | top, 24 px, solid or hidden; workspaces, clock, tray |
| Dock / taskbar | bottom-center floating dock, 56 px icons, magnify optional, auto-hide optional | bottom taskbar 44 px, Start button left, pinned apps, tray and clock right | none |
| Launcher | Spotlight-style centered search (Super+Space) | Start menu (Super): pinned grid, all apps, search, power | keyboard runner (Super+Space), minimal |
| Windows | floating, rounded 14 px, soft shadow, buttons on the left (close/min/max, color-coded with icons on hover) | floating, buttons on the right, snap layouts on maximize-hover | tiled with gaps, 2 px accent border on focus, no titlebars by default |
| Tiling | optional (Super+T toggles per workspace) | snap only | default; dwindle and master layouts |
| Workspaces | horizontal, 3-finger swipe, overview (Super+Tab) | Task View (Super+Tab) | numbered (Super+1..9), animated slide |
| Window buttons side | left | right | n/a (keyboard) |

## 9. Brand asset slots (to be filled by the founder)

| Asset | Format | Sizes |
|---|---|---|
| Logo mark | SVG (single color + full color) | n/a |
| Wordmark | SVG | n/a |
| App/launcher icon | SVG | 16–512 |
| GRUB theme logo | PNG | 256, 512 |
| Plymouth logo | PNG | 128, 256 (light and dark) |
| Installer/welcome hero | SVG | n/a |
| Windows Setup icon | ICO | 16–256 |
| Default wallpapers | PNG/JPEG | 3840×2160 + 2560×1600, light and dark variants |

The founder's logo is in `branding/logo/` (see ADR-025). Its sun amber `#EE9A2E` is part of the art and is not the UI `accent` token.

## 10. Accessibility

- WCAG 2.2 AA minimum for all text and essential UI.
- Full keyboard operation of the shell and every app. A visible focus ring is always shown.
- Screen reader support through Qt Accessibility (AT-SPI) and the Orca screen reader, which is preinstalled and off by default.
- Scaling at 100–200% in 25% steps, plus fractional scaling. A large-text option. A high-contrast theme variant.
- Information is never conveyed by color alone (state, quarantine, errors).
