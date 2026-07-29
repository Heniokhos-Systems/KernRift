#!/usr/bin/env python3
"""Derive a VS Code file icon from the full-size logo.

The logo is a 1024x1024 full-bleed black square with the letterform occupying
only the middle ~60%. Dropped straight into a file icon it renders at 16px in
the explorer, where that padding leaves the glyph too small to read. So crop to
the letterform, square it, re-pad deliberately, and round the corners to match
the rest of VS Code's icon language.

Usage: make-file-icon.py <source.png> <dest.png> [size]
"""
import sys
from PIL import Image, ImageDraw

BG = (13, 17, 23)      # #0d1117 — the dark field the previous SVG icon used
PAD_FRAC = 0.06        # breathing room around the glyph, as a fraction of size
THRESHOLD = 28         # luminance above which a pixel counts as content


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    src, dest = sys.argv[1], sys.argv[2]
    size = int(sys.argv[3]) if len(sys.argv) > 3 else 128

    im = Image.open(src).convert('RGB')

    # Crop to the glyph, ignoring the black field around it.
    mask = im.convert('L').point(lambda p: 255 if p > THRESHOLD else 0)
    bbox = mask.getbbox()
    if bbox is None:
        raise SystemExit(f'{src}: no content found above threshold {THRESHOLD}')
    glyph = im.crop(bbox)

    # Square it on the longer edge so the aspect ratio is never distorted.
    gw, gh = glyph.size
    side = max(gw, gh)
    squared = Image.new('RGB', (side, side), BG)
    squared.paste(glyph, ((side - gw) // 2, (side - gh) // 2))

    # Re-pad by a known amount, then downsample.
    pad = int(side * PAD_FRAC)
    padded = Image.new('RGB', (side + 2 * pad, side + 2 * pad), BG)
    padded.paste(squared, (pad, pad))
    icon = padded.resize((size, size), Image.LANCZOS).convert('RGBA')

    # Round the corners so it reads as an icon rather than a black tile.
    radius = max(2, size // 8)
    corner = Image.new('L', (size, size), 0)
    ImageDraw.Draw(corner).rounded_rectangle((0, 0, size - 1, size - 1),
                                             radius=radius, fill=255)
    icon.putalpha(corner)
    icon.save(dest, optimize=True)

    print(f'{dest}: {size}x{size}, cropped from {bbox}, '
          f'{len(open(dest, "rb").read())} bytes')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
