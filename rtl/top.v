module top (
    input  wire        CLK,

    output wire        LCD_CLK,
    output wire        LCD_DEN,
    output wire [4:0]  LCD_R,
    output wire [5:0]  LCD_G,
    output wire [4:0]  LCD_B,

    input  wire        BTN
);

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

    wire [9:0] px;
    wire [9:0] py;
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

    wire [4:0] menu_r;
    wire [5:0] menu_g;
    wire [4:0] menu_b;

    wire [4:0] menu3_r;
    wire [5:0] menu3_g;
    wire [4:0] menu3_b;

    menu_renderer u_menu (
        .pclk (pclk),
        .px   (px),
        .py   (py),
        .r    (menu_r),
        .g    (menu_g),
        .b    (menu_b)
    );

    menu3_renderer u_menu3 (
        .pclk (pclk),
        .px   (px),
        .py   (py),
        .r    (menu3_r),
        .g    (menu3_g),
        .b    (menu3_b)
    );

    reg [2:0] btn_sync = 3'b111;
    always @(posedge pclk) begin
        btn_sync <= {btn_sync[1:0], BTN};
    end

    wire btn_pressed = ~btn_sync[2];

    reg [19:0] debounce_cnt = 20'd0;
    reg        btn_state    = 1'b0;
    reg        btn_prev     = 1'b0;
    reg        screen_sel   = 1'b0;

    always @(posedge pclk) begin
        if (!rst_n) begin
            debounce_cnt <= 20'd0;
            btn_state    <= 1'b0;
            btn_prev     <= 1'b0;
            screen_sel   <= 1'b0;
        end else begin
            if (btn_pressed == btn_state) begin
                debounce_cnt <= 20'd0;
            end else begin
                debounce_cnt <= debounce_cnt + 1'b1;
                if (debounce_cnt == 20'hFFFFF) begin
                    btn_state    <= btn_pressed;
                    debounce_cnt <= 20'd0;
                end
            end

            btn_prev <= btn_state;
            if (btn_state && !btn_prev) begin
                screen_sel <= ~screen_sel;
            end
        end
    end

    reg den_d;
    always @(posedge pclk) begin
        den_d <= den;
    end

    assign LCD_R = screen_sel ? menu3_r : menu_r;
    assign LCD_G = screen_sel ? menu3_g : menu_g;
    assign LCD_B = screen_sel ? menu3_b : menu_b;

    assign LCD_DEN = den_d & rst_n;
    assign LCD_CLK = ~pclk;

endmodule
