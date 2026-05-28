#!/usr/bin/env python3

"""Convert a PNG to an RGB565 .mem file for the FPGA sprite ROM.

Usage:
    python tools/png_to_mem.py assets/sprite.png rtl/sprite.mem [size]

Notes:
- Default size is 64 (= 64x64). The image is auto-cropped to the bounding
  box of non-magenta pixels first, then resized with nearest-neighbor.
  This way the sprite fills the 64x64 grid no matter how much magenta
  padding is around it in the source PNG.
- The FPGA treats RGB565 0xF81F (pure magenta) as transparent.
  So in your PNG, paint the background pure magenta (255, 0, 255) wherever
  you want the blue screen background to show through.
"""

import sys

try:
    from PIL import Image
except ImportError:
    print("error: Pillow not installed. Run: pip install pillow")
    sys.exit(1)


MAGENTA_TOLERANCE = 30  # sum of |R-255| + |G-0| + |B-255|


def is_magenta(r, g, b):
    return abs(r - 255) + abs(g - 0) + abs(b - 255) <= MAGENTA_TOLERANCE


def auto_crop(img):
    """Crop img to the bounding box of non-magenta pixels."""
    w, h = img.size
    min_x, min_y, max_x, max_y = w, h, -1, -1
    pixels = img.load()
    for y in range(h):
        for x in range(w):
            r, g, b = pixels[x, y]
            if not is_magenta(r, g, b):
                if x < min_x: min_x = x
                if y < min_y: min_y = y
                if x > max_x: max_x = x
                if y > max_y: max_y = y

    if max_x < 0:
        print("warning: image is entirely magenta; skipping auto-crop")
        return img

    # Make the crop square so the sprite isn't distorted when resized.
    cw = max_x - min_x + 1
    ch = max_y - min_y + 1
    side = max(cw, ch)
    cx = (min_x + max_x) // 2
    cy = (min_y + max_y) // 2
    half = side // 2
    left   = max(0, cx - half)
    top    = max(0, cy - half)
    right  = min(w, left + side)
    bottom = min(h, top + side)

    print(f"auto-cropping {img.size} -> ({right-left}x{bottom-top}) "
          f"around non-magenta bounds ({min_x},{min_y})-({max_x},{max_y})")
    return img.crop((left, top, right, bottom))


def main():
    if len(sys.argv) < 3:
        print("usage: png_to_mem.py <input.png> <output.mem> [size=64]")
        sys.exit(1)

    src  = sys.argv[1]
    dst  = sys.argv[2]
    size = int(sys.argv[3]) if len(sys.argv) > 3 else 64

    img = Image.open(src).convert("RGB")
    img = auto_crop(img)

    if img.size != (size, size):
        print(f"resizing {img.size} -> {size}x{size}")
        img = img.resize((size, size), Image.NEAREST)

    with open(dst, "w") as f:
        f.write(f"// {size}x{size} RGB565 sprite, generated from {src}\n")
        for y in range(size):
            for x in range(size):
                r, g, b = img.getpixel((x, y))
                rgb565 = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
                f.write(f"{rgb565:04X}\n")

    print(f"wrote {size*size} pixels to {dst}")


if __name__ == "__main__":
    main()
