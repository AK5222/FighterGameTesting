# FighterGameTesting

A Street Fighter–style FPGA game on a 4.3" 480×272 TFT LCD. Two animated knights move, jump, and attack each other, with health bars in the HUD that drain on landed hits. No framebuffer — all rendering is done in real time.

**Hardware:**
Screen: 4.3 inch TFT LCD display touch screen RGB 40PIN 480X272 800X480 (No touch 480X272)
FPGA: ICESugar-pro

---

## Build Command

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force; . "C:\oss-cad-suite\oss-cad-suite\environment.ps1"; mkdir build -ErrorAction SilentlyContinue; yosys -p "synth_ecp5 -top top -json build/top.json" rtl/pll.v rtl/lcd_timing.v rtl/sprite_renderer.v rtl/bg_renderer.v rtl/debounce.v rtl/top.v; nextpnr-ecp5 --25k --package CABGA256 --speed 6 --json build/top.json --textcfg build/top.cfg --lpf top.lpf --freq 25; ecppack --svf build/top.svf build/top.cfg build/top.bit
```

After building, drag `build/top.bit` onto the iCELink USB drive.

---

## Sprites Command

```powershell
# Player sprite (6 frames: 1-4 = walk cycle, 5 = attack windup, 6 = attack swing)
python tools/png_to_mem.py assets/knight1.png assets/knight2.png assets/knight3.png assets/knight4.png assets/knight5.png assets/knight6.png rtl/sprite.mem

# Opponent sprite (same layout, mirrored)
python tools/png_to_mem.py assets/opp1.png assets/opp2.png assets/opp3.png assets/opp4.png assets/opp5.png assets/opp6.png rtl/sprite2.mem

# Background image
python tools/png_to_mem.py assets/bg.png rtl/bg.mem --bg 120x68
```

The tool auto-crops and resizes each frame to 64×64. It uses a shared bounding box across all frames so the sprite stays the same size throughout the animation. Magenta (255, 0, 255) or fully transparent pixels become the transparent color on screen.

---

## How it works

There is no framebuffer. Instead, the FPGA answers "what color is pixel (x, y) right now?" in real time, 9 million times per second, as the LCD scans across the screen.

The 25 MHz crystal feeds a PLL that produces a 9 MHz pixel clock. Each clock cycle, `lcd_timing.v` knows which pixel is being scanned. The renderers check whether that pixel falls inside their regions and look up colors from on-chip memory (BRAM) or compute them directly.

All BRAM reads take 1 cycle. The HUD is drawn procedurally (no BRAM) but its flags are registered by 1 cycle to stay pipeline-aligned. The pixel mux priority is: **HUD border → HUD fill → player sprite → opponent sprite → background**.

Magenta (RGB565 `0xF81F`) is the transparent color — magenta pixels in the source PNG show the background instead.

---

## File guide

### Verilog (`rtl/`)

| File | Purpose |
|------|---------|
| `top.v` | Top-level: wires all modules together, sprite positions, HUD, pixel mux |
| `pll.v` | PLL: 25 MHz → 9 MHz pixel clock |
| `lcd_timing.v` | Raster scan counter (px, py, den, frame_tick) |
| `sprite_renderer.v` | Parameterized BRAM sprite ROM with 4-frame animation support |
| `bg_renderer.v` | Background image renderer, 4× pixel scaling (120×68 → 480×272) |
| `debounce.v` | 2-FF synchronizer + counter debounce |
| `sprite.mem` | Generated player sprite ROM (4 frames × 64×64 RGB565) |
| `sprite2.mem` | Generated opponent sprite ROM (4 frames × 64×64 RGB565) |
| `bg.mem` | Generated background image (120×68 RGB565) |

### Other

| File | Purpose |
|------|---------|
| `top.lpf` | FPGA pin assignments |
| `tools/png_to_mem.py` | Converts PNGs to `rtl/*.mem` (supports multi-frame, alpha, magenta-key) |
| `Makefile` | Linux/macOS/WSL build script |
| `assets/*.png` | Source PNGs (magenta or transparent background = transparent on screen) |

---

## Hardware wiring

Buttons wire the same way: one leg to the FPGA pin, the other to GND. No resistor needed — the FPGA's internal pull-up handles it.

| Button | FPGA pin | Function |
|--------|----------|---------|
| Player Left | A8 | Move player left |
| Player Right | A7 | Move player right |
| Player Jump | A6 | Player jump |
| Player Attack | A5 | Player attack swing (deals damage on overlap) |
| Opponent Left | E1 | Move opponent left |
| Opponent Right | C2 | Move opponent right |
| Opponent Jump | B2 | Opponent jump |
| Opponent Attack | A2 | Opponent attack swing |

---

## Tweaking behavior

| Want to change | Where to edit |
|----------------|--------------|
| Movement speed | `STEP` in `rtl/top.v` (pixels per frame, default 2) |
| Sprite size | `SPRITE_W` / `SPRITE_H` in `rtl/top.v` |
| Ground level | `Y_GROUND` in `rtl/top.v` (sprite bottom y, default 124 → screen y 188) |
| Starting positions | `sprite_x <= 10'd80` and `opp_x <= 10'd336` in `rtl/top.v` |
| Jump height | `JUMP_HEIGHT` in `rtl/top.v` (pixels above ground, default 80) |
| Jump duration | `JUMP_RISE` / `JUMP_FALL` in `rtl/top.v` (frames per phase, default 20 each) |
| Animation speed | `ANIM_DIV` in `rtl/top.v` (frame_ticks between walk frames, default 7) |
| Health bar size | `BAR_W` / `BAR_H` in `rtl/top.v` (default 144×12) |
| Attack windup / swing length | `ATTACK_WINDUP_TICKS` / `ATTACK_SWING_TICKS` in `rtl/top.v` (frame_ticks, default 10 each ≈ 0.18 s) |
| Damage per hit | `HIT_DAMAGE` in `rtl/top.v` (default 10 → ~14 hits to KO with BAR_W=144) |
| Hitbox width | `HITBOX_INSET_X` in `rtl/top.v` (pixels shaved off each side; default 16 → 32-px effective hitbox out of 64-px sprite. Larger = tighter, smaller = wider) |
| Hitbox height | `HITBOX_INSET_Y` in `rtl/top.v` (default 0; same idea as X but for vertical) |
| Transparent color | `TRANSPARENT_COLOR` in `rtl/sprite_renderer.v` |
| Button debounce time | `COUNT_MAX` in `rtl/debounce.v` (cycles at 9 MHz, default 90000 ≈ 10 ms) |

---

## BRAM budget

The ECP5-25F has 56 BRAM blocks. Current usage:

| Resource | BRAMs |
|----------|-------|
| Player sprite (6 × 64×64) | ~24 |
| Opponent sprite (6 × 64×64) | ~24 |
| Background (120×68) | 8 |
| **Total** | **~56 / 56** |

This is right at the limit. If `nextpnr-ecp5` errors with `no BELs remaining`, shrink the background to `--bg 60x34` and change `BG_W` / `BG_H` plus the two `>> 2` shifts in `rtl/bg_renderer.v` to `>> 3` (8× pixel scaling). That drops the background to ~2 BRAMs.
