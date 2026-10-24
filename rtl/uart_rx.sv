// 8N1 UART receiver with a fractional baud generator, so the baud rate does
// not need to divide the clock evenly (12.288 MHz / 2 Mbaud = 6.144).
//
// 8N1 = 1 start bit (0), 8 data bits LSB first, 1 stop bit (1). Line idles at 1.
// Timing: a 16-bit accumulator adds INC every clock; each time it overflows,
// one bit period has passed and we sample the line.
module uart_rx #(
    parameter int CLK_HZ = 12_288_000,
    parameter int BAUD   = 2_000_000
) (
    input  logic       clk,
    input  logic       rst,
    input  logic       rxd,      // serial line from the PC
    output logic [7:0] data,     // received byte
    output logic       valid     // 1 for one clock when data is new
);
  localparam int ACC_W = 16;     // accumulator width
  // INC = 65536 * BAUD / CLK_HZ, rounded -> overflows once per bit period.
  localparam logic [ACC_W-1:0] INC = ACC_W'(((64'd1 << ACC_W) * BAUD + CLK_HZ / 2) / CLK_HZ);
  // The start edge is seen ~3 clocks late (synchronizer + edge detect). The
  // first tick should sample rx_s (itself 2 clocks late) in the middle of the
  // start bit: 0.5 bit + 2 clocks after the edge, which is 2 clocks after
  // busy is set. Later ticks are one bit apart.
  localparam logic [ACC_W-1:0] ACC_START = ACC_W'((64'd1 << ACC_W) - 2 * INC + (INC / 2));

  // Two flip-flops in a row: the input isn't synced to our clock, this
  // prevents metastability from reaching the logic.
  logic rx_meta, rx_s;
  always_ff @(posedge clk) {rx_s, rx_meta} <= {rx_meta, rxd};

  logic [ACC_W-1:0] acc;         // baud-rate accumulator
  logic [3:0] bitn;  // 0 start bit, 1..8 data bits, 9 stop bit
  logic busy;                    // 1 while receiving a byte
  logic [ACC_W:0] acc_next;      // one extra bit to catch the overflow
  assign acc_next = {1'b0, acc} + {1'b0, INC};

  always_ff @(posedge clk) begin
    valid <= 1'b0;                     // default: no new byte
    if (rst) begin
      busy <= 1'b0;
      acc  <= '0;
      bitn <= '0;
      data <= '0;
    end else if (!busy) begin          // idle: wait for a start bit
      if (!rx_s) begin                 // line went low = start bit
        busy <= 1'b1;
        acc  <= ACC_START;             // preload so the first sample lands mid-bit
        bitn <= '0;
      end
    end else begin                     // receiving
      acc <= acc_next[ACC_W-1:0];
      if (acc_next[ACC_W]) begin       // overflow = middle of the next bit
        bitn <= bitn + 4'd1;
        if (bitn == 4'd0) begin
          if (rx_s) busy <= 1'b0;  // glitch, not a start bit
        end else if (bitn == 4'd9) begin   // stop bit
          busy  <= 1'b0;
          valid <= rx_s;  // drop bytes with a bad stop bit
        end else begin                     // data bits 1..8
          data <= {rx_s, data[7:1]};       // shift in from the top; LSB arrives first
        end
      end
    end
  end
endmodule
