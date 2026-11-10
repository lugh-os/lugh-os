#!/usr/bin/env python3
"""Render the Lugh default wallpaper "Dawn" (light) and its "Dusk" (dark) variant.

    python3 branding/wallpapers/make-wallpapers.py [--out DIR] [--preview]

Procedural and deterministic (fixed seed): a low sun rising behind soft layered
horizon arcs. Needs numpy and Pillow (apt install python3-numpy python3-pil).

Composition rules (DESIGN-SYSTEM §1, §9):
  - the only gradients in Lugh live here;
  - the top ~6 % (bar) is plain sky and the bottom ~14 % (dock) is one flat
    hill, so the glass bar and dock stay calm and readable;
  - no purple/indigo, no text, no logo;
  - film grain (triangular dither, ±2–2.6 levels) before quantising and 4:4:4
    chroma, so the gradients survive JPEG without banding or colour blocks.

Every shape is placed in height-normalised units centred on the width, so the
16:9 and 16:10 renders share one composition.
"""
import argparse
import os

import numpy as np
from PIL import Image, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
SIZES = [(3840, 2160), (2560, 1600)]
BLUR_SIZE = (960, 540)


def hexc(h):
    h = h.lstrip("#")
    return np.array([int(h[i:i + 2], 16) for i in (0, 2, 4)], np.float32) / 255.0


def to_lin(c):
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def to_srgb(c):
    c = np.clip(c, 0.0, 1.0)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * np.power(c, 1 / 2.4) - 0.055)


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3 - 2 * t)


def lerp(a, b, t):
    return a + (b - a) * t[..., None]


PALETTES = {
    # Dawn: warm paper sky, amber glow, sand and terracotta hills.
    "light": dict(
        sky_top="#F7F6F3", sky_mid="#F7EDE0", sky_low="#F8DDB8",
        glow="#F2A93B", glow_strength=0.50, halo="#FBE6C4",
        sun_core="#FEF0D6", sun_edge="#F9D49A", sun_alpha=0.95,
        rim="#FFE2B0", rim_strength=0.55,
        # back → front: (ridge colour, foot colour)
        hills=[("#F0D9BE", "#EDD8C2"),
               ("#E8C7A3", "#E5CCB3"),
               ("#DEB18C", "#E0C3A8"),
               ("#E2C7AD", "#EEE4D9")],
        haze="#F9E7CF",
        grain=2.0,
    ),
    # Dusk: deep warm charcoal, a dim ember low on the horizon.
    "dark": dict(
        sky_top="#141413", sky_mid="#191614", sky_low="#2B1F17",
        glow="#A9561C", glow_strength=0.30, halo="#4A2C16",
        sun_core="#E8A458", sun_edge="#D2843A", sun_alpha=0.80,
        rim="#E08A3A", rim_strength=0.40,
        hills=[("#2A211B", "#231D18"),
               ("#221C18", "#1D1916"),
               ("#1C1815", "#181614"),
               ("#171614", "#141413")],
        haze="#3A2819",
        grain=2.6,
    ),
}

# Composition, in height units: x in [-aspect/2, aspect/2] (0 = centre), y in [0, 1] top→bottom.
SUN = dict(x=0.30, y=0.680, r=0.080)
# Each ridge: a flat `base` level with smooth domes (cx, top, half-width) rising
# out of it; the ridge is the soft-min (highest) of its domes, so joints read as
# valleys rather than corners. The sun sits in the valley of the back ridge.
RIDGES = [
    dict(base=0.710, domes=[(-0.45, 0.585, 0.80), (0.95, 0.630, 0.70)]),
    dict(base=0.765, domes=[(-0.05, 0.672, 0.70), (-0.98, 0.700, 0.60), (0.98, 0.712, 0.50)]),
    dict(base=0.815, domes=[(-0.30, 0.722, 0.95), (0.85, 0.745, 0.70)]),
    dict(base=0.880, domes=[(0.40, 0.795, 1.40)]),
]


def ridge_y(x, spec, soft=0.010):
    base = spec["base"]
    ys = [np.full_like(x, base)]
    for cx, top, rx in spec["domes"]:
        u = np.clip((x - cx) / rx, -1.0, 1.0)
        # smooth bump: flat tangent at the top and where it meets the base
        ys.append(top + (base - top) * (1.0 - (1.0 - u * u) ** 2))
    ys = np.stack(ys)
    m = ys.min(0)
    return m - soft * np.log(np.sum(np.exp(-(ys - m) / soft), 0))


def render(w, h, mode, seed=7):
    p = PALETTES[mode]
    L = lambda k: to_lin(hexc(p[k]))  # noqa: E731
    aspect = w / h
    xs = (np.arange(w, dtype=np.float32) + 0.5) / h - aspect / 2
    ys = (np.arange(h, dtype=np.float32) + 0.5) / h
    X, Y = np.meshgrid(xs, ys)
    px = 1.0 / h  # one pixel in height units

    # ---- sky: calm at the top, warming towards the horizon -----------------
    t = smoothstep(0.05, 0.72, Y)
    sky = lerp(np.broadcast_to(L("sky_top"), (h, w, 3)), np.broadcast_to(L("sky_mid"), (h, w, 3)), t)
    sky = lerp(sky, np.broadcast_to(L("sky_low"), (h, w, 3)), smoothstep(0.35, 0.78, Y) ** 1.4)

    # sun glow: a wide, flattened radial falloff (wider than tall, like haze)
    dx, dy = X - SUN["x"], (Y - SUN["y"]) * 1.55
    d = np.sqrt(dx * dx + dy * dy)
    glow = np.exp(-(d / 0.42) ** 2) * p["glow_strength"]
    glow *= smoothstep(-0.02, 0.18, Y)  # never reach the bar
    sky = lerp(sky, np.broadcast_to(L("glow"), (h, w, 3)), glow)
    halo = np.exp(-(d / 0.16) ** 2) * 0.65
    sky = lerp(sky, np.broadcast_to(L("halo"), (h, w, 3)), halo)

    # sun disc: soft-edged, warmer at the rim
    ds = np.sqrt((X - SUN["x"]) ** 2 + (Y - SUN["y"]) ** 2)
    disc = 1.0 - smoothstep(SUN["r"] - 2.5 * px, SUN["r"] + 2.5 * px, ds)
    core_t = smoothstep(0.0, SUN["r"], ds) ** 3.0
    sun_col = lerp(np.broadcast_to(L("sun_core"), (h, w, 3)), np.broadcast_to(L("sun_edge"), (h, w, 3)), core_t)
    img = lerp(sky, sun_col, disc * p["sun_alpha"])

    # ---- hills, back to front ----------------------------------------------
    haze = L("haze")
    n = len(RIDGES)
    for i, (spec, (c_top, c_foot)) in enumerate(zip(RIDGES, p["hills"])):
        ry = ridge_y(xs, spec)[None, :]
        depth = Y - ry  # >0 inside the hill
        mask = smoothstep(-0.9 * px, 0.9 * px, depth)
        # body: ridge colour → foot colour over ~0.18 h
        body = lerp(np.broadcast_to(to_lin(hexc(c_top)), (h, w, 3)),
                    np.broadcast_to(to_lin(hexc(c_foot)), (h, w, 3)),
                    smoothstep(0.0, 0.20, depth))
        # atmospheric haze: far hills melt into the glow near the sun
        near_sun = np.exp(-((X - SUN["x"]) / 0.55) ** 2)
        haze_amt = (0.38 * (n - 1 - i) / (n - 1)) * (0.45 + 0.55 * near_sun) * (1 - smoothstep(0.0, 0.10, depth))
        body = lerp(body, np.broadcast_to(haze, (h, w, 3)), haze_amt)
        # rim light along the ridge, strongest towards the sun
        rim = np.exp(-np.maximum(depth, 0) / (2.2 * px * (1 + 0.6 * i))) * np.exp(-((X - SUN["x"]) / 0.38) ** 2)
        body = lerp(body, np.broadcast_to(L("rim"), (h, w, 3)), rim * p["rim_strength"] * (1.0 - 0.18 * i))
        img = lerp(img, body, mask)

    # very soft vignette at the corners, keeps the eye centred
    vx = X / (aspect / 2)
    vig = (vx * vx * 0.6 + (Y - 0.55) ** 2 * 0.8)
    vig_amt = smoothstep(0.25, 1.1, vig) * (0.05 if mode == "light" else 0.18)
    img = img * (1 - vig_amt[..., None]) if mode == "dark" else lerp(img, np.broadcast_to(to_lin(hexc("#EFE9E1")), (h, w, 3)), vig_amt)

    # ---- encode: sRGB + triangular grain/dither -----------------------------
    srgb = to_srgb(img) * 255.0
    rng = np.random.default_rng(seed + w)
    noise = (rng.random((h, w, 1), dtype=np.float32) - rng.random((h, w, 1), dtype=np.float32)) * p["grain"]
    srgb = srgb + noise
    return Image.fromarray(np.clip(np.round(srgb), 0, 255).astype(np.uint8), "RGB")


def save_jpeg(im, path):
    im.save(path, "JPEG", quality=88, optimize=True, progressive=True, subsampling="4:4:4")
    print(f"  {os.path.basename(path):32s} {im.size[0]}x{im.size[1]}  {os.path.getsize(path) / 1024:7.0f} KiB")


def blurred(full, mode, seed=11):
    """Small pre-blurred copy (~30 px blur at 3840 wide) for the lock screen and
    for cheap glass-blur simulation; scaled up smoothly at runtime."""
    small = full.resize(BLUR_SIZE, Image.LANCZOS)
    arr = np.asarray(small.filter(ImageFilter.GaussianBlur(7.5)), np.float32)
    rng = np.random.default_rng(seed)
    arr = arr + (rng.random(arr.shape[:2] + (1,), dtype=np.float32) - rng.random(arr.shape[:2] + (1,), dtype=np.float32)) * 0.8
    return Image.fromarray(np.clip(np.round(arr), 0, 255).astype(np.uint8), "RGB")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=HERE)
    ap.add_argument("--preview", action="store_true", help="also write small PNG previews to /tmp/lugh-wallpaper-preview/")
    ap.add_argument("--only", choices=["light", "dark"])
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    for mode in (["light", "dark"] if not a.only else [a.only]):
        for w, h in SIZES:
            im = render(w, h, mode)
            save_jpeg(im, os.path.join(a.out, f"dawn-{mode}-{w}x{h}.jpg"))
            if (w, h) == SIZES[0]:
                save_jpeg(blurred(im, mode), os.path.join(a.out, f"dawn-{mode}-blur.jpg"))
                if a.preview:
                    os.makedirs("/tmp/lugh-wallpaper-preview", exist_ok=True)
                    im.resize((1920, 1080), Image.LANCZOS).save(f"/tmp/lugh-wallpaper-preview/{mode}.png")


if __name__ == "__main__":
    main()
