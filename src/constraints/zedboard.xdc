# Clock – 100 MHz PL GCLK (Y9)
set_property PACKAGE_PIN Y9       [get_ports clk]
set_property IOSTANDARD  LVCMOS33 [get_ports clk]
create_clock -period 10.000 -name sys_clk -waveform {0.000 5.000} [get_ports clk]

# Reset button – BTNR (R18, LVCMOS33)
set_property PACKAGE_PIN R18      [get_ports rst]
set_property IOSTANDARD  LVCMOS33 [get_ports rst]

# PMOD Header JA – Keypad columns (active LOW outputs)
# JA1=col[3]  JA2=col[2]  JA3=col[1]  JA4=col[0]
set_property PACKAGE_PIN AA9      [get_ports {col[0]}]
set_property PACKAGE_PIN Y10      [get_ports {col[1]}]
set_property PACKAGE_PIN AA11     [get_ports {col[2]}]
set_property PACKAGE_PIN Y11      [get_ports {col[3]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {col[*]}]

# PMOD Header JA – Keypad rows (active LOW, inputs with pull-ups)
# JA7=row[3]  JA8=row[2]  JA9=row[1]  JA10=row[0]
set_property PACKAGE_PIN AA8      [get_ports {row[0]}]
set_property PACKAGE_PIN AB9      [get_ports {row[1]}]
set_property PACKAGE_PIN AB10     [get_ports {row[2]}]
set_property PACKAGE_PIN AB11     [get_ports {row[3]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {row[*]}]
set_property PULLUP      true     [get_ports {row[*]}]

# Timing exceptions for async inputs handled by synchronisers in RTL
set_false_path -from [get_ports {row[*]}]
set_false_path -from [get_ports rst]