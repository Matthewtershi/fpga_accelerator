#!/bin/sh
# Simulate the bring-up core with Icarus Verilog (brew install icarus-verilog).
set -e
cd "$(dirname "$0")/.."
mkdir -p build
iverilog -g2012 -o build/tb_bringup \
    sim/tb_audio_bringup.sv rtl/sine_lut.sv rtl/uart_rx.sv rtl/sample_fifo.sv \
    rtl/i2s_tx.sv rtl/debounce.sv rtl/audio_bringup_core.sv
vvp build/tb_bringup
