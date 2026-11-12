#!/usr/bin/env python3
"""Pre-render the 9-patch soft shadows used by Shadow.qml.

    python3 ui/components/Lugh/UI/assets/make-shadows.py

Writes, next to this script:
  shadows/<level>-r<radius>.png   rounded-rect 9-patch, one per level/radius
  shadows/<level>-p<height>.png   pill (radius = height / 2) 3-patch, one per
                                  level/height
  shadows.js                      geometry table read by Shadow.qml

Each shadow is two Gaussian layers composited together: a tight contact
shadow just under the edge and a wide ambient one dropped by the level's y
offset (Theme.elevation*.y). The inside of the casting shape (inset half a
pixel so the shadow tucks under the target's antialiased edge) is cut out, so
translucent surfaces (GlassPanel) never get a grey cast under them, and the
cut-out has exactly the target's corner radius, so no shadow core peeks out
past a corner (the "second shape" behind every surface came from a cut-out
whose corners did not match the target).

Alpha is normalized per level so that the darkest pixel *outside* the shape is
255: Theme.elevation*.opacity is then exactly the peak alpha the shadow puts
on screen. Keep it under the compositor's blur threshold (Hyprland layer rule
`ignore_alpha`), or the shadow gets a blurred backdrop of its own.

Rect images: the source rect is just large enough that the stretched middle
row and column sit outside every corner's influence (radius + 2 sigma), so
stretching to any larger size is seamless; smaller targets are drawn by
Shadow.qml as four clipped corner quadrants. Pill images are baked at the
pill's exact height (Shadow.qml scales them uniformly to the target height, a
pill scaled is still a pill) and only stretch horizontally. Requires numpy
and Pillow.
"""
import math
import os

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "shadows")

# (sigma px, y offset px, weight). Keep the ambient y in sync with
# Theme.elevation*.y (2 / 6 / 12).
LEVELS = {
    "menu":    [(1.2, 1, 0.60), (5.0, 2, 0.85)],
    "popover": [(1.5, 1, 0.50), (10.0, 6, 0.90)],
    "window":  [(2.5, 2, 0.45), (18.0, 12, 0.95)],
}
# Corner radii baked; Shadow.qml picks the smallest one >= the target's
# radius (a rounder cut-out never lets the shadow out past a corner). Covers
# Theme.radius* (6/10/14/20) and every even radius up to 32.
RADII = list(range(0, 33, 2)) + [40, 48]
# Pill heights baked; Shadow.qml picks the nearest and scales it.
PILLS = [12, 16, 20, 24, 28, 32, 36, 40, 44, 48, 56, 64, 72, 80, 96]
SS = 4  # supersampling for the rounded-rect masks
HOLE_INSET = 0.5


def rrect_mask(w, h, x0, y0, rw, rh, r):
    """Antialiased coverage of a rounded rect (x0, y0, rw, rh, r) in a w*h image."""
    ys = (np.arange(h * SS) + 0.5) / SS
    xs = (np.arange(w * SS) + 0.5) / SS
    X, Y = np.meshgrid(xs, ys)
    # distance outside the rounded rect (signed-distance style, r clamped)
    r = max(0.0, min(r, rw / 2, rh / 2))
    cx = np.clip(X, x0 + r, x0 + rw - r)
    cy = np.clip(Y, y0 + r, y0 + rh - r)
    inside_box = (X >= x0) & (X <= x0 + rw) & (Y >= y0) & (Y <= y0 + rh)
    m = inside_box & (np.hypot(X - cx, Y - cy) <= r) if r > 0 else inside_box
    m = m.astype(np.float64)
    return m.reshape(h, SS, w, SS).mean(axis=(1, 3))


def gaussian_blur(a, sigma):
    if sigma <= 0:
        return a
    k = int(math.ceil(3.5 * sigma))
    t = np.arange(-k, k + 1)
    g = np.exp(-(t * t) / (2 * sigma * sigma))
    g /= g.sum()
    # zero-pad so the kernel may be longer than the image (thin pill strips)
    a = np.pad(a, k)
    a = np.apply_along_axis(lambda r: np.convolve(r, g, mode="same"), 1, a)
    a = np.apply_along_axis(lambda c: np.convolve(c, g, mode="same"), 0, a)
    return a[k:-k, k:-k]


def shadow_alpha(layers, W, H, x0, y0, rw, rh, radius):
    keep = np.ones((H, W))
    for s, dy, wgt in layers:
        m = rrect_mask(W, H, x0, y0 + dy, rw, rh, radius)
        keep *= 1.0 - wgt * gaussian_blur(m, s)
    alpha = 1.0 - keep
    shape = rrect_mask(W, H, x0, y0, rw, rh, radius)
    hole = rrect_mask(W, H, x0 + HOLE_INSET, y0 + HOLE_INSET,
                      rw - 2 * HOLE_INSET, rh - 2 * HOLE_INSET,
                      max(0.0, radius - HOLE_INSET))
    # peak alpha outside the shape (pixels the shape does not fully cover)
    outside = float((alpha * (1.0 - shape)).max())
    return alpha * (1.0 - hole), outside


def margins(layers):
    """How far the shadow reaches past the shape on each side."""
    ml = max(math.ceil(3 * s) for s, _, _ in layers)
    mt = max(0, max(math.ceil(3 * s - dy) for s, dy, _ in layers))
    mb = max(math.ceil(3 * s + dy) for s, dy, _ in layers)
    return ml, mt, ml, mb


def render_rect(level, radius):
    layers = LEVELS[level]
    ml, mt, mr, mb = margins(layers)
    # rows/columns from the rect edge that a corner influences
    cx = max(math.ceil(radius + 2.0 * s) for s, _, _ in layers)
    ct = max(math.ceil(radius + 2.0 * s + dy) for s, dy, _ in layers)
    cb = max(math.ceil(radius + 2.0 * s - dy) for s, dy, _ in layers)
    cx, ct, cb = max(cx, radius + 1), max(ct, radius + 1), max(cb, radius + 1)
    rw, rh = 2 * cx + 2, ct + cb + 2
    W, H = ml + rw + mr, mt + rh + mb
    alpha, outside = shadow_alpha(layers, W, H, ml, mt, rw, rh, radius)
    # BorderImage borders in image px (the 2 px middle stretches); margins =
    # how far the image extends past the target on each side.
    geo = {"ml": ml, "mt": mt, "mr": mr, "mb": mb,
           "bl": ml + cx, "br": mr + cx, "bt": mt + ct, "bb": mb + cb}
    return f"r{radius}", alpha, outside, geo


def render_pill(level, height):
    layers = LEVELS[level]
    ml, mt, mr, mb = margins(layers)
    radius = height / 2
    cx = max(math.ceil(radius + 2.0 * s) for s, _, _ in layers)
    rw = 2 * cx + 2
    W, H = ml + rw + mr, mt + height + mb
    alpha, outside = shadow_alpha(layers, W, H, ml, mt, rw, height, radius)
    # No vertical middle: the image is drawn at exactly the baked height.
    geo = {"ml": ml, "mt": mt, "mr": mr, "mb": mb,
           "bl": ml + cx, "br": mr + cx, "bt": mt + height // 2, "bb": mb + height - height // 2}
    return f"p{height}", alpha, outside, geo


def main():
    os.makedirs(OUT, exist_ok=True)
    for f in os.listdir(OUT):
        if f.endswith(".png"):
            os.remove(os.path.join(OUT, f))
    table = {}
    for lv in LEVELS:
        shots = [render_rect(lv, r) for r in RADII] + [render_pill(lv, h) for h in PILLS]
        peak = max(o for _, _, o, _ in shots)
        table[lv] = {}
        for key, alpha, _, geo in shots:
            a8 = np.clip(np.round(alpha / peak * 255), 0, 255).astype(np.uint8)
            img = np.zeros(a8.shape + (4,), np.uint8)
            img[..., 3] = a8
            Image.fromarray(img, "RGBA").save(
                os.path.join(OUT, f"{lv}-{key}.png"), optimize=True)
            table[lv][key] = geo
    lines = [
        "// Generated by make-shadows.py: do not edit by hand.",
        ".pragma library",
        "",
        f"var radii = {RADII};",
        f"var pills = {PILLS};",
        "var geometry = {",
    ]
    for lv, per in table.items():
        lines.append(f"    \"{lv}\": {{")
        for key, g in per.items():
            fields = ", ".join(f"{k}: {v}" for k, v in g.items())
            lines.append(f"        \"{key}\": {{ {fields} }},")
        lines.append("    },")
    lines += ["};", ""]
    with open(os.path.join(HERE, "shadows.js"), "w") as f:
        f.write("\n".join(lines))
    n = sum(len(v) for v in table.values())
    print(f"wrote {n} shadows to {OUT}")


if __name__ == "__main__":
    main()
