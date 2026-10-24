// Synchronous FIFO with a registered (block RAM friendly) read port.
// rd_data is valid the cycle after rd_en.
module sample_fifo #(
    parameter int AW = 12,
    parameter int DW = 16
) (
    input  logic          clk,
    input  logic          rst,
    input  logic          wr_en,
    input  logic [DW-1:0] wr_data,
    input  logic          rd_en,
    output logic [DW-1:0] rd_data,
    output logic [AW:0]   level,
    output logic          empty,
    output logic          full
);
  logic [DW-1:0] mem[2**AW];
  logic [AW:0] wr_ptr, rd_ptr;

  assign level = wr_ptr - rd_ptr;
  assign empty = (level == '0);
  assign full  = (level == (AW+1)'(2**AW));

  always_ff @(posedge clk) begin
    if (rst) begin
      wr_ptr <= '0;
      rd_ptr <= '0;
    end else begin
      if (wr_en && !full) begin
        mem[wr_ptr[AW-1:0]] <= wr_data;
        wr_ptr <= wr_ptr + 1'b1;
      end
      if (rd_en && !empty) rd_ptr <= rd_ptr + 1'b1;
    end
    if (rd_en) rd_data <= mem[rd_ptr[AW-1:0]];
  end
endmodule
