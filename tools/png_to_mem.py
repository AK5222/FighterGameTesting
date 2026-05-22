#!/usr/bin/env python3
"""Convert a PNG to an RGB565 .mem file for the FPGA sprite ROM.

Usage:
    python tools/png_to_mem.py assets/sprite.png rtl/sprite.mem [size]

Notes:
- Default size is 64 (= 64x64). The image is resized with nearest-neighbor
  (preserves the pixelated look) if it doesn't already match.
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


def main():
    if len(sys.argv) < 3:
        print("usage: png_to_mem.py <input.png> <output.mem> [size=64]")
        sys.exit(1)

    src  = sys.argv[1]
    dst  = sys.argv[2]
    size = int(sys.argv[3]) if len(sys.argv) > 3 else 64

    img = Image.open(src).convert("RGB")
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
