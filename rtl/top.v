// Bring-up design for the Cmod A7-35T: buttons drive the LEDs, a counter
// cycles the RGB LED. Signals tagged mark_debug can be probed with an ILA.
module top (
    input  wire       clk,      // 12 MHz board oscillator
    input  wire [1:0] btn,      // active high
    output wire [1:0] led,      // active high
    output wire       led0_r,   // RGB LED, active low
    output wire       led0_g,
    output wire       led0_b
);
    (* mark_debug = "true" *) reg [1:0]  btn_sync = 2'b00;
    (* mark_debug = "true" *) reg [23:0] counter  = 24'd0;

    always @(posedge clk) begin
        btn_sync <= btn;
        counter  <= counter + 1'b1;
    end

    assign led = btn_sync;

    // Top three counter bits step through RGB colors about every 0.35 s.
    assign led0_r = ~counter[23];
    assign led0_g = ~counter[22];
    assign led0_b = ~counter[21];
endmodule
