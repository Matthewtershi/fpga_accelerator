// Sends 16-bit samples over a 2 Mbaud UART into audio_bringup_core and checks
// the I2S words that come out. Run with: sim/run_bringup.sh
`timescale 1ns / 1ps

module tb_audio_bringup;
  logic clk = 0;
  logic rst = 1;
  logic rxd = 1;
  logic sclk, lrck, sdin, led_active, led_error;

  always #40.690 clk = ~clk;  // 12.288 MHz

  audio_bringup_core dut (
      .clk, .rst, .uart_rxd(rxd), .btn_mode(1'b0), .btn_clear(1'b0),
      .sclk, .lrck, .sdin, .led_active, .led_error,
      .frame_tick(), .clear_tick(), .alarm_active(1'b0), .alarm_pcm(16'sd0)
  );

  // ---- UART driver: 2 Mbaud = 500 ns per bit ----
  task automatic send_byte(input [7:0] b);
    rxd = 0; #500;
    for (int i = 0; i < 8; i++) begin rxd = b[i]; #500; end
    rxd = 1; #500;
  endtask

  task automatic send_sample(input [15:0] s);
    send_byte(s[7:0]);
    send_byte(s[15:8]);
  endtask

  // ---- I2S receiver ----
  logic [31:0] sh;
  logic prev_lrck = 0;
  logic [23:0] left_words[$];
  logic [23:0] right_words[$];

  always @(posedge sclk) begin
    sh = {sh[30:0], sdin};
    if (lrck !== prev_lrck) begin
      if (prev_lrck) right_words.push_back(sh[31:8]);
      else left_words.push_back(sh[31:8]);
      prev_lrck = lrck;
    end
  end

  int errors = 0;

  function automatic [15:0] pattern(input int i);
    return 16'(i * 37 + 11);
  endfunction

  // Non-zero words from the left channel must equal pattern(0..n-1), and
  // the right channel must match the left.
  task automatic check_stream(input int n, input string name);
    int j = 0;
    int nonzero = 0;
    for (int i = 0; i < left_words.size(); i++) begin
      if (left_words[i] != 0) begin
        nonzero++;
        if (j < n && left_words[i] !== {pattern(j), 8'h00}) begin
          if (errors < 10)
            $display("%s: left[%0d] = %h, expected %h", name, i, left_words[i], {pattern(j), 8'h00});
          errors++;
        end
        j++;
      end
    end
    if (nonzero != n) begin
      $display("%s: got %0d non-zero samples, expected %0d", name, nonzero, n);
      errors++;
    end
    for (int i = 0; i < right_words.size() && i < left_words.size() - 1; i++)
      if (right_words[i] !== left_words[i]) begin
        $display("%s: right[%0d]=%h != left=%h", name, i, right_words[i], left_words[i]);
        errors++;
        break;
      end
  endtask

  initial begin
    #1000 rst = 0;

    // Tone mode after reset: expect a non-silent tone at -18 dBFS.
    #(3_000_000);
    begin
      int peak;
      int v;
      peak = 0;
      for (int i = 0; i < left_words.size(); i++) begin
        v = $signed(left_words[i]) / 256;
        if (v < 0) v = -v;
        if (v > peak) peak = v;
      end
      $display("tone: %0d words, peak %0d (expect ~4095)", left_words.size(), peak);
      if (peak < 3500 || peak > 4200) begin $display("tone: FAIL"); errors++; end
    end

    // Stream 1: burst larger than PREFILL, sent faster than real time.
    // A leading zero sample leaves tone mode; wait for the last tone frames
    // to drain, then start capturing.
    send_sample(16'h0000);
    #(1_000_000);
    left_words.delete(); right_words.delete();
    for (int i = 0; i < 2000; i++) send_sample(pattern(i));
    #(120_000_000);
    check_stream(2000, "stream-long");
    $display("stream-long: %0d frames captured, error LED = %b", left_words.size(), led_error);
    if (led_error) errors++;

    // Stream 2: shorter than PREFILL, must still play after the idle timeout.
    left_words.delete(); right_words.delete();
    for (int i = 0; i < 300; i++) send_sample(pattern(i));
    #(150_000_000);
    check_stream(300, "stream-short");
    if (led_error) begin $display("unexpected error LED"); errors++; end

    if (errors == 0) $display("PASS");
    else $display("FAIL: %0d errors", errors);
    $finish;
  end
endmodule
