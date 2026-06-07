module uart_rx #(
    parameter CLK_FREQ  = 9_000_000,
    parameter BAUD_RATE = 9_600
) (
    input  wire       pclk,
    input  wire       rst_n,
    input  wire       rx,
    output reg        data_valid,
    output reg  [7:0] data_out
);

    localparam CLKS_PER_BIT = CLK_FREQ / BAUD_RATE;

    localparam IDLE  = 2'd0;
    localparam START = 2'd1;
    localparam DATA  = 2'd2;
    localparam STOP  = 2'd3;

    reg [1:0]  state     = IDLE;
    reg [9:0]  clk_cnt   = 0;      // widened to 10 bits
    reg [2:0]  bit_idx   = 0;
    reg [7:0]  shift_reg = 0;
    reg        rx_sync1  = 1;
    reg        rx_sync2  = 1;

    always @(posedge pclk) begin
        rx_sync1 <= rx;
        rx_sync2 <= rx_sync1;
    end

    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= IDLE;
            clk_cnt    <= 0;
            bit_idx    <= 0;
            shift_reg  <= 0;
            data_valid <= 0;
            data_out   <= 0;
        end else begin
            data_valid <= 0;

            case (state)
                IDLE: begin
                    if (rx_sync2 == 0) begin
                        state   <= START;
                        clk_cnt <= 0;
                    end
                end

                START: begin
                    if (clk_cnt == (CLKS_PER_BIT / 2) - 1) begin
                        if (rx_sync2 == 0) begin
                            state   <= DATA;
                            clk_cnt <= 0;
                            bit_idx <= 0;
                        end else begin
                            state <= IDLE;
                        end
                    end else begin
                        clk_cnt <= clk_cnt + 1;
                    end
                end

                DATA: begin
                    if (clk_cnt == CLKS_PER_BIT - 1) begin
                        clk_cnt            <= 0;
                        shift_reg[bit_idx] <= rx_sync2;
                        if (bit_idx == 7) begin
                            state <= STOP;
                        end else begin
                            bit_idx <= bit_idx + 1;
                        end
                    end else begin
                        clk_cnt <= clk_cnt + 1;
                    end
                end

                STOP: begin
                    if (clk_cnt == CLKS_PER_BIT - 1) begin
                        data_valid <= 1;
                        data_out   <= shift_reg;
                        state      <= IDLE;
                        clk_cnt    <= 0;
                    end else begin
                        clk_cnt <= clk_cnt + 1;
                    end
                end
            endcase
        end
    end

endmodule