# Lugh wallpapers

**Dawn** is the default Lugh wallpaper: a low sun rising behind soft layered hills. It comes in a light variant (Dawn) and a dark variant (Dusk). DESIGN-SYSTEM §1 allows gradients in one place only, the default wallpaper, and this is it.

## Files

| File | Size | Use |
|---|---|---|
| `dawn-light-3840x2160.jpg` | 3840×2160 (16:9) | Light theme, screens wider than 2560 device pixels |
| `dawn-light-2560x1600.jpg` | 2560×1600 (16:10) | Light theme, screens up to 2560 device pixels wide |
| `dawn-dark-3840x2160.jpg` | 3840×2160 | Dark theme ("Dusk"), large screens |
| `dawn-dark-2560x1600.jpg` | 2560×1600 | Dark theme, other screens |
| `dawn-light-blur.jpg`, `dawn-dark-blur.jpg` | 960×540 | Pre-blurred copies (a blur of about 30 px at 3840 wide). The lock screen and the preview's glass backdrops scale these up, so nothing blurs at runtime |
| `make-wallpapers.py` | | Generates every file above |

The `lugh-branding` package installs the JPEGs to `/usr/share/backgrounds/lugh/`. The shell's `Wallpaper` item (`ui/shell/qml/Lugh/Shell/wallpaper/Wallpaper.qml`) loads them from that directory. In a source tree without the package installed, it falls back to this directory.

## Design rules

- Colors come from the Lugh palette (DESIGN-SYSTEM §2). The light variant uses warm paper neutrals (`#F7F6F3`, `#EEECE7`) with sand and muted terracotta hills, and an amber glow in the `#E8962E`/`#F2A93B` family. The dark variant uses deep warm charcoal (`#141413`, `#1C1B19`) with a dim ember. There is no purple, indigo or blue-violet, no text and no logo.
- The top ~6% sits under the bar and is plain sky. The bottom ~14% sits under the dock and is a single flat hill. Contrast stays moderate there, so text on shell glass keeps passing AA.
- Film grain (a triangular dither of ±2 levels on light and ±2.6 on dark) is added before quantizing. The JPEGs use 4:4:4 chroma. Together these stop the gradients from banding or showing color blocks after compression.
- Shapes are placed in height-normalized units centered on the width, so the 16:9 and 16:10 files share one composition and crop cleanly to other aspect ratios (the item uses cover-fit).

## Regenerating

```sh
python3 branding/wallpapers/make-wallpapers.py            # writes into this directory
python3 branding/wallpapers/make-wallpapers.py --preview  # also writes 1920×1080 PNGs to /tmp/lugh-wallpaper-preview/
```

You need `python3-numpy` and `python3-pil`. The output is deterministic because the seeds are fixed. A full run takes about 30 s. If you change the art, regenerate it and commit the JPEGs.

## License

Copyright 2026 Lugh Developers. Licensed under **CC-BY-SA-4.0** (Creative Commons Attribution-ShareAlike 4.0 International, <https://creativecommons.org/licenses/by-sa/4.0/>). You may share and adapt the wallpapers, including commercially, if you credit "Lugh Developers" and release adaptations under the same license. The generator script `make-wallpapers.py` falls under the repository's GPL-3.0-or-later license.
