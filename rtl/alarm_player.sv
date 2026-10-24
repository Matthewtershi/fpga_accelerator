// Plays the clip in alarm_rom once per start pulse.
// The ROM holds 16 kHz samples; the I2S frame rate is 48 kHz, so each ROM
// sample is held for 3 frames.
module alarm_player (
    input  logic               clk,
    input  logic               rst,
    input  logic               start,   // one-clock pulse: play from the beginning
    input  logic               frame,   // one-clock pulse per 48 kHz frame
    output logic               active,  // 1 while playing
    output logic signed [15:0] pcm      // current sample
);
  logic [16:0] addr;                    // which ROM sample we're on
  logic [16:0] last;                    // address of the final sample
  logic [1:0]  hold;                    // frames spent on this sample, 0..2
  logic signed [7:0] data;              // ROM output

  alarm_rom u_rom (.clk, .addr, .data, .last);

  always_ff @(posedge clk) begin
    if (rst) begin
      active <= 1'b0;
      addr   <= '0;
      hold   <= '0;
    end else if (start) begin           // (re)start from the top
      active <= 1'b1;
      addr   <= '0;
      hold   <= '0;
    end else if (frame && active) begin
      if (hold == 2'd2) begin           // held for 3 frames: next sample
        hold <= '0;
        if (addr == last) active <= 1'b0;   // end of clip
        else addr <= addr + 1'b1;
      end else begin
        hold <= hold + 1'b1;
      end
    end
  end

  assign pcm = {data, 8'h00};           // 8-bit -> 16-bit by padding zeros at the bottom
endmodule
