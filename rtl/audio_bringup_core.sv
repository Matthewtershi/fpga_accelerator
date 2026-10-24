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
//
// Data path: UART bytes -> pair into 16-bit samples -> FIFO -> I2S -> DAC
module audio_bringup_core #(
    parameter int CLK_HZ  = 12_288_000,  // clock frequency, used by the UART
    parameter int BAUD    = 2_000_000,   // serial bits per second
    parameter int PREFILL = 1024         // samples to buffer before playing (~21 ms)
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
    output logic led_error,   // FIFO overflow or underrun since last clear
    output logic frame_tick,  // one pulse per 48 kHz frame
    output logic clear_tick,  // one pulse per btn_clear press
    input  logic alarm_active,             // 1 = play alarm_pcm instead of tone/stream
    input  logic signed [15:0] alarm_pcm   // alarm sample
);
  localparam int AW = 12;                           // FIFO address bits -> 2^12 = 4096 samples
  localparam logic [31:0] TONE_INC = 32'd39370534;  // 440 Hz at 48 kHz
  localparam int IDLE_BITS = 20;                    // ~85 ms without a byte

  // ---- Buttons: clean up bounce, get one pulse per press ----
  logic mode_press, clear_press;
  debounce u_db_mode (.clk, .rst, .in(btn_mode), .press(mode_press));
  debounce u_db_clear (.clk, .rst, .in(btn_clear), .press(clear_press));

  // ---- UART: one byte at a time from the PC ----
  logic [7:0] rx_data;     // the byte received
  logic rx_valid;          // 1 for one clock when rx_data is new
  uart_rx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_rx (
      .clk, .rst, .rxd(uart_rxd), .data(rx_data), .valid(rx_valid)
  );

  // Byte pairing with an idle timeout so a dropped byte cannot leave the
  // stream permanently misaligned.
  logic [IDLE_BITS:0] idle_cnt;   // clocks since the last byte
  logic idle;
  assign idle = idle_cnt[IDLE_BITS];  // top bit set = no bytes for ~85 ms

  logic        half;       // 1 = holding the low byte, waiting for the high byte
  logic [7:0]  lo_byte;    // low byte of the sample in progress
  logic        push;       // 1 for one clock: write push_data into the FIFO
  logic [15:0] push_data;  // the completed 16-bit sample

  always_ff @(posedge clk) begin
    push <= 1'b0;                          // default: no write this clock
    if (rst) begin
      idle_cnt <= '0;
      half     <= 1'b0;
    end else begin
      if (rx_valid) begin                  // a byte arrived
        idle_cnt <= '0;                    // restart idle timer
        if (!half) begin
          lo_byte <= rx_data;              // first byte = low half
          half    <= 1'b1;
        end else begin
          push_data <= {rx_data, lo_byte}; // second byte = high half; join them
          push      <= 1'b1;               // write the sample to the FIFO
          half      <= 1'b0;
        end
      end else if (!idle) begin
        idle_cnt <= idle_cnt + 1'b1;       // no byte: keep counting
      end else begin
        half <= 1'b0;                      // long silence: forget any half sample
      end
    end
  end

  // ---- FIFO: buffers samples so uneven serial timing doesn't glitch audio ----
  logic [15:0] fifo_rd_data;  // sample read out
  logic [AW:0] fifo_level;    // how many samples are stored
  logic fifo_empty, fifo_full, fifo_rd_en;
  sample_fifo #(.AW(AW), .DW(16)) u_fifo (
      .clk, .rst,
      .wr_en(push), .wr_data(push_data),
      .rd_en(fifo_rd_en), .rd_data(fifo_rd_data),
      .level(fifo_level), .empty(fifo_empty), .full(fifo_full)
  );

  // ---- I2S transmitter: sends left/right to the DAC 48,000 times a second ----
  logic sample_req;            // pulses once per sample: "give me the next one"
  logic [23:0] left, right;    // sample to send (DAC takes 24 bits)
  i2s_tx u_i2s (.clk, .rst, .left, .right, .sample_req, .sclk, .lrck, .sdin);

  // Test tone.
  logic [31:0] tone_phase;     // position in the sine wave; wraps every cycle
  logic signed [15:0] sine;    // sine value at that position
  sine_lut u_sine (.addr(tone_phase[31:24]), .data(sine));  // top 8 bits pick 1 of 256 table entries

  logic tone_mode;    // 1 = play test tone, 0 = play serial stream
  logic playing;      // stream is currently playing
  logic rd_pending;   // FIFO read issued last clock; data arrives this clock
  logic req_d;        // sample_req delayed one clock
  logic err;          // sticky error flag -> LED1
  logic dry;          // FIFO ran empty while playing
  logic signed [15:0] pcm;  // the sample actually sent to the DAC

  // OK to start playing: buffer is full enough, or the sender stopped and
  // whatever is left should be played out.
  logic start_ok;
  assign start_ok = (fifo_level >= (AW+1)'(PREFILL)) || (idle && !fifo_empty);

  // Read one sample from the FIFO when the DAC asks and we're streaming.
  assign fifo_rd_en = sample_req && !tone_mode && (playing || start_ok) && !fifo_empty;

  always_ff @(posedge clk) begin
    if (rst) begin
      tone_mode  <= 1'b1;               // boot into test-tone mode
      playing    <= 1'b0;
      rd_pending <= 1'b0;
      req_d      <= 1'b0;
      err        <= 1'b0;
      dry        <= 1'b0;
      tone_phase <= '0;
      pcm        <= '0;
    end else begin
      if (mode_press) tone_mode <= ~tone_mode;   // BTN0 flips mode
      else if (rx_valid) tone_mode <= 1'b0;      // any serial byte -> stream mode

      if (push && fifo_full) err <= 1'b1;        // overflow: sample lost
      // Underrun only counts as an error if the stream resumes afterwards;
      // draining at end of file is normal.
      if (rx_valid && dry) begin
        dry <= 1'b0;
        if (!idle) err <= 1'b1;
      end
      if (clear_press) err <= 1'b0;              // BTN1 clears the error

      rd_pending <= fifo_rd_en;                  // FIFO data is ready one clock after a read
      req_d      <= sample_req;

      if (sample_req) begin                      // once per 48 kHz sample:
        tone_phase <= tone_phase + TONE_INC;     // step through the sine wave
        if (!tone_mode && (playing || start_ok)) begin
          if (fifo_empty) begin
            playing <= 1'b0;                     // ran out: stop
            dry     <= 1'b1;
          end else begin
            playing <= 1'b1;                     // have data: keep playing
            dry     <= 1'b0;
          end
        end
        if (tone_mode) begin                     // tone mode overrides streaming
          playing <= 1'b0;
          dry     <= 1'b0;
        end
      end

      // One clock after sample_req: pick the sample for the next frame.
      // (tone_phase has advanced by then, which is harmless.)
      if (req_d) begin
        if (alarm_active) pcm <= alarm_pcm;           // alarm overrides everything
        else if (rd_pending) pcm <= $signed(fifo_rd_data);  // streamed sample
        else if (tone_mode) pcm <= sine >>> 3;  // -18 dBFS (divide by 8 = quieter)
        else pcm <= '0;                               // nothing to play: silence
      end
    end
  end

  assign left  = {pcm, 8'h00};    // 16-bit sample -> 24 bits by padding zeros at the bottom
  assign right = {pcm, 8'h00};    // same sample on both channels (mono)

  assign led_active = tone_mode | playing;   // LED0
  assign led_error  = err;                   // LED1

  assign frame_tick = sample_req;            // lets the alarm player step in sync
  assign clear_tick = clear_press;           // BTN1 also starts the alarm
endmodule
