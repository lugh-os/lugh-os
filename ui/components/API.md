# LughUI — component contract (`import Lugh.UI`)

The QML module `Lugh.UI` lives in `ui/components/Lugh/UI/` (import path:
`ui/components`). Tokens come from the `Theme` singleton (`Theme.qml`, read it
first). This file fixes every component's **public API** so the shell, greeter
and apps can be written against it in parallel. Implementations may add
private properties (prefix `_`), never rename or drop these.

## Rules for every component

- **Qt 6.8 only** (Debian trixie ships 6.8.2). Do not use APIs added after 6.8
  (e.g. `RectangularShadow`, `ShapePath` additions of 6.9+). The host has 6.11,
  so this is on you, not the tests.
- Build on `QtQuick.Templates as T` where a template exists (Button, Switch,
  Slider, TextField, ItemDelegate, Menu, MenuItem, ToolTip, Popup, Dialog,
  TabBar…), never on `QtQuick.Controls` styles.
- All colors, fonts, radii, spacing and durations come from `Theme`. No hex
  literals in components.
- States per DESIGN-SYSTEM §7: hover (`Theme.hoverOverlay` / `surface2`, 120 ms),
  pressed (`surface3` / `pressedOverlay`, buttons scale 0.98), keyboard focus
  (`FocusRing`, only on `visualFocus`), selected (`Theme.selectedBg` +
  `accentText` + an indicator that is not color alone), disabled
  (`Theme.disabledOpacity`, no hover, tooltip from `disabledReason` when set),
  loading, empty, error where they apply.
- Motion: durations `Theme.durMicro/Small/Medium/Large`, easing
  `Easing.BezierSpline` + `Theme.easeStandard`. When `Theme.reduceMotion` is
  true, skip scale/position animation and only fade, using `Theme.durReduced`.
- Accessibility: set `Accessible.role`, `Accessible.name` (falls back to
  `text` / `tooltip`), `Accessible.description` where useful. Keyboard: Space
  and Enter activate buttons; arrows move sliders/segments/tabs/menus.
- **Performance**: no `layer.enabled` or `MultiEffect` on content that changes
  every frame; no per-frame JS; prefer `Rectangle`/`Text` over images; static
  shadows use `Shadow` (cheap, no offscreen pass). Every animation must run on
  the render thread–friendly properties (opacity, scale, x/y, color).
- Hit targets ≥ `Theme.hitTarget` (32 px).

## Components

| Type | Base | Public API |
|---|---|---|
| `Icon` | Text (icon font) | `name: string` (Lucide name, kebab-case, e.g. `"wifi"`, `"volume-2"`, `"battery-medium"`), `size: int = 20`, `color: color = Theme.text`. Unknown name → renders nothing and warns once. Crisp at any size (font glyph). |
| `IconNames` (singleton) | QtObject | `glyph(name) → string`, `has(name) → bool`. Generated from the vendored Lucide font. |
| `AppIcon` | Item | `iconName: string` (freedesktop icon name, absolute path or URL), `size: int = 48`, `fallbackText: string` (app name; first letter drawn on a squircle plate when the icon can't be found). Non-square icons sit on a subtle `surface` plate (DESIGN-SYSTEM §6). `sourceSize` always set (no oversized textures). |
| `FocusRing` | Rectangle | Child of the focused control. `target: Item = parent`, `radius: real` (outer radius = target radius + offset), `show: bool` (default `target.visualFocus ?? target.activeFocus`). Draws `Theme.focusRingWidth` ring at `Theme.focusRingOffset` outside the target. |
| `Button` | T.Button | `text`, `iconName: string = ""`, `variant: string = "secondary"` (`primary` \| `secondary` \| `ghost` \| `danger`), `size: string = "md"` (`md` 36 px \| `sm` 28 px visual, 32 px hit), `loading: bool` (spinner replaces icon, button disabled for input but not dimmed), `disabledReason: string`. Signal `clicked()`. |
| `IconButton` | T.Button | `iconName`, `tooltip: string` (also the accessible name; required), `size: int = 32`, `iconSize: int = 18`, `variant: string = "ghost"` (`ghost` \| `filled` \| `glass` \| `accent`), `checkable`, `checked` (checked = selected state), `badge: int = 0` (count badge, >0 shows). Signal `clicked()`. |
| `Toggle` | T.Switch | `checked`, `text: string = ""` (label to the left, row fills width when set), `disabledReason`. Signal `toggled()`. Track is a pill; checked = accent fill + knob right + check glyph in knob (not color alone). |
| `Slider` | T.Slider | `value`, `from = 0`, `to = 1`, `stepSize = 0.01`, `iconName: string = ""` (leading icon; tapping it emits `iconClicked()`), `iconTooltip`, `showValue: bool = false` (percentage at the end, tabular numerals), `live: bool = true`. Signals `moved()`, `iconClicked()`. Thick (control-center style) track: 28 px, accent fill, rounded. |
| `SegmentedControl` | Item | `model: var` (array of strings or of `{text, iconName}`), `currentIndex: int`, signal `activated(int index)`. Sliding selection pill animates (spring) between segments. |
| `Badge` | Item | `text: string`, `tone: string = "accent"` (`accent` \| `neutral` \| `danger` \| `success` \| `info`), `dot: bool = false` (8 px dot, no text). |
| `Spinner` | Item | `running: bool = true`, `size: int = 16`, `color: color = Theme.textMuted`. Arc rotation via `RotationAnimator` (render thread). |
| `TextField` | T.TextField | `placeholderText`, `iconName: string = ""` (leading), `errorText: string = ""` (shows danger border + message below + icon), `password: bool = false` (masked, with a reveal IconButton), `clearable: bool = false`. Signal `accepted()` (inherited). |
| `SearchField` | T.TextField | Search icon leading, clear button when not empty, `large: bool = false` (launcher size: 52 px tall, `typeTitle3`-sized 20 px text, no border, transparent bg), `busy: bool` (spinner replaces the search icon). |
| `ListRow` | T.ItemDelegate | `title`, `subtitle: string = ""`, `iconName: string = ""` (Lucide symbolic) **or** `appIcon: string = ""` (freedesktop app icon via `AppIcon`), `iconSize: int` (20 symbolic / 32 app), `trailingText: string = ""`, `showChevron: bool = false`, `selected: bool` (selected state with check/indicator), `highlighted` (inherited: keyboard-current row, e.g. launcher), `trailing: Component = null` (custom trailing item, e.g. a Toggle), `danger: bool = false`. Height 40 (title only) / 52 (with subtitle). |
| `Tabs` | T.TabBar | `model: var` (strings), `currentIndex`, underline indicator slides (accent, 2 px). |
| `Menu` | T.Menu | Styled popup menu (surface, `radiusMd`, `Shadow` elevation menu, 6 px padding, enter: fade + scale 0.96→1 in `durSmall`). Use `MenuItem` / `MenuSeparator` children. |
| `MenuItem` | T.MenuItem | `text`, `iconName: string = ""`, `shortcutText: string = ""` (right-aligned, muted), `danger: bool = false`, checkable/checked show a check glyph. |
| `MenuSeparator` | T.MenuSeparator | 1 px `Theme.border`, 4 px vertical margin. |
| `Tooltip` | T.ToolTip | `text`, `delay = 600`, `timeout = -1`. `typeCaption`, inverted colors (`text` bg, `bg` text) for contrast, `radiusSm`. Also usable as attached `T.ToolTip` style replacement inside components. |
| `Card` | Rectangle | `padding: int = Theme.space16`, `elevated: bool = false` (adds `Shadow` menu level), default property → content `Item` with padding. Surface + 1 px border, `radiusMd`. Optional `interactive: bool` with hover/pressed/focus states and signal `clicked()`. |
| `GlassPanel` | Item | Shell glass surface: `radius: real = Theme.radiusXl`, `elevation: string = "popover"` (`none` \| `menu` \| `popover` \| `window`), default property → content. Draws `Theme.glass` fill + 1 px `Theme.glassBorder` hairline + a 1 px inner top highlight (`Theme.glassHighlight`) + `Shadow`. The blur behind is done by the compositor (Hyprland `layerrule = blur`); in the preview the frame simulates it. Opaque fallback when `Theme.transparency` is false. |
| `Shadow` | Item | Cheap static soft shadow for a rounded rect, **no MultiEffect / no offscreen pass** (e.g. a few stacked translucent rounded rects or a prebuilt 9-patch `BorderImage`). `target: Item` (shadow follows its geometry), `radius: real`, `elevation: string` (`menu` \| `popover` \| `window`, from `Theme.elevation*`). Put it as a sibling **below** the target. |
| `Popover` | T.Popup | Surface popup: `radiusLg`, `Shadow` popover level, `padding = Theme.space16`, enter = fade + scale 0.96→1 + 4 px slide (`durMedium`), exit = fade (`durSmall`). `glass: bool = false` uses `GlassPanel` instead of `surface`. Closes on Esc and outside click. |
| `Dialog` | T.Dialog | `title`, `text` (body), `primaryText: string = "OK"`, `secondaryText: string = "Cancel"`, `danger: bool = false` (primary becomes `danger` variant), `busy: bool`, `errorText: string`, signals `accepted()`, `rejected()`. Modal scrim `Theme.scrim`. Width 400, `radiusLg`, `typeTitle3` title. Esc rejects, Enter accepts. Default property → extra content between body and buttons. |
| `Skeleton` | Rectangle | `radius = Theme.radiusSm`, shimmer sweep ≤ 1.2 s loop (`surface2` → `surface3`), stops when invisible. Under reduce motion: static. |
| `EmptyState` | Item | `iconName: string = ""` (small symbolic, optional: illustration-free), `title`, `body: string = ""`, `actionText: string = ""` (shows a primary `Button`), signal `action()`. Centered, max width 320. |
| `ErrorBanner` | Rectangle | `text` (plain-language cause), `actionText: string = ""` (recovery action), `dismissible: bool = true`, signals `action()`, `dismissed()`. `danger` icon (`circle-alert`) + text, tinted `danger` at 10% bg, 1 px danger border at 40%, `radiusMd`. |

## Liquid components (design language v2, `docs/design/lugh-mode.md`)

| Type | Base | Public API |
|---|---|---|
| `Squish` | Item | Wrapper that gives its content the liquid press/hover feel. `pressed: bool`, `hovered: bool`, `lift: real = 0` (px the content rises on hover), `pressScale: real = Theme.squishScale`, default property → content. Scale and y animate with the snappy spring; under reduce motion nothing moves. Sized to its content. |
| `Island` | T.Button | Floating glass capsule (the bar islands, toasts, OSD). `radius: real = height / 2`, `elevation: string = "menu"`, `padding: int = Theme.space12`, `active: bool` (its panel is open: stays highlighted), `interactive: bool = true` (false ⇒ no hover/press, not focusable), default property → content `Row`-like item. Width follows content and **springs** (liquid) when the content changes size (`animateWidth: bool = true`). Squish on press, hover brighten, FocusRing. Signal `clicked()`. Uses `GlassPanel` inside. Readonly `rect sceneRect` (its rect mapped to the window/scene, updates as it moves) for morph origins. |
| `MorphPanel` | Item | A glass panel that grows out of an origin rect. `open: bool`, `originRect: rect` (scene coords, e.g. `ShellState.statusIsland`), `targetRect: rect` (scene coords), `originRadius: real = originRect.height / 2`, `radius: real = Theme.radiusXl`, `elevation: string = "popover"`, default property → content (laid out at the **target** size from the start so it never reflows mid-morph; clipped to the current shape; opacity follows progress, fully visible from ~40%). Readonly `shown: bool` (open or animating), `progress: real` (0..1), `settled: bool`. Opening: liquid spring on x/y/width/height/radius; closing: `durSmall` ease, no overshoot. Reduce motion: fade only at the target rect. When `targetRect` changes while open (a drawer opened) the panel glides to it with the liquid spring. Fill it into a fullscreen overlay item (`anchors.fill: parent` on the overlay; the panel positions itself). |
| `IconToggle` | T.Button | Round icon toggle for the control center. `iconName`, `checkedIconName: string = ""` (icon when on, if different), `checked`, `size: int = 48`, `label: string` (accessible name + tooltip; required), `stateText: string = ""` (appended to the accessible name/tooltip: "on, Kigali Heights 5G"), `hasDetail: bool = false` (small chevron tick at the bottom-right; emits `detailRequested()` on tick click, long press, right click or →), `busy: bool` (ring spinner around it), `tone: string = "accent"`. On = accent fill + `onAccent` icon; off = `surface2`-like translucent fill. Liquid fill transition (the accent grows from the center), squish on press. Signals `toggled()`, `detailRequested()`. |
| `Chip` | T.Button | Small selectable capsule (audio outputs, power profiles). `text`, `iconName: string = ""`, `selected: bool` (accent tint + check tick), `size: string = "md"` (28 px visual, 32 hit). Signal `clicked()`. |
| `Drawer` | Item | Expand/collapse container. `expanded: bool`, default property → content, `implicitHeight` animates between 0 and the content height with the liquid spring (content clipped, fades in). Content is created lazily on first expand (`lazy: bool = true`) and kept. Readonly `animating: bool`. Reduce motion: instant height + fade. |
| `Slider` (addition) | T.Slider | `compact: bool = false` ⇒ 20 px track for islands/OSD and the control center rows; same API. |

## Tests and gallery

- `ui/components/gallery/Gallery.qml` renders every component in every state,
  light and dark (`--dark` flag), used for screenshots and contrast checks.
- Screenshot any QML file: `scripts/qml-shot.sh <file.qml> <out.png> [w] [h] [delay-ms] [-- args]`.
  It sets the import paths for `Lugh.UI` and `Lugh.Shell`. A window flashes
  for ~1 s (GPU rendering); export `QT_QPA_PLATFORM=offscreen` when your scene
  has no shader effects to avoid the flash.
