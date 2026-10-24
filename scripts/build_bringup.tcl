# Non-project Vivado build for the serial -> Pmod I2S2 bring-up.
#   vivado -mode batch -source scripts/build_bringup.tcl
set root [file normalize [file join [file dirname [info script]] ..]]
set out  [file join $root build bringup]
file mkdir $out

if {![file exists $root/rtl/alarm_rom.mem]} {
    error "rtl/alarm_rom.mem is missing; run: python scripts/gen_alarm_rom.py <clip.wav>"
}

read_verilog -sv [list \
    $root/rtl/alarm_rom.sv \
    $root/rtl/alarm_player.sv \
    $root/rtl/sine_lut.sv \
    $root/rtl/uart_rx.sv \
    $root/rtl/sample_fifo.sv \
    $root/rtl/i2s_tx.sv \
    $root/rtl/debounce.sv \
    $root/rtl/audio_bringup_core.sv \
    $root/rtl/cmod_a7_bringup_top.sv]
read_mem $root/rtl/alarm_rom.mem
read_xdc $root/constraints/cmod_a7_bringup.xdc

synth_design -top cmod_a7_bringup_top -part xc7a35tcpg236-1
opt_design
place_design
route_design

report_utilization    -file $out/utilization.rpt
report_timing_summary -file $out/timing.rpt
write_bitstream -force $out/cmod_a7_bringup.bit
