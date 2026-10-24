// Cmod A7-35T top level: serial audio -> Pmod I2S2 DAC on header JA.
// This file only does board-level plumbing: make the audio clock, make a
// reset, connect the core to the pins. The real logic is in audio_bringup_core.
module cmod_a7_bringup_top (
    input  logic       sysclk,     // 12 MHz
    input  logic [1:0] btn,        // the two push buttons
    input  logic       uart_rxd,   // FT2232 TX -> FPGA (Digilent name: uart_txd_in)
    output logic [1:0] led,        // the two green LEDs
    output logic       da_mclk,    // DAC master clock (12.288 MHz)
    output logic       da_lrck,    // DAC left/right select (48 kHz)
    output logic       da_sclk,    // DAC bit clock (3.072 MHz)
    output logic       da_sdin     // DAC serial data, one bit per SCLK
);
  // 12 MHz * 64 = 768 MHz VCO, / 62.5 = 12.288 MHz = 256 * 48 kHz.
  logic clk_fb, clk_audio_unbuf, clk_audio, locked;
  MMCME2_BASE #(                     // built-in clock synthesizer block
      .CLKIN1_PERIOD   (83.333),     // input period in ns (12 MHz)
      .DIVCLK_DIVIDE   (1),          // no input divide
      .CLKFBOUT_MULT_F (64.0),       // multiply up to 768 MHz internally
      .CLKOUT0_DIVIDE_F(62.5)        // divide down to 12.288 MHz
  ) u_mmcm (
      .CLKIN1  (sysclk),             // board clock in
      .CLKFBIN (clk_fb),             // feedback loop, required by the MMCM
      .CLKFBOUT(clk_fb),
      .CLKOUT0 (clk_audio_unbuf),    // new clock out (not yet buffered)
      .LOCKED  (locked),             // 1 once the output clock is stable
      .PWRDWN  (1'b0),               // never power down
      .RST     (1'b0)                // never reset
  );
  BUFG u_bufg (.I(clk_audio_unbuf), .O(clk_audio));  // global clock buffer: reaches every flop with low skew

  // Hold reset high until the clock is locked, then release it 3 clocks later.
  logic [2:0] rst_sync = 3'b111;                     // starts in reset at power-up
  always_ff @(posedge clk_audio or negedge locked)
    if (!locked) rst_sync <= 3'b111;                 // clock not stable: force reset
    else rst_sync <= {rst_sync[1:0], 1'b0};          // shift zeros in, one per clock
  logic rst;
  assign rst = rst_sync[2];                          // reset seen by the rest of the design

  logic sclk, lrck, sdin;
  logic led_error, frame_tick, clear_tick, alarm_active;
  logic signed [15:0] alarm_pcm;
  audio_bringup_core u_core (        // the actual design
      .clk(clk_audio), .rst,         // .rst is shorthand for .rst(rst)
      .uart_rxd,
      .btn_mode(btn[0]), .btn_clear(btn[1]),
      .sclk, .lrck, .sdin,
      .led_active(led[0]), .led_error,
      .frame_tick, .clear_tick,
      .alarm_active, .alarm_pcm
  );

  // BTN1 plays the clip stored in block RAM (see scripts/gen_alarm_rom.py).
  alarm_player u_alarm (
      .clk(clk_audio), .rst,
      .start(clear_tick), .frame(frame_tick),
      .active(alarm_active), .pcm(alarm_pcm)
  );

  assign led[1] = led_error | alarm_active;  // LED1: error, or alarm playing

  assign da_lrck = lrck;             // core I2S outputs straight to the Pmod pins
  assign da_sclk = sclk;
  assign da_sdin = sdin;

  // Forward the clock to the DAC through an ODDR rather than fabric routing.
  // D1=1 on the rising edge, D2=0 on the falling edge -> a clean copy of clk_audio.
  ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .INIT(1'b0), .SRTYPE("SYNC")) u_mclk (
      .Q(da_mclk), .C(clk_audio), .CE(1'b1), .D1(1'b1), .D2(1'b0), .R(1'b0), .S(1'b0)
  );
endmodule
