# =============================================================================
# Makefile -- builds the FPGA bitstream from Verilog sources.
# =============================================================================
#
# This file is mainly useful on Linux / macOS / WSL. On Windows we usually
# just paste the giant PowerShell one-liner from README.md instead.
# Both do the same thing -- the steps are:
#
#   1. yosys             : synthesize Verilog -> netlist of FPGA primitives
#   2. nextpnr-ecp5      : place & route the netlist on the actual chip
#   3. ecppack           : pack the routed design into a .bit bitstream
#   4. dfu-util          : upload the .bit to the board (or drag to iCELink)
#
# Requires the oss-cad-suite installed and on PATH (provides all four tools).
# =============================================================================

PROJECT  := top
TOP      := top                                      # top-level Verilog module
SRC      := rtl/pll.v \
            rtl/lcd_timing.v \
            rtl/sprite_renderer.v \
            rtl/debounce.v \
            rtl/top.v
LPF      := top.lpf                                  # pin assignments

# ICESugar-Pro = Lattice ECP5 LFE5U-25F-6BG256C
DEVICE   := 25k
PACKAGE  := CABGA256
SPEED    := 6

BUILD    := build

.PHONY: all prog clean pll

# Default target: produce the bitstream
all: $(BUILD)/$(PROJECT).bit

$(BUILD):
	mkdir -p $(BUILD)

# Step 1: synthesis (Verilog -> JSON netlist of ECP5 primitives)
$(BUILD)/$(PROJECT).json: $(SRC) | $(BUILD)
	yosys -p "read_verilog $(SRC); synth_ecp5 -top $(TOP) -json $@"

# Step 2: place & route (netlist + pin map -> physical layout)
$(BUILD)/$(PROJECT).config: $(BUILD)/$(PROJECT).json $(LPF)
	nextpnr-ecp5 --$(DEVICE) --package $(PACKAGE) --speed $(SPEED) \
	    --json $< --lpf $(LPF) --textcfg $@

# Step 3: pack the layout into a programmable .bit file (with compression)
$(BUILD)/$(PROJECT).bit: $(BUILD)/$(PROJECT).config
	ecppack --compress $< $@

# (Optional) Regenerate the PLL wrapper. Only needed if you change the
# pixel clock frequency. Hand-tweaking pll.v works too.
pll:
	ecppll -i 25 -o 9 -f rtl/pll.v --module pll

# Upload to the board over USB DFU. On Windows, dragging build/top.bit onto
# the iCELink USB drive does the same thing.
prog: $(BUILD)/$(PROJECT).bit
	dfu-util -a 0 -D $<

# Wipe all build artifacts
clean:
	rm -rf $(BUILD)