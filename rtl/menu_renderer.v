
module menu_renderer #(
    parameter        MEM_FILE = "rtl/menu.mem",
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