#!/usr/bin/env python3
"""Draws the ZMRIG mark, once, in every format the repository needs.

The mark is a RandomX rig's two layers of memory: the cache (the solid core)
inside the dataset (the ring that surrounds it). It is built as a single
stroked centreline, so the band is the same width all the way round, the two cut
corners give the block an axis (which is what stops it reading as a checkbox or
a letter), and one tone is all it needs.

    python3 site/tools/make-logo.py

Writes, into `site/static/img/`:

    logo.svg          black, for light pages
    logo-dark.svg     white, for dark pages
    favicon.svg       follows the browser's colour scheme
    favicon-32.png    white tile, black mark
    favicon-192.png
    apple-touch-icon.png

Requires Pillow for the PNGs (`pip install --user pillow`). Everything is
committed: GitHub Pages serves these files, and an icon that has to be built on
the fly is an icon that goes missing.
"""

from pathlib import Path

from PIL import Image, ImageDraw

OUT = Path(__file__).resolve().parent.parent / "static" / "img"

# --- geometry, on a 32 unit grid -------------------------------------------
#
# The centreline of the ring. Round numbers on purpose: at 16 px one grid unit
# is half a pixel, so anything off-grid turns to mush.
BAND = 3.4          # stroke width
CORNER = 2.1        # radius of the two rounded corners
CORE = 7.6          # side of the solid core, centred
CORE_RADIUS = 1.5

# Corner points of the centreline, clockwise from the top-left.
STRAIGHT = [
    (7.0, 4.9),
    (20.6, 4.9),    # top edge, then the 45 degree cut
    (27.1, 11.4),
    (27.1, 20.6),   # right edge, then the second cut
    (20.6, 27.1),
    (7.0, 27.1),
]
STEPS = 14          # points per rounded corner


def centreline_points():
    """Closed centreline, as (x, y) pairs, with the corners sampled."""
    import math

    pts = [(7.0, 4.9), (20.6, 4.9), (27.1, 11.4), (27.1, 20.6), (20.6, 27.1), (7.0, 27.1)]

    # bottom-left: centre (7, 25), from angle 90 deg to 180 deg
    for i in range(1, STEPS + 1):
        a = math.radians(90 + 90 * i / STEPS)
        pts.append((7.0 + CORNER * math.cos(a), 25.0 + CORNER * math.sin(a)))

    pts.append((4.9, 25.0))
    pts.append((4.9, 7.0))

    # top-left: centre (7, 7), from 180 deg to 270 deg
    for i in range(1, STEPS + 1):
        a = math.radians(180 + 90 * i / STEPS)
        pts.append((7.0 + CORNER * math.cos(a), 7.0 + CORNER * math.sin(a)))

    return pts


def _fmt(v):
    text = f"{v:.2f}".rstrip("0").rstrip(".")
    return text if text else "0"


def svg_document(colour, note=""):
    pts = centreline_points()
    head = f"M{_fmt(pts[0][0])} {_fmt(pts[0][1])}"
    body = "".join(f" L{_fmt(x)} {_fmt(y)}" for x, y in pts[1:])
    half = CORE / 2
    core = 16 - half

    return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32" width="32" height="32" role="img" aria-label="ZMRIG">
  <title>ZMRIG</title>{note}
  <path fill="none" stroke="{colour}" stroke-width="{_fmt(BAND)}" stroke-linejoin="round" stroke-linecap="round" d="{head}{body} Z"/>
  <rect x="{_fmt(core)}" y="{_fmt(core)}" width="{_fmt(CORE)}" height="{_fmt(CORE)}" rx="{_fmt(CORE_RADIUS)}" fill="{colour}"/>
</svg>
"""


NOTE = """
  <!--
    The cache inside the dataset: the two layers of memory every coin in this
    repository has to build before it can hash. One tone, no gradient, no
    letterform; the two cut corners are the only decoration, and they exist so
    the block has a direction.
  -->"""


def png(size, tile=None, ink=(0, 0, 0, 255)):
    """Rasterises the mark. `tile` paints a rounded background of that colour."""
    ss = 16
    s = size * ss
    if tile is not None:
        unit = s / 32 * 0.84
        off = (s - unit * 32) / 2
    else:
        unit = s / 32
        off = 0.0

    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    if tile is not None:
        ImageDraw.Draw(img).rounded_rectangle([0, 0, s - 1, s - 1], radius=s * 0.19, fill=tile)

    mask = Image.new("L", (s, s), 0)
    d = ImageDraw.Draw(mask)
    pts = [(off + x * unit, off + y * unit) for x, y in centreline_points()]
    d.line(pts + [pts[0]], fill=255, width=max(1, round(BAND * unit)), joint="curve")

    half = CORE / 2
    d.rounded_rectangle(
        [off + (16 - half) * unit, off + (16 - half) * unit,
         off + (16 + half) * unit, off + (16 + half) * unit],
        radius=CORE_RADIUS * unit,
        fill=255,
    )

    img.paste(Image.new("RGBA", (s, s), ink), (0, 0), mask)
    return img.resize((size, size), Image.LANCZOS)


def main():
    OUT.mkdir(parents=True, exist_ok=True)

    (OUT / "logo.svg").write_text(svg_document("#000000", NOTE))
    (OUT / "logo-dark.svg").write_text(svg_document("#ffffff", NOTE))

    # A tab bar can be light or dark and the mark has one tone, so the favicon
    # carries the opposite tone instead of assuming a background.
    favicon = svg_document("#000000").replace(
        '<title>ZMRIG</title>',
        "<title>ZMRIG</title>\n  <style>\n"
        "    path { stroke: #000000; }\n    rect { fill: #000000; }\n"
        "    @media (prefers-color-scheme: dark) {\n"
        "      path { stroke: #ffffff; }\n      rect { fill: #ffffff; }\n    }\n"
        "  </style>",
    )
    (OUT / "favicon.svg").write_text(favicon)

    white = (255, 255, 255, 255)
    for name, size in (
        ("favicon-32.png", 32),
        ("favicon-192.png", 192),
        ("apple-touch-icon.png", 180),
    ):
        png(size, tile=white).save(OUT / name, optimize=True)
        print(f"wrote {name} {size}x{size}")

    for name in ("logo.svg", "logo-dark.svg", "favicon.svg"):
        print(f"wrote {name}")


if __name__ == "__main__":
    main()
