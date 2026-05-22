// Synchronizer + counter-based debouncer for a single mechanical button.
// Default ~10 ms at 9 MHz pclk (90_000 cycles). Output is active-high "pressed".

module debounce #(
    parameter integer COUNT_MAX = 90_000
) (
    input  wire pclk,
    input  wire rst_n,
    input  wire btn_raw_n,    // active-low from the pin (pull-up, pressed=0)
    output reg  pressed       // active-high, debounced
);

    // 2-FF synchronizer
    reg s0, s1;
    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            s0 <= 1'b1;
            s1 <= 1'b1;
        end else begin
            s0 <= btn_raw_n;
            s1 <= s0;
        end
    end

    wire sync_pressed = ~s1;  // flip to active-high view

    // Counter that must saturate before we accept a level change
    reg [$clog2(COUNT_MAX+1)-1:0] cnt;

    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            cnt     <= 0;
            pressed <= 1'b0;
        end else if (sync_pressed != pressed) begin
            if (cnt == COUNT_MAX) begin
                pressed <= sync_pressed;
                cnt     <= 0;
            end else begin
                cnt <= cnt + 1'b1;
            end
        end else begin
            cnt <= 0;
        end
    end

endmodule
