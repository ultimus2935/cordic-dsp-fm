# Clock – 100 MHz PL GCLK (Y9)
set_property PACKAGE_PIN Y9         [get_ports sys_clk]
set_property IOSTANDARD  LVCMOS33   [get_ports sys_clk]
create_clock -period 10.000 -name sys_clk -waveform {0.000 5.000} [get_ports sys_clk]

# Reset button – BTNR (R18, LVCMOS33)
set_property PACKAGE_PIN R18        [get_ports rst]
set_property IOSTANDARD  LVCMOS33   [get_ports rst]

# PMOD Header JA – Keypad columns (active LOW, inactive columns high-Z)
# JA1=COL1 (col[0])  JA2=COL2 (col[1])  JA3=COL3 (col[2])  JA4=COL4 (col[3])
set_property PACKAGE_PIN Y11        [get_ports {kp_col[0]}]
set_property PACKAGE_PIN AA11       [get_ports {kp_col[1]}]
set_property PACKAGE_PIN Y10        [get_ports {kp_col[2]}]
set_property PACKAGE_PIN AA9        [get_ports {kp_col[3]}]
set_property IOSTANDARD  LVCMOS33   [get_ports {kp_col[*]}]

# PMOD Header JA – Keypad rows (active LOW, inputs with pull-ups)
# JA7=ROW1 (row[0])  JA8=ROW2 (row[1])  JA9=ROW3 (row[2])  JA10=ROW4 (row[3])
set_property PACKAGE_PIN AB11       [get_ports {kp_row[0]}]
set_property PACKAGE_PIN AB10       [get_ports {kp_row[1]}]
set_property PACKAGE_PIN AB9        [get_ports {kp_row[2]}]
set_property PACKAGE_PIN AA8        [get_ports {kp_row[3]}]
set_property IOSTANDARD  LVCMOS33   [get_ports {kp_row[*]}]
set_property PULLUP      true       [get_ports {kp_row[*]}]

# PMOD Header JC – Digilent PMOD DA2 DAC interface
# JC1=da_sync (AB7)  JC2=da_mosi1 (AB6)  JC3=da_mosi2 (Y4)  JC4=da_sclk (AA4)
set_property PACKAGE_PIN AB7        [get_ports da_sync_n]
set_property IOSTANDARD LVCMOS33    [get_ports da_sync_n]
set_property PACKAGE_PIN AB6        [get_ports da_mosi1]
set_property IOSTANDARD LVCMOS33    [get_ports da_mosi1]
set_property PACKAGE_PIN Y4         [get_ports da_mosi2]
set_property IOSTANDARD LVCMOS33    [get_ports da_mosi2]
set_property PACKAGE_PIN AA4        [get_ports da_sclk]
set_property IOSTANDARD LVCMOS33    [get_ports da_sclk]

# PMOD Header JD – Microphone SPI interface
# JD1=mic_cs_n (V7)  JD3=mic_miso (V5)  JD4=mic_sclk (V4)
set_property PACKAGE_PIN V7         [get_ports mic_cs_n]
set_property IOSTANDARD LVCMOS33    [get_ports mic_cs_n]
set_property PACKAGE_PIN V5         [get_ports mic_miso]
set_property IOSTANDARD LVCMOS33    [get_ports mic_miso]
set_property PULLDOWN    true       [get_ports mic_miso]
set_property PACKAGE_PIN V4         [get_ports mic_sclk]
set_property IOSTANDARD LVCMOS33    [get_ports mic_sclk]

# Timing exceptions for async inputs handled by synchronisers in RTL
set_false_path -from [get_ports {kp_row[*]}]
set_false_path -from [get_ports rst]

# Switch SW7 mapped to da2_func
set_property PACKAGE_PIN M15        [get_ports da2_func]
set_property IOSTANDARD LVCMOS33    [get_ports da2_func]

# Switch SW1 mapped to msg_src_sw (0 = test tone, 1 = microphone)
set_property PACKAGE_PIN G22        [get_ports msg_src_sw]
set_property IOSTANDARD LVCMOS33    [get_ports msg_src_sw]
set_false_path -from [get_ports msg_src_sw]

# Switch SW2 mapped to freeze_sw (0 = circular record, 1 = freeze buffer)
set_property PACKAGE_PIN H22        [get_ports freeze_sw]
set_property IOSTANDARD LVCMOS33    [get_ports freeze_sw]
set_false_path -from [get_ports freeze_sw]

# Switch SW0 mapped to led_func
set_property PACKAGE_PIN F22        [get_ports led_func]
set_property IOSTANDARD LVCMOS33    [get_ports led_func]

# LEDs (LD0 to LD7) mapped to leds[7:0]
set_property PACKAGE_PIN T22        [get_ports {leds[0]}]
set_property IOSTANDARD LVCMOS33    [get_ports {leds[0]}]
set_property PACKAGE_PIN T21        [get_ports {leds[1]}]
set_property IOSTANDARD LVCMOS33    [get_ports {leds[1]}]
set_property PACKAGE_PIN U22        [get_ports {leds[2]}]
set_property IOSTANDARD LVCMOS33    [get_ports {leds[2]}]
set_property PACKAGE_PIN U21        [get_ports {leds[3]}]
set_property IOSTANDARD LVCMOS33    [get_ports {leds[3]}]
set_property PACKAGE_PIN V22        [get_ports {leds[4]}]
set_property IOSTANDARD LVCMOS33    [get_ports {leds[4]}]
set_property PACKAGE_PIN W22        [get_ports {leds[5]}]
set_property IOSTANDARD LVCMOS33    [get_ports {leds[5]}]
set_property PACKAGE_PIN U19        [get_ports {leds[6]}]
set_property IOSTANDARD LVCMOS33    [get_ports {leds[6]}]
set_property PACKAGE_PIN U14        [get_ports {leds[7]}]
set_property IOSTANDARD LVCMOS33    [get_ports {leds[7]}]
