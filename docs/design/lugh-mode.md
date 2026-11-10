# Lugh mode — design language v2 ("Liquid")

> Status: **Accepted** (ADR-028) · Applies to `lugh-shell` in **Lugh mode**. The later *Mac-like* and *Windows-like* modes get their own layouts; the former full-width bar is kept as `bar/FullBar.qml` for the Mac-like mode.

Lugh mode is its own desktop, not a copy. Three ideas carry it.

## 1. Floating islands, not bars

Nothing spans the screen. The top of the screen holds three floating glass **islands**; the dock is a fourth.

```
 ╭──────────────────────╮        ╭────────────╮        ╭───────────────╮
 │ ◣ Firefox  ▬ ● ○ ○   │        │ Tue 10 · 02:20 │    │ US  ⌔ ◍ ▮ 64 │
 ╰──────────────────────╯        ╰────────────╯        ╰───────────────╯
   logo island (left)             center island          status island (right)

                          ╭──────────────────────────╮
                          │  ▣  ▣  ▣  ▣  ▣ │ ▣ │ ▣   │   dock
                          ╰──────────────────────────╯
```

| Island | Content | Click |
|---|---|---|
| Logo (left, x = 10) | Lugh mark, focused app name, hairline, workspace dots | mark → Lugh menu; dot → workspace |
| Center ("the Lugh island") | date · time; a dot when notifications wait. **It is also the OSD**: on a volume/brightness/caps/layout change it widens and shows icon + slim level + value for 1.2 s, then returns to the clock. Media: a tiny playing indicator. | → notification center + calendar |
| Status (right, 10 from edge) | keyboard layout (if > 1), network, volume, battery — icons only | → control center |

Geometry: islands are 36 px tall, `radiusFull`, 8 px from the top edge, glass + hairline + menu-level shadow. The bar surface is 52 px tall (exclusive zone 48). Text in islands: `Theme.typeLabel` (13/500), tabular numerals for time. There is no separate OSD surface.

## 2. Liquid motion

Things do not pop; they **grow out of what you touched** and settle like liquid.

- **Morph:** every panel opens out of its island: it starts at the island's rect and radius and springs to its own rect (`MorphPanel`). Content fades in during the last 60%. Closing reverses, quicker and without overshoot. Launcher ← center island, control center ← status island, notification center ← center island, Lugh menu ← logo island.
- **Springs:** movement and size use `Theme.liquid*` (soft, ≤ 3% overshoot); small state changes use `Theme.snappy*`. Fades use `Theme.easeStandard`.
- **Squish:** pressing an island, a dock icon or a toggle scales it to 0.96 and springs back. Hover lifts by 1–2 px or brightens; nothing jumps.
- **Reflow:** when content changes size (a drawer opens, a toast leaves, a dock icon appears) neighbours glide with the liquid spring. Heights are animated, never snapped.
- **Reduce motion:** every morph becomes a 100 ms cross-fade; no scale, no travel.
- **Budget:** only `x`, `y`, `width`, `height`, `scale`, `opacity`, `radius` animate. No blur, no shader, no `layer` during motion. A dropped frame is a bug.

## 3. Compact, icon-first, expandable

Show the icon and the state; reveal detail only when asked.

**Control center** (320 px wide, grows out of the status island):

```
 ╭──────────────────────────────────────╮
 │  (⌔)  (ᛒ)  (☾)  (✈)                 │  round icon toggles, 48 px, 2 rows × 4
 │  (◐)  (☀)  (⚡)  (⌨)                │  on = accent fill; no labels
 │  Wi-Fi · Kigali Heights 5G        ›  │  one caption line: name + state of the
 │                                      │  hovered/focused toggle (or last touched)
 │  🔈 ▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬○────────   ⌄    │  ONE volume slider; ⌄ expands the drawer:
 │     ├ outputs  (chips)               │    output chips, per-app sliders, mic
 │     ├ Firefox ▬▬▬▬○──  VLC ▬▬▬▬▬○    │
 │     └ 🎙 ▬▬▬▬▬▬○──                   │
 │  ☼ ▬▬▬▬▬▬▬▬▬▬▬▬○──────────           │  brightness
 │  ♪ Umuhanzi w'Ijuru · Meddy  ⏮ ⏯ ⏭  │  media, one row, only when playing
 │  ▮ 64% · 3 h 40    (AN)  🔒  ⏻      │  footer
 ╰──────────────────────────────────────╯
```

- A toggle with detail (Wi-Fi, Bluetooth, power profile) shows a small chevron tick. Click toggles; the chevron, a long press, right click or → opens its **drawer** in place (the panel grows with the liquid spring): networks, devices, profiles. One drawer at a time.
- Toggles never spell their state in the grid. The caption line, the tooltip and the accessible name do ("Wi-Fi, on, Kigali Heights 5G").
- **Notifications:** toasts are compact capsules (icon, title, one line) under the status island; hover or focus expands one to its body and actions.
- **Dock:** 48 px icons by default (40–80), subtle liquid magnify on hover (1.18×, neighbours follow), an amber ember capsule under running apps (wider for the focused one), squish on press.
- **Launcher:** 600 px, 44 px rows, drops out of the center island.
- **Lock / greeter:** the password field is a floating glass capsule; the clock is the hero.

## Accessibility (unchanged rules, restated because icons carry more)

- Every icon-only control has an accessible name with its state, a tooltip, and a 32 px+ hit target (toggles are 48).
- State is never color alone: on-toggles also change the icon (e.g. `wifi` → `wifi-off`) or carry a check tick.
- Focus ring on every island, toggle, chip and row. Full keyboard path: Tab between groups, arrows inside a grid or list, Enter/Space to act, → to open a drawer, Esc to close a drawer then the panel.
- Contrast is enforced by `scripts/check-contrast.py`.
