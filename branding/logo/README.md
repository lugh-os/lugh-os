# Lugh logo

The Lugh mark is an **L** with a **sun** resting in its corner: Lugh is the god of light and of craft. These files are the founder's artwork with the export clutter removed. The shapes and colors match the original exactly, so don't redraw or recolor them.

## Files

| File | What it is | Use it for |
|---|---|---|
| `lugh-logo.svg` | Full-color mark, charcoal L and amber sun | Light backgrounds. This is the master file |
| `lugh-logo-dark.svg` | Full-color mark, light L and amber sun | Dark backgrounds |
| `lugh-logo-mono.svg` | One color, `fill="currentColor"` | Places where the mark is tinted by CSS or QML (`color:`) |
| `lugh-logo-mono-dark.svg` | One color, `#1C1B19` | One-color print, embossing, fax-grade output |
| `lugh-logo-mono-light.svg` | One color, `#FFFFFF` | Over photos and over solid color fills |
| `lugh-wordmark.svg` | "lugh" in Inter SemiBold, converted to outlines | Light backgrounds, where the mark is already shown nearby |
| `lugh-wordmark-dark.svg` | Same, in `#EDEBE6` | Dark backgrounds |
| `lugh-lockup.svg` | Mark to the left of the wordmark, vertically centered | Light backgrounds: installer, website, about dialogs |
| `lugh-lockup-dark.svg` | Same, dark-background colors | Dark backgrounds: boot, greeter |
| `png/lugh-logo-{128,256,512}.png` | Renders of `lugh-logo.svg`, transparent | GRUB theme, Plymouth (light) |
| `png/lugh-logo-dark-{128,256,512}.png` | Renders of `lugh-logo-dark.svg`, transparent | Plymouth (dark) |
| `../icons/hicolor/scalable/apps/lugh-logo.svg` | App icon (`Icon=lugh-logo`, os-release `LOGO=lugh-logo`) | Icon theme |
| `../icons/hicolor/<N>x<N>/apps/lugh-logo.png` | Icon renders at 16, 22, 24, 32, 48, 64, 128, 256 and 512 px | Icon theme |

All SVGs are plain paths with `role="img"` and `<title>Lugh</title>`. None of them depends on a font.

The mark SVGs use a `0 0 200 200` canvas. The artwork spans x 40–160 and y 32–168, so the canvas includes some built-in padding. The app icon uses the same artwork with a tighter `20 20 160 160` viewBox, so the mark fills about 85% of the icon square and stays legible at 16 px. The wordmark and lockup viewBoxes are cropped tight to the ink, so you add clear space yourself (see below).

## Colors

| Role | Light background | Dark background |
|---|---|---|
| L and wordmark | `#2A2420` charcoal | `#EDEBE6` (dark-theme `text`) |
| Sun | `#EE9A2E` amber | `#EE9A2E` amber |
| Mono | `#1C1B19` or `currentColor` | `#FFFFFF` |

The sun's amber `#EE9A2E` is part of the logo and is **not** the UI accent token (`#E8962E` light / `#F2A93B` dark). Don't swap one for the other. In the mono variants the L and the sun share one color. They don't touch, so the mark still reads.

## Clear space and minimum size

- **Clear space:** keep at least the width of the L's stem free on every side of the art. That is 30 units on the 200-unit canvas, about 22% of the mark's height. For the lockup, use the same distance measured from its outer edges.
- **Minimum size:** the mark is 16 px tall on screen (use the `16x16` icon render) or 6 mm in print. The lockup is 24 px tall on screen or 8 mm in print. Below 24 px, use the mark without the wordmark.
- Don't stretch, rotate, outline, add shadows to, or recolor the mark. Don't move the sun. Don't put the full-color light mark on dark backgrounds (use `-dark`) or on busy photos (use `-mono-light`).

## Wordmark

Set in Inter SemiBold (600), lowercase, with −0.02 em tracking (Inter's recommended tracking at display sizes) and no kerning pairs. The letters were converted to outlines from `Inter-SemiBold.otf` with fontTools. In the lockup the wordmark's ascender is 62% of the mark's height, its ink is centered vertically on the mark, and the gap is 36 units (a little more than the L stem).

## Re-rendering the PNGs

```sh
scripts/render-brand-assets.sh
```

The script runs from any directory and gives the same result every time it runs (it overwrites the same files). If the host has `rsvg-convert` (`apt install librsvg2-bin`), the script uses it. Otherwise it renders inside a `debian:trixie` container and changes the outputs' owner back to your user. Commit the regenerated PNGs. To change the artwork, edit the SVGs first. Edit `lugh-logo.svg` as the master, then copy the same shapes into the other variants and into the scalable icon.
