# Non-project Vivado build for the serial -> Pmod I2S2 bring-up.
#   vivado -mode batch -source scripts/build_bringup.tcl
set root [file normalize [file join [file dirname [info script]] ..]]
set out  [file join $root build bringup]
file mkdir $out

read_verilog -sv [list \
    $root/rtl/sine_lut.sv \
    $root/rtl/uart_rx.sv \
    $root/rtl/sample_fifo.sv \
    $root/rtl/i2s_tx.sv \
    $root/rtl/debounce.sv \
    $root/rtl/audio_bringup_core.sv \
    $root/rtl/cmod_a7_bringup_top.sv]
read_xdc $root/constraints/cmod_a7_bringup.xdc

synth_design -top cmod_a7_bringup_top -part xc7a35tcpg236-1
opt_design
place_design
route_design

report_utilization    -file $out/utilization.rpt
report_timing_summary -file $out/timing.rpt
write_bitstream -force $out/cmod_a7_bringup.bit
