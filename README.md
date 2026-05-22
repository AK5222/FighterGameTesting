# FighterGameTesting

Screen: 4.3 inch TFT LCD display touch screen RGB 40PIN 480X272 800X480 (No touch 480X272)  
FPGA: ICESugar-pro

Build: Set-ExecutionPolicy -Scope Process Bypass -Force; . "C:\oss-cad-suite\oss-cad-suite\environment.ps1"; ecppll -i 25 -o 9 -f rtl/pll.v --module pll; mkdir build -ErrorAction SilentlyContinue; yosys -p "synth_ecp5 -top top -json build/top.json" rtl/pll.v rtl/lcd_timing.v rtl/sprite_renderer.v rtl/debounce.v rtl/top.v; nextpnr-ecp5 --25k --package CABGA256 --speed 6 --json build/top.json --textcfg build/top.cfg --lpf top.lpf --freq 25; ecppack --svf build/top.svf build/top.cfg build/top.bit

