// I2S master transmitter for the Pmod I2S2 DAC (CS4344).
//   clk  = MCLK = 256 * Fs  (12.288 MHz -> Fs = 48 kHz)
//   SCLK = MCLK / 4         (64 * Fs, 32 SCLKs per channel)
//   LRCK = Fs, low = left
// Data is 24 bits, MSB first, one SCLK after the LRCK edge, changing on the
// SCLK falling edge.
module i2s_tx (
    input  logic        clk,
    input  logic        rst,
    input  logic [23:0] left,
    input  logic [23:0] right,
    output logic        sample_req,  // pulse ~55 clocks before left/right are latched
    output logic        sclk,
    output logic        lrck,
    output logic        sdin
);
  logic [7:0] cnt;
  logic [7:0] cnt_n;
  assign cnt_n = cnt + 8'd1;

  logic [5:0] slot_n;  // SCLK period index within the frame, 0..63
  logic [4:0] k_n;     // SCLK index within the channel, 0..31
  assign slot_n = cnt_n[7:2];
  assign k_n    = slot_n[4:0];

  logic [23:0] l_q, r_q;
  logic [23:0] word_n;
  assign word_n = slot_n[5] ? r_q : l_q;

  logic in_data;
  assign in_data = (k_n >= 5'd1) && (k_n <= 5'd24);

  assign sample_req = (cnt == 8'd200);

  always_ff @(posedge clk) begin
    if (rst) begin
      cnt  <= '0;
      sclk <= 1'b0;
      lrck <= 1'b0;
      sdin <= 1'b0;
      l_q  <= '0;
      r_q  <= '0;
    end else begin
      cnt  <= cnt_n;
      sclk <= cnt_n[1];
      lrck <= slot_n[5];
      sdin <= in_data ? word_n[5'd24 - k_n] : 1'b0;
      if (cnt_n == 8'd0) begin
        l_q <= left;
        r_q <= right;
      end
    end
  end
endmodule
