#!/usr/bin/env bash
# Regenerate the generated images of the Lugh Plymouth theme (branding/plymouth/lugh/):
#
#   logo.png, logo-128.png   copies of branding/logo/png/lugh-logo-{256,128}.png
#   progress-track.png       1x1 #E4E1DA, stretched into the progress line track
#   progress-fill.png        1x1 #E8962E, stretched into the progress line fill
#   entry.png, entry@2x.png  passphrase field: #FFFFFF, 1 px #DEDAD2 border,
#                            8 px radius, 320x40 (640x80 at 2x)
#   bullet.png, bullet@2x.png  passphrase bullet: #1C1B19 dot, 8 px (16 px)
#
# The output is committed, so building the package never runs this.
# Needs: python3.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
THEME="$HERE/lugh"
LOGO="$(dirname "$HERE")/logo/png"

for s in 128 256; do
  [[ -f "$LOGO/lugh-logo-$s.png" ]] ||
    { echo "make-assets: $LOGO/lugh-logo-$s.png missing (run scripts/render-brand-assets.sh)" >&2; exit 1; }
done
cp "$LOGO/lugh-logo-256.png" "$THEME/logo.png"
cp "$LOGO/lugh-logo-128.png" "$THEME/logo-128.png"

python3 -I - "$THEME" <<'PY'
import struct, sys, zlib

out = sys.argv[1]

def png(path, w, h, pixels):
    """Write an 8-bit RGBA PNG with no timestamps (reproducible)."""
    raw = b"".join(b"\x00" + bytes(pixels[y * w * 4:(y + 1) * w * 4]) for y in range(h))
    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data))
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)))
        f.write(chunk(b"IDAT", zlib.compress(raw, 9)))
        f.write(chunk(b"IEND", b""))

def rgb(color):
    return [int(color[i:i + 2], 16) for i in (1, 3, 5)]

def coverage(x, y, w, h, r, inset, ss):
    """Fraction of pixel (x, y) inside a rounded rect inset by `inset`."""
    x0, y0, x1, y1 = inset, inset, w - inset, h - inset
    rr = max(r - inset, 0)
    hit = 0
    for sy in range(ss):
        for sx in range(ss):
            fx = x + (sx + 0.5) / ss
            fy = y + (sy + 0.5) / ss
            if not (x0 <= fx <= x1 and y0 <= fy <= y1):
                continue
            cx = min(max(fx, x0 + rr), x1 - rr)
            cy = min(max(fy, y0 + rr), y1 - rr)
            if (fx - cx) ** 2 + (fy - cy) ** 2 <= rr * rr:
                hit += 1
    return hit / (ss * ss)

def box(w, h, r, fill, border=None, bw=0, ss=6):
    """Anti-aliased rounded box, optionally with a border of width bw."""
    f, b = rgb(fill), rgb(border or fill)
    px = []
    for y in range(h):
        for x in range(w):
            outer = coverage(x, y, w, h, r, 0, ss)
            inner = coverage(x, y, w, h, r, bw, ss) if bw else outer
            if outer == 0:
                px += [0, 0, 0, 0]
                continue
            c = [(b[i] * (outer - inner) + f[i] * inner) / outer for i in range(3)]
            px += [round(v) for v in c] + [round(255 * outer)]
    return px

png(f"{out}/progress-track.png", 1, 1, rgb("#E4E1DA") + [255])
png(f"{out}/progress-fill.png", 1, 1, rgb("#E8962E") + [255])
for suffix, s in (("", 1), ("@2x", 2)):
    png(f"{out}/entry{suffix}.png", 320 * s, 40 * s,
        box(320 * s, 40 * s, 8 * s, "#FFFFFF", "#DEDAD2", 1 * s))
    png(f"{out}/bullet{suffix}.png", 8 * s, 8 * s, box(8 * s, 8 * s, 4 * s, "#1C1B19"))
PY

echo "make-assets: Plymouth theme images written to $THEME"
