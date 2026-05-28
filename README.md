# FighterGameTesting

An FPGA project that drives a 4.3" 480×272 TFT LCD and displays a movable 64×64 sprite loaded from a PNG. Built as a starting point for a Street Fighter–style game on real hardware.

**Hardware:** ICESugar-Pro (Lattice ECP5), 4.3" RGB TFT LCD (480×272), 2× pushbuttons on pins A8 / A7.

---

## How it works

There is no framebuffer. Instead, the FPGA answers "what color is pixel (x, y) right now?" in real time, 9 million times per second, as the LCD scans across the screen.

The 25 MHz crystal feeds a PLL that produces a 9 MHz pixel clock. Each clock cycle, `lcd_timing.v` knows which pixel is being scanned. `sprite_renderer.v` checks whether that pixel falls inside the sprite's bounding box and, if so, looks up its color from a block of on-chip memory (BRAM). The sprite image is baked into the bitstream at build time from `rtl/sprite.mem`.

Magenta (RGB565 `0xF81F`) is the transparent color — any magenta pixel in the source PNG shows the background instead.

---

## File guide

### Verilog (`rtl/`)

| File | Purpose |
|------|---------|
| `top.v` | Top-level: wires all modules together |
| `pll.v` | PLL: 25 MHz → 9 MHz pixel clock |
| `lcd_timing.v` | Raster scan counter (px, py, den, frame_tick) |
| `sprite_renderer.v` | BRAM sprite ROM + chroma-key transparency |
| `debounce.v` | Cleans up noisy button signals |
| `sprite.mem` | Generated RGB565 hex data (one pixel per line) |

### Other

| File | Purpose |
|------|---------|
| `top.lpf` | FPGA pin assignments |
| `tools/png_to_mem.py` | Converts a PNG to `rtl/sprite.mem` |
| `Makefile` | Linux/macOS/WSL build script |
| `assets/*.png` | Source PNGs (magenta background = transparent) |

---

## Build & flash (Windows)

Paste this one-liner in PowerShell from the project folder:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force; . "C:\oss-cad-suite\oss-cad-suite\environment.ps1"; mkdir build -ErrorAction SilentlyContinue; yosys -p "synth_ecp5 -top top -json build/top.json" rtl/pll.v rtl/lcd_timing.v rtl/sprite_renderer.v rtl/debounce.v rtl/top.v; nextpnr-ecp5 --25k --package CABGA256 --speed 6 --json build/top.json --textcfg build/top.cfg --lpf top.lpf --freq 25; ecppack --svf build/top.svf build/top.cfg build/top.bit
```

Then drag `build/top.bit` onto the iCELink USB drive that appears when the board is plugged in.


## Swapping sprites

1. Put a PNG in `assets/`. Make the background pure magenta `(255, 0, 255)` — those pixels become transparent on screen.
2. Convert it: `python tools/png_to_mem.py assets/yourfile.png rtl/sprite.mem`
3. Rebuild and flash (same one-liner above).

The script auto-crops to the non-magenta content and resizes to 64×64. First-time setup: `pip install pillow`.

---

## Tweaking behavior

| Want to change | Edit
| Movement speed | `STEP` in `rtl/top.v` (pixels per frame, default 2) 
| Sprite size | `SPRITE_W` / `SPRITE_H` in `rtl/top.v` 
| Vertical position | `Y_FIXED` in `rtl/top.v` 
| Starting x position | `sprite_x <= 10'd208;` in `rtl/top.v` 
| Background color | `BG_R`, `BG_G`, `BG_B` in `rtl/top.v` (RGB565) 
| Transparent color | `TRANSPARENT_COLOR` in `rtl/sprite_renderer.v` 
| Button debounce time | `COUNT_MAX` in `rtl/debounce.v` (cycles at 9 MHz) 

---

## Hardware wiring

Both buttons wire the same way: one leg to the FPGA pin, the other to GND. No resistor needed — the FPGA's internal pull-up handles it.

| Button | FPGA pin | Function |
|---|---|---|
| Left | A8 | Move sprite left |
| Right | A7 | Move sprite right |

---
