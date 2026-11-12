# Lugh mode — design language v2 ("Liquid")

> Status: **Accepted** (ADR-028) · Applies to `lugh-shell` in **Lugh mode**. The later *Mac-like* and *Windows-like* modes get their own layouts; Lugh mode moved from top islands + dock to one bottom panel (see §1).

Lugh mode is its own desktop, not a copy. Three ideas carry it.

## 1. One bottom panel

The top bar and the dock are gone. One glass **panel** sits at the bottom edge: a floating pill by default, a full-width strip when *Floating* is off (Customize → Panel).

```
 ╭────────────────────────────────────────────────────────────────────────╮
 │ ◣  ⌕  ▦▦   ▣  ▣  ▣  ▣  ▣ │ 🗑                      ⌔ ◍ ▮ 64   02:20  │
 │            ˙     ˙                                       Tue 10 Nov  │
 ╰────────────────────────────────────────────────────────────────────────╯
  start search workspaces  apps (pinned + running) · Trash      tray + clock
```

| Item | Content | Click |
|---|---|---|
| Start (left) | Lugh mark | → Lugh menu (opens upward); right-click → Customize |
| Search | magnifier (optional) | → launcher, grown out of the start area |
| Workspaces | rows × cols grid: solid = current, outline with core = occupied, outline = empty | → overview (Super+Tab); wheel / PageUp/PageDown switch |
| Apps | pinned and running apps, running dots, Trash; optional magnify | launch / focus / cycle; right-click → app menu |
| Tray + clock (right) | keyboard layout (if > 1), network, volume, battery, time over date; a dot when notifications wait, a slashed bell under Do Not Disturb. **It is also the OSD** on volume/brightness changes. | → quick panel |

Right-click on empty panel space: Customize Panel…, Auto-hide, Floating, Magnify Icons, alignment. Overlays keep their bottom edge above the panel (`ShellState.panelReserved`, the panel's height plus margin even under auto-hide, because every overlay reveals it). **Super+B** focuses the panel (focus ring on the start button, arrows to move, Esc to give the keyboard back).

## 2. Liquid motion

Things do not pop; they **grow out of what you touched** and settle like liquid.

- **Grow out of what you touched:** overlays are drawn at their final size from the first frame; shape and content scale up together from what opened them (0.88–0.95) and fade in, 240 ms open, 180 ms close. Quick panel and notification center ← tray, launcher ← start/search (or its own center from the keyboard), Lugh menu ← start button, overview and Customize ← the screen center. `Theme.animationScale` (Customize → Motion) scales every duration and spring.
- **Springs:** movement and size use `Theme.liquid*` (soft, ≤ 3% overshoot); small state changes use `Theme.snappy*`. Fades use `Theme.easeStandard`.
- **Squish:** pressing a panel button, an app icon or a tile scales it to 0.96 and springs back. Hover lifts by 1–2 px or brightens; nothing jumps.
- **Reflow:** when content changes size (a drawer opens, a toast leaves, an app icon appears) neighbours glide with the liquid spring. Heights are animated, never snapped.
- **Reduce motion:** every morph becomes a 100 ms cross-fade; no scale, no travel.
- **Budget:** only `x`, `y`, `width`, `height`, `scale`, `opacity`, `radius` animate. No blur, no shader, no `layer` during motion. A dropped frame is a bug.

## 3. Compact, icon-first, expandable

Show the icon and the state; reveal detail only when asked.

**Quick panel** (360 px wide, bottom-right, grows out of the tray): the clock (large) and long date with Customize, lock and power buttons; the month calendar (a chevron folds it to the current week); pill tiles in two columns in the order of `ShellSettings.quickToggles` (pencil → edit mode: drag or Shift+arrows to reorder, ⊖ to remove, + chips to add); volume and brightness with their value on the right ("62%", "Muted"); one now-playing row; the newest three notifications with Clear all and Do Not Disturb. Every section can be switched off in Customize → Quick panel. It never scrolls on a normal screen: when it would be taller than the space above the panel it tightens its spacing, then folds the calendar, then shows fewer notifications ("Show all N" stays). **Keep awake** is a tile like the others; it holds a logind idle inhibitor while on.

- A toggle with detail (Wi-Fi, Bluetooth, power profile) shows a small chevron tick. Click toggles; the chevron, a long press, right click or → opens its **drawer** in place (the panel grows with the liquid spring): networks, devices, profiles. One drawer at a time.
- Toggles never spell their state in the grid. The caption line, the tooltip and the accessible name do ("Wi-Fi, on, Kigali Heights 5G").
- **Notifications:** toasts are compact capsules (icon, title, one line) at the top-right corner; hover or focus expands one to its body and actions.
- **Panel apps:** 48 px icons by default (40–80), subtle liquid magnify on hover (1.18×, neighbours follow), an amber ember capsule under running apps (wider for the focused one), squish on press.
- **Launcher:** 600 px, 44 px rows, a little above the middle of the screen; typing only changes its height.
- **Overview (Super+Tab):** the workspace grid with each workspace's windows, a search filter, arrows to pick, Enter to go. Super+Ctrl+arrows move between neighbouring workspaces (+Shift takes the window).
- **Customize:** one sheet with search and seven sections (Appearance, Panel, Clock & tray, Quick panel, Workspaces, Windows, Motion); every change applies live.
- **Window title bars:** apps that leave the frame to the compositor (foot, kitty, mpv, Qt, X11 apps) get Lugh's compact 26 px bar (Inter 10, theme colours, buttons on the right in the Customize → Windows order). GTK, libadwaita and Firefox keep their own header bars, compacted by Lugh's `gtk.css`; no window ever gets two bars.
- **Lock / greeter:** the password field is a floating glass capsule; the clock is the hero.

## Accessibility (unchanged rules, restated because icons carry more)

- Every icon-only control has an accessible name with its state, a tooltip, and a 32 px+ hit target (toggles are 48).
- State is never color alone: on-toggles also change the icon (e.g. `wifi` → `wifi-off`) or carry a check tick.
- Focus ring on every panel button, tile, chip and row. Full keyboard path: Tab between groups, arrows inside a grid or list, Enter/Space to act, → to open a drawer, Esc to close a drawer then the panel.
- Contrast is enforced by `scripts/check-contrast.py`.
