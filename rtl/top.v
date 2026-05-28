// Top module: ICESugar-Pro + 480x272 DE-only LCD.
// - PLL: 25 MHz -> 9 MHz pixel clock.
// - lcd_timing generates pixel coords and DEN.
// - sprite_renderer outputs a movable sprite (1-cycle pipelined).
// - BTN_L (A8) / BTN_R (A7) move left/right per-frame.
// - BTN_J (A5) triggers a fixed jump arc (up then down).

module top (
    input  wire        CLK,

    // LCD (DE-only)
    output wire        LCD_CLK,
    output wire        LCD_DEN,
    output wire [4:0]  LCD_R,
    output wire [5:0]  LCD_G,
    output wire [4:0]  LCD_B,

    // Buttons (active-low, pull-up)
    input  wire        BTN_L,
    input  wire        BTN_R,
    input  wire        BTN_J
);

    // ---------------- Clocking & reset ----------------
    wire pclk;
    wire pll_locked;

    pll u_pll (
        .clkin   (CLK),
        .clkout0 (pclk),
        .locked  (pll_locked)
    );

    reg [7:0] rst_cnt = 8'd0;
    reg       rst_n   = 1'b0;
    always @(posedge pclk or negedge pll_locked) begin
        if (!pll_locked) begin
            rst_cnt <= 8'd0;
            rst_n   <= 1'b0;
        end else if (rst_cnt != 8'hFF) begin
            rst_cnt <= rst_cnt + 1'b1;
            rst_n   <= 1'b0;
        end else begin
            rst_n <= 1'b1;
        end
    end

    // ---------------- LCD timing ----------------
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

    // ---------------- Buttons ----------------
    wire btn_l_pressed, btn_r_pressed, btn_j_pressed;

    debounce u_db_l (
        .pclk      (pclk),
        .rst_n     (rst_n),
        .btn_raw_n (BTN_L),
        .pressed   (btn_l_pressed)
    );

    debounce u_db_r (
        .pclk      (pclk),
        .rst_n     (rst_n),
        .btn_raw_n (BTN_R),
        .pressed   (btn_r_pressed)
    );

    debounce u_db_j (
        .pclk      (pclk),
        .rst_n     (rst_n),
        .btn_raw_n (BTN_J),
        .pressed   (btn_j_pressed)
    );

    // ---------------- Sprite position ----------------
    localparam [9:0] SPRITE_W  = 10'd64;
    localparam [9:0] SPRITE_H  = 10'd64;
    localparam [9:0] STEP      = 10'd2;         // pixels per frame while held
    localparam [9:0] X_MAX     = 10'd480 - SPRITE_W;
    localparam [9:0] Y_GROUND  = 10'd104;       // resting Y (272/2 - 64/2)

    // Jump parameters
    // JUMP_RISE + JUMP_FALL frames total arc. JUMP_HEIGHT in pixels.
    localparam [5:0] JUMP_RISE   = 6'd20;       // frames going up
    localparam [5:0] JUMP_FALL   = 6'd20;       // frames coming down
    localparam [9:0] JUMP_HEIGHT = 10'd80;      // max pixels above ground

    reg [9:0] sprite_x;
    reg [9:0] sprite_y;

    // Jump state machine
    reg        jumping;
    reg [5:0]  jump_cnt;   // counts frames into the jump

    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            sprite_x <= 10'd208;
            sprite_y <= Y_GROUND;
            jumping  <= 1'b0;
            jump_cnt <= 6'd0;
        end else if (frame_tick) begin

            // --- Horizontal movement (always allowed) ---
            if (btn_l_pressed && !btn_r_pressed) begin
                sprite_x <= (sprite_x > STEP) ? sprite_x - STEP : 10'd0;
            end else if (btn_r_pressed && !btn_l_pressed) begin
                sprite_x <= (sprite_x < X_MAX - STEP) ? sprite_x + STEP : X_MAX;
            end

            // --- Jump state machine ---
            if (!jumping) begin
                if (!btn_j_pressed) begin
                    jumping  <= 1'b1;
                    jump_cnt <= 6'd0;
                end
                sprite_y <= Y_GROUND;
            end else begin
                jump_cnt <= jump_cnt + 1'b1;

                if (jump_cnt < JUMP_RISE) begin
                    // Rising phase: move up linearly
                    // Each frame moves up by JUMP_HEIGHT / JUMP_RISE pixels
                    sprite_y <= Y_GROUND - ((jump_cnt + 1) * JUMP_HEIGHT / JUMP_RISE);
                end else if (jump_cnt < JUMP_RISE + JUMP_FALL) begin
                    // Falling phase: move back down linearly
                    sprite_y <= (Y_GROUND - JUMP_HEIGHT) +
                                ((jump_cnt - JUMP_RISE + 1) * JUMP_HEIGHT / JUMP_FALL);
                end else begin
                    // Land
                    sprite_y <= Y_GROUND;
                    jumping  <= 1'b0;
                    jump_cnt <= 6'd0;
                end
            end
        end
    end

    // ---------------- Sprite render ----------------
    wire       sp_in;
    wire [4:0] sp_r;
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
        .sprite_y  (sprite_y),
        .in_sprite (sp_in),
        .r         (sp_r),
        .g         (sp_g),
        .b         (sp_b)
    );

    // ---------------- Pixel mux ----------------
    reg den_d;
    always @(posedge pclk) begin
        den_d <= den;
    end

    // Background: dark navy blue
    localparam [4:0] BG_R = 5'h02;
    localparam [5:0] BG_G = 6'h04;
    localparam [4:0] BG_B = 5'h0A;

    reg [4:0] r_out;
    reg [5:0] g_out;
    reg [4:0] b_out;
    reg       den_out;

    always @(posedge pclk) begin
        den_out <= den_d & rst_n;
        if (sp_in) begin
            r_out <= sp_r;
            g_out <= sp_g;
            b_out <= sp_b;
        end else begin
            r_out <= BG_R;
            g_out <= BG_G;
            b_out <= BG_B;
        end
    end

    assign LCD_R   = r_out;
    assign LCD_G   = g_out;
    assign LCD_B   = b_out;
    assign LCD_DEN = den_out;
    assign LCD_CLK = ~pclk;

endmodule