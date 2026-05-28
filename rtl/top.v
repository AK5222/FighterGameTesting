// =============================================================================
// top.v -- main module. This is where everything is wired together.
// =============================================================================
//
// What this file does (high level):
//   1. Takes the 25 MHz crystal oscillator on the FPGA board (input CLK).
//   2. Uses a PLL to make a 9 MHz "pixel clock" (pclk) that drives the LCD.
//   3. Runs an LCD timing generator that scans across all 480x272 pixels,
//      55x per second, telling us which pixel is being drawn right now.
//   4. Reads two physical buttons (A8 and A7) and debounces them so they
//      don't jitter when pressed.
//   5. Keeps a single number "sprite_x" -- where the sprite's left edge is.
//      Pressing left/right shifts it 2 pixels per frame.
//   6. Asks the sprite_renderer: "for the pixel being drawn right now, is it
//      part of the sprite? If so, what color?"
//   7. Sends RGB to the LCD: sprite color if inside the sprite, else dark blue.
//
// Important concept:
//   There is NO framebuffer (no stored image of the whole screen). The FPGA
//   answers "what color is this pixel?" in real time for each pixel as the
//   LCD scans across. This is why it works on a tiny chip with a small amount
//   of memory.
//
// =============================================================================

module top (
    input  wire        CLK,        // 25 MHz crystal from the FPGA board

    // LCD outputs (DE-only mode -- no HSYNC/VSYNC pins, panel uses DEN flag)
    output wire        LCD_CLK,    // pixel clock to the panel
    output wire        LCD_DEN,    // "data enable" -- 1 when a real pixel is being sent
    output wire [4:0]  LCD_R,      // red   (5 bits = 32 levels)
    output wire [5:0]  LCD_G,      // green (6 bits = 64 levels)
    output wire [4:0]  LCD_B,      // blue  (5 bits = 32 levels)
                                   // Together: RGB565 = 16-bit color, 65k colors

    // Two breadboard buttons. Active-LOW: the pin sits at 3.3V when not pressed
    // (due to internal pull-up resistor enabled in top.lpf), and goes to 0V
    // when the button is pressed (button connects pin to GND).
    input  wire        BTN_L,
    input  wire        BTN_R
);

    // =========================================================================
    // 1) CLOCKING + RESET
    //    The LCD needs ~9 MHz pixel clock. The board only gives us 25 MHz.
    //    A PLL (Phase-Locked Loop) is a circuit that takes one clock and
    //    multiplies/divides it to produce another. See rtl/pll.v.
    // =========================================================================
    wire pclk;          // the new 9 MHz pixel clock
    wire pll_locked;    // 1 once the PLL has stabilized

    pll u_pll (
        .clkin   (CLK),
        .clkout0 (pclk),
        .locked  (pll_locked)
    );

    // Hold the rest of the design in reset for ~256 pclk cycles AFTER the PLL
    // locks. Reason: the PLL output is unstable for a brief moment when it
    // first locks, and we don't want the LCD to receive garbage during that
    // window. While rst_n=0, the LCD's DEN line is forced low, so the panel
    // ignores everything.
    reg [7:0] rst_cnt = 8'd0;
    reg       rst_n   = 1'b0;     // active-LOW reset (1 = running, 0 = reset)
    always @(posedge pclk or negedge pll_locked) begin
        if (!pll_locked) begin
            // PLL not locked yet -> hold reset, clear counter
            rst_cnt <= 8'd0;
            rst_n   <= 1'b0;
        end else if (rst_cnt != 8'hFF) begin
            // PLL is locked but we haven't waited long enough yet
            rst_cnt <= rst_cnt + 1'b1;
            rst_n   <= 1'b0;
        end else begin
            // Counter saturated -> safe to release reset
            rst_n <= 1'b1;
        end
    end

    // =========================================================================
    // 2) LCD TIMING -- scans across all pixels of the screen
    //    Produces:
    //      px, py     = which pixel is being drawn right now (0..479, 0..271)
    //      den        = 1 when we're inside the visible 480x272 area
    //      frame_tick = pulses once per full screen redraw (~55 times per sec)
    // =========================================================================
    wire [9:0] px, py;
    wire       den;
    wire       frame_tick;

    lcd_timing u_timing (
        .pclk       (pclk),
        .rst_n      (rst_n),
        .px         (px),
        .py         (py),
        .den        (den),
        .frame_tick (frame_tick)
    );

    // =========================================================================
    // 3) BUTTONS -- debounce both physical buttons
    //    Mechanical buttons "bounce" when pressed -- the contacts chatter for
    //    a few milliseconds, producing dozens of fake on/off events. The
    //    debouncer filters that out so we see one clean "pressed" signal.
    // =========================================================================
    wire btn_l_pressed, btn_r_pressed;

    debounce u_db_l (
        .pclk      (pclk),
        .rst_n     (rst_n),
        .btn_raw_n (BTN_L),         // raw, active-low from the pin
        .pressed   (btn_l_pressed)  // clean, active-high
    );

    debounce u_db_r (
        .pclk      (pclk),
        .rst_n     (rst_n),
        .btn_raw_n (BTN_R),
        .pressed   (btn_r_pressed)
    );

    // =========================================================================
    // 4) SPRITE POSITION -- tracks where the sprite is, updated once per frame
    // =========================================================================

    // Constants you can tweak:
    localparam [9:0] SPRITE_W = 10'd64;          // sprite is 64x64 pixels
    localparam [9:0] SPRITE_H = 10'd64;
    localparam [9:0] STEP     = 10'd2;           // pixels moved per frame while held
                                                 // (2 px @ 55 fps ~= 110 px/sec)
    localparam [9:0] X_MAX    = 10'd480 - SPRITE_W;  // rightmost legal sprite_x
    localparam [9:0] Y_FIXED  = 10'd104;         // 272/2 - 64/2 = vertically centered

    reg [9:0] sprite_x;   // current x position (left edge) of the sprite

    // Why update only on frame_tick, not every clock cycle?
    //   At 9 MHz the position would change 9 million times per second --
    //   the sprite would teleport off the screen instantly. Once per frame
    //   (55 times/sec) is the natural rate for smooth motion.
    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            sprite_x <= 10'd208;   // center on reset: 480/2 - 64/2 = 208
        end else if (frame_tick) begin
            // If only left held: move left, clamp to 0
            if (btn_l_pressed && !btn_r_pressed) begin
                sprite_x <= (sprite_x > STEP) ? sprite_x - STEP : 10'd0;
            // If only right held: move right, clamp to X_MAX
            end else if (btn_r_pressed && !btn_l_pressed) begin
                sprite_x <= (sprite_x < X_MAX - STEP) ? sprite_x + STEP : X_MAX;
            end
            // If both or neither held: stay put
        end
    end

    // =========================================================================
    // 5) SPRITE RENDERER -- "for the pixel at (px, py), is it part of the
    //    sprite (whose top-left corner is at (sprite_x, Y_FIXED)) and if
    //    so, what color?"
    // =========================================================================
    wire       sp_in;     // 1 if the current pixel is inside the (non-transparent) sprite
    wire [4:0] sp_r;      // sprite color components (RGB565)
    wire [5:0] sp_g;
    wire [4:0] sp_b;

    sprite_renderer #(
        .W (SPRITE_W),
        .H (SPRITE_H)
    ) u_sprite (
        .pclk      (pclk),
        .px        (px),
        .py        (py),
        .sprite_x  (sprite_x),
        .sprite_y  (Y_FIXED),
        .in_sprite (sp_in),
        .r         (sp_r),
        .g         (sp_g),
        .b         (sp_b)
    );

    // =========================================================================
    // 6) PIXEL MUX -- pick between sprite color and background color, then
    //    drive the LCD output pins.
    // =========================================================================

    // The sprite_renderer has 1 cycle of internal delay (it reads its ROM
    // synchronously). To keep den lined up with the sprite's RGB output, we
    // delay den by one cycle too. Otherwise the right edge of the sprite
    // would smear by one pixel.
    reg den_d;
    always @(posedge pclk) begin
        den_d <= den;
    end

    // Background color = dark navy blue. Free to tweak.
    localparam [4:0] BG_R = 5'h02;
    localparam [5:0] BG_G = 6'h04;
    localparam [4:0] BG_B = 5'h0A;

    reg [4:0] r_out;
    reg [5:0] g_out;
    reg [4:0] b_out;
    reg       den_out;

    always @(posedge pclk) begin
        // While reset is asserted, force DEN low so the panel ignores us.
        den_out <= den_d & rst_n;

        if (sp_in) begin
            // Inside the sprite (and not on a transparent pixel) -> sprite color
            r_out <= sp_r;
            g_out <= sp_g;
            b_out <= sp_b;
        end else begin
            // Outside (or transparent) -> background color shows through
            r_out <= BG_R;
            g_out <= BG_G;
            b_out <= BG_B;
        end
    end

    assign LCD_R   = r_out;
    assign LCD_G   = g_out;
    assign LCD_B   = b_out;
    assign LCD_DEN = den_out;

    // The LCD wants its pixel clock 180 degrees out of phase with the data
    // (it latches on the rising edge, so we want data stable then -- which
    // means transitioning data on the falling edge of pclk). Inverting pclk
    // here achieves that. If colors look smeared, try removing the "~".
    assign LCD_CLK = ~pclk;

endmodule
