// =============================================================================
// top.v -- TEMPORARY MENU TEST VERSION
// Displays rtl/menu.mem on the 480x272 LCD using menu_renderer.
// =============================================================================

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

    // =========================================================================
    // 3) MENU RENDERER
    // =========================================================================
    wire [4:0] menu_r;
    wire [5:0] menu_g;
    wire [4:0] menu_b;

    menu_renderer u_menu (
        .pclk (pclk),
        .px   (px),
        .py   (py),
        .r    (menu_r),
        .g    (menu_g),
        .b    (menu_b)
    );

    // =========================================================================
    // 4) LCD OUTPUT
    // =========================================================================
    // menu_renderer has 1-cycle latency, so delay DEN by 1 cycle too.
    reg den_d;

    always @(posedge pclk) begin
        den_d <= den;
    end

    assign LCD_R   = menu_r;
    assign LCD_G   = menu_g;
    assign LCD_B   = menu_b;
    assign LCD_DEN = den_d & rst_n;

    // Keep this the same as your original top.v
    assign LCD_CLK = ~pclk;

    // UART is unused in this temporary menu-only test.
    wire unused_uart_rx = UART_RX;

endmodule