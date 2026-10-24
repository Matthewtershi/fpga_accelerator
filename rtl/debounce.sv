// Two-flop synchronizer, ~21 ms debounce at 12.288 MHz, and a one-clock
// pulse on each press.
module debounce #(
    parameter int STABLE_CLKS = 2**18
) (
    input  logic clk,
    input  logic rst,
    input  logic in,
    output logic press
);
  logic meta, sync, state;
  logic [$clog2(STABLE_CLKS)-1:0] cnt;

  always_ff @(posedge clk) begin
    {sync, meta} <= {meta, in};
    press <= 1'b0;
    if (rst) begin
      state <= 1'b0;
      cnt   <= '0;
    end else if (sync == state) begin
      cnt <= '0;
    end else begin
      cnt <= cnt + 1'b1;
      if (cnt == STABLE_CLKS - 1) begin
        state <= sync;
        cnt   <= '0;
        press <= sync;
      end
    end
  end
endmodule
