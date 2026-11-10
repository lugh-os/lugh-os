#!/usr/bin/env python3
"""WCAG 2.x contrast check for the LughUI design tokens (phase-1 acceptance 12).

    scripts/check-contrast.py                # every pair, light + dark, every accent
    scripts/check-contrast.py --failures     # only what fails (and advisories)
    scripts/check-contrast.py --json         # machine-readable result
    scripts/check-contrast.py --static       # skip the qml6 runtime cross-check

Tokens are parsed from ui/components/Lugh/UI/Theme.qml (light, dark, and the
six accent presets). When qml6 is available the script also loads Theme.qml in
an offscreen QML engine and reads back the values QML really produces; any
token whose runtime value differs from the source is a failure (and the
runtime value is what the ratios use, since that is what users see).

Pairs checked (DESIGN-SYSTEM §2, §7, §10):
  text            text / textMuted on bg, surface, surface2, surface3     4.5:1
  accent          accentText on bg / surface / selected rows             4.5:1
                  onAccent on accent (rest + pressed)                    4.5:1
  semantic        danger / success / info / warning on bg / surface      4.5:1
                  onDanger on danger (rest + pressed), badge fills       4.5:1
                  text on the ErrorBanner tint                           4.5:1
  tooltip         bg on text (inverted)                                  4.5:1
  glass           text / textMuted on Theme.glass composited over the
                  lightest and darkest region of every bundled
                  branding/wallpapers/*-<mode>-blur.jpg (needs PIL; else
                  assumes bg behind). This is island text at rest.       4.5:1
  island          text / textMuted (typeLabel) on a hovered and on an
                  active/pressed island, over every bundled wallpaper    4.5:1
  icontoggle      off: Theme.text icon on its translucent fill (rest,
                  hover, pressed) over glass over the lightest / darkest
                  wallpaper region, and over surface; busy arc           3:1
                  on: onAccent icon on accent, every preset; tone fills  3:1
  chip            selected: accentText (label + check) on the accent
                  tint; unselected: text on the neutral fill; both over
                  surface, bg and glass over the wallpaper extremes      4.5:1
  non-text        Toggle off track (its textMuted hairline) vs bg /
                  surface / surface2                                     3:1
  focus           focus ring vs bg / surface / surface2 and vs glass
                  over the wallpaper extremes, every preset              3:1
Advisory (reported, never fail the run): input borders, the off toggle
fill without its hairline, glass over the other theme's wallpapers,
accentText on plain glass and surface2, the island focus ring directly over
the wallpaper (it is drawn outside the capsule).

Exit status: 0 all required pairs pass, 1 a required pair fails or a token's
runtime value differs from Theme.qml, 2 Theme.qml could not be parsed.
Pure stdlib; PIL is optional.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass, asdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
THEME = ROOT / "ui/components/Lugh/UI/Theme.qml"
WALLPAPERS = ROOT / "branding/wallpapers"
UI = ROOT / "ui/components/Lugh/UI"

AA_TEXT = 4.5
AA_NONTEXT = 3.0

RGBA = tuple  # (r, g, b, a), floats 0..1


# ---- color math -------------------------------------------------------------

def hex_rgba(h: str) -> RGBA:
    h = h.strip().lstrip("#")
    if len(h) == 6:
        return (int(h[0:2], 16) / 255, int(h[2:4], 16) / 255, int(h[4:6], 16) / 255, 1.0)
    if len(h) == 8:  # QML #AARRGGBB
        return (int(h[2:4], 16) / 255, int(h[4:6], 16) / 255, int(h[6:8], 16) / 255, int(h[0:2], 16) / 255)
    raise ValueError(f"bad color #{h}")


def to_hex(c: RGBA) -> str:
    rgb = "".join(f"{round(v * 255):02X}" for v in c[:3])
    return f"#{rgb}" if c[3] >= 0.999 else f"#{rgb}@{c[3]:.2f}"


def over(fg: RGBA, bg: RGBA) -> RGBA:
    """Source-over composite of fg on an opaque bg."""
    a = fg[3]
    return tuple(fg[i] * a + bg[i] * (1 - a) for i in range(3)) + (1.0,)


def with_alpha(c: RGBA, a: float) -> RGBA:
    return (c[0], c[1], c[2], a)


def tint(base: RGBA, overlay: RGBA) -> RGBA:
    """Qt.tint(base, overlay): overlay alpha-blended on base."""
    return over(overlay, base)


def luminance(c: RGBA) -> float:
    def ch(v: float) -> float:
        return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4
    r, g, b = (ch(v) for v in c[:3])
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def ratio(a: RGBA, b: RGBA) -> float:
    la, lb = luminance(a), luminance(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


# ---- Theme.qml parsing --------------------------------------------------------

_num = r"[-+]?\d*\.?\d+(?:\s*/\s*\d*\.?\d+)?"


def _eval_num(s: str) -> float:
    s = s.strip()
    if not re.fullmatch(r"[-+]?\d*\.?\d+(\s*/\s*\d*\.?\d+)?", s):
        raise ValueError(s)
    if "/" in s:
        a, b = s.split("/")
        return float(a) / float(b)
    return float(s)


def _qt_rgba(args: str) -> RGBA:
    parts = [_eval_num(p) for p in args.split(",")]
    if len(parts) != 4:
        raise ValueError(args)
    return tuple(parts)  # type: ignore[return-value]


def parse_theme(path: Path) -> dict:
    """Returns {'light': {...}, 'dark': {...}, 'accents': {name: {light: [..], dark: [..]}}, 'names': [...]}."""
    src = path.read_text(encoding="utf-8")
    light: dict[str, RGBA] = {}
    dark: dict[str, RGBA] = {}

    # readonly property color NAME: dark ? "#.." : "#.."
    for m in re.finditer(r'property\s+color\s+(\w+)\s*:\s*dark\s*\?\s*"(#[0-9A-Fa-f]{6,8})"\s*:\s*"(#[0-9A-Fa-f]{6,8})"', src):
        dark[m[1]] = hex_rgba(m[2])
        light[m[1]] = hex_rgba(m[3])
    # readonly property color NAME: "#.."
    for m in re.finditer(r'property\s+color\s+(\w+)\s*:\s*"(#[0-9A-Fa-f]{6,8})"\s*$', src, re.M):
        dark[m[1]] = light[m[1]] = hex_rgba(m[2])
    # Binding { target: theme; property: "NAME"; value: [theme.]dark ? "#.." : "#.." }
    for m in re.finditer(r'property\s*:\s*"(\w+)"\s*;\s*value\s*:\s*(?:\w+\.)?dark\s*\?\s*"(#[0-9A-Fa-f]{6,8})"\s*:\s*"(#[0-9A-Fa-f]{6,8})"', src):
        dark[m[1]] = hex_rgba(m[2])
        light[m[1]] = hex_rgba(m[3])
    # readonly property color NAME: dark ? Qt.rgba(..) : Qt.rgba(..)
    for m in re.finditer(r'property\s+color\s+(\w+)\s*:\s*dark\s*\?\s*Qt\.rgba\(([^)]*)\)\s*:\s*Qt\.rgba\(([^)]*)\)', src):
        dark[m[1]] = _qt_rgba(m[2])
        light[m[1]] = _qt_rgba(m[3])
    # glass: `!transparency ? surface : dark ? Qt.rgba(..) : Qt.rgba(..)` (may span lines)
    m = re.search(r'property\s+color\s+glass\s*:[^\n]*\n?\s*:\s*dark\s*\?\s*Qt\.rgba\(([^)]*)\)\s*:\s*Qt\.rgba\(([^)]*)\)', src)
    if m:
        dark["glass"] = _qt_rgba(m[1])
        light["glass"] = _qt_rgba(m[2])
    # selectedBg alpha and the toggle-independent constants
    m = re.search(r'property\s+color\s+selectedBg\s*:\s*Qt\.rgba\(accent\.r,\s*accent\.g,\s*accent\.b,\s*(' + _num + r')\)', src)
    selected_alpha = _eval_num(m[1]) if m else 0.16
    m = re.search(r'property\s+real\s+disabledOpacity\s*:\s*(' + _num + ')', src)
    disabled_opacity = _eval_num(m[1]) if m else 0.4

    accents: dict[str, dict[str, list[RGBA]]] = {}
    for m in re.finditer(r'"(\w+)"\s*:\s*\{\s*light:\s*\[([^\]]*)\]\s*,\s*dark:\s*\[([^\]]*)\]\s*\}', src):
        lv = [hex_rgba(x) for x in re.findall(r'"(#[0-9A-Fa-f]{6,8})"', m[2])]
        dv = [hex_rgba(x) for x in re.findall(r'"(#[0-9A-Fa-f]{6,8})"', m[3])]
        if len(lv) == 3 and len(dv) == 3:
            accents[m[1]] = {"light": lv, "dark": dv}
    m = re.search(r'accentNames\s*:\s*\[([^\]]*)\]', src)
    names = re.findall(r'"(\w+)"', m[1]) if m else list(accents)

    required = ["bg", "surface", "surface2", "surface3", "border", "text", "textMuted",
                "success", "danger", "info", "warning", "onDanger", "glass",
                "hoverOverlay", "pressedOverlay"]
    missing = [k for k in required if k not in light or k not in dark]
    if missing or not accents:
        raise ValueError(f"could not parse tokens: {missing or 'accent presets'}")

    # Lint: QML reads `property color onFoo: …` as a signal handler when a
    # property `foo` exists, so the value never applies (it stays #000000).
    props = set(re.findall(r'property\s+\w+\s+(\w+)\s*:', src))
    shadowed = sorted(p for p in props
                      if re.fullmatch(r"on[A-Z]\w*", p) and (p[2].lower() + p[3:]) in props)

    return {"light": light, "dark": dark, "accents": accents, "names": names,
            "selected_alpha": selected_alpha, "disabled_opacity": disabled_opacity,
            "shadowed": shadowed, "source": src}


def theme_for(t: dict, mode: str, accent: str) -> dict[str, RGBA]:
    v = dict(t[mode])
    a = t["accents"].get(accent, t["accents"].get("amber"))[mode]
    v["accent"], v["onAccent"], v["accentText"] = a
    # Theme.qml: focusRing = dark ? accent : accentText (non-text 3:1 in light).
    v["focusRing"] = v["accent"] if mode == "dark" else v["accentText"]
    v["selectedBg"] = with_alpha(v["accent"], t["selected_alpha"])
    return v


# ---- runtime cross-check (qml6, offscreen) ----------------------------------

RUNTIME_TOKENS = ["bg", "surface", "surface2", "surface3", "border", "text", "textMuted",
                  "accent", "onAccent", "accentText", "success", "danger", "info", "warning",
                  "warningFill", "onDanger", "glass", "selectedBg", "focusRing",
                  "hoverOverlay", "pressedOverlay"]


def runtime_tokens(names: list[str]) -> dict | None:
    qml = shutil.which("qml6") or shutil.which("qml") or ("/usr/lib/qt6/bin/qml" if os.path.exists("/usr/lib/qt6/bin/qml") else None)
    if not qml:
        return None
    probe = """import QtQuick
import Lugh.UI
Item {
    Component.onCompleted: {
        const toks = %s, accents = %s, out = {};
        function hex(c) { return [c.r, c.g, c.b, c.a].map(v => Math.round(v * 255)); }
        for (const mode of ["light", "dark"]) {
            Theme.dark = mode === "dark";
            for (const a of accents) {
                Theme.accentName = a;
                const row = {};
                for (const k of toks) row[k] = hex(Theme[k]);
                out[mode + "/" + a] = row;
            }
        }
        console.log("LUGH_THEME_JSON " + JSON.stringify(out));
        Qt.exit(0);
    }
}
""" % (json.dumps(RUNTIME_TOKENS), json.dumps(names))
    with tempfile.TemporaryDirectory(prefix="lugh-contrast-") as d:
        f = Path(d) / "probe.qml"
        f.write_text(probe)
        env = dict(os.environ, QT_QPA_PLATFORM="offscreen", QT_FORCE_STDERR_LOGGING="1")
        try:
            p = subprocess.run([qml, "-I", str(ROOT / "ui/components"), str(f)], env=env,
                               capture_output=True, text=True, timeout=40)
        except (OSError, subprocess.TimeoutExpired):
            return None
    for line in (p.stdout + p.stderr).splitlines():
        if "LUGH_THEME_JSON " in line:
            raw = json.loads(line.split("LUGH_THEME_JSON ", 1)[1])
            return {k: {t: tuple(x / 255 for x in v) for t, v in row.items()} for k, row in raw.items()}
    return None


# ---- wallpaper sampling -------------------------------------------------------

def wallpaper_regions(mode: str) -> list[tuple[str, RGBA, RGBA]]:
    """[(name, lightest, darkest)] region averages of every bundled blurred
    wallpaper of a mode (branding/wallpapers/<name>-<mode>-blur.jpg)."""
    try:
        from PIL import Image  # type: ignore
    except ImportError:
        return []
    out = []
    for path in sorted(WALLPAPERS.glob(f"*-{mode}-blur.jpg")) if WALLPAPERS.exists() else []:
        try:
            with Image.open(path) as im:
                # 48x30 grid ≈ 53 px regions on a 2560-wide screen: about bar height.
                small = im.convert("RGB").resize((48, 30), Image.BOX)
                px = [tuple(v / 255 for v in small.getpixel((x, y))) + (1.0,)
                      for y in range(small.height) for x in range(small.width)]
        except OSError:
            continue
        px.sort(key=luminance)
        out.append((path.name[:-len("-blur.jpg")], px[-1], px[0]))
    return out


def extremes(regs: list[tuple[str, RGBA, RGBA]]) -> list[tuple[str, RGBA]]:
    """The lightest and the darkest region across a set of wallpapers."""
    if not regs:
        return []
    hi = max(regs, key=lambda r: luminance(r[1]))
    lo = min(regs, key=lambda r: luminance(r[2]))
    return [(f"{hi[0]} lightest", hi[1]), (f"{lo[0]} darkest", lo[2])]


def component_alpha(file: str, default: float, nth: int = 0) -> float:
    """Alpha of the nth `Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, A)` in a component."""
    try:
        src = (UI / file).read_text(encoding="utf-8")
    except OSError:
        return default
    found = re.findall(r"Qt\.rgba\(Theme\.text\.r,\s*Theme\.text\.g,\s*Theme\.text\.b,\s*(" + _num + r")\)", src)
    try:
        return _eval_num(found[nth])
    except (IndexError, ValueError):
        return default


# ---- the checks ---------------------------------------------------------------

@dataclass
class Check:
    mode: str
    accent: str
    group: str
    fg_name: str
    bg_name: str
    fg: str
    bg: str
    ratio: float
    need: float
    required: bool

    @property
    def ok(self) -> bool:
        return self.ratio + 1e-9 >= self.need


def build_checks(t: dict, rt: dict | None) -> tuple[list[Check], list[str]]:
    checks: list[Check] = []
    notes: list[str] = []
    seen: set[tuple] = set()

    def add(mode, accent, group, fgn, fg, bgn, bg, need, required=True):
        key = (mode, group, fgn, bgn, to_hex(fg), to_hex(bg))
        if accent == "*" and key in seen:
            return
        seen.add(key)
        if bg[3] < 0.999:
            raise ValueError(f"background {bgn} not opaque")
        fg_c = over(fg, bg) if fg[3] < 0.999 else fg
        checks.append(Check(mode, accent, group, fgn, bgn, to_hex(fg_c), to_hex(bg),
                            round(ratio(fg_c, bg), 2), need, required))

    toggle_fill_a = component_alpha("IconToggle.qml", 0.10)   # off fill: Theme.text at 10%
    chip_fill_a = component_alpha("Chip.qml", 0.08)           # unselected fill: Theme.text at 8%

    for mode in ("light", "dark"):
        regs = wallpaper_regions(mode)
        walls = extremes(regs)
        other = extremes(wallpaper_regions("dark" if mode == "light" else "light"))
        if not regs:
            notes.append(f"{mode}: no wallpaper blur sample (PIL or file missing); glass assumed over bg")
        else:
            notes.append(f"{mode}: glass sampled over {', '.join(r[0] for r in regs)}"
                         f" (extremes: {walls[0][0]}, {walls[1][0]})")
        for accent in t["names"]:
            v = theme_for(t, mode, accent)
            if rt and f"{mode}/{accent}" in rt:
                v.update(rt[f"{mode}/{accent}"])
            base = {k: v[k] for k in ("bg", "surface", "surface2", "surface3")}
            first = accent == t["names"][0]
            A = "*"  # accent-independent rows are listed once

            if first:
                # --- neutral text
                for fgn in ("text", "textMuted"):
                    for bgn, bgc in base.items():
                        add(mode, A, "text", fgn, v[fgn], bgn, bgc, AA_TEXT)
                # --- semantic text and fills
                for fgn in ("danger", "success", "info", "warning"):
                    for bgn in ("bg", "surface"):
                        add(mode, A, "semantic", fgn, v[fgn], bgn, v[bgn], AA_TEXT)
                add(mode, A, "semantic", "onDanger", v["onDanger"], "danger", v["danger"], AA_TEXT)
                add(mode, A, "semantic", "onDanger", v["onDanger"], "danger+pressed",
                    tint(v["danger"], v["pressedOverlay"]), AA_TEXT)
                add(mode, A, "semantic", "onDanger", v["onDanger"], "danger+hover",
                    tint(v["danger"], v["hoverOverlay"]), AA_TEXT)
                for fill in ("success", "info"):  # Badge tones use onDanger on these
                    add(mode, A, "semantic", "onDanger", v["onDanger"], f"{fill} (badge)", v[fill], AA_TEXT)
                add(mode, A, "semantic", "text", v["text"], "surface3 (neutral badge)", v["surface3"], AA_TEXT)
                for bgn in ("bg", "surface"):
                    banner = over(with_alpha(v["danger"], 0.10), v[bgn])
                    add(mode, A, "semantic", "text", v["text"], f"errorBanner on {bgn}", banner, AA_TEXT)
                    add(mode, A, "semantic", "danger (icon)", v["danger"], f"errorBanner on {bgn}", banner, AA_NONTEXT)
                # --- tooltip (inverted)
                add(mode, A, "tooltip", "bg", v["bg"], "text", v["text"], AA_TEXT)
                # --- glass
                # (island text at rest is exactly this: typeLabel text / textMuted on glass)
                glass = v["glass"]
                regions = ([(f"{n} {w}", c) for n, hi, lo in regs for w, c in (("lightest", hi), ("darkest", lo))]
                           if regs else [("bg", v["bg"])])
                for rn, rc in regions:
                    comp = over(glass, rc)
                    for fgn in ("text", "textMuted"):
                        add(mode, A, "glass", fgn, v[fgn], f"glass over {rn}", comp, AA_TEXT)
                        # --- island: hovered, and active (panel open) / pressed
                        add(mode, A, "island", fgn, v[fgn], f"island hover over {rn}",
                            tint(comp, v["hoverOverlay"]), AA_TEXT)
                        add(mode, A, "island", fgn, v[fgn], f"island active over {rn}",
                            tint(comp, v["pressedOverlay"]), AA_TEXT)
                for rn, rc in other:
                    comp = over(glass, rc)
                    for fgn in ("text", "textMuted"):
                        add(mode, A, "glass", fgn, v[fgn], f"glass over other-theme {rn}", comp, AA_TEXT, required=False)
                # --- IconToggle off: Theme.text icon on Theme.text@10% (+ state overlays)
                ext = [(f"glass over {rn}", over(glass, rc)) for rn, rc in walls] or [("glass over bg", over(glass, v["bg"]))]
                for bn, bc in ext + [("surface", v["surface"])]:
                    fill = over(with_alpha(v["text"], toggle_fill_a), bc)
                    add(mode, A, "icontoggle", "text (off icon)", v["text"], f"off fill on {bn}", fill, AA_NONTEXT)
                    add(mode, A, "icontoggle", "text (off icon)", v["text"], f"off fill+hover on {bn}",
                        tint(fill, v["hoverOverlay"]), AA_NONTEXT)
                    add(mode, A, "icontoggle", "text (off icon)", v["text"], f"off fill+pressed on {bn}",
                        tint(fill, v["pressedOverlay"]), AA_NONTEXT)
                # tone fills (danger / success / info use onDanger, neutral inverts)
                for fill in ("danger", "success", "info"):
                    add(mode, A, "icontoggle", "onDanger (on icon)", v["onDanger"], f"{fill} tone", v[fill], AA_NONTEXT)
                add(mode, A, "icontoggle", "bg (on icon)", v["bg"], "neutral tone (text)", v["text"], AA_NONTEXT)
                # --- Chip unselected: text label, textMuted icon on Theme.text@8%
                for bn, bc in ext + [("surface", v["surface"]), ("bg", v["bg"])]:
                    fill = over(with_alpha(v["text"], chip_fill_a), bc)
                    add(mode, A, "chip", "text", v["text"], f"chip on {bn}", fill, AA_TEXT)
                    add(mode, A, "chip", "textMuted (icon)", v["textMuted"], f"chip on {bn}", fill, AA_NONTEXT)
                # --- advisory non-text boundaries (WCAG 1.4.11)
                add(mode, A, "non-text", "border", v["border"], "surface", v["surface"], AA_NONTEXT, required=False)
                add(mode, A, "non-text", "border (input)", v["border"], "surface2", v["surface2"], AA_NONTEXT, required=False)
                off = with_alpha(v["text"], 0.24 if mode == "dark" else 0.20)  # Toggle.qml off track
                for bgn in ("bg", "surface", "surface2"):
                    # the 1 px textMuted hairline is what carries the off track (WCAG 1.4.11)
                    add(mode, A, "non-text", "toggle off track (hairline)", v["textMuted"], bgn, v[bgn], AA_NONTEXT)
                    add(mode, A, "non-text", "toggle off fill (no hairline)", over(off, v[bgn]), bgn, v[bgn],
                        AA_NONTEXT, required=False)

            # --- accent (per preset)
            for bgn in ("bg", "surface"):
                add(mode, accent, "accent", "accentText", v["accentText"], bgn, v[bgn], AA_TEXT)
                sel = over(v["selectedBg"], v[bgn])
                add(mode, accent, "accent", "accentText", v["accentText"], f"selectedBg on {bgn}", sel, AA_TEXT)
            # check glyph of a highlighted checkable MenuItem / accent text on inputs
            add(mode, accent, "accent", "accentText", v["accentText"], "surface2", v["surface2"], AA_TEXT,
                required=False)
            add(mode, accent, "accent", "onAccent", v["onAccent"], "accent", v["accent"], AA_TEXT)
            add(mode, accent, "accent", "onAccent", v["onAccent"], "accent+hover",
                tint(v["accent"], v["hoverOverlay"]), AA_TEXT)
            add(mode, accent, "accent", "onAccent", v["onAccent"], "accent+pressed",
                tint(v["accent"], v["pressedOverlay"]), AA_TEXT)
            for bgn in ("bg", "surface", "surface2"):
                add(mode, accent, "focus", "focusRing", v["focusRing"], bgn, v[bgn], AA_NONTEXT)
            # --- liquid set on glass (control center), per preset
            add(mode, accent, "icontoggle", "onAccent (on icon)", v["onAccent"], "accent", v["accent"], AA_NONTEXT)
            ext = ([(f"glass over {rn}", over(v["glass"], rc)) for rn, rc in walls]
                   or [("glass over bg", over(v["glass"], v["bg"]))])
            for bn, bc in ext:
                add(mode, accent, "focus", "focusRing", v["focusRing"], bn, bc, AA_NONTEXT)
                add(mode, accent, "glass", "accentText", v["accentText"], bn, bc, AA_TEXT, required=False)
                # busy arc on an off toggle is drawn in focusRing
                add(mode, accent, "icontoggle", "focusRing (busy arc)", v["focusRing"], f"off fill on {bn}",
                    over(with_alpha(v["text"], toggle_fill_a), bc), AA_NONTEXT)
            for bn, bc in ext + [("surface", v["surface"]), ("bg", v["bg"])]:
                add(mode, accent, "chip", "accentText (selected)", v["accentText"], f"selectedBg on {bn}",
                    over(v["selectedBg"], bc), AA_TEXT)
            # the island's ring sits outside the capsule, straight on the wallpaper
            for rn, rc in walls:
                add(mode, accent, "focus", "focusRing (island)", v["focusRing"], f"wallpaper {rn}", rc,
                    AA_NONTEXT, required=False)
    return checks, notes


def runtime_mismatches(t: dict, rt: dict) -> list[str]:
    out = []
    for key, row in rt.items():
        mode, accent = key.split("/")
        v = theme_for(t, mode, accent)
        for tok, val in row.items():
            if tok not in v:
                continue
            want = v[tok]
            if any(abs(a - b) > 1.5 / 255 for a, b in zip(want, val)):
                out.append(f"{mode:5} {accent:8} {tok:12} Theme.qml says {to_hex(want):12} QML gives {to_hex(val)}")
    return out


# ---- output ---------------------------------------------------------------------

def table(rows: list[Check]) -> str:
    hdr = ("mode", "accent", "group", "foreground", "background", "fg", "bg", "ratio", "need", "")
    data = [(c.mode, c.accent, c.group, c.fg_name, c.bg_name, c.fg, c.bg, f"{c.ratio:.2f}",
             f"{c.need:g}", ("ok" if c.ok else "FAIL") + ("" if c.required else " (advisory)")) for c in rows]
    w = [max(len(str(r[i])) for r in [hdr] + data) for i in range(len(hdr))]
    line = lambda r: "  ".join(str(x).ljust(w[i]) for i, x in enumerate(r)).rstrip()
    return "\n".join([line(hdr), line(tuple("-" * x for x in w))] + [line(r) for r in data])


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--theme", type=Path, default=THEME)
    ap.add_argument("--failures", action="store_true", help="only list failing pairs")
    ap.add_argument("--json", action="store_true", help="print JSON instead of a table")
    ap.add_argument("--static", action="store_true", help="skip the qml6 runtime cross-check")
    a = ap.parse_args()

    try:
        t = parse_theme(a.theme)
    except (OSError, ValueError) as e:
        print(f"check-contrast: {e}", file=sys.stderr)
        return 2

    rt = None if a.static else runtime_tokens(t["names"])
    mism = runtime_mismatches(t, rt) if rt else []
    checks, notes = build_checks(t, rt)
    if a.static:
        notes.append("runtime cross-check skipped (--static): ratios use the values written in Theme.qml")
    elif rt is None:
        notes.append("runtime cross-check unavailable (no qml6, or the probe failed): ratios use Theme.qml values")
    else:
        notes.append("ratios use the colors QML actually produces (runtime probe via qml6)")
    for p in t["shadowed"]:
        base = p[2].lower() + p[3:]
        notes.append(f"Theme.qml: `{p}: …` is read by QML as a signal-handler script because a property"
                     f" `{base}` exists, so its value never applies at runtime")

    failed = [c for c in checks if not c.ok and c.required]
    advis = [c for c in checks if not c.ok and not c.required]
    status = 1 if failed or mism else 0

    if a.json:
        print(json.dumps({"ok": status == 0, "checks": [dict(asdict(c), ok=c.ok) for c in checks],
                          "runtime_mismatches": mism, "notes": notes}, indent=1))
        return status

    rows = [c for c in checks if not c.ok] if a.failures else checks
    if rows:
        print(table(rows))
        print()
    for n in notes:
        print(f"note: {n}")
    if mism:
        print(f"\nRUNTIME MISMATCH ({len(mism)}): Theme.qml values that QML does not apply:")
        for m in mism:
            print(f"  {m}")
    req = [c for c in checks if c.required]
    print(f"\n{len(req) - len(failed)}/{len(req)} required pairs pass"
          f" · {len(failed)} fail · {len(advis)} advisory below threshold"
          f" · {len(mism)} runtime mismatches")
    if failed:
        print("\nFAILURES:")
        print(table(failed))
    return status


if __name__ == "__main__":
    sys.exit(main())
