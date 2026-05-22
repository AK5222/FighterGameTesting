// Swappable sprite renderer.
// v1: procedural solid-color square (bounding-box test).
// v2 (future): replace the body with a synchronous ROM read indexed by
// (px - sprite_x) + (py - sprite_y)*W. Output is registered (1-cycle latency)
// so the bitmap swap is drop-in without shifting the image.
//
// TRANSPARENT_COLOR exists today so non-rectangular sprites (chroma key)
// work later without changing the interface.

module sprite_renderer #(
    parameter [9:0]  W                 = 10'd32,
    parameter [9:0]  H                 = 10'd32,
    parameter [15:0] FILL_COLOR        = 16'hF800,  // RGB565: solid red
    parameter [15:0] TRANSPARENT_COLOR = 16'hF81F   // magenta = "see-through"
) (
    input  wire        pclk,
    input  wire [9:0]  px,
    input  wire [9:0]  py,
    input  wire [9:0]  sprite_x,
    input  wire [9:0]  sprite_y,
    output reg         in_sprite,
    output reg  [4:0]  r,
    output reg  [5:0]  g,
    output reg  [4:0]  b
);

    wire inside_bbox = (px >= sprite_x) && (px < sprite_x + W) &&
                       (py >= sprite_y) && (py < sprite_y + H);

    wire [15:0] pixel_color = inside_bbox ? FILL_COLOR : TRANSPARENT_COLOR;

    always @(posedge pclk) begin
        in_sprite <= inside_bbox && (pixel_color != TRANSPARENT_COLOR);
        r <= pixel_color[15:11];
        g <= pixel_color[10:5];
        b <= pixel_color[4:0];
    end

endmodule
