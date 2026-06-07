module uart_input (
    input  wire       pclk,
    input  wire       rst_n,
    input  wire       rx,
    input  wire       frame_tick,

    output reg        p1_left,
    output reg        p1_right,
    output reg        p1_jump,
    output reg        p1_block,
    output reg        p1_atk1,
    output reg        p1_atk2,

    output reg        p2_left,
    output reg        p2_right,
    output reg        p2_jump,
    output reg        p2_block,
    output reg        p2_atk1,
    output reg        p2_atk2
);

    localparam DIR_NONE  = 3'd0;
    localparam DIR_LEFT  = 3'd1;
    localparam DIR_RIGHT = 3'd2;
    localparam DIR_UP    = 3'd3;
    localparam DIR_DOWN  = 3'd4;

    wire       byte_valid;
    wire [7:0] byte_data;

    uart_rx #(
        .CLK_FREQ  (9_000_000),
        .BAUD_RATE (9_600)
    ) u_rx (
        .pclk       (pclk),
        .rst_n      (rst_n),
        .rx         (rx),
        .data_valid (byte_valid),
        .data_out   (byte_data)
    );

    localparam WAIT_START  = 2'd0;
    localparam WAIT_ID     = 2'd1;
    localparam WAIT_DIR    = 2'd2;
    localparam WAIT_BTNS   = 2'd3;

    reg [1:0] pkt_state = WAIT_START;
    reg [7:0] pkt_id;
    reg [7:0] pkt_dir;

    // Shadow registers written by UART, latched to outputs on frame_tick
    reg p1_left_next,  p1_right_next,  p1_jump_next,  p1_block_next;
    reg p1_atk1_next,  p1_atk2_next;
    reg p2_left_next,  p2_right_next,  p2_jump_next,  p2_block_next;
    reg p2_atk1_next,  p2_atk2_next;

    // UART packet decoder writes to shadow registers
    // Blocked during frame_tick to prevent race with latch
    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            pkt_state      <= WAIT_START;
            p1_left_next   <= 0; p1_right_next <= 0;
            p1_jump_next   <= 0; p1_block_next <= 0;
            p1_atk1_next   <= 0; p1_atk2_next  <= 0;
            p2_left_next   <= 0; p2_right_next <= 0;
            p2_jump_next   <= 0; p2_block_next <= 0;
            p2_atk1_next   <= 0; p2_atk2_next  <= 0;
        end else if (byte_valid && !frame_tick) begin
            case (pkt_state)
                WAIT_START: begin
                    if (byte_data == 8'hAA)
                        pkt_state <= WAIT_ID;
                end
                WAIT_ID: begin
                    pkt_id    <= byte_data;
                    pkt_state <= WAIT_DIR;
                end
                WAIT_DIR: begin
                    pkt_dir   <= byte_data;
                    pkt_state <= WAIT_BTNS;
                end
                WAIT_BTNS: begin
                    pkt_state <= WAIT_START;
                    if (pkt_id == 8'd1) begin
                        p1_left_next  <= (pkt_dir == DIR_LEFT);
                        p1_right_next <= (pkt_dir == DIR_RIGHT);
                        p1_jump_next  <= (pkt_dir == DIR_UP);
                        p1_block_next <= (pkt_dir == DIR_DOWN);
                        p1_atk1_next  <= byte_data[0];
                        p1_atk2_next  <= byte_data[1];
                    end else if (pkt_id == 8'd2) begin
                        p2_left_next  <= (pkt_dir == DIR_LEFT);
                        p2_right_next <= (pkt_dir == DIR_RIGHT);
                        p2_jump_next  <= (pkt_dir == DIR_UP);
                        p2_block_next <= (pkt_dir == DIR_DOWN);
                        p2_atk1_next  <= byte_data[0];
                        p2_atk2_next  <= byte_data[1];
                    end
                end
            endcase
        end
    end

    // Latch shadow registers to outputs on frame_tick
    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            p1_left  <= 0; p1_right <= 0;
            p1_jump  <= 0; p1_block <= 0;
            p1_atk1  <= 0; p1_atk2  <= 0;
            p2_left  <= 0; p2_right <= 0;
            p2_jump  <= 0; p2_block <= 0;
            p2_atk1  <= 0; p2_atk2  <= 0;
        end else if (frame_tick) begin
            p1_left  <= p1_left_next;  p1_right <= p1_right_next;
            p1_jump  <= p1_jump_next;  p1_block <= p1_block_next;
            p1_atk1  <= p1_atk1_next;  p1_atk2  <= p1_atk2_next;
            p2_left  <= p2_left_next;  p2_right <= p2_right_next;
            p2_jump  <= p2_jump_next;  p2_block <= p2_block_next;
            p2_atk1  <= p2_atk1_next;  p2_atk2  <= p2_atk2_next;
        end
    end

endmodule