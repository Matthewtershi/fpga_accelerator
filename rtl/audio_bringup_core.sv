// Serial-to-I2S audio bring-up. Everything runs on the 12.288 MHz audio clock.
//
// UART stream format: signed 16-bit little-endian mono samples at 48 kHz,
// sent to both channels. Samples are buffered in a FIFO; playback starts once
// PREFILL samples are queued (or the stream goes idle with data left over)
// and stops when the FIFO runs dry.
//
// Boot state is a 440 Hz test tone, so the DAC and headphones can be checked
// before any serial data is sent. The first UART byte switches to stream mode.
//   btn_mode  toggles tone / stream
//   btn_clear clears the sticky error LED
module audio_bringup_core #(
    parameter int CLK_HZ  = 12_288_000,
    parameter int BAUD    = 2_000_000,
    parameter int PREFILL = 1024
) (
    input  logic clk,
    input  logic rst,
    input  logic uart_rxd,
    input  logic btn_mode,
    input  logic btn_clear,
    output logic sclk,
    output logic lrck,
    output logic sdin,
    output logic led_active,  // tone playing, or stream playing
    output logic led_error    // FIFO overflow or underrun since last clear
);
  localparam int AW = 12;
  localparam logic [31:0] TONE_INC = 32'd39370534;  // 440 Hz at 48 kHz
  localparam int IDLE_BITS = 20;                    // ~85 ms without a byte

  logic mode_press, clear_press;
  debounce u_db_mode (.clk, .rst, .in(btn_mode), .press(mode_press));
  debounce u_db_clear (.clk, .rst, .in(btn_clear), .press(clear_press));

  logic [7:0] rx_data;
  logic rx_valid;
  uart_rx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_rx (
      .clk, .rst, .rxd(uart_rxd), .data(rx_data), .valid(rx_valid)
  );

  // Byte pairing with an idle timeout so a dropped byte cannot leave the
  // stream permanently misaligned.
  logic [IDLE_BITS:0] idle_cnt;
  logic idle;
  assign idle = idle_cnt[IDLE_BITS];

  logic        half;
  logic [7:0]  lo_byte;
  logic        push;
  logic [15:0] push_data;

  always_ff @(posedge clk) begin
    push <= 1'b0;
    if (rst) begin
      idle_cnt <= '0;
      half     <= 1'b0;
    end else begin
      if (rx_valid) begin
        idle_cnt <= '0;
        if (!half) begin
          lo_byte <= rx_data;
          half    <= 1'b1;
        end else begin
          push_data <= {rx_data, lo_byte};
          push      <= 1'b1;
          half      <= 1'b0;
        end
      end else if (!idle) begin
        idle_cnt <= idle_cnt + 1'b1;
      end else begin
        half <= 1'b0;
      end
    end
  end

  logic [15:0] fifo_rd_data;
  logic [AW:0] fifo_level;
  logic fifo_empty, fifo_full, fifo_rd_en;
  sample_fifo #(.AW(AW), .DW(16)) u_fifo (
      .clk, .rst,
      .wr_en(push), .wr_data(push_data),
      .rd_en(fifo_rd_en), .rd_data(fifo_rd_data),
      .level(fifo_level), .empty(fifo_empty), .full(fifo_full)
  );

  logic sample_req;
  logic [23:0] left, right;
  i2s_tx u_i2s (.clk, .rst, .left, .right, .sample_req, .sclk, .lrck, .sdin);

  // Test tone.
  logic [31:0] tone_phase;
  logic signed [15:0] sine;
  sine_lut u_sine (.addr(tone_phase[31:24]), .data(sine));

  logic tone_mode, playing, rd_pending, req_d, err, dry;
  logic signed [15:0] pcm;

  logic start_ok;
  assign start_ok = (fifo_level >= (AW+1)'(PREFILL)) || (idle && !fifo_empty);

  assign fifo_rd_en = sample_req && !tone_mode && (playing || start_ok) && !fifo_empty;

  always_ff @(posedge clk) begin
    if (rst) begin
      tone_mode  <= 1'b1;
      playing    <= 1'b0;
      rd_pending <= 1'b0;
      req_d      <= 1'b0;
      err        <= 1'b0;
      dry        <= 1'b0;
      tone_phase <= '0;
      pcm        <= '0;
    end else begin
      if (mode_press) tone_mode <= ~tone_mode;
      else if (rx_valid) tone_mode <= 1'b0;

      if (push && fifo_full) err <= 1'b1;
      // Underrun only counts as an error if the stream resumes afterwards;
      // draining at end of file is normal.
      if (rx_valid && dry) begin
        dry <= 1'b0;
        if (!idle) err <= 1'b1;
      end
      if (clear_press) err <= 1'b0;

      rd_pending <= fifo_rd_en;
      req_d      <= sample_req;

      if (sample_req) begin
        tone_phase <= tone_phase + TONE_INC;
        if (!tone_mode && (playing || start_ok)) begin
          if (fifo_empty) begin
            playing <= 1'b0;
            dry     <= 1'b1;
          end else begin
            playing <= 1'b1;
            dry     <= 1'b0;
          end
        end
        if (tone_mode) begin
          playing <= 1'b0;
          dry     <= 1'b0;
        end
      end

      // One clock after sample_req: pick the sample for the next frame.
      // (tone_phase has advanced by then, which is harmless.)
      if (req_d) begin
        if (rd_pending) pcm <= $signed(fifo_rd_data);
        else if (tone_mode) pcm <= sine >>> 3;  // -18 dBFS
        else pcm <= '0;
      end
    end
  end

  assign left  = {pcm, 8'h00};
  assign right = {pcm, 8'h00};

  assign led_active = tone_mode | playing;
  assign led_error  = err;
endmodule
