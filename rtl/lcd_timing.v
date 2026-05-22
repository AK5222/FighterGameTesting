// 480x272 DE-only LCD timing generator (AT043TN24-style porches).
// H_total = 535 (HSW=4, HBP=43, H_active=480, HFP=8)
// V_total = 298 (VSW=10, VBP=12, V_active=272, VFP=4)
// At 9 MHz pixel clock: refresh = 9_000_000 / (535*298) ~= 56.5 Hz.

module lcd_timing (
    input  wire        pclk,
    input  wire        rst_n,
    output reg  [9:0]  px,          // 0..479 when den=1, else 0
    output reg  [9:0]  py,          // 0..271 when den=1, else 0
    output reg         den,         // data-enable for the panel
    output reg         frame_tick   // 1-cycle pulse at the end of each frame
);

    localparam H_SYNC   = 4;
    localparam H_BP     = 43;
    localparam H_ACTIVE = 480;
    localparam H_FP     = 8;
    localparam H_TOTAL  = H_SYNC + H_BP + H_ACTIVE + H_FP; // 535

    localparam V_SYNC   = 10;
    localparam V_BP     = 12;
    localparam V_ACTIVE = 272;
    localparam V_FP     = 4;
    localparam V_TOTAL  = V_SYNC + V_BP + V_ACTIVE + V_FP; // 298

    localparam H_ACTIVE_START = H_SYNC + H_BP;            // 47
    localparam H_ACTIVE_END   = H_ACTIVE_START + H_ACTIVE; // 527
    localparam V_ACTIVE_START = V_SYNC + V_BP;            // 22
    localparam V_ACTIVE_END   = V_ACTIVE_START + V_ACTIVE; // 294

    reg [9:0] h_cnt;
    reg [9:0] v_cnt;

    wire h_active = (h_cnt >= H_ACTIVE_START) && (h_cnt < H_ACTIVE_END);
    wire v_active = (v_cnt >= V_ACTIVE_START) && (v_cnt < V_ACTIVE_END);

    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            h_cnt      <= 10'd0;
            v_cnt      <= 10'd0;
            px         <= 10'd0;
            py         <= 10'd0;
            den        <= 1'b0;
            frame_tick <= 1'b0;
        end else begin
            // Horizontal counter
            if (h_cnt == H_TOTAL - 1) begin
                h_cnt <= 10'd0;
                // Vertical counter
                if (v_cnt == V_TOTAL - 1) begin
                    v_cnt      <= 10'd0;
                    frame_tick <= 1'b1;
                end else begin
                    v_cnt      <= v_cnt + 1'b1;
                    frame_tick <= 1'b0;
                end
            end else begin
                h_cnt      <= h_cnt + 1'b1;
                frame_tick <= 1'b0;
            end

            den <= h_active && v_active;
            px  <= h_active ? (h_cnt - H_ACTIVE_START) : 10'd0;
            py  <= v_active ? (v_cnt - V_ACTIVE_START) : 10'd0;
        end
    end

endmodule
