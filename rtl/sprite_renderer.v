// Sprite renderer (v2): 64x64 RGB565 bitmap loaded from rtl/sprite.mem.
// - mem[] is inferred as a block RAM by yosys (synchronous read pattern below).
// - 1-cycle latency from (px, py) to (in_sprite, r, g, b) — same as v1.
// - Any pixel equal to TRANSPARENT_COLOR (magenta) is treated as see-through.
//
// To change the image: edit assets/sprite.png and run
//   python tools/png_to_mem.py assets/sprite.png rtl/sprite.mem
// then rebuild.

module sprite_renderer #(
    parameter [9:0]  W                 = 10'd64,
    parameter [9:0]  H                 = 10'd64,
    parameter [15:0] TRANSPARENT_COLOR = 16'hF81F   // magenta = "see-through"
) (
    input  wire        pclk,
    input  wire [9:0]  px,
    input  wire [9:0]  py,
    input  wire [9:0]  sprite_x,
    input  wire [9:0]  sprite_y,
    output wire        in_sprite,
    output wire [4:0]  r,
    output wire [5:0]  g,
    output wire [4:0]  b
);

    // ROM holding the 64x64 sprite, one RGB565 pixel per entry.
    reg [15:0] mem [0:4095];
    initial $readmemh("rtl/sprite.mem", mem);

    // Bounding-box test on full-width coords.
    wire inside_bbox = (px >= sprite_x) && (px < sprite_x + W) &&
                       (py >= sprite_y) && (py < sprite_y + H);

    // Local coords inside the sprite. Full subtract first, then keep low 6 bits.
    // (Only valid when inside_bbox; outside, the read result is ignored.)
    wire [9:0] lx_full = px - sprite_x;
    wire [9:0] ly_full = py - sprite_y;
    wire [5:0] lx = lx_full[5:0];
    wire [5:0] ly = ly_full[5:0];
    wire [11:0] addr = {ly, lx};

    // Synchronous BRAM read + pipelined bbox flag. This is the pattern
    // yosys recognizes as a block RAM with synchronous read port.
    reg [15:0] pixel_q;
    reg        inside_q;
    always @(posedge pclk) begin
        pixel_q  <= mem[addr];
        inside_q <= inside_bbox;
    end

    // Chroma key + RGB565 split.
    assign in_sprite = inside_q && (pixel_q != TRANSPARENT_COLOR);
    assign r         = pixel_q[15:11];
    assign g         = pixel_q[10:5];
    assign b         = pixel_q[4:0];

endmodule
