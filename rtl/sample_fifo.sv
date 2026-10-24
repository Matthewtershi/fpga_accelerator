// Synchronous FIFO with a registered (block RAM friendly) read port.
// rd_data is valid the cycle after rd_en.
//
// A circular buffer: write at wr_ptr, read at rd_ptr, both wrap around.
// Pointers are one bit wider than the address so full and empty differ.
module sample_fifo #(
    parameter int AW = 12,   // address bits -> 2^AW entries
    parameter int DW = 16    // bits per entry
) (
    input  logic          clk,
    input  logic          rst,
    input  logic          wr_en,     // write wr_data this clock
    input  logic [DW-1:0] wr_data,
    input  logic          rd_en,     // read one entry this clock
    output logic [DW-1:0] rd_data,   // the entry read (one clock later)
    output logic [AW:0]   level,     // number of entries stored
    output logic          empty,
    output logic          full
);
  logic [DW-1:0] mem[2**AW];         // the storage; Vivado maps this to block RAM
  logic [AW:0] wr_ptr, rd_ptr;       // total writes / reads so far (wrapping)

  assign level = wr_ptr - rd_ptr;                 // stored = written - read
  assign empty = (level == '0);
  assign full  = (level == (AW+1)'(2**AW));       // all 4096 slots used

  always_ff @(posedge clk) begin
    if (rst) begin
      wr_ptr <= '0;
      rd_ptr <= '0;
    end else begin
      if (wr_en && !full) begin                   // ignore writes when full
        mem[wr_ptr[AW-1:0]] <= wr_data;           // low bits = slot address
        wr_ptr <= wr_ptr + 1'b1;
      end
      if (rd_en && !empty) rd_ptr <= rd_ptr + 1'b1;  // ignore reads when empty
    end
    if (rd_en) rd_data <= mem[rd_ptr[AW-1:0]];    // registered read (block RAM style)
  end
endmodule
