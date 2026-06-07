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
    input  wire        CLK,
 
    output wire        LCD_CLK,
    output wire        LCD_DEN,
    output wire [4:0]  LCD_R,
    output wire [5:0]  LCD_G,
    output wire [4:0]  LCD_B,
 
    input  wire        UART_RX
);
 
    // =========================================================================
    // 1) CLOCKING + RESET
    // =========================================================================
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
 
    // =========================================================================
    // 2) LCD TIMING
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
    // 3) UART INPUT
    // =========================================================================
    wire p1_left, p1_right, p1_jump, p1_block, p1_atk1, p1_atk2;
    wire p2_left, p2_right, p2_jump, p2_block, p2_atk1, p2_atk2;
 
    uart_input u_uart (
        .pclk       (pclk),
        .rst_n      (rst_n),
        .rx         (UART_RX),
        .frame_tick (frame_tick),
        .p1_left    (p1_left),  .p1_right (p1_right),
        .p1_jump    (p1_jump),  .p1_block (p1_block),
        .p1_atk1    (p1_atk1),  .p1_atk2  (p1_atk2),
        .p2_left    (p2_left),  .p2_right (p2_right),
        .p2_jump    (p2_jump),  .p2_block (p2_block),
        .p2_atk1    (p2_atk1),  .p2_atk2  (p2_atk2)
    );
 
    wire btn_l_pressed   = p1_left;
    wire btn_r_pressed   = p1_right;
    wire btn_j_pressed   = p1_jump;
    wire btn_a_pressed   = p1_atk1;
    wire btn_a2_pressed  = p1_atk2;
    wire btn_block       = p1_block;
 
    wire btn_ol_pressed  = p2_left;
    wire btn_or_pressed  = p2_right;
    wire btn_oj_pressed  = p2_jump;
    wire btn_oa_pressed  = p2_atk1;
    wire btn_oa2_pressed = p2_atk2;
    wire btn_oblock      = p2_block;
 
    // =========================================================================
    // 4) SPRITE POSITION + GAME LOGIC
    // =========================================================================
    localparam [9:0] SPRITE_W  = 10'd64;
    localparam [9:0] SPRITE_H  = 10'd64;
    localparam [9:0] STEP      = 10'd2;
    localparam [9:0] X_MAX     = 10'd480 - SPRITE_W;
    localparam [9:0] Y_GROUND  = 10'd124;
 
    localparam [5:0] JUMP_RISE   = 6'd20;
    localparam [5:0] JUMP_FALL   = 6'd20;
    localparam [9:0] JUMP_HEIGHT = 10'd80;
 
    localparam [5:0] ATTACK_WINDUP_TICKS = 6'd10;
    localparam [5:0] ATTACK_SWING_TICKS  = 6'd10;
    localparam [9:0] HIT_DAMAGE          = 10'd10;
 
    localparam [9:0] HITBOX_INSET_X = 10'd12;
    localparam [9:0] HITBOX_INSET_Y = 10'd0;
 
    localparam [9:0] BAR_W   = 10'd144;
    localparam [9:0] BAR_H   = 10'd12;
    localparam [9:0] P_BAR_X = 10'd8;
    localparam [9:0] P_BAR_Y = 10'd8;
    localparam [9:0] O_BAR_X = 10'd480 - 10'd8 - BAR_W;
    localparam [9:0] O_BAR_Y = 10'd8;
 
    reg [9:0] player_hp;
    reg [9:0] opp_hp;
 
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
    reg        jumping;
    reg [5:0]  jump_cnt;
 
    localparam [3:0] ANIM_DIV   = 4'd7;
    localparam [2:0] LAST_FRAME = 3'd3;
    reg [3:0] anim_cnt;
    reg [2:0] frame_index;
    wire moving = btn_l_pressed ^ btn_r_pressed;
 
    reg        attacking;
    reg        attack_phase;
    reg [5:0]  attack_cnt;
    reg        hit_consumed;
    reg        btn_a_prev;
 
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
 
            btn_a_prev <= btn_a_pressed;
 
            if (!attacking) begin
                if (btn_l_pressed && !btn_r_pressed)
                    sprite_x <= (sprite_x > STEP) ? sprite_x - STEP : 10'd0;
                else if (btn_r_pressed && !btn_l_pressed)
                    sprite_x <= (sprite_x < X_MAX - STEP) ? sprite_x + STEP : X_MAX;
            end
 
            if (!attacking) begin
                if (btn_a_pressed && !btn_a_prev && !jumping) begin
                    attacking    <= 1'b1;
                    attack_phase <= 1'b0;
                    attack_cnt   <= 6'd0;
                    hit_consumed <= 1'b0;
                end
            end else begin
                attack_cnt <= attack_cnt + 1'b1;
                if (attack_phase == 1'b0 && attack_cnt == ATTACK_WINDUP_TICKS - 1) begin
                    attack_phase <= 1'b1;
                    attack_cnt   <= 6'd0;
                end else if (attack_phase == 1'b1 && attack_cnt == ATTACK_SWING_TICKS - 1) begin
                    attacking <= 1'b0;
                end
                if (player_landing_hit) hit_consumed <= 1'b1;
            end
 
            if (attacking) begin
                frame_index <= attack_phase ? 3'd5 : 3'd4;
                anim_cnt    <= ANIM_DIV;
            end else if (!moving) begin
                anim_cnt    <= ANIM_DIV;
                frame_index <= 3'd0;
            end else if (anim_cnt == ANIM_DIV) begin
                anim_cnt    <= 4'd0;
                frame_index <= (frame_index == LAST_FRAME) ? 3'd0 : frame_index + 1'b1;
            end else begin
                anim_cnt <= anim_cnt + 1'b1;
            end
 
            if (!jumping) begin
                if (btn_j_pressed && !attacking) begin
                    jumping  <= 1'b1;
                    jump_cnt <= 6'd0;
                end
                sprite_y <= Y_GROUND;
            end else begin
                jump_cnt <= jump_cnt + 1'b1;
                if (jump_cnt < JUMP_RISE) begin
                    sprite_y <= Y_GROUND - ((jump_cnt + 1) * JUMP_HEIGHT / JUMP_RISE);
                end else if (jump_cnt < JUMP_RISE + JUMP_FALL) begin
                    sprite_y <= (Y_GROUND - JUMP_HEIGHT) +
                                ((jump_cnt - JUMP_RISE + 1) * JUMP_HEIGHT / JUMP_FALL);
                end else begin
                    sprite_y <= Y_GROUND;
                    jumping  <= 1'b0;
                    jump_cnt <= 6'd0;
                end
            end
        end
    end
 
    // =========================================================================
    // 5) OPPONENT STATE
    // =========================================================================
    reg [9:0] opp_x;
    reg [9:0] opp_y;
    reg        opp_jumping;
    reg [5:0]  opp_jump_cnt;
    reg [3:0]  opp_anim_cnt;
    reg [2:0]  opp_frame_index;
    wire opp_moving = btn_ol_pressed ^ btn_or_pressed;
 
    reg        opp_attacking;
    reg        opp_attack_phase;
    reg [5:0]  opp_attack_cnt;
    reg        opp_hit_consumed;
    reg        btn_oa_prev;
 
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
 
            btn_oa_prev <= btn_oa_pressed;
 
            if (!opp_attacking) begin
                if (btn_ol_pressed && !btn_or_pressed)
                    opp_x <= (opp_x > STEP) ? opp_x - STEP : 10'd0;
                else if (btn_or_pressed && !btn_ol_pressed)
                    opp_x <= (opp_x < X_MAX - STEP) ? opp_x + STEP : X_MAX;
            end
 
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
 
            if (opp_attacking) begin
                opp_frame_index <= opp_attack_phase ? 3'd5 : 3'd4;
                opp_anim_cnt    <= ANIM_DIV;
            end else if (!opp_moving) begin
                opp_anim_cnt    <= ANIM_DIV;
                opp_frame_index <= 3'd0;
            end else if (opp_anim_cnt == ANIM_DIV) begin
                opp_anim_cnt    <= 4'd0;
                opp_frame_index <= (opp_frame_index == LAST_FRAME) ? 3'd0 : opp_frame_index + 1'b1;
            end else begin
                opp_anim_cnt <= opp_anim_cnt + 1'b1;
            end
 
            if (!opp_jumping) begin
                if (btn_oj_pressed && !opp_attacking) begin
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
    // 6) HIT DETECTION
    // =========================================================================
    wire [9:0] p_left   = sprite_x + HITBOX_INSET_X;
    wire [9:0] p_right  = sprite_x + SPRITE_W - HITBOX_INSET_X;
    wire [9:0] p_top    = sprite_y + HITBOX_INSET_Y;
    wire [9:0] p_bottom = sprite_y + SPRITE_H - HITBOX_INSET_Y;
    wire [9:0] o_left   = opp_x    + HITBOX_INSET_X;
    wire [9:0] o_right  = opp_x    + SPRITE_W - HITBOX_INSET_X;
    wire [9:0] o_top    = opp_y    + HITBOX_INSET_Y;
    wire [9:0] o_bottom = opp_y    + SPRITE_H - HITBOX_INSET_Y;
 
    wire boxes_overlap = (p_left < o_right) && (p_right > o_left)
                      && (p_top  < o_bottom) && (p_bottom > o_top);
 
    wire player_landing_hit = attacking     && attack_phase     && boxes_overlap && !hit_consumed;
    wire opp_landing_hit    = opp_attacking && opp_attack_phase && boxes_overlap && !opp_hit_consumed;
 
    // =========================================================================
    // 7) DRAW BUFFERS -- latch positions at frame start to prevent mid-frame
    //    updates causing screen corruption when sprite moves
    // =========================================================================
    reg [9:0] sprite_x_draw, sprite_y_draw;
    reg [2:0] frame_index_draw;
    reg [9:0] opp_x_draw, opp_y_draw;
    reg [2:0] opp_frame_index_draw;
 
    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            sprite_x_draw       <= 10'd80;
            sprite_y_draw       <= Y_GROUND;
            frame_index_draw    <= 3'd0;
            opp_x_draw          <= 10'd336;
            opp_y_draw          <= Y_GROUND;
            opp_frame_index_draw <= 3'd0;
        end else if (frame_tick) begin
            sprite_x_draw       <= sprite_x;
            sprite_y_draw       <= sprite_y;
            frame_index_draw    <= frame_index;
            opp_x_draw          <= opp_x;
            opp_y_draw          <= opp_y;
            opp_frame_index_draw <= opp_frame_index;
        end
    end
 
    // =========================================================================
    // 8) SPRITE RENDERERS
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
        .sprite_x    (sprite_x_draw),
        .sprite_y    (sprite_y_draw),
        .frame_index (frame_index_draw),
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
        .sprite_x    (opp_x_draw),
        .sprite_y    (opp_y_draw),
        .frame_index (opp_frame_index_draw),
        .in_sprite   (opp_in),
        .r           (opp_r),
        .g           (opp_g),
        .b           (opp_b)
    );
 
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
    // 9) HUD
    // =========================================================================
    wire in_p_bar = (px >= P_BAR_X) && (px < P_BAR_X + BAR_W)
                 && (py >= P_BAR_Y) && (py < P_BAR_Y + BAR_H);
    wire in_o_bar = (px >= O_BAR_X) && (px < O_BAR_X + BAR_W)
                 && (py >= O_BAR_Y) && (py < O_BAR_Y + BAR_H);
 
    wire p_border = in_p_bar && (px == P_BAR_X || px == P_BAR_X + BAR_W - 1
                              || py == P_BAR_Y || py == P_BAR_Y + BAR_H - 1);
    wire o_border = in_o_bar && (px == O_BAR_X || px == O_BAR_X + BAR_W - 1
                              || py == O_BAR_Y || py == O_BAR_Y + BAR_H - 1);
 
    wire p_filled = (px - P_BAR_X) < player_hp;
    wire o_filled = (px - O_BAR_X) >= (BAR_W - opp_hp);
 
    reg in_p_bar_q, in_o_bar_q, p_border_q, o_border_q, p_filled_q, o_filled_q;
    always @(posedge pclk) begin
        in_p_bar_q <= in_p_bar;
        in_o_bar_q <= in_o_bar;
        p_border_q <= p_border;
        o_border_q <= o_border;
        p_filled_q <= p_filled;
        o_filled_q <= o_filled;
    end
 
    localparam [4:0] BORDER_R   = 5'd31, HP_FILL_R  = 5'd0,  HP_EMPTY_R = 5'd5;
    localparam [5:0] BORDER_G   = 6'd63, HP_FILL_G  = 6'd56, HP_EMPTY_G = 6'd5;
    localparam [4:0] BORDER_B   = 5'd31, HP_FILL_B  = 5'd0,  HP_EMPTY_B = 5'd5;
 
    // =========================================================================
    // 10) PIXEL MUX
    // =========================================================================
    reg den_d;
    always @(posedge pclk) begin
        den_d <= den;
    end
 
    reg [4:0] r_out;
    reg [5:0] g_out;
    reg [4:0] b_out;
    reg       den_out;
 
    always @(posedge pclk) begin
        den_out <= den_d & rst_n;
 
        if (p_border_q || o_border_q) begin
            r_out <= BORDER_R; g_out <= BORDER_G; b_out <= BORDER_B;
        end else if (in_p_bar_q) begin
            r_out <= p_filled_q ? HP_FILL_R : HP_EMPTY_R;
            g_out <= p_filled_q ? HP_FILL_G : HP_EMPTY_G;
            b_out <= p_filled_q ? HP_FILL_B : HP_EMPTY_B;
        end else if (in_o_bar_q) begin
            r_out <= o_filled_q ? HP_FILL_R : HP_EMPTY_R;
            g_out <= o_filled_q ? HP_FILL_G : HP_EMPTY_G;
            b_out <= o_filled_q ? HP_FILL_B : HP_EMPTY_B;
        end else if (sp_in) begin
            r_out <= sp_r; g_out <= sp_g; b_out <= sp_b;
        end else if (opp_in) begin
            r_out <= opp_r; g_out <= opp_g; b_out <= opp_b;
        end else begin
            r_out <= bg_r; g_out <= bg_g; b_out <= bg_b;
        end
    end
 
    assign LCD_R   = r_out;
    assign LCD_G   = g_out;
    assign LCD_B   = b_out;
    assign LCD_DEN = den_out;
    assign LCD_CLK = ~pclk;
 
endmodule