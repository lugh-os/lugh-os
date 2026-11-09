#!/usr/bin/env bash
# Regenerate the generated assets of the Lugh GRUB theme (branding/grub/):
#
#   logo.png                    copy of branding/logo/png/lugh-logo-128.png
#   select_{nw,n,ne,w,c,e,sw,s,se}.png
#                               selected menu item: amber #E8962E, 8 px radius
#   terminal_box_*.png          edit/command-line panel: black (gfxterm paints
#                               the text cells black anyway), 8 px radius
#   timeout_bar_*.png           timeout bar track: #E4E1DA, 3 px tall between
#                               transparent 12/13 px pads (GRUB forces >= 28 px)
#   timeout_hl_*.png            timeout bar fill: #E8962E
#   inter-regular-16.pf2        "Inter Regular 16"   (footer, countdown)
#   inter-regular-24.pf2        "Inter Regular 24"   (menu items)
#   inter-semibold-24.pf2       "Inter SemiBold Regular 24" (selected menu item;
#                               grub-mkfont appends the style "Regular" to -n)
#
# The output is committed, so building the package or the ISO never runs this.
#
# Needs: grub-mkfont (grub-common), python3, and the static Inter OTFs
# (Inter-Regular.otf, Inter-SemiBold.otf). They are looked up in $INTER_DIR,
# then ~/.local/share/fonts/inter, /usr/share/fonts/opentype/inter.
# Inter is under the SIL OFL 1.1 (see FONT-LICENSE).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRANDING="$(dirname "$HERE")"

die() { printf 'make-assets: %s\n' "$*" >&2; exit 1; }

command -v grub-mkfont >/dev/null || die "grub-mkfont not found (apt install grub-common)"
command -v python3 >/dev/null || die "python3 not found"

inter_dir=""
for d in "${INTER_DIR:-}" "$HOME/.local/share/fonts/inter" /usr/share/fonts/opentype/inter; do
  if [[ -n "$d" && -f "$d/Inter-Regular.otf" && -f "$d/Inter-SemiBold.otf" ]]; then
    inter_dir="$d"
    break
  fi
done
[[ -n "$inter_dir" ]] || die "Inter-Regular.otf/Inter-SemiBold.otf not found; set INTER_DIR"

# Printable ASCII, Latin-1, Latin Extended-A, general punctuation (dashes,
# quotes, bullet, ellipsis), the euro sign and the arrows used in the footer.
# Anything else falls back to GRUB's unicode.pf2 when it is loaded.
RANGE="0x20-0x7E,0xA0-0x17F,0x2010-0x2027,0x20AC-0x20AC,0x2190-0x2193"

mkfont() { # <otf> <size> <out> [grub-mkfont options]
  local otf="$1" size="$2" out="$3"
  shift 3
  # grub-mkfont warns about every OpenType feature it does not use; hide that.
  grub-mkfont --range="$RANGE" --size="$size" --output="$HERE/$out" "$@" \
    "$inter_dir/$otf" 2> >(grep -v 'unsupported font feature' >&2)
}
mkfont Inter-Regular.otf 16 inter-regular-16.pf2
mkfont Inter-Regular.otf 24 inter-regular-24.pf2
# Without --name, the SemiBold face would also be called "Inter Regular 24".
mkfont Inter-SemiBold.otf 24 inter-semibold-24.pf2 --name="Inter SemiBold"

logo="$BRANDING/logo/png/lugh-logo-128.png"
[[ -f "$logo" ]] || die "$logo missing (run scripts/render-brand-assets.sh)"
cp "$logo" "$HERE/logo.png"

python3 -I - "$HERE" <<'PY'
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

def rounded(w, h, r, color, ss=8):
    """Anti-aliased rounded rectangle filling w x h, as a flat RGBA list."""
    rr, gg, bb = (int(color[i:i + 2], 16) for i in (1, 3, 5))
    px = []
    for y in range(h):
        for x in range(w):
            hit = 0
            for sy in range(ss):
                for sx in range(ss):
                    fx = x + (sx + 0.5) / ss
                    fy = y + (sy + 0.5) / ss
                    cx = min(max(fx, r), w - r)
                    cy = min(max(fy, r), h - r)
                    if (fx - cx) ** 2 + (fy - cy) ** 2 <= r * r:
                        hit += 1
            px += [rr, gg, bb, round(255 * hit / (ss * ss))]
    return px

def nine_slice(prefix, color, r=8):
    """Split a (2r+1)-square rounded box into GRUB's 9 styled-box pixmaps."""
    n = 2 * r + 1
    full = rounded(n, n, r, color)
    cols = {"w": (0, r), "c": (r, 1), "e": (r + 1, r)}
    rows = {"n": (0, r), "c": (r, 1), "s": (r + 1, r)}
    for rk, (y0, hh) in rows.items():
        for ck, (x0, ww) in cols.items():
            name = {"nw": "nw", "nc": "n", "ne": "ne", "cw": "w", "cc": "c",
                    "ce": "e", "sw": "sw", "sc": "s", "se": "se"}[rk + ck]
            px = []
            for y in range(y0, y0 + hh):
                px += full[(y * n + x0) * 4:(y * n + x0 + ww) * 4]
            png(f"{out}/{prefix}_{name}.png", ww, hh, px)

nine_slice("select", "#E8962E")
nine_slice("terminal_box", "#000000")

# Timeout progress bar. GRUB 2.12 makes a progress bar at least 28 px tall
# whatever the theme says (gui_progress_bar.c), so the track pixmaps carry
# transparent 12 px (top) and 13 px (bottom) borders: 28 - 25 = a 3 px line.
# The fill is drawn with highlight_overlay, inside the track's content area.
def solid(color, a=255):
    return [int(color[i:i + 2], 16) for i in (1, 3, 5)] + [a]

clear = [0, 0, 0, 0]
for name, (w, h) in {"nw": (1, 12), "n": (1, 12), "ne": (1, 12),
                     "w": (1, 1), "c": (1, 1), "e": (1, 1),
                     "sw": (1, 13), "s": (1, 13), "se": (1, 13)}.items():
    px = solid("#E4E1DA") if h == 1 else clear * (w * h)
    png(f"{out}/timeout_bar_{name}.png", w, h, px)
for name in ("nw", "n", "ne", "w", "c", "e", "sw", "s", "se"):
    png(f"{out}/timeout_hl_{name}.png", 1, 1, solid("#E8962E") if name == "c" else clear)
PY

echo "make-assets: GRUB theme assets written to $HERE"
