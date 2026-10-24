// I2S master transmitter for the Pmod I2S2 DAC (CS4344).
//   clk  = MCLK = 256 * Fs  (12.288 MHz -> Fs = 48 kHz)
//   SCLK = MCLK / 4         (64 * Fs, 32 SCLKs per channel)
//   LRCK = Fs, low = left
// Data is 24 bits, MSB first, one SCLK after the LRCK edge, changing on the
// SCLK falling edge.
//
// One sample frame = 256 clocks = 64 SCLKs = 32 for left + 32 for right.
// A single 8-bit counter (cnt) drives everything:
//   cnt[1]   -> SCLK      (toggles every 2 clocks)
//   cnt[7:2] -> which SCLK we're on (0..63)
//   cnt[7]   -> LRCK      (0 = left half, 1 = right half)
module i2s_tx (
    input  logic        clk,
    input  logic        rst,
    input  logic [23:0] left,        // left sample to send
    input  logic [23:0] right,       // right sample to send
    output logic        sample_req,  // pulse ~55 clocks before left/right are latched
    output logic        sclk,
    output logic        lrck,
    output logic        sdin
);
  logic [7:0] cnt;                  // position in the frame, 0..255
  logic [7:0] cnt_n;                // next value of cnt
  assign cnt_n = cnt + 8'd1;        // wraps 255 -> 0 automatically

  logic [5:0] slot_n;  // SCLK period index within the frame, 0..63
  logic [4:0] k_n;     // SCLK index within the channel, 0..31
  assign slot_n = cnt_n[7:2];       // divide by 4: 4 clocks per SCLK
  assign k_n    = slot_n[4:0];      // drop the left/right bit

  logic [23:0] l_q, r_q;            // samples latched for this frame
  logic [23:0] word_n;              // the channel currently being sent
  assign word_n = slot_n[5] ? r_q : l_q;  // second half of frame = right

  logic in_data;                    // 1 during the 24 data bits of a channel
  assign in_data = (k_n >= 5'd1) && (k_n <= 5'd24);  // bit 0 is the I2S 1-bit delay; 25..31 are padding

  assign sample_req = (cnt == 8'd200);  // ask for the next sample near the end of the frame

  always_ff @(posedge clk) begin
    if (rst) begin
      cnt  <= '0;
      sclk <= 1'b0;
      lrck <= 1'b0;
      sdin <= 1'b0;
      l_q  <= '0;
      r_q  <= '0;
    end else begin
      cnt  <= cnt_n;                                 // advance
      sclk <= cnt_n[1];                              // 2 clocks low, 2 high
      lrck <= slot_n[5];                             // 0 = left, 1 = right
      sdin <= in_data ? word_n[5'd24 - k_n] : 1'b0;  // k=1 -> bit 23 (MSB) ... k=24 -> bit 0
      if (cnt_n == 8'd0) begin                       // start of a new frame:
        l_q <= left;                                 // grab the new samples
        r_q <= right;
      end
    end
  end
endmodule
