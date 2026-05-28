#!/usr/bin/env python3

"""Convert one or more PNGs into a single RGB565 .mem file for the FPGA sprite ROM.

Usage:
    python tools/png_to_mem.py <input1.png> [input2.png ...] <output.mem> [--size N]

Examples:
    # Single static sprite (v2-style)
    python tools/png_to_mem.py assets/knight.png rtl/sprite.mem

    # 4-frame walk cycle (v3) -- concatenates all frames into one .mem
    python tools/png_to_mem.py assets/knight1.png assets/knight2.png \\
                               assets/knight3.png assets/knight4.png rtl/sprite.mem

Each frame is auto-cropped to its non-magenta bounding box, then resized to
SIZE x SIZE (default 64). Frames are written one after another in the output
file, so the FPGA addresses them as mem[frame_index*SIZE*SIZE + y*SIZE + x].

Magenta (255, 0, 255) in the source PNG = transparent on the FPGA.
"""

import sys

try:
    from PIL import Image
except ImportError:
    print("error: Pillow not installed. Run: pip install pillow")
    sys.exit(1)


MAGENTA_TOLERANCE = 30   # sum of |R-255| + |G-0| + |B-255|
ALPHA_THRESHOLD   = 128  # alpha < this = treat as transparent


def is_magenta(r, g, b):
    return abs(r - 255) + abs(g - 0) + abs(b - 255) <= MAGENTA_TOLERANCE


def load_image(path):
    """Open a PNG. Returns (rgb_image, alpha_image_or_None).
    If the PNG has alpha, use that for transparency.
    Otherwise fall back to magenta-keying."""
    img = Image.open(path)
    if img.mode in ("RGBA", "LA") or (img.mode == "P" and "transparency" in img.info):
        img = img.convert("RGBA")
        return img.convert("RGB"), img.split()[-1]
    return img.convert("RGB"), None


def is_transparent_pixel(rgb, alpha, x, y):
    """True if pixel (x, y) should be treated as background."""
    if alpha is not None:
        return alpha.getpixel((x, y)) < ALPHA_THRESHOLD
    r, g, b = rgb.getpixel((x, y))
    return is_magenta(r, g, b)


def opaque_bbox(rgb, alpha):
    """Return (min_x, min_y, max_x, max_y) of opaque (non-background) pixels."""
    w, h = rgb.size
    min_x, min_y, max_x, max_y = w, h, -1, -1
    for y in range(h):
        for x in range(w):
            if not is_transparent_pixel(rgb, alpha, x, y):
                if x < min_x: min_x = x
                if y < min_y: min_y = y
                if x > max_x: max_x = x
                if y > max_y: max_y = y
    if max_x < 0:
        return None
    return (min_x, min_y, max_x, max_y)


def squarify_bbox(bbox, w, h):
    """Expand a bbox to a square crop region that fits inside (w, h)."""
    min_x, min_y, max_x, max_y = bbox
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
    return (left, top, right, bottom)


def shared_crop_region(frames):
    """Compute one square crop region that contains EVERY frame's opaque
    pixels. Using a shared region means all frames resize by the same factor,
    so the sprite stays the same size throughout the animation.

    frames: list of (rgb, alpha) tuples."""
    # All images must be the same canvas size for shared coordinates to make sense.
    sizes = {rgb.size for (rgb, _) in frames}
    if len(sizes) > 1:
        print(f"  warning: input PNGs have different sizes {sizes}; "
              f"falling back to per-frame crop (sprite may change size between frames)")
        return None

    w, h = frames[0][0].size
    union_min_x, union_min_y = w, h
    union_max_x, union_max_y = -1, -1
    for (rgb, alpha) in frames:
        bbox = opaque_bbox(rgb, alpha)
        if bbox is None:
            continue
        mn_x, mn_y, mx_x, mx_y = bbox
        if mn_x < union_min_x: union_min_x = mn_x
        if mn_y < union_min_y: union_min_y = mn_y
        if mx_x > union_max_x: union_max_x = mx_x
        if mx_y > union_max_y: union_max_y = mx_y

    if union_max_x < 0:
        return None
    return squarify_bbox((union_min_x, union_min_y, union_max_x, union_max_y), w, h)


def load_frames(paths, size):
    """Load PNGs, crop them all with a shared bounding box, resize to size x size.
    Returns a list of (rgb, alpha) tuples already at (size, size)."""
    print(f"loading {len(paths)} frame(s)...")
    raw = []
    for p in paths:
        rgb, alpha = load_image(p)
        kind = "RGBA (alpha key)" if alpha is not None else "RGB (magenta key)"
        print(f"  {p}  [{kind}, {rgb.size}]")
        raw.append((rgb, alpha))

    crop = shared_crop_region(raw)
    if crop is None:
        print("  no shared crop region; using per-frame bboxes")
        cropped = []
        for (rgb, alpha) in raw:
            bbox = opaque_bbox(rgb, alpha)
            if bbox is not None:
                box = squarify_bbox(bbox, *rgb.size)
                rgb   = rgb.crop(box)
                alpha = alpha.crop(box) if alpha is not None else None
            cropped.append((rgb, alpha))
    else:
        left, top, right, bottom = crop
        print(f"  shared crop: ({left},{top})-({right},{bottom}) "
              f"= {right-left}x{bottom-top} -> resized to {size}x{size}")
        cropped = []
        for (rgb, alpha) in raw:
            rgb   = rgb.crop(crop)
            alpha = alpha.crop(crop) if alpha is not None else None
            cropped.append((rgb, alpha))

    # Resize. NEAREST keeps alpha crisp (no half-transparent halo around the sprite).
    out = []
    for (rgb, alpha) in cropped:
        rgb = rgb.resize((size, size), Image.NEAREST)
        if alpha is not None:
            alpha = alpha.resize((size, size), Image.NEAREST)
        out.append((rgb, alpha))
    return out


def write_pixel(f, r, g, b):
    # Snap near-magenta pixels (e.g. 249,0,244 from lossy export) to the
    # exact transparent color the FPGA checks for (0xF81F). Otherwise they'd
    # render as faint pink instead of letting the background show through.
    if is_magenta(r, g, b):
        f.write("F81F\n")
        return
    rgb565 = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
    f.write(f"{rgb565:04X}\n")


def write_bg(src, dst, bw, bh):
    """Background mode: resize one PNG to (bw, bh), write as packed RGB565.
    No transparency key (every pixel is opaque). Also detects the grass-line y
    so the caller knows what Y_GROUND to set in top.v."""
    print(f"background: {src} -> {bw}x{bh}")
    rgb, _ = load_image(src)
    rgb = rgb.resize((bw, bh), Image.NEAREST)

    with open(dst, "w") as f:
        f.write(f"// background {bw}x{bh} RGB565, from {src}\n")
        for y in range(bh):
            for x in range(bw):
                r, g, b = rgb.getpixel((x, y))
                rgb565 = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
                f.write(f"{rgb565:04X}\n")

    # Find the topmost row that is mostly grass-green -- that's the flat
    # horizon line the sprite should stand on.
    px = rgb.load()
    for y in range(bh):
        green = sum(1 for x in range(bw)
                    if (px[x, y][1] > px[x, y][0]
                        and px[x, y][1] > px[x, y][2]
                        and px[x, y][1] > 100
                        and px[x, y][0] < 200))
        if green > bw * 0.5:
            # Screen height is 272. Scale factor = 272 // bh (assumes the
            # bg_renderer uses px>>shift, py>>shift to map screen->bg coords).
            scale = 272 // bh
            screen_y = y * scale
            print(f"wrote {bw*bh} pixels to {dst}")
            print(f"detected grass-line at bg y={y} -> screen y={screen_y} "
                  f"(assuming {scale}x scaling)")
            print(f"  -> set Y_GROUND = {screen_y - 64} in rtl/top.v "
                  f"(sprite bottom lands on grass)")
            return
    print(f"wrote {bw*bh} pixels to {dst}")
    print("note: no obvious grass line detected; tweak Y_GROUND by hand")


def main():
    # Parse optional flags out of argv (any position).
    args = sys.argv[1:]
    size = 64
    bg_dims = None

    if "--size" in args:
        i = args.index("--size")
        size = int(args[i + 1])
        del args[i:i+2]

    if "--bg" in args:
        i = args.index("--bg")
        bg_dims = tuple(int(v) for v in args[i + 1].lower().split("x"))
        del args[i:i+2]

    if len(args) < 2:
        print("usage: png_to_mem.py <input1.png> [input2.png ...] <output.mem> "
              "[--size N] [--bg WxH]")
        sys.exit(1)

    inputs = args[:-1]
    dst    = args[-1]
    n      = len(inputs)

    if bg_dims is not None:
        bw, bh = bg_dims
        write_bg(inputs[0], dst, bw, bh)
        return

    frames = load_frames(inputs, size)

    with open(dst, "w") as f:
        f.write(f"// {n} frame(s), {size}x{size} RGB565 each\n")
        for src in inputs:
            f.write(f"// frame: {src}\n")
        for (rgb, alpha) in frames:
            for y in range(size):
                for x in range(size):
                    if alpha is not None and alpha.getpixel((x, y)) < ALPHA_THRESHOLD:
                        f.write("F81F\n")    # transparent
                        continue
                    r, g, b = rgb.getpixel((x, y))
                    write_pixel(f, r, g, b)

    total = n * size * size
    print(f"wrote {total} pixels ({n} frame{'s' if n != 1 else ''}) to {dst}")


if __name__ == "__main__":
    main()
