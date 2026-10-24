// Two-flop synchronizer, ~21 ms debounce at 12.288 MHz, and a one-clock
// pulse on each press.
//
// Mechanical buttons "bounce" (flicker on/off) for a few ms when pressed.
// Only accept a new state after it has held steady for STABLE_CLKS clocks.
module debounce #(
    parameter int STABLE_CLKS = 2**18   // 262144 clocks ~= 21 ms
) (
    input  logic clk,
    input  logic rst,
    input  logic in,      // raw button
    output logic press    // 1 for one clock when a press is accepted
);
  logic meta, sync, state;                 // state = accepted button value
  logic [$clog2(STABLE_CLKS)-1:0] cnt;     // how long sync has differed from state

  always_ff @(posedge clk) begin
    {sync, meta} <= {meta, in};            // two flops: make the input safe to use
    press <= 1'b0;                         // default: no pulse
    if (rst) begin
      state <= 1'b0;
      cnt   <= '0;
    end else if (sync == state) begin
      cnt <= '0;                           // no change (or it bounced back): restart
    end else begin
      cnt <= cnt + 1'b1;                   // input differs: count how long
      if (cnt == STABLE_CLKS - 1) begin    // held long enough: accept it
        state <= sync;
        cnt   <= '0;
        press <= sync;                     // pulse on press only, not on release
      end
    end
  end
endmodule
