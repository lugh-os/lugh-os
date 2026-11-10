#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Render the Lugh wallpaper set: Dawn (default), Tide and Ember, each as a
light and a dark variant of the same scene.

    python3 branding/wallpapers/make-wallpapers.py                  # everything (~5 min)
    python3 branding/wallpapers/make-wallpapers.py --only tide      # one wallpaper
    python3 branding/wallpapers/make-wallpapers.py --only dawn --mode dark
    python3 branding/wallpapers/make-wallpapers.py --preview        # quarter-res PNGs + desktop
                                                                    # mocks in /tmp/lugh-wallpaper-preview/

Original, procedural art: every pixel is computed here from closed-form
functions (sums of sines with fixed phases), so the output is deterministic,
resolution-independent and uses no third-party image, texture or model. Needs
numpy and Pillow only (apt install python3-numpy python3-pil).

Each scene is rendered once at 5120x2880 in linear light, in horizontal strips
(float32, low memory, one wallpaper at a time), with analytic anti-aliasing on
every edge. The master is then scaled to the shipped sizes, film grain is
added (it is what keeps the soft gradients from banding after JPEG) and the
files are written as progressive 4:4:4 JPEGs, plus wallpapers.json.

Composition rules (DESIGN-SYSTEM §1-2, docs/design/lugh-mode.md):
  - the top ~7 % (islands) and bottom ~12 % (dock) stay calm and mid-contrast;
  - overall contrast is moderate so text on glass keeps AA
    (scripts/check-contrast.py samples the *-blur.jpg files);
  - warm neutrals + amber; Tide adds one cool counter-tone (teal / green-grey);
    no purple, indigo or violet; no text, no logo;
  - shapes live in height units centred on the width (x in [-8/9, 8/9],
    y in [0, 1] top to bottom), so the 16:10 file is a plain centre crop.
"""
import argparse
import json
import os
import time

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
MASTER = (5120, 2880)
SIZES = [(5120, 2880), (3840, 2160), (2560, 1600)]
BLUR_SIZE = (960, 540)
PREVIEW_DIR = "/tmp/lugh-wallpaper-preview"
TAU = 2 * np.pi
F = np.float32


# ---- colour and math helpers -----------------------------------------------

def lin(h):
    """'#RRGGBB' -> linear-light RGB."""
    h = h.lstrip("#")
    c = np.array([int(h[i:i + 2], 16) for i in (0, 2, 4)], np.float64) / 255.0
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4).astype(F)


def to_srgb(c):
    c = np.clip(c, 0.0, 1.0)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * np.power(c, 1 / 2.4) - 0.055).astype(F)


def sstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3 - 2 * t)


def mix(a, b, t):
    """a, b: (...,3) or (3,); t: (h,w) weight."""
    t = np.asarray(t, F)[..., None]
    return a + (b - a) * t


def gauss(x, s):
    return np.exp(-(x / s) ** 2)


def waves(x, rng, f0, n=4, lac=1.9, gain=0.5):
    """Smooth 1-D 'noise': n sines, fixed random phases. Returns (value, d/dx)."""
    v = np.zeros_like(x)
    dv = np.zeros_like(x)
    a, f = 1.0, f0
    for _ in range(n):
        ph = rng.uniform(0, TAU)
        ff = f * rng.uniform(0.85, 1.15)
        v += a * np.sin(TAU * ff * x + ph)
        dv += a * TAU * ff * np.cos(TAU * ff * x + ph)
        a *= gain
        f *= lac
    return v, dv


# ---- Dawn: a low sun behind long silk dunes ---------------------------------

DAWN = {
    "light": dict(
        sky=("#F6F3EE", "#F8EAD6", "#FAD4A0"), glow="#F4A640", glow_s=0.50, halo="#FFF0D0", halo_s=0.90,
        sun=("#FFFBF0", "#FFEFC8"), sun_a=1.0,
        # back -> front colour stops: (crest, foot)
        crest=("#F9DDB0", "#F2BC88", "#E8A47A", "#EDCDB2"),
        foot=("#EEC296", "#D4926C", "#C4805F", "#E8D3C0"),
        haze="#FCE2BC", haze_s=0.60, rim="#FFF6E2", rim_s=0.90, sheen="#FFE0AE", sheen_s=0.60,
        shadow="#9C5A40", shadow_s=0.50, line_s=0.40, lit=0.16, vig=("#EDE6DC", 0.07), grain=2.2,
    ),
    "dark": dict(
        sky=("#141312", "#191513", "#2A1D15"), glow="#B25A1C", glow_s=0.40, halo="#7A441B", halo_s=0.75,
        sun=("#EDB064", "#DC8A3A"), sun_a=0.96,
        crest=("#4A3222", "#35271E", "#2A201A", "#1E1A17"),
        foot=("#241C17", "#1A1614", "#161413", "#161413"),
        haze="#5A3820", haze_s=0.50, rim="#F2A552", rim_s=0.85, sheen="#B25E22", sheen_s=0.55,
        shadow="#0C0B0A", shadow_s=0.50, line_s=0.30, lit=0.30, vig=("#000000", 0.20), grain=2.8,
    ),
}
DAWN_SUN = (0.26, 0.598, 0.060)       # x, y, radius
DAWN_N = 9


def dawn_ridges(xs):
    """Ridge height y_i(x) and slope for every layer, back to front."""
    rng = np.random.default_rng(2026)
    out = []
    sx = DAWN_SUN[0]
    for i in range(DAWN_N):
        f = i / (DAWN_N - 1)
        base = 0.615 + 0.300 * f ** 1.25
        amp = 0.016 + 0.038 * np.sin(np.pi * min(f * 1.15, 1.0)) ** 1.2
        if i == DAWN_N - 1:
            amp = 0.012                       # the dock sits on this one: nearly flat
        w, dw = waves(xs + 3.1 * i, rng, f0=0.34 + 0.05 * (i % 3), n=3, lac=2.1, gain=0.42)
        y = base + amp * w
        dy = amp * dw
        if i < 3:                             # open a valley in the far dunes where the sun sits
            dip = 0.020 * (1 - i / 3)
            g = np.exp(-((xs - sx) / 0.30) ** 2)
            y = y + dip * g
            dy = dy + dip * g * (-2 * (xs - sx) / 0.30 ** 2)
        out.append((y.astype(F), dy.astype(F)))
    return out


def stops(cols, f):
    """Piecewise-linear interpolation through colour stops at f in [0,1]."""
    cs = [lin(c) for c in cols]
    p = f * (len(cs) - 1)
    k = min(int(p), len(cs) - 2)
    return cs[k] + (cs[k + 1] - cs[k]) * F(p - k)


def dawn(xs, ys, px, mode):
    p = DAWN[mode]
    X, Y = xs[None, :], ys[:, None]
    sx, sy, sr = DAWN_SUN
    h, w = len(ys), len(xs)

    # sky: calm paper at the top, warming to the horizon
    s0, s1, s2 = (lin(c) for c in p["sky"])
    img = mix(np.broadcast_to(s0, (h, w, 3)), s1, np.broadcast_to(sstep(0.06, 0.50, Y), (h, w)))
    img = mix(img, s2, np.broadcast_to(sstep(0.28, 0.64, Y) ** 1.3, (h, w)))
    d = np.sqrt((X - sx) ** 2 + ((Y - sy) * 1.9) ** 2)
    img = mix(img, lin(p["glow"]), np.exp(-(d / 0.42) ** 1.5) * p["glow_s"])
    img = mix(img, lin(p["halo"]), gauss(d, 0.15) * p["halo_s"])
    ds = np.sqrt((X - sx) ** 2 + (Y - sy) ** 2)
    disc = 1.0 - sstep(sr - 1.2 * px, sr + 1.2 * px, ds)
    suncol = mix(np.broadcast_to(lin(p["sun"][0]), (h, w, 3)), lin(p["sun"][1]), sstep(0.0, sr, ds) ** 2.5)
    img = mix(img, suncol, disc * p["sun_a"])

    ridges = dawn_ridges(xs)
    rng = np.random.default_rng(77)
    near = gauss(xs - sx, 0.62)[None, :]                    # how close (in x) to the sun
    near2 = 0.10 + 0.90 * gauss(xs - sx, 0.55)[None, :]
    side = np.tanh((sx - xs) / 0.10)                        # +1 left of the sun, -1 right
    for i, (ry, dry) in enumerate(ridges):
        f = i / (DAWN_N - 1)
        lw1, _ = waves(xs + 1.7 * i, rng, 0.55, n=3)        # always drawn: keeps the rng in step
        lw2, _ = waves(xs - 2.3 * i, rng, 0.40, n=3)
        le1, _ = waves(xs + 0.9 * i, rng, 0.45, n=2)
        le2, _ = waves(xs - 1.1 * i, rng, 0.60, n=2)
        d = Y - ry[None, :]
        if d.max() < -2 * px:
            continue
        dpos = np.maximum(d, 0)
        span = 0.050 + 0.075 * f
        body = mix(np.broadcast_to(stops(p["crest"], f), (h, w, 3)), stops(p["foot"], f),
                   sstep(0.0, span, dpos))
        # faces turned to the sun are a little brighter, the others fall into shade
        lit = np.tanh(9.0 * dry * side)[None, :]
        body = body * (1.0 + p["lit"] * lit * np.exp(-dpos / 0.14))[..., None]
        # distance haze: far dunes melt into the glow
        body = mix(body, lin(p["haze"]), p["haze_s"] * (1 - f) ** 1.6 * (0.35 + 0.65 * near) * np.ones_like(d))
        # light through the crest: a wide soft sheen and a fine bright rim
        body = mix(body, lin(p["sheen"]), p["sheen_s"] * (0.3 + 0.7 * near2) * (1 - 0.45 * f) * np.exp(-dpos / (0.020 + 0.026 * f)))
        body = mix(body, lin(p["rim"]), p["rim_s"] * near2 * (1 - 0.35 * f) * np.exp(-dpos / (0.0016 + 0.0012 * f)))
        # two fine specular threads following the fold, fading in and out
        for lw, le, off, wd in ((lw1, le1, 0.30, 0.0011), (lw2, le2, 0.62, 0.0016)):
            dl = d - span * (off + 0.10 * lw[None, :])
            env = sstep(0.1, 1.2, le + 0.6)[None, :] * near2
            body = mix(body, lin(p["sheen"]), p["line_s"] * (1 - 0.3 * f) * env * gauss(dl, wd * (1 + f)))
        # contact shadow cast by the dune in front
        if i < DAWN_N - 1:
            g = np.maximum(ridges[i + 1][0][None, :] - Y, 0)
            body = mix(body, lin(p["shadow"]), p["shadow_s"] * (0.55 + 0.45 * f) * np.exp(-g / (0.014 + 0.016 * f)))
        if i == DAWN_N - 1:                                  # dock zone: settle to one calm tone
            body = mix(body, stops(p["foot"], 1.0), np.broadcast_to(sstep(0.86, 0.93, Y), (h, w)) * 0.85)
        img = mix(img, body, sstep(-0.7 * px, 0.7 * px, d))

    vx = X / (8 / 9)
    vig = sstep(0.30, 1.15, vx * vx * 0.6 + (Y - 0.55) ** 2 * 0.8) * p["vig"][1]
    return mix(img, lin(p["vig"][0]), vig)


# ---- Tide: liquid glass ------------------------------------------------------

TIDE = {
    "light": dict(
        base=("#F3EEE6", "#EFE6DA"), lip="#FFFFFF", lip_s=0.90, shadow="#9C6A50", shadow_s=0.36,
        caust="#FFF6E4", caust_s=0.50,
        # back -> front: (tint, opacity)
        sheets=[("#FBF3E6", 0.80), ("#F4CE9A", 0.74), ("#779C94", 0.70), ("#E39E76", 0.74),
                ("#F6D9B2", 0.76), ("#EFE3D4", 0.86)],
        vig=("#E9E1D6", 0.05), grain=2.2,
    ),
    "dark": dict(
        base=("#181614", "#141312"), lip="#F2A655", lip_s=0.72, shadow="#070606", shadow_s=0.50,
        caust="#D98A3C", caust_s=0.30,
        sheets=[("#2C231C", 0.80), ("#7A4219", 0.62), ("#1D4B46", 0.66), ("#96531F", 0.58),
                ("#3B2A1E", 0.78), ("#1C1917", 0.88)],
        vig=("#000000", 0.20), grain=2.8,
    ),
}
# Each sheet is a sheet of glass whose upper edge (the lip) is a slow wave drawn
# along a line through a pivot left of the canvas; the lines fan out to the right.
# (angle in degrees, pivot y, wave amplitude, base frequency)
TIDE_SHEETS = [(-21.0, 0.44, 0.050, 0.42), (-13.5, 0.47, 0.060, 0.36), (-6.5, 0.50, 0.066, 0.47),
               (0.5, 0.54, 0.058, 0.40), (7.0, 0.58, 0.046, 0.52), (12.5, 0.63, 0.030, 0.45)]
TIDE_PIVOT_X = -1.15


def tide(xs, ys, px, mode):
    p = TIDE[mode]
    X, Y = xs[None, :].astype(F), ys[:, None].astype(F)
    h, w = len(ys), len(xs)
    b0, b1 = lin(p["base"][0]), lin(p["base"][1])
    img = mix(np.broadcast_to(b0, (h, w, 3)), b1, np.broadcast_to(sstep(0.0, 1.0, Y), (h, w)))
    calm = (sstep(0.035, 0.17, Y) * (1 - sstep(0.80, 0.93, Y))) * np.ones_like(X)
    rng = np.random.default_rng(1912)
    n = len(TIDE_SHEETS)
    for k, ((ang, py, amp, f0), (tint, op)) in enumerate(zip(TIDE_SHEETS, p["sheets"])):
        a = np.deg2rad(ang)
        u = (X - TIDE_PIVOT_X) * np.cos(a) + (Y - py) * np.sin(a)
        v = -(X - TIDE_PIVOT_X) * np.sin(a) + (Y - py) * np.cos(a)
        wv, dwv = waves(u, rng, f0, n=3, lac=1.8, gain=0.45)
        grow = sstep(0.0, 1.3, u)                        # the wave opens up away from the pivot
        s = (v - amp * grow * wv) / np.sqrt(1.0 + (amp * grow * dwv) ** 2)   # ~distance below the lip
        c1, _ = waves(u + 0.7, rng, 0.9, n=3)
        c2, _ = waves(u - 0.4, rng, 0.7, n=3)
        ce, _ = waves(u, rng, 0.5, n=2)
        sp = np.maximum(s, 0)
        # the shadow the sheet casts on what lies behind it
        img = mix(img, lin(p["shadow"]), p["shadow_s"] * calm * np.exp(np.minimum(s, 0) / 0.030) * (s < 0))
        # the glass itself: densest just under the lip, clearing with depth
        body = np.broadcast_to(lin(tint), (h, w, 3))
        floor = 0.90 if k == n - 1 else 0.42
        thick = floor + (1 - floor) * np.exp(-sp / (0.10 + 0.02 * k))
        body = mix(body, lin(p["lip"]), 0.50 * np.exp(-sp / 0.012))                     # light caught in the edge
        body = mix(body, lin(p["lip"]), p["lip_s"] * np.exp(-sp / 0.0016))              # the lip
        body = mix(body, lin(p["lip"]), 0.30 * p["lip_s"] * gauss(s - 0.0085, 0.0011))  # its inner edge
        # caustic threads: light bent through the lip, wandering below it
        env = sstep(-0.2, 1.0, ce)
        for cw, off, wd, st in ((c1, 0.050, 0.0030, 1.0), (c2, 0.105, 0.0060, 0.6)):
            body = mix(body, lin(p["caust"]), p["caust_s"] * st * env * gauss(s - off - 0.016 * cw, wd))
        cover = sstep(-0.7 * px, 0.7 * px, s) * op * thick * calm
        img = mix(img, body, cover)
    vx = X / (8 / 9)
    vig = sstep(0.35, 1.2, vx * vx * 0.6 + (Y - 0.5) ** 2 * 0.9) * p["vig"][1]
    return mix(img, lin(p["vig"][0]), np.broadcast_to(vig, (h, w)))


# ---- Ember: a quiet sun and its rings ----------------------------------------

EMBER = {
    "light": dict(
        bg=("#F7F1E7", "#EFE7DC"), glow="#FBDDAE", glow_s=0.55, sun=("#FFF9EC", "#FFE9BC"),
        shell="#F6C88A", shell_s=0.34, rim="#FFFFFF", rim_s=0.95, bloom=0.55, grain=2.0,
    ),
    "dark": dict(
        bg=("#1A1614", "#121110"), glow="#7A3D15", glow_s=0.42, sun=("#E39C4B", "#D48434"),
        shell="#8F4A1B", shell_s=0.24, rim="#F0A050", rim_s=0.65, bloom=0.60, grain=2.8,
    ),
}
EMBER_C = (0.0, 0.47, 0.082)
EMBER_SHELLS = (0.138, 0.196, 0.262, 0.338)


def ember(xs, ys, px, mode):
    p = EMBER[mode]
    X, Y = xs[None, :].astype(F), ys[:, None].astype(F)
    h, w = len(ys), len(xs)
    cx, cy, r0 = EMBER_C
    r = np.sqrt((X - cx) ** 2 + (Y - cy) ** 2)
    img = mix(np.broadcast_to(lin(p["bg"][0]), (h, w, 3)), lin(p["bg"][1]), sstep(0.15, 1.0, r))
    img = mix(img, lin(p["glow"]), p["glow_s"] * gauss(r, 0.30))

    rng = np.random.default_rng(404)
    for k in reversed(range(len(EMBER_SHELLS))):          # large shells first
        R = EMBER_SHELLS[k]
        # each shell drifts a little off centre and is slightly out of round
        ox, oy = cx + 0.007 * (k + 1), cy + 0.011 * (k + 1)
        dx, dy = X - ox, Y - oy
        rr = np.sqrt(dx * dx + dy * dy)
        th = np.arctan2(dy, dx)
        eps = sum(rng.uniform(0.004, 0.010) / n * np.sin(n * th + rng.uniform(0, TAU)) for n in (2, 3, 5))
        q = rr / (R * (1.0 + eps))
        s = (1.0 - q) * R                                   # distance inside the rim
        inside = sstep(-0.8 * px, 0.8 * px, s)
        fill = p["shell_s"] * (0.50 + 0.50 * np.clip(q, 0, 1) ** 5)
        img = mix(img, lin(p["shell"]), inside * fill)
        arc = 0.5 + 0.5 * np.cos(th - (-2.2 + 0.5 * k))     # the rim catches light on its upper left
        rim = np.exp(-np.maximum(s, 0) / 0.0015) * inside
        img = mix(img, lin(p["rim"]), p["rim_s"] * (0.12 + 0.88 * arc ** 2) * rim)

    # two hairline rings far out, barely there
    for R, a in ((0.405, 0.30), (0.452, 0.16)):
        dx, dy = X - cx - 0.03, Y - cy - 0.045
        th = np.arctan2(dy, dx)
        arc = (0.5 + 0.5 * np.cos(th + 2.0)) ** 2 * sstep(0.03, 0.12, Y) * (1 - sstep(0.84, 0.93, Y))
        img = mix(img, lin(p["rim"]), p["rim_s"] * a * arc * gauss(np.sqrt(dx * dx + dy * dy) - R, 0.0011))

    # the sun: flat and luminous, a soft edge and a tight bloom
    bloom = np.exp(-np.maximum(r - r0, 0) / 0.020)
    img = mix(img, lin(p["sun"][1]), p["bloom"] * bloom)
    disc = 1.0 - sstep(r0 - 0.0025, r0 + 0.0025, r)
    sun = mix(np.broadcast_to(lin(p["sun"][0]), (h, w, 3)), lin(p["sun"][1]), sstep(0.2 * r0, r0, r) ** 1.5)
    return mix(img, sun, disc)


# ---- pipeline ----------------------------------------------------------------

SCENES = {
    "dawn": dict(title="Dawn", fn=dawn, seed=7,
                 blurb="A low sun behind long silk dunes. The default Lugh wallpaper."),
    "tide": dict(title="Tide", fn=tide, seed=19,
                 blurb="Liquid glass: slow folds of warm light with a deep teal counter-tone."),
    "ember": dict(title="Ember", fn=ember, seed=31,
                  blurb="A quiet sun and its rings. Minimal, made for focus."),
}


def render_master(name, mode, size=MASTER, strip=180):
    """The scene in sRGB-encoded float32 (h, w, 3), rendered strip by strip."""
    w, h = size
    fn = SCENES[name]["fn"]
    xs = ((np.arange(w, dtype=np.float64) + 0.5) / h - (w / h) / 2).astype(F)
    ys_all = ((np.arange(h, dtype=np.float64) + 0.5) / h).astype(F)
    out = np.empty((h, w, 3), F)
    for y0 in range(0, h, strip):
        out[y0:y0 + strip] = to_srgb(fn(xs, ys_all[y0:y0 + strip], 1.0 / h, mode))
    return out


def scaled(master, size):
    """Centre-crop the master to the target aspect, then Lanczos-resize (float)."""
    mh, mw = master.shape[:2]
    w, h = size
    cw = min(mw, int(round(mh * w / h)))
    ch = min(mh, int(round(mw * h / w)))
    x0, y0 = (mw - cw) // 2, (mh - ch) // 2
    crop = master[y0:y0 + ch, x0:x0 + cw]
    if (cw, ch) == (w, h):
        return crop
    return np.stack([np.asarray(Image.fromarray(np.ascontiguousarray(crop[..., c]), "F").resize((w, h), Image.LANCZOS))
                     for c in range(3)], -1)


def grained(arr, amount, seed):
    """sRGB float (0..1) -> 8-bit image with triangular film grain / dither."""
    h, w = arr.shape[:2]
    rng = np.random.default_rng(seed)
    n = (rng.random((h, w, 1), dtype=F) - rng.random((h, w, 1), dtype=F)) * F(amount)
    return Image.fromarray(np.clip(np.round(arr * 255.0 + n), 0, 255).astype(np.uint8), "RGB")


def save_jpeg(im, path, quality=90):
    im.save(path, "JPEG", quality=quality, optimize=True, progressive=True, subsampling=0)
    print(f"  {os.path.basename(path):30s} {im.size[0]}x{im.size[1]}  {os.path.getsize(path) / 1024:7.0f} KiB")


def blurred(arr, seed):
    """Small pre-blurred copy (~30 px blur at 3840 wide) for the lock screen and
    cheap glass backdrops; scaled up smoothly at runtime."""
    small = Image.fromarray(np.clip(np.round(scaled(arr, BLUR_SIZE) * 255.0), 0, 255).astype(np.uint8), "RGB")
    a = np.asarray(small.filter(ImageFilter.GaussianBlur(7.5)), F)
    rng = np.random.default_rng(seed)
    a = a + (rng.random(a.shape[:2] + (1,), dtype=F) - rng.random(a.shape[:2] + (1,), dtype=F)) * 0.8
    return Image.fromarray(np.clip(np.round(a), 0, 255).astype(np.uint8), "RGB")


def mock_desktop(im, mode):
    """The preview with the Lugh-mode islands and dock drawn on it: glass =
    blurred wallpaper + tint (white 72 % / charcoal 82 %), on a 1600x900 screen."""
    W, H = 1600, 900
    base = im.resize((W, H), Image.LANCZOS)
    blur = base.filter(ImageFilter.GaussianBlur(12))
    tint = (255, 255, 255) if mode == "light" else (28, 27, 25)
    glass = Image.blend(blur, Image.new("RGB", (W, H), tint), 0.72 if mode == "light" else 0.82)
    mask = Image.new("L", (W * 2, H * 2), 0)
    d = ImageDraw.Draw(mask)
    caps = [(10, 8, 250, 44), (W // 2 - 85, 8, W // 2 + 85, 44), (W - 170, 8, W - 10, 44),
            (W // 2 - 230, H - 70, W // 2 + 230, H - 10)]
    for x0, y0, x1, y1 in caps:
        d.rounded_rectangle((x0 * 2, y0 * 2, x1 * 2, y1 * 2), radius=(y1 - y0), fill=255)
    out = Image.composite(glass, base, mask.resize((W, H), Image.LANCZOS))
    d = ImageDraw.Draw(out)
    ink, muted = ((28, 27, 25), (95, 91, 84)) if mode == "light" else ((237, 235, 230), (162, 157, 148))
    d.rounded_rectangle((24, 22, 110, 30), 4, fill=ink)
    for k in range(4):
        d.ellipse((150 + k * 20, 21, 160 + k * 20, 31), fill=muted if k else (232, 150, 46))
    d.rounded_rectangle((W // 2 - 60, 22, W // 2 + 60, 30), 4, fill=ink)
    for k in range(4):
        d.rounded_rectangle((W - 150 + k * 34, 18, W - 134 + k * 34, 34), 4, fill=muted)
    for k in range(8):
        x = W // 2 - 214 + k * 54
        d.rounded_rectangle((x, H - 62, x + 44, H - 18), 11, fill=(232, 150, 46) if k == 0 else muted)
    return out


def manifest(out):
    data = {
        "license": "CC-BY-SA-4.0",
        "copyright": "2026 Lugh Developers",
        "default": "dawn",
        "sizes": [f"{w}x{h}" for w, h in SIZES] + ["blur"],
        "pattern": "{name}-{variant}-{size}.jpg",
        "wallpapers": [dict(name=n, title=s["title"], description=s["blurb"], uri=f"lugh://wallpapers/{n}",
                            variants={m: {**{f"{w}x{h}": f"{n}-{m}-{w}x{h}.jpg" for w, h in SIZES},
                                          "blur": f"{n}-{m}-blur.jpg"} for m in ("light", "dark")})
                       for n, s in SCENES.items()
                       if os.path.exists(os.path.join(out, f"{n}-light-{MASTER[0]}x{MASTER[1]}.jpg"))],
    }
    with open(os.path.join(out, "wallpapers.json"), "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2)
        fh.write("\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--out", default=HERE)
    ap.add_argument("--only", choices=list(SCENES), help="render one wallpaper")
    ap.add_argument("--mode", choices=["light", "dark"], help="render one variant")
    ap.add_argument("--preview", action="store_true",
                    help=f"quarter-res PNG + desktop mock in {PREVIEW_DIR}/ instead of the JPEGs")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    for name in ([a.only] if a.only else list(SCENES)):
        for mode in ([a.mode] if a.mode else ["light", "dark"]):
            t0 = time.time()
            seed = SCENES[name]["seed"] + (0 if mode == "light" else 100)
            if a.preview:
                os.makedirs(PREVIEW_DIR, exist_ok=True)
                m = render_master(name, mode, (MASTER[0] // 4, MASTER[1] // 4))
                im = grained(m, DAWN[mode]["grain"] * 0.5, seed)
                im.save(f"{PREVIEW_DIR}/{name}-{mode}.png")
                mock_desktop(im, mode).save(f"{PREVIEW_DIR}/{name}-{mode}-mock.jpg", quality=92)
                print(f"  {PREVIEW_DIR}/{name}-{mode}.png (+ -mock.jpg)  {time.time() - t0:.1f} s")
                continue
            print(f"{SCENES[name]['title']} ({mode})")
            m = render_master(name, mode)
            grain = {"dawn": DAWN, "tide": TIDE, "ember": EMBER}[name][mode]["grain"]
            for i, (w, h) in enumerate(SIZES):
                save_jpeg(grained(scaled(m, (w, h)), grain, seed + i), os.path.join(a.out, f"{name}-{mode}-{w}x{h}.jpg"))
            save_jpeg(blurred(m, seed + 9), os.path.join(a.out, f"{name}-{mode}-blur.jpg"), quality=88)
            del m
            print(f"  {time.time() - t0:.0f} s")
    if not a.preview:
        manifest(a.out)


if __name__ == "__main__":
    main()
