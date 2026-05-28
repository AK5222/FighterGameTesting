// =============================================================================
// lcd_timing.v -- generates the "raster scan" coordinates for the LCD panel.
// =============================================================================
//
// What is a raster scan?
//   Every LCD draws pixels one at a time, left-to-right, top-to-bottom, over
//   and over forever. This module simulates that scanning beam with two
//   counters:
//       h_cnt = which column we're on
//       v_cnt = which row we're on
//   Every pclk tick (~9 million times per second), h_cnt increments by 1.
//   When h_cnt reaches the end of a line, it resets and v_cnt goes up by 1.
//   When v_cnt reaches the end of the screen, both reset and we've drawn
//   one complete frame.
//
// What are "porches" (HSW, HBP, HFP)?
//   The visible area of the screen is 480x272, but the panel needs a few
//   extra "blanking" cycles around it. These come from the era of CRT TVs
//   when the electron beam had to physically move back to start the next
//   line. Modern LCDs keep the same convention. The porches are:
//       HSW (Horizontal Sync Width)  -- sync pulse at start of each line
//       HBP (Horizontal Back Porch)  -- delay after sync, before drawing
//       (then 480 visible pixels)
//       HFP (Horizontal Front Porch) -- delay after drawing, before next line
//   Same idea for V (vertical), wrapped around the 272 visible rows.
//
//   We use AT043TN24-style timing -- standard for generic 4.3" 480x272 panels.
//
// Outputs we send out:
//   px, py     = the pixel currently being drawn (0..479 across, 0..271 down)
//   den        = "data enable" -- 1 only inside the visible area; 0 in porches
//                The panel only reads RGB when DEN=1.
//   frame_tick = single-cycle pulse at the very end of each frame (used by
//                top.v as a "once per frame" event for moving the sprite)
// =============================================================================

module lcd_timing (
    input  wire        pclk,
    input  wire        rst_n,
    output reg  [9:0]  px,
    output reg  [9:0]  py,
    output reg         den,
    output reg         frame_tick
);

    // ---- Horizontal timing parameters (in pixels) ----
    localparam H_SYNC   = 4;
    localparam H_BP     = 43;
    localparam H_ACTIVE = 480;          // visible width
    localparam H_FP     = 8;
    localparam H_TOTAL  = H_SYNC + H_BP + H_ACTIVE + H_FP;  // 535

    // ---- Vertical timing parameters (in lines) ----
    localparam V_SYNC   = 10;
    localparam V_BP     = 12;
    localparam V_ACTIVE = 272;          // visible height
    localparam V_FP     = 4;
    localparam V_TOTAL  = V_SYNC + V_BP + V_ACTIVE + V_FP;  // 298

    // ---- Derived: where the visible area starts/ends in counter space ----
    localparam H_ACTIVE_START = H_SYNC + H_BP;              // 47
    localparam H_ACTIVE_END   = H_ACTIVE_START + H_ACTIVE;  // 527
    localparam V_ACTIVE_START = V_SYNC + V_BP;              // 22
    localparam V_ACTIVE_END   = V_ACTIVE_START + V_ACTIVE;  // 294

    // Refresh rate = pclk / (H_TOTAL * V_TOTAL) = 9 MHz / (535 * 298) ~= 56.5 Hz

    // The actual scanning counters.
    reg [9:0] h_cnt;
    reg [9:0] v_cnt;

    // Are we currently inside the visible window (horizontally / vertically)?
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
            // ---- Advance horizontal counter ----
            if (h_cnt == H_TOTAL - 1) begin
                // End of this line. Reset h_cnt, advance v_cnt.
                h_cnt <= 10'd0;
                if (v_cnt == V_TOTAL - 1) begin
                    // End of this frame. Reset v_cnt. Pulse frame_tick once.
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

            // ---- Compute the outputs: visible-area coords and DEN flag ----
            // den is 1 only when both h and v are in the active window.
            den <= h_active && v_active;
            // Subtract the offset so px/py are 0-based within the visible area.
            // (Outside the visible area, we output 0 -- those values aren't used.)
            px  <= h_active ? (h_cnt - H_ACTIVE_START) : 10'd0;
            py  <= v_active ? (v_cnt - V_ACTIVE_START) : 10'd0;
        end
    end

endmodule
