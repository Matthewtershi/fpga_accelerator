## Cmod A7-35T pins for the serial -> Pmod I2S2 bring-up.
## Pin numbers are from Digilent's Cmod-A7-Master.xdc (digilent-xdc repo), and
## the Pmod I2S2 pin order matches Digilent's Pmod I2S2 reference design.

set_property -dict { PACKAGE_PIN L17 IOSTANDARD LVCMOS33 } [get_ports sysclk]
create_clock -period 83.333 -name sysclk [get_ports sysclk]

set_property -dict { PACKAGE_PIN A18 IOSTANDARD LVCMOS33 } [get_ports {btn[0]}]
set_property -dict { PACKAGE_PIN B18 IOSTANDARD LVCMOS33 } [get_ports {btn[1]}]

set_property -dict { PACKAGE_PIN A17 IOSTANDARD LVCMOS33 } [get_ports {led[0]}]
set_property -dict { PACKAGE_PIN C16 IOSTANDARD LVCMOS33 } [get_ports {led[1]}]

## FT2232H channel B UART. uart_rxd is the FPGA input (Digilent: uart_txd_in,
## J17). J18 is the FPGA's transmit output and is unused here.
set_property -dict { PACKAGE_PIN J17 IOSTANDARD LVCMOS33 } [get_ports uart_rxd]

## Pmod JA, wired to the Pmod I2S2 DAC half (top row, pins 1-4).
set_property -dict { PACKAGE_PIN G17 IOSTANDARD LVCMOS33 } [get_ports da_mclk]
set_property -dict { PACKAGE_PIN G19 IOSTANDARD LVCMOS33 } [get_ports da_lrck]
set_property -dict { PACKAGE_PIN N18 IOSTANDARD LVCMOS33 } [get_ports da_sclk]
set_property -dict { PACKAGE_PIN L18 IOSTANDARD LVCMOS33 } [get_ports da_sdin]

## Buttons, UART and LEDs are asynchronous to the audio clock or too slow to matter.
set_false_path -from [get_ports {btn[*] uart_rxd}]
set_false_path -to [get_ports {led[*]}]

set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
