// =============================================================================
// debounce.v -- clean up a noisy mechanical button signal.
// =============================================================================
//
// The problem (button bounce):
//   When you press a physical button, the metal contacts inside slam together
//   and physically bounce off each other for ~5-20 milliseconds. During that
//   time, the electrical signal flips on/off rapidly -- you might see 20
//   "presses" from a single tap. If we used the raw signal directly, the
//   sprite would jitter erratically or move 20 pixels per tap.
//
// The fix (debouncing):
//   Wait for the signal to stay stable for a while (10 ms here) before
//   accepting any change. The button has to be in its new state continuously
//   for the whole 10 ms window before we update our "pressed" output.
//
// Bonus problem (metastability):
//   The raw button pin is "asynchronous" -- it can change at any time,
//   including right at the rising edge of our clock. This can put a flip-flop
//   into a metastable state (output briefly undefined). Solution: pass the
//   signal through TWO flip-flops in series before using it. By the second
//   flop, any metastability has settled. This is called a "2-FF synchronizer".
//
// Pin convention:
//   The button is wired so that pressing it pulls the pin to GND (=0), and
//   when released, an internal pull-up resistor pulls it to 3.3V (=1).
//   So the raw input is "active LOW" (pressed = 0).
//   We invert it internally so the output is "active HIGH" (pressed = 1)
//   which is the easier convention to use elsewhere.
// =============================================================================

module debounce #(
    parameter integer COUNT_MAX = 90_000   // ~10 ms at 9 MHz pclk
) (
    input  wire pclk,
    input  wire rst_n,
    input  wire btn_raw_n,    // raw pin: 0 = pressed, 1 = released
    output reg  pressed       // clean output: 1 = pressed, 0 = released
);

    // ---- 2-FF synchronizer ----
    // s0 captures the (possibly metastable) raw pin.
    // s1 captures s0 -- by now any metastability has resolved.
    reg s0, s1;
    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            s0 <= 1'b1;   // default to "not pressed" while in reset
            s1 <= 1'b1;
        end else begin
            s0 <= btn_raw_n;
            s1 <= s0;
        end
    end

    // Flip the polarity so 1 = pressed (easier downstream).
    wire sync_pressed = ~s1;

    // ---- Debounce counter ----
    // If the synchronized signal differs from our current "pressed" output,
    // count up. Only once the counter saturates (10 ms of steady mismatch)
    // do we actually flip the output. If the signal flickers back during
    // the wait, the counter resets and we start over.
    reg [$clog2(COUNT_MAX+1)-1:0] cnt;

    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            cnt     <= 0;
            pressed <= 1'b0;
        end else if (sync_pressed != pressed) begin
            // Signal disagrees with our state -- count toward a switch
            if (cnt == COUNT_MAX) begin
                pressed <= sync_pressed;   // commit the change
                cnt     <= 0;
            end else begin
                cnt <= cnt + 1'b1;
            end
        end else begin
            // Signal agrees with our state -- no change pending, reset counter
            cnt <= 0;
        end
    end

endmodule
