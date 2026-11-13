#!/usr/bin/env python3
"""Converts the designer's parts into files the WoW client loads for certain.

    python3 tools/build_media.py      (or: make media)

design/gildenslots-v2/teile/*.png -> GuildSlots/Media/Art/*.tga (32-bit BGRA, uncompressed,
origin bottom left, same power-of-two size as the PNG). The client reads TGA and BLP; PNG is
not confirmed for the Forever client. Fonts and their licence are copied to
GuildSlots/Media/Fonts/. The output is deterministic: the same input gives the same bytes.

Parts the add-on does not use are skipped (SKIP below); everything else is converted.
"""

import os
import shutil
import sys

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "design", "gildenslots-v2")
ART_IN = os.path.join(SRC, "teile")
FONT_IN = os.path.join(SRC, "fonts")
ART_OUT = os.path.join(ROOT, "GuildSlots", "Media", "Art")
FONT_OUT = os.path.join(ROOT, "GuildSlots", "Media", "Fonts")

# Delivered but not drawn by the add-on (no scroll bars, no check boxes, no drop-downs).
SKIP = {"icon_check", "icon_chevron_down", "scroll_thumb"}
FONTS = [
    "ArchivoNarrow-Bold.ttf",
    "ArchivoNarrow-Medium.ttf",
    "CinzelDecorative-Black.ttf",
    "Marcellus-Regular.ttf",
    "OFL.txt",
]


def power_of_two(n):
    return n > 0 and n & (n - 1) == 0


def write_tga(img, path):
    """Uncompressed 32-bit true-colour TGA, rows bottom-up, no ID, no footer."""
    w, h = img.size
    header = bytes([
        0,  # no image ID
        0,  # no colour map
        2,  # uncompressed true colour
        0, 0, 0, 0, 0,  # colour map spec
        0, 0, 0, 0,  # x, y origin
        w & 255, w >> 8, h & 255, h >> 8,
        32,  # bits per pixel
        8,  # 8 alpha bits, origin bottom left
    ])
    r, g, b, a = img.split()
    bgra = Image.merge("RGBA", (b, g, r, a)).transpose(Image.Transpose.FLIP_TOP_BOTTOM)
    with open(path, "wb") as fh:
        fh.write(header)
        fh.write(bgra.tobytes())


def main():
    os.makedirs(ART_OUT, exist_ok=True)
    os.makedirs(FONT_OUT, exist_ok=True)
    wanted = set()
    for name in sorted(os.listdir(ART_IN)):
        stem, ext = os.path.splitext(name)
        if ext != ".png" or stem in SKIP:
            continue
        img = Image.open(os.path.join(ART_IN, name)).convert("RGBA")
        w, h = img.size
        if not (power_of_two(w) and power_of_two(h)):
            sys.exit(f"{name}: {w} x {h} is not a power of two")
        write_tga(img, os.path.join(ART_OUT, stem + ".tga"))
        wanted.add(stem + ".tga")
    # Drop files of parts that were removed or skipped since the last run.
    for name in sorted(os.listdir(ART_OUT)):
        if name not in wanted:
            os.remove(os.path.join(ART_OUT, name))
    for name in FONTS:
        shutil.copyfile(os.path.join(FONT_IN, name), os.path.join(FONT_OUT, name))
    print(f"{len(wanted)} textures, {len(FONTS)} font files")


if __name__ == "__main__":
    main()
