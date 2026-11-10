# Lugh wallpapers

Three original wallpapers, each a light and a dark variant of the same scene. All of it is procedural art made by `make-wallpapers.py` in this directory: no photographs, no third-party textures, no image-generation service.

| Name | Title | Scene |
|---|---|---|
| `dawn` | **Dawn** (default) | A low sun behind long silk dunes: rim light on the crests, haze with distance, a few fine specular threads. Light is paper, sand and terracotta; dark is warm charcoal with an ember sun. |
| `tide` | **Tide** | Liquid glass: six translucent sheets fanning across the screen, each with a bright lip, a soft shadow and caustic threads. Warm neutrals and amber with one teal counter-tone. |
| `ember` | **Ember** | A quiet sun inside four slightly irregular shells of light. Minimal, made for focus. |

DESIGN-SYSTEM §1 allows gradients in one place only, the wallpapers.

## Files

Every wallpaper ships these files, named `<name>-<light|dark>-<size>.jpg`:

| Size | Pixels | Use |
|---|---|---|
| `5120x2880` | 5120×2880 (16:9), the master | screens wider than 3840 device pixels |
| `3840x2160` | 3840×2160 (16:9) | screens wider than 2560 device pixels |
| `2560x1600` | 2560×1600 (16:10, centre crop) | everything else |
| `blur` | 960×540 | pre-blurred copy (about 30 px at 3840 wide) for the lock screen, the greeter and glass backdrops, so nothing blurs at runtime |

JPEG quality 90, 4:4:4 chroma, progressive. The whole set is about 9 MB.

`wallpapers.json` is the manifest for the Settings app: for each wallpaper its `name`, `title`, `description`, its `uri` (`lugh://wallpapers/<name>`, the value to store in the appearance settings) and the file of every variant and size. The generator writes it.

The `lugh-branding` package installs the JPEGs to `/usr/share/backgrounds/lugh/`. The shell's `Wallpaper` item (`ui/shell/qml/Lugh/Shell/wallpaper/Wallpaper.qml`) loads them from there (`Wallpaper { name: "tide" }`, or `lugh://wallpapers/tide` in `Services.appearance.wallpaperLight` / `wallpaperDark`) and picks the size from the item's width in device pixels. In a source tree without the package it falls back to this directory.

## Design rules

- Colors come from the Lugh palette (DESIGN-SYSTEM §2): warm paper neutrals, sand, terracotta and amber on light; deep warm charcoal with ember on dark. Tide adds one cool counter-tone, a teal green-grey. No purple, indigo or violet, no text, no logo.
- The top ~7% sits under the islands and the bottom ~12% under the dock. Both stay calm and mid-contrast, so the glass reads and text on it keeps AA. `scripts/check-contrast.py` samples `dawn-*-blur.jpg`; the brightest region of every dark blur and the darkest of every light blur stay inside the same limit.
- Shapes are placed in height units centred on the width, so the 16:10 file is a plain centre crop of the master and other aspect ratios crop cleanly (the item uses cover-fit).
- Edges are anti-aliased analytically at 5120×2880. Film grain (a triangular dither of about ±2 levels on light, ±2.8 on dark) is added after scaling and before quantizing; with 4:4:4 chroma it keeps the gradients from banding.

## Regenerating

```sh
python3 branding/wallpapers/make-wallpapers.py                  # all files and wallpapers.json, into this directory
python3 branding/wallpapers/make-wallpapers.py --only tide      # one wallpaper (dawn, tide, ember)
python3 branding/wallpapers/make-wallpapers.py --only dawn --mode dark
python3 branding/wallpapers/make-wallpapers.py --preview        # quarter-res PNGs and desktop mocks, ~8 s
```

You need `python3-numpy` and `python3-pil`. The output is deterministic (fixed seeds, closed-form shapes). `--preview` writes `<name>-<mode>.png` (1280×720) and `<name>-<mode>-mock.jpg` (the islands and dock drawn on it) to `/tmp/lugh-wallpaper-preview/` and leaves the JPEGs alone. A full run takes about 5 minutes on one core of a busy laptop (20 to 110 s per variant; Tide is the slow one) and peaks at about 1 GB of memory (strips of float32, one wallpaper at a time). If you change the art, regenerate it, run `python3 scripts/check-contrast.py` and commit the JPEGs.

## License

Wallpapers (the JPEG files): Copyright 2026 Lugh Developers, licensed under **CC-BY-SA-4.0** (Creative Commons Attribution-ShareAlike 4.0 International, <https://creativecommons.org/licenses/by-sa/4.0/>). You may share and adapt them, including commercially, if you credit "Lugh Developers" and release adaptations under the same license.

The generator `make-wallpapers.py` is GPL-3.0-or-later, like the rest of the repository.
