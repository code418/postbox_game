#!/usr/bin/env python3
"""Generates the royal cypher illustrations in assets/cyphers/.

One single-colour SVG per quiz cypher (lib/monarch_info.dart
MonarchInfo.all). The app tints them at runtime (CypherArt in
lib/widgets/cypher_art.dart), so every shape is drawn in #000.

    pip install -r tool/cypher_art/requirements.txt
    python3 tool/cypher_art/build_cypher_svgs.py

These are stylised drawings, not reproductions: a crown over the
monarch's letters with the regnal number between them, as they are cast
on a postbox door. The letters are outlined from Playfair Display, the
app's display font (SIL Open Font License 1.1), so the SVGs need no font
at runtime: the Wear OS build has no Google Fonts. The crowns are built
from simple primitives below.

The output deliberately uses only <path>, with fill or stroke, and no
<text>, <image>, filters or masks (test/cypher_art_test.dart pins this):
flutter_svg renders exactly what is drawn here, on the phone and on the
watch.
"""

from __future__ import annotations

import argparse
import hashlib
import sys
import urllib.request
from dataclasses import dataclass
from pathlib import Path

from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.ttLib import TTFont
from fontTools.varLib import instancer

REPO = Path(__file__).resolve().parents[2]
OUT_DIR = REPO / "assets" / "cyphers"
CACHE_DIR = Path(__file__).resolve().parent / ".cache"

# google/fonts at a pinned commit, verified by hash, so a rerun produces
# byte-identical SVGs.
FONTS_COMMIT = "2fe1e8c6b137fb13041a7cfca6fdcd8a910ea4dc"
FONTS = {
    "italic": (
        "PlayfairDisplay-Italic[wght].ttf",
        "a5e26dc5e2e77fb2803a0bf02fd4f81ee136ec8dea863ccdb0c59a263b21378b",
    ),
    "upright": (
        "PlayfairDisplay[wght].ttf",
        "c40f2293766a503bc70cce9e512ef844a4ccb7cbcde792fe2ea31d191917d8d6",
    ),
}

# Every file shares one canvas so the art sizes identically everywhere.
VIEW_W = 200.0
VIEW_H = 160.0


def fmt(v: float) -> str:
    s = f"{v:.2f}".rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s


# ── primitives ────────────────────────────────────────────────────────────


class Path2D:
    """A tiny absolute-coordinate SVG path builder."""

    def __init__(self) -> None:
        self.parts: list[str] = []

    def move(self, x: float, y: float) -> "Path2D":
        self.parts.append(f"M{fmt(x)} {fmt(y)}")
        return self

    def line(self, x: float, y: float) -> "Path2D":
        self.parts.append(f"L{fmt(x)} {fmt(y)}")
        return self

    def curve(self, x1, y1, x2, y2, x, y) -> "Path2D":
        self.parts.append(
            f"C{fmt(x1)} {fmt(y1)} {fmt(x2)} {fmt(y2)} {fmt(x)} {fmt(y)}")
        return self

    def close(self) -> "Path2D":
        self.parts.append("Z")
        return self

    def polygon(self, pts) -> "Path2D":
        self.move(*pts[0])
        for p in pts[1:]:
            self.line(*p)
        return self.close()

    def ellipse(self, cx, cy, rx, ry, clockwise=True) -> "Path2D":
        # Four cubic quarter-arcs. Direction matters for even-odd holes only
        # cosmetically; both directions are emitted the same way.
        k = 0.5522847498
        if clockwise:
            self.move(cx, cy - ry)
            self.curve(cx + k * rx, cy - ry, cx + rx, cy - k * ry, cx + rx, cy)
            self.curve(cx + rx, cy + k * ry, cx + k * rx, cy + ry, cx, cy + ry)
            self.curve(cx - k * rx, cy + ry, cx - rx, cy + k * ry, cx - rx, cy)
            self.curve(cx - rx, cy - k * ry, cx - k * rx, cy - ry, cx, cy - ry)
        else:
            self.move(cx, cy - ry)
            self.curve(cx - k * rx, cy - ry, cx - rx, cy - k * ry, cx - rx, cy)
            self.curve(cx - rx, cy + k * ry, cx - k * rx, cy + ry, cx, cy + ry)
            self.curve(cx + k * rx, cy + ry, cx + rx, cy + k * ry, cx + rx, cy)
            self.curve(cx + rx, cy - k * ry, cx + k * rx, cy - ry, cx, cy - ry)
        return self.close()

    def round_rect(self, x0, y0, x1, y1, r) -> "Path2D":
        k = 0.5522847498 * r
        self.move(x0 + r, y0)
        self.line(x1 - r, y0)
        self.curve(x1 - r + k, y0, x1, y0 + r - k, x1, y0 + r)
        self.line(x1, y1 - r)
        self.curve(x1, y1 - r + k, x1 - r + k, y1, x1 - r, y1)
        self.line(x0 + r, y1)
        self.curve(x0 + r - k, y1, x0, y1 - r + k, x0, y1 - r)
        self.line(x0, y0 + r)
        self.curve(x0, y0 + r - k, x0 + r - k, y0, x0 + r, y0)
        return self.close()

    def d(self) -> str:
        return " ".join(self.parts)


@dataclass
class Shape:
    """One <path>: filled (even-odd, so holes punch through) or stroked."""

    d: str
    stroke: float | None = None

    def svg(self) -> str:
        if self.stroke is None:
            return f'<path fill-rule="evenodd" d="{self.d}"/>'
        return (f'<path fill="none" stroke="#000" stroke-width="{fmt(self.stroke)}"'
                f' stroke-linecap="round" stroke-linejoin="round" d="{self.d}"/>')


class Frame:
    """Maps a crown's local design coordinates onto the canvas."""

    def __init__(self, cx: float, base_y: float, scale: float) -> None:
        self.cx, self.base_y, self.s = cx, base_y, scale

    def p(self, x: float, y: float) -> tuple[float, float]:
        return self.cx + x * self.s, self.base_y + y * self.s

    def len(self, v: float) -> float:
        return v * self.s


def cross_pattee(f: Frame, cx: float, cy: float, size: float) -> Path2D:
    """A cross with arms flaring outwards, centred on (cx, cy)."""
    a, t, big = size / 2, size * 0.09, size * 0.24
    pts = [
        (cx - t, cy - t), (cx - big, cy - a), (cx + big, cy - a),
        (cx + t, cy - t), (cx + a, cy - big), (cx + a, cy + big),
        (cx + t, cy + t), (cx + big, cy + a), (cx - big, cy + a),
        (cx - t, cy + t), (cx - a, cy + big), (cx - a, cy - big),
    ]
    return Path2D().polygon([f.p(*q) for q in pts])


def fleur_de_lis(f: Frame, cx: float, base: float, h: float) -> Path2D:
    """A simplified fleur-de-lis standing on (cx, base), h tall."""
    p = Path2D()
    w = h * 0.5
    # Centre petal: an almond pointing up.
    p.move(*f.p(cx, base - h))
    p.curve(*f.p(cx + w * 0.42, base - h * 0.72),
            *f.p(cx + w * 0.34, base - h * 0.42), *f.p(cx, base - h * 0.30))
    p.curve(*f.p(cx - w * 0.34, base - h * 0.42),
            *f.p(cx - w * 0.42, base - h * 0.72), *f.p(cx, base - h))
    p.close()
    # Side petals curling outwards and down.
    for side in (-1, 1):
        p.move(*f.p(cx + side * w * 0.12, base - h * 0.30))
        p.curve(*f.p(cx + side * w * 0.55, base - h * 0.62),
                *f.p(cx + side * w * 1.05, base - h * 0.70),
                *f.p(cx + side * w * 1.0, base - h * 0.42))
        p.curve(*f.p(cx + side * w * 0.95, base - h * 0.30),
                *f.p(cx + side * w * 0.70, base - h * 0.30),
                *f.p(cx + side * w * 0.62, base - h * 0.36))
        p.curve(*f.p(cx + side * w * 0.55, base - h * 0.30),
                *f.p(cx + side * w * 0.35, base - h * 0.22),
                *f.p(cx + side * w * 0.12, base - h * 0.22))
        p.close()
    # Collar and foot.
    p.round_rect(*f.p(cx - w * 0.55, base - h * 0.26),
                 *f.p(cx + w * 0.55, base - h * 0.14), f.len(h * 0.03))
    p.polygon([f.p(cx - w * 0.18, base - h * 0.14), f.p(cx + w * 0.18, base - h * 0.14),
               f.p(cx + w * 0.30, base), f.p(cx - w * 0.30, base)])
    return p


def jewelled_band(f: Frame, half_w: float, h: float, holes) -> Shape:
    p = Path2D().round_rect(*f.p(-half_w, -h), *f.p(half_w, 0), f.len(2))
    for (x, rx, ry) in holes:
        p.ellipse(*f.p(x, -h / 2), f.len(rx), f.len(ry))
    return Shape(p.d())


def monde_top(cy: float, r: float, cross: float) -> float:
    """Height above the band's bottom edge of the cross on a monde."""
    return -(cy - r - cross + 0.6)


def monde(f: Frame, cy: float, r: float, cross: float) -> list[Shape]:
    """The orb, with a hole for its band, and the cross on top."""
    orb = Path2D().ellipse(*f.p(0, cy), f.len(r), f.len(r))
    orb.round_rect(*f.p(-r * 0.75, cy - r * 0.16), *f.p(r * 0.75, cy + r * 0.16),
                   f.len(r * 0.1))
    return [Shape(orb.d()), Shape(cross_pattee(f, 0, cy - r - cross / 2 + 0.6, cross).d())]


def arch(f: Frame, pts, width: float) -> Shape:
    """A stroked arch through cubic control points (in local coords)."""
    p = Path2D().move(*f.p(*pts[0]))
    for i in range(1, len(pts), 3):
        p.curve(*f.p(*pts[i]), *f.p(*pts[i + 1]), *f.p(*pts[i + 2]))
    return Shape(p.d(), stroke=f.len(width))


def pearls(f: Frame, pts, r: float, count: int) -> Shape:
    """Pearls spaced along one cubic segment."""
    (x0, y0), (x1, y1), (x2, y2), (x3, y3) = pts
    p = Path2D()
    for i in range(1, count + 1):
        t = i / (count + 1)
        mt = 1 - t
        x = mt**3 * x0 + 3 * mt * mt * t * x1 + 3 * mt * t * t * x2 + t**3 * x3
        y = mt**3 * y0 + 3 * mt * mt * t * y1 + 3 * mt * t * t * y2 + t**3 * y3
        p.ellipse(*f.p(x, y), f.len(r), f.len(r))
    return Shape(p.d())


# ── crowns ──────────────────────────────────────────────────────────────
# Local design space: the band's bottom edge is y = 0, the crown grows up
# into negative y, and x = 0 is the centre line. Each crown is about 80
# units wide and 72 tall.

BAND_H = 11.0


def rim(f: Frame, fleurs: bool = True) -> list[Shape]:
    top = -BAND_H
    shapes = [
        jewelled_band(f, 38, BAND_H, [(0, 4.2, 3.0), (-17, 2.4, 2.4), (17, 2.4, 2.4),
                                      (-30, 1.8, 1.8), (30, 1.8, 1.8)]),
        Shape(cross_pattee(f, 0, top - 7.5, 15).d()),
        Shape(cross_pattee(f, -34, top - 5.5, 11).d()),
        Shape(cross_pattee(f, 34, top - 5.5, 11).d()),
    ]
    if fleurs:
        shapes += [Shape(fleur_de_lis(f, -17, top + 0.5, 13).d()),
                   Shape(fleur_de_lis(f, 17, top + 0.5, 13).d())]
    return shapes


def tudor_crown(f: Frame) -> list[Shape]:
    """Rounded arches rising to a domed top: Victoria to George VI, and
    Charles III."""
    top = -BAND_H
    shapes = rim(f)
    for side in (-1, 1):
        s = side
        outer = [(s * 34, top - 11), (s * 37, -48), (s * 18, -60), (0, -58)]
        inner = [(s * 17, top - 13), (s * 18, -44), (s * 9, -55), (0, -57)]
        shapes.append(arch(f, outer, 4.6))
        shapes.append(arch(f, inner, 3.0))
        shapes.append(pearls(f, outer, 1.5, 6))
    shapes.append(arch(f, [(0, top - 15), (0, -35), (0, -48), (0, -58)], 3.0))
    shapes += monde(f, *TUDOR_MONDE)
    return shapes


TUDOR_MONDE = (-62.5, 5.6, 10)
ST_EDWARD_MONDE = (-50.5, 5.6, 10)
SCOTTISH_MONDE = (-71.0, 7.5, 12)


def st_edwards_crown(f: Frame) -> list[Shape]:
    """Arches that dip in the middle, the monde sitting low between them:
    Elizabeth II."""
    top = -BAND_H
    shapes = rim(f)
    for side in (-1, 1):
        s = side
        outer = [(s * 34, top - 11), (s * 40, -50), (s * 24, -62), (s * 13, -56),
                 (s * 7, -53), (s * 2, -48), (0, -45)]
        inner = [(s * 17, top - 13), (s * 19, -44), (s * 12, -51), (s * 6, -49),
                 (s * 3, -48), (s * 1, -46), (0, -45)]
        shapes.append(arch(f, outer, 4.6))
        shapes.append(arch(f, inner, 3.0))
        shapes.append(pearls(f, outer[:4], 1.5, 5))
    shapes.append(arch(f, [(0, top - 15), (0, -30), (0, -38), (0, -45)], 3.0))
    shapes += monde(f, *ST_EDWARD_MONDE)
    return shapes


def scottish_crown(f: Frame) -> list[Shape]:
    """The Crown of Scotland: three big fleurs-de-lis on the rim, crosses
    between them, high arches meeting under a large monde."""
    top = -BAND_H
    shapes = [
        jewelled_band(f, 40, BAND_H, [(0, 3.4, 3.4), (-13, 2.6, 2.0), (13, 2.6, 2.0),
                                      (-25, 2.2, 2.2), (25, 2.2, 2.2),
                                      (-35, 1.6, 1.6), (35, 1.6, 1.6)]),
        Shape(fleur_de_lis(f, 0, top + 0.5, 20).d()),
        Shape(fleur_de_lis(f, -27, top + 0.5, 16).d()),
        Shape(fleur_de_lis(f, 27, top + 0.5, 16).d()),
        Shape(cross_pattee(f, -14, top - 6, 11).d()),
        Shape(cross_pattee(f, 14, top - 6, 11).d()),
        Shape(cross_pattee(f, -39, top - 4.5, 8).d()),
        Shape(cross_pattee(f, 39, top - 4.5, 8).d()),
    ]
    for side in (-1, 1):
        s = side
        outer = [(s * 37, top - 9), (s * 42, -52), (s * 22, -66), (s * 3, -64)]
        inner = [(s * 14, top - 12), (s * 17, -46), (s * 8, -60), (s * 2, -63)]
        shapes.append(arch(f, outer, 4.8))
        shapes.append(arch(f, inner, 3.4))
        shapes.append(pearls(f, outer, 1.7, 7))
        shapes.append(pearls(f, inner, 1.3, 5))
    shapes += monde(f, *SCOTTISH_MONDE)
    return shapes


# ── lettering ───────────────────────────────────────────────────────────


class Typeface:
    def __init__(self, path: Path, weight: int) -> None:
        font = instancer.instantiateVariableFont(TTFont(path), {"wght": weight})
        self.glyphs = font.getGlyphSet()
        self.cmap = font.getBestCmap()
        self.cap = font["OS/2"].sCapHeight

    def glyph(self, ch: str):
        return self.glyphs[self.cmap[ord(ch)]]

    def bounds(self, ch: str):
        pen = BoundsPen(self.glyphs)
        self.glyph(ch).draw(pen)
        return pen.bounds


@dataclass
class Run:
    text: str
    face: Typeface
    cap_height: float  # canvas units
    tracking: float = 0.0  # extra space between this run's own letters


def layout_runs(runs: list[Run], gap: float, baseline: float) -> tuple[list[Shape], float]:
    """Lays the runs out left to right by ink bounds, then centres them."""
    placed: list[tuple[str, Typeface, float, float, float]] = []
    cursor = 0.0
    for i, run in enumerate(runs):
        if i:
            cursor += gap
        s = run.cap_height / run.face.cap
        # Small numerals sit centred on the big letters' x-height band.
        y = baseline
        if run is not runs[0] and run is not runs[-1]:
            big = runs[0].cap_height
            y = baseline - (big - run.cap_height) * 0.5
        for j, ch in enumerate(run.text):
            if j:
                cursor += run.tracking
            x0, _, x1, _ = run.face.bounds(ch)
            placed.append((ch, run.face, s, cursor - x0 * s, y))
            cursor += (x1 - x0) * s
    shift = (VIEW_W - cursor) / 2
    shapes = []
    for ch, face, s, dx, y in placed:
        pen = SVGPathPen(face.glyphs, ntos=fmt)
        face.glyph(ch).draw(TransformPen(pen, (s, 0, 0, -s, dx + shift, y)))
        shapes.append(Shape(pen.getCommands()))
    return shapes, cursor


# ── cyphers ─────────────────────────────────────────────────────────────


@dataclass
class Cypher:
    code: str
    crown: str  # tudor | st_edward | scottish
    letters: tuple[str, str] | None  # (first, last) or None for crown only
    numeral: str = ""


CYPHERS = [
    Cypher("VR", "tudor", ("V", "R")),
    Cypher("EVIIR", "tudor", ("E", "R"), "VII"),
    # George V's boxes carry a plain "GR": GVR and GR share artwork, and
    # quiz_helpers.dart never offers one as a distractor for the other.
    Cypher("GVR", "tudor", ("G", "R")),
    Cypher("GR", "tudor", ("G", "R")),
    Cypher("EVIIIR", "tudor", ("E", "R"), "VIII"),
    Cypher("GVIR", "tudor", ("G", "R"), "VI"),
    Cypher("EIIR", "st_edward", ("E", "R"), "II"),
    Cypher("CIIIR", "tudor", ("C", "R"), "III"),
    Cypher("SCOTTISH_CROWN", "scottish", None),
]

# (builder, height in local units from the band's bottom to the top cross)
CROWNS = {
    "tudor": (tudor_crown, monde_top(*TUDOR_MONDE)),
    "st_edward": (st_edwards_crown, monde_top(*ST_EDWARD_MONDE)),
    "scottish": (scottish_crown, monde_top(*SCOTTISH_MONDE)),
}

# Lettering: cap height of the big letters, and where they stand.
CAP = 52.0
BASELINE = VIEW_H - 9
# Every lettered cypher draws its crown at the same scale, so the crowns
# match in width and St Edward's Crown is visibly the squatter one.
CROWN_GAP = 9.0
CROWN_BOTTOM = BASELINE - CAP - CROWN_GAP
LETTERED_CROWN_SCALE = (CROWN_BOTTOM - 4) / monde_top(*TUDOR_MONDE)


MAX_LETTERING_W = VIEW_W - 12


def lettering(c: Cypher, italic: Typeface, upright: Typeface,
              factor: float) -> tuple[list[Shape], float]:
    big = (CAP if c.numeral else CAP + 4) * factor
    runs = [Run(c.letters[0], italic, big)]
    if c.numeral:
        runs.append(Run(c.numeral, upright, big * 0.52, tracking=1.6 * factor))
    runs.append(Run(c.letters[1], italic, big))
    gap = (7.0 if c.numeral else 14.0) * factor
    return layout_runs(runs, gap, BASELINE)


def build(c: Cypher, italic: Typeface, upright: Typeface) -> str:
    shapes: list[Shape] = []
    draw_crown, crown_h = CROWNS[c.crown]
    if c.letters is None:
        # Crown alone, as large as the canvas allows: its lack of letters is
        # what tells it apart.
        scale = (VIEW_H - 10) / crown_h
        shapes += draw_crown(Frame(VIEW_W / 2, VIEW_H - 5, scale))
    else:
        shapes += draw_crown(Frame(VIEW_W / 2, CROWN_BOTTOM, LETTERED_CROWN_SCALE))
        letters, width = lettering(c, italic, upright, 1.0)
        if width > MAX_LETTERING_W:
            # EVIIIR's long numeral: shrink this one rather than every cypher.
            letters, width = lettering(c, italic, upright, MAX_LETTERING_W / width)
        shapes += letters
    body = "\n".join("  " + s.svg() for s in shapes)
    return (
        "<!-- Generated by tool/cypher_art/build_cypher_svgs.py: do not edit by hand.\n"
        "     Letters outlined from Playfair Display (SIL Open Font License 1.1). -->\n"
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {fmt(VIEW_W)} {fmt(VIEW_H)}">\n'
        f"{body}\n</svg>\n"
    )


def fetch_fonts(font_dir: Path | None) -> dict[str, Path]:
    out = {}
    for key, (name, sha) in FONTS.items():
        path = (font_dir or CACHE_DIR) / name
        if not path.exists():
            if font_dir is not None:
                sys.exit(f"missing {path}")
            CACHE_DIR.mkdir(parents=True, exist_ok=True)
            quoted = name.replace("[", "%5B").replace("]", "%5D")
            url = (f"https://raw.githubusercontent.com/google/fonts/{FONTS_COMMIT}"
                   f"/ofl/playfairdisplay/{quoted}")
            print(f"fetching {url}")
            with urllib.request.urlopen(url, timeout=60) as r:
                path.write_bytes(r.read())
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if digest != sha:
            sys.exit(f"{path}: sha256 {digest} != pinned {sha}")
        out[key] = path
    return out


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--font-dir", type=Path,
                    help="directory already holding the pinned Playfair Display files")
    ap.add_argument("--out", type=Path, default=OUT_DIR)
    args = ap.parse_args()
    fonts = fetch_fonts(args.font_dir)
    italic = Typeface(fonts["italic"], 800)
    upright = Typeface(fonts["upright"], 700)
    args.out.mkdir(parents=True, exist_ok=True)
    for c in CYPHERS:
        (args.out / f"{c.code.lower()}.svg").write_text(build(c, italic, upright))
        print(f"wrote {c.code.lower()}.svg")


if __name__ == "__main__":
    main()
