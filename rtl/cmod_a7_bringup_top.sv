// Cmod A7-35T top level: serial audio -> Pmod I2S2 DAC on header JA.
module cmod_a7_bringup_top (
    input  logic       sysclk,     // 12 MHz
    input  logic [1:0] btn,
    input  logic       uart_rxd,   // FT2232 TX -> FPGA (Digilent name: uart_txd_in)
    output logic [1:0] led,
    output logic       da_mclk,
    output logic       da_lrck,
    output logic       da_sclk,
    output logic       da_sdin
);
  // 12 MHz * 64 = 768 MHz VCO, / 62.5 = 12.288 MHz = 256 * 48 kHz.
  logic clk_fb, clk_audio_unbuf, clk_audio, locked;
  MMCME2_BASE #(
      .CLKIN1_PERIOD   (83.333),
      .DIVCLK_DIVIDE   (1),
      .CLKFBOUT_MULT_F (64.0),
      .CLKOUT0_DIVIDE_F(62.5)
  ) u_mmcm (
      .CLKIN1  (sysclk),
      .CLKFBIN (clk_fb),
      .CLKFBOUT(clk_fb),
      .CLKOUT0 (clk_audio_unbuf),
      .LOCKED  (locked),
      .PWRDWN  (1'b0),
      .RST     (1'b0)
  );
  BUFG u_bufg (.I(clk_audio_unbuf), .O(clk_audio));

  logic [2:0] rst_sync = 3'b111;
  always_ff @(posedge clk_audio or negedge locked)
    if (!locked) rst_sync <= 3'b111;
    else rst_sync <= {rst_sync[1:0], 1'b0};
  logic rst;
  assign rst = rst_sync[2];

  logic sclk, lrck, sdin;
  audio_bringup_core u_core (
      .clk(clk_audio), .rst,
      .uart_rxd,
      .btn_mode(btn[0]), .btn_clear(btn[1]),
      .sclk, .lrck, .sdin,
      .led_active(led[0]), .led_error(led[1])
  );

  assign da_lrck = lrck;
  assign da_sclk = sclk;
  assign da_sdin = sdin;

  // Forward the clock to the DAC through an ODDR rather than fabric routing.
  ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .INIT(1'b0), .SRTYPE("SYNC")) u_mclk (
      .Q(da_mclk), .C(clk_audio), .CE(1'b1), .D1(1'b1), .D2(1'b0), .R(1'b0), .S(1'b0)
  );
endmodule
