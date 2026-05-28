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
// Top module: ICESugar-Pro + 480x272 DE-only LCD.
// - PLL: 25 MHz -> 9 MHz pixel clock.
// - lcd_timing generates pixel coords and DEN.
// - sprite_renderer outputs a movable sprite (1-cycle pipelined).
// - BTN_L (A8) / BTN_R (A7) move left/right per-frame.
// - BTN_J (A6) triggers a fixed jump arc (up then down).
// - BTN_A (A5) plays a 2-frame attack animation; if boxes overlap during the
//   swing phase the opponent loses HP.
// - Opponent has the same 4 buttons on E1/C2/B2/A2.

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
    input  wire        BTN_R,
    input  wire        BTN_J,
    input  wire        BTN_A,         // A5: player attack

    // Opponent buttons (E1=left, C2=right, B2=jump, A2=attack)
    input  wire        BTN_OL,
    input  wire        BTN_OR,
    input  wire        BTN_OJ,
    input  wire        BTN_OA
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

    debounce u_db_j (
        .pclk      (pclk),
        .rst_n     (rst_n),
        .btn_raw_n (BTN_J),
        .pressed   (btn_j_pressed)
    );

    wire btn_a_pressed;
    debounce u_db_a (
        .pclk      (pclk),
        .rst_n     (rst_n),
        .btn_raw_n (BTN_A),
        .pressed   (btn_a_pressed)
    );

    wire btn_ol_pressed, btn_or_pressed;
    debounce u_db_ol (
        .pclk      (pclk),
        .rst_n     (rst_n),
        .btn_raw_n (BTN_OL),
        .pressed   (btn_ol_pressed)
    );
    debounce u_db_or (
        .pclk      (pclk),
        .rst_n     (rst_n),
        .btn_raw_n (BTN_OR),
        .pressed   (btn_or_pressed)
    );
    debounce u_db_oj (
        .pclk      (pclk),
        .rst_n     (rst_n),
        .btn_raw_n (BTN_OJ),
        .pressed   (btn_oj_pressed)
    );
    wire btn_oa_pressed;
    debounce u_db_oa (
        .pclk      (pclk),
        .rst_n     (rst_n),
        .btn_raw_n (BTN_OA),
        .pressed   (btn_oa_pressed)
    );

    // ---------------- Sprite position ----------------
    localparam [9:0] SPRITE_W  = 10'd64;
    localparam [9:0] SPRITE_H  = 10'd64;
    localparam [9:0] STEP      = 10'd2;         // pixels per frame while held
    localparam [9:0] X_MAX     = 10'd480 - SPRITE_W;
    localparam [9:0] Y_GROUND  = 10'd124;       // sprite bottom lands on grass line (screen y=188)

    // Jump parameters
    // JUMP_RISE + JUMP_FALL frames total arc. JUMP_HEIGHT in pixels.
    localparam [5:0] JUMP_RISE   = 6'd20;       // frames going up
    localparam [5:0] JUMP_FALL   = 6'd20;       // frames coming down
    localparam [9:0] JUMP_HEIGHT = 10'd80;      // max pixels above ground

    // Attack parameters
    localparam [5:0] ATTACK_WINDUP_TICKS = 6'd10;   // ~0.18 s of windup pose (frame 4)
    localparam [5:0] ATTACK_SWING_TICKS  = 6'd10;   // ~0.18 s of swing pose  (frame 5)
    localparam [9:0] HIT_DAMAGE          = 10'd10;  // HP lost per landed hit

    // ---- HUD: health bars (drawn procedurally, no BRAM cost) ----
    localparam [9:0] BAR_W   = 10'd144;          // bar width = max HP, 1 pixel per HP
    localparam [9:0] BAR_H   = 10'd12;
    localparam [9:0] P_BAR_X = 10'd8;            // player bar: top-left corner
    localparam [9:0] P_BAR_Y = 10'd8;
    localparam [9:0] O_BAR_X = 10'd480 - 10'd8 - BAR_W;  // opponent bar: top-right (= 328)
    localparam [9:0] O_BAR_Y = 10'd8;

    reg [9:0] player_hp;   // 0..BAR_W
    reg [9:0] opp_hp;
    // Decrement HP when the OTHER side lands a hit. hit_consumed/opp_hit_consumed
    // (set inside each attack state machine) guarantee one HP delta per attack
    // press even if the boxes stay overlapping for the rest of the swing.
    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            player_hp <= BAR_W;
            opp_hp    <= BAR_W;
        end else if (frame_tick) begin
            if (opp_landing_hit)
                player_hp <= (player_hp > HIT_DAMAGE) ? player_hp - HIT_DAMAGE : 10'd0;
            if (player_landing_hit)
                opp_hp    <= (opp_hp    > HIT_DAMAGE) ? opp_hp    - HIT_DAMAGE : 10'd0;
        end
    end

    reg [9:0] sprite_x;
    reg [9:0] sprite_y;

    // Jump state machine
    reg        jumping;
    reg [5:0]  jump_cnt;   // counts frames into the jump

    // Walk-cycle animation: advance frame_index every ANIM_DIV frame_ticks
    // while a movement button is held. Idle = held at 0 (idle pose).
    // 6 frames total: 0=idle, 1-3=walk cycle, 4=attack windup, 5=attack swing.
    // Walk cycle wraps at LAST_FRAME=3; frames 4-5 are only reached via the
    // attack state machine below.
    localparam [3:0] ANIM_DIV   = 4'd7;
    localparam [2:0] LAST_FRAME = 3'd3;   // highest walk-cycle frame index
    reg [3:0] anim_cnt;
    reg [2:0] frame_index;
    wire moving = btn_l_pressed ^ btn_r_pressed;   // exactly one direction held

    // Player attack state machine
    reg        attacking;
    reg        attack_phase;     // 0 = windup (frame 4), 1 = swing (frame 5)
    reg [5:0]  attack_cnt;
    reg        hit_consumed;     // latches when a hit lands during this swing
    reg        btn_a_prev;       // sampled at last frame_tick; used for rising-edge detect

    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            sprite_x     <= 10'd80;
            sprite_y     <= Y_GROUND;
            jumping      <= 1'b0;
            jump_cnt     <= 6'd0;
            anim_cnt     <= ANIM_DIV;
            frame_index  <= 3'd0;
            attacking    <= 1'b0;
            attack_phase <= 1'b0;
            attack_cnt   <= 6'd0;
            hit_consumed <= 1'b0;
            btn_a_prev   <= 1'b0;
        end else if (frame_tick) begin

            // Sample button state at frame_tick rate -- the trigger below uses
            // (current && !previous) to fire only on the press edge, never
            // while the button is held.
            btn_a_prev <= btn_a_pressed;

            // --- Horizontal movement (locked in place while attacking) ---
            if (!attacking) begin
                if (btn_l_pressed && !btn_r_pressed) begin
                    sprite_x <= (sprite_x > STEP) ? sprite_x - STEP : 10'd0;
                end else if (btn_r_pressed && !btn_l_pressed) begin
                    sprite_x <= (sprite_x < X_MAX - STEP) ? sprite_x + STEP : X_MAX;
                end
                // If both or neither held: stay put
            end

            // --- Attack state machine ---
            if (!attacking) begin
                // Rising-edge trigger: press the button once = one attack.
                // Holding it down does NOT auto-repeat.
                if (btn_a_pressed && !btn_a_prev && !jumping) begin
                    attacking    <= 1'b1;
                    attack_phase <= 1'b0;
                    attack_cnt   <= 6'd0;
                    hit_consumed <= 1'b0;
                end
            end else begin
                attack_cnt <= attack_cnt + 1'b1;
                if (attack_phase == 1'b0 && attack_cnt == ATTACK_WINDUP_TICKS - 1) begin
                    attack_phase <= 1'b1;     // windup -> swing
                    attack_cnt   <= 6'd0;
                end else if (attack_phase == 1'b1 && attack_cnt == ATTACK_SWING_TICKS - 1) begin
                    attacking <= 1'b0;        // end attack, back to walk/idle
                end
                // Latch hit_consumed the first time a hit lands this swing
                if (player_landing_hit) hit_consumed <= 1'b1;
            end

            // --- Frame index: attack overrides walk cycle ---
            if (attacking) begin
                frame_index <= attack_phase ? 3'd5 : 3'd4;
                anim_cnt    <= ANIM_DIV;       // walk resumes cleanly after attack
            end else if (!moving) begin
                // Idle: freeze on frame 0. Pre-load divider so first frame_tick
                // after a movement button is pressed advances straight to frame 1.
                anim_cnt    <= ANIM_DIV;
                frame_index <= 3'd0;
            end else if (anim_cnt == ANIM_DIV) begin
                anim_cnt    <= 4'd0;
                frame_index <= (frame_index == LAST_FRAME) ? 3'd0
                                                           : frame_index + 1'b1;
            end else begin
                anim_cnt <= anim_cnt + 1'b1;
            end

            // --- Jump state machine (no new jump while attacking) ---
            if (!jumping) begin
                if (!btn_j_pressed && !attacking) begin
                    jumping  <= 1'b1;
                    jump_cnt <= 6'd0;
                end
                sprite_y <= Y_GROUND;
            end else begin
                jump_cnt <= jump_cnt + 1'b1;

                if (jump_cnt < JUMP_RISE) begin
                    // Rising phase: move up linearly
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

    // =========================================================================
    // 5) OPPONENT STATE -- mirrors player logic, driven by BTN_OL/OR/OJ/OA
    // =========================================================================
    reg [9:0] opp_x;
    reg [9:0] opp_y;
    reg        opp_jumping;
    reg [5:0]  opp_jump_cnt;
    reg [3:0]  opp_anim_cnt;
    reg [2:0]  opp_frame_index;
    wire opp_moving = btn_ol_pressed ^ btn_or_pressed;

    // Opponent attack state machine
    reg        opp_attacking;
    reg        opp_attack_phase;
    reg [5:0]  opp_attack_cnt;
    reg        opp_hit_consumed;
    reg        btn_oa_prev;      // rising-edge detect on opponent attack button

    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            opp_x            <= 10'd336;
            opp_y            <= Y_GROUND;
            opp_jumping      <= 1'b0;
            opp_jump_cnt     <= 6'd0;
            opp_anim_cnt     <= ANIM_DIV;
            opp_frame_index  <= 3'd0;
            opp_attacking    <= 1'b0;
            opp_attack_phase <= 1'b0;
            opp_attack_cnt   <= 6'd0;
            opp_hit_consumed <= 1'b0;
            btn_oa_prev      <= 1'b0;
        end else if (frame_tick) begin

            btn_oa_prev <= btn_oa_pressed;   // for rising-edge detect

            // --- Horizontal movement (locked while attacking) ---
            if (!opp_attacking) begin
                if (btn_ol_pressed && !btn_or_pressed) begin
                    opp_x <= (opp_x > STEP) ? opp_x - STEP : 10'd0;
                end else if (btn_or_pressed && !btn_ol_pressed) begin
                    opp_x <= (opp_x < X_MAX - STEP) ? opp_x + STEP : X_MAX;
                end
            end

            // --- Attack state machine ---
            if (!opp_attacking) begin
                if (btn_oa_pressed && !btn_oa_prev && !opp_jumping) begin
                    opp_attacking    <= 1'b1;
                    opp_attack_phase <= 1'b0;
                    opp_attack_cnt   <= 6'd0;
                    opp_hit_consumed <= 1'b0;
                end
            end else begin
                opp_attack_cnt <= opp_attack_cnt + 1'b1;
                if (opp_attack_phase == 1'b0 && opp_attack_cnt == ATTACK_WINDUP_TICKS - 1) begin
                    opp_attack_phase <= 1'b1;
                    opp_attack_cnt   <= 6'd0;
                end else if (opp_attack_phase == 1'b1 && opp_attack_cnt == ATTACK_SWING_TICKS - 1) begin
                    opp_attacking <= 1'b0;
                end
                if (opp_landing_hit) opp_hit_consumed <= 1'b1;
            end

            // --- Frame index: attack overrides walk cycle ---
            if (opp_attacking) begin
                opp_frame_index <= opp_attack_phase ? 3'd5 : 3'd4;
                opp_anim_cnt    <= ANIM_DIV;
            end else if (!opp_moving) begin
                opp_anim_cnt    <= ANIM_DIV;
                opp_frame_index <= 3'd0;
            end else if (opp_anim_cnt == ANIM_DIV) begin
                opp_anim_cnt    <= 4'd0;
                opp_frame_index <= (opp_frame_index == LAST_FRAME) ? 3'd0
                                                                   : opp_frame_index + 1'b1;
            end else begin
                opp_anim_cnt <= opp_anim_cnt + 1'b1;
            end

            // --- Jump state machine (no new jump while attacking) ---
            if (!opp_jumping) begin
                if (!btn_oj_pressed && !opp_attacking) begin
                    opp_jumping  <= 1'b1;
                    opp_jump_cnt <= 6'd0;
                end
                opp_y <= Y_GROUND;
            end else begin
                opp_jump_cnt <= opp_jump_cnt + 1'b1;
                if (opp_jump_cnt < JUMP_RISE) begin
                    opp_y <= Y_GROUND - ((opp_jump_cnt + 1) * JUMP_HEIGHT / JUMP_RISE);
                end else if (opp_jump_cnt < JUMP_RISE + JUMP_FALL) begin
                    opp_y <= (Y_GROUND - JUMP_HEIGHT) +
                             ((opp_jump_cnt - JUMP_RISE + 1) * JUMP_HEIGHT / JUMP_FALL);
                end else begin
                    opp_y        <= Y_GROUND;
                    opp_jumping  <= 1'b0;
                    opp_jump_cnt <= 6'd0;
                end
            end
        end
    end

    // =========================================================================
    // 6) HIT DETECTION -- bounding-box overlap + landing-hit flags
    // =========================================================================
    // Sprite boxes overlap if both X and Y axes overlap.
    wire boxes_overlap = (sprite_x <  opp_x + SPRITE_W) && (sprite_x + SPRITE_W >  opp_x)
                      && (sprite_y <  opp_y + SPRITE_H) && (sprite_y + SPRITE_H >  opp_y);

    // "Landing a hit" = attacker is in the swing phase, boxes overlap, and
    // we haven't already taken HP off the defender this attack.
    wire player_landing_hit = attacking     && attack_phase     && boxes_overlap && !hit_consumed;
    wire opp_landing_hit    = opp_attacking && opp_attack_phase && boxes_overlap && !opp_hit_consumed;

    // =========================================================================
    // 7) SPRITE RENDERERS -- player (sprite.mem) and opponent (sprite2.mem)
    // =========================================================================
    wire       sp_in;
    wire [4:0] sp_r;
    wire [5:0] sp_g;
    wire [4:0] sp_b;

    sprite_renderer #(
        .MEM_FILE   ("rtl/sprite.mem"),
        .W          (SPRITE_W),
        .H          (SPRITE_H),
        .NUM_FRAMES (6),
        .FRAME_BITS (3)
    ) u_sprite (
        .pclk        (pclk),
        .px          (px),
        .py          (py),
        .sprite_x    (sprite_x),
        .sprite_y    (sprite_y),
        .frame_index (frame_index),
        .in_sprite   (sp_in),
        .r           (sp_r),
        .g           (sp_g),
        .b           (sp_b)
    );

    wire       opp_in;
    wire [4:0] opp_r;
    wire [5:0] opp_g;
    wire [4:0] opp_b;

    sprite_renderer #(
        .MEM_FILE   ("rtl/sprite2.mem"),
        .W          (SPRITE_W),
        .H          (SPRITE_H),
        .NUM_FRAMES (6),
        .FRAME_BITS (3)
    ) u_opp (
        .pclk        (pclk),
        .px          (px),
        .py          (py),
        .sprite_x    (opp_x),
        .sprite_y    (opp_y),
        .frame_index (opp_frame_index),
        .in_sprite   (opp_in),
        .r           (opp_r),
        .g           (opp_g),
        .b           (opp_b)
    );

    // ---- Background renderer (240x136 pixel-doubled to 480x272) ----
    wire [4:0] bg_r;
    wire [5:0] bg_g;
    wire [4:0] bg_b;
    bg_renderer u_bg (
        .pclk (pclk),
        .px   (px),
        .py   (py),
        .r    (bg_r),
        .g    (bg_g),
        .b    (bg_b)
    );

    // =========================================================================
    // 8) HUD -- procedurally-drawn health bars (top-left + top-right corners)
    // =========================================================================
    // Bounding box + fill tests (combinational on px/py).
    wire in_p_bar = (px >= P_BAR_X) && (px < P_BAR_X + BAR_W)
                 && (py >= P_BAR_Y) && (py < P_BAR_Y + BAR_H);
    wire in_o_bar = (px >= O_BAR_X) && (px < O_BAR_X + BAR_W)
                 && (py >= O_BAR_Y) && (py < O_BAR_Y + BAR_H);

    // 1-pixel white border around each bar
    wire p_border = in_p_bar && (px == P_BAR_X || px == P_BAR_X + BAR_W - 1
                              || py == P_BAR_Y || py == P_BAR_Y + BAR_H - 1);
    wire o_border = in_o_bar && (px == O_BAR_X || px == O_BAR_X + BAR_W - 1
                              || py == O_BAR_Y || py == O_BAR_Y + BAR_H - 1);

    // Filled portion: player fills left-to-right, opponent fills right-to-left
    wire p_filled = (px - P_BAR_X) < player_hp;
    wire o_filled = (px - O_BAR_X) >= (BAR_W - opp_hp);

    // Register flags 1 cycle to align with sprite/bg renderers' BRAM latency.
    reg in_p_bar_q, in_o_bar_q, p_border_q, o_border_q, p_filled_q, o_filled_q;
    always @(posedge pclk) begin
        in_p_bar_q <= in_p_bar;
        in_o_bar_q <= in_o_bar;
        p_border_q <= p_border;
        o_border_q <= o_border;
        p_filled_q <= p_filled;
        o_filled_q <= o_filled;
    end

    // HUD colors (RGB565 component widths)
    localparam [4:0] BORDER_R   = 5'd31, HP_FILL_R  = 5'd0,  HP_EMPTY_R = 5'd5;
    localparam [5:0] BORDER_G   = 6'd63, HP_FILL_G  = 6'd56, HP_EMPTY_G = 6'd5;
    localparam [4:0] BORDER_B   = 5'd31, HP_FILL_B  = 5'd0,  HP_EMPTY_B = 5'd5;

    // =========================================================================
    // 9) PIXEL MUX -- HUD > player > opponent > background priority
    // =========================================================================

    // The sprite_renderer has 1 cycle of internal delay (it reads its ROM
    // synchronously). To keep den lined up with the sprite's RGB output, we
    // delay den by one cycle too. Otherwise the right edge of the sprite
    // would smear by one pixel.
    reg den_d;
    always @(posedge pclk) begin
        den_d <= den;
    end

    reg [4:0] r_out;
    reg [5:0] g_out;
    reg [4:0] b_out;
    reg       den_out;

    always @(posedge pclk) begin
        // While reset is asserted, force DEN low so the panel ignores us.
        den_out <= den_d & rst_n;

        if (p_border_q || o_border_q) begin
            r_out <= BORDER_R;
            g_out <= BORDER_G;
            b_out <= BORDER_B;
        end else if (in_p_bar_q) begin
            r_out <= p_filled_q ? HP_FILL_R : HP_EMPTY_R;
            g_out <= p_filled_q ? HP_FILL_G : HP_EMPTY_G;
            b_out <= p_filled_q ? HP_FILL_B : HP_EMPTY_B;
        end else if (in_o_bar_q) begin
            r_out <= o_filled_q ? HP_FILL_R : HP_EMPTY_R;
            g_out <= o_filled_q ? HP_FILL_G : HP_EMPTY_G;
            b_out <= o_filled_q ? HP_FILL_B : HP_EMPTY_B;
        end else if (sp_in) begin
            r_out <= sp_r;
            g_out <= sp_g;
            b_out <= sp_b;
        end else if (opp_in) begin
            r_out <= opp_r;
            g_out <= opp_g;
            b_out <= opp_b;
        end else begin
            r_out <= bg_r;
            g_out <= bg_g;
            b_out <= bg_b;
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