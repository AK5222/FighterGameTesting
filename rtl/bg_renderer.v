// =============================================================================
// bg_renderer.v -- "what color is the background at pixel (px, py)?"
// =============================================================================
//
// Why a separate renderer:
//   A full 480x272 framebuffer would need ~260 KB of BRAM. With two animated
//   sprites already consuming 32 BRAM blocks, we have limited room for a
//   background. So we store it at quarter resolution (120x68 = ~16 KB)
//   and "pixel-quadruple" on the way out -- every BG pixel covers a 4x4
//   block on screen. Fits in ~8 BRAM blocks.
//
// How a pixel is looked up:
//   1. Take the screen pixel (px, py).
//   2. Divide both by 4: bx = px >> 2 (0..119), by = py >> 2 (0..67).
//   3. addr = by * BG_W + bx.
//   4. Read mem[addr] -- one cycle later, RGB565 comes out.
//
// Like sprite_renderer this introduces 1 cycle of latency. top.v already
// delays DEN by one cycle (den_d) for the sprite path; the same delay
// covers this renderer too.
// =============================================================================

module bg_renderer #(
    parameter        MEM_FILE = "rtl/bg.mem",
    parameter [9:0]  BG_W     = 10'd120,
    parameter [9:0]  BG_H     = 10'd68
) (
    input  wire        pclk,
    input  wire [9:0]  px,
    input  wire [9:0]  py,
    output wire [4:0]  r,
    output wire [5:0]  g,
    output wire [4:0]  b
);

    // ---- ROM: BG_W * BG_H entries x 16 bits per pixel ----
    reg [15:0] mem [0:BG_W*BG_H - 1];
    initial $readmemh(MEM_FILE, mem);

    // ---- 4x pixel scale: each BG pixel covers a 4x4 block on screen ----
    wire [9:0] bx = px >> 2;   // 0..119
    wire [9:0] by = py >> 2;   // 0..67

    // ---- Address: row * width + column. by * 120 = constant-multiply,
    //      yosys reduces it to shifts/adds (no DSP needed). ----
    wire [17:0] addr = (by * BG_W) + bx;

    // ---- Synchronous BRAM read (1-cycle latency, same as sprite_renderer) ----
    reg [15:0] pixel_q;
    always @(posedge pclk) begin
        pixel_q <= mem[addr];
    end

    assign r = pixel_q[15:11];
    assign g = pixel_q[10:5];
    assign b = pixel_q[4:0];

endmodule
