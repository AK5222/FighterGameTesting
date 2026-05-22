# ICESugar-Pro build: yosys + nextpnr-ecp5 + ecppack
# Requires: oss-cad-suite (or yosys/nextpnr-ecp5/ecppack on PATH) and dfu-util.

PROJECT  := top
TOP      := top
SRC      := rtl/pll.v rtl/lcd_timing.v rtl/sprite_renderer.v rtl/debounce.v rtl/top.v
LPF      := top.lpf

DEVICE   := 25k
PACKAGE  := CABGA256
SPEED    := 6

BUILD    := build

.PHONY: all prog clean pll

all: $(BUILD)/$(PROJECT).bit

$(BUILD):
	mkdir -p $(BUILD)

$(BUILD)/$(PROJECT).json: $(SRC) | $(BUILD)
	yosys -p "read_verilog $(SRC); synth_ecp5 -top $(TOP) -json $@"

$(BUILD)/$(PROJECT).config: $(BUILD)/$(PROJECT).json $(LPF)
	nextpnr-ecp5 --$(DEVICE) --package $(PACKAGE) --speed $(SPEED) \
	    --json $< --lpf $(LPF) --textcfg $@

$(BUILD)/$(PROJECT).bit: $(BUILD)/$(PROJECT).config
	ecppack --compress $< $@

# Regenerate the PLL wrapper if you want to tweak the output frequency.
pll:
	ecppll -i 25 -o 9 -f rtl/pll.v --module pll

prog: $(BUILD)/$(PROJECT).bit
	dfu-util -a 0 -D $<

clean:
	rm -rf $(BUILD)
