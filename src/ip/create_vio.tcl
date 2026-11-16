# =============================================================================
# create_vio.tcl - creates the vio_0 debug IP used by top_module.v (USE_VIO)
# =============================================================================
# Run once in the Vivado Tcl console with the project open:
#     source <repo>/src/ip/create_vio.tcl
# It creates vio_0 with the probe widths top_module.v expects and turns on the
# USE_VIO define for the project. To build without VIO again:
#     set_property verilog_define {} [current_fileset]
# =============================================================================

create_ip -name vio -vendor xilinx.com -library ip -module_name vio_0

set_property -dict [list \
    CONFIG.C_NUM_PROBE_IN     {11} \
    CONFIG.C_NUM_PROBE_OUT    {3}  \
    CONFIG.C_PROBE_IN0_WIDTH  {12} \
    CONFIG.C_PROBE_IN1_WIDTH  {8}  \
    CONFIG.C_PROBE_IN2_WIDTH  {14} \
    CONFIG.C_PROBE_IN3_WIDTH  {12} \
    CONFIG.C_PROBE_IN4_WIDTH  {8}  \
    CONFIG.C_PROBE_IN5_WIDTH  {7}  \
    CONFIG.C_PROBE_IN6_WIDTH  {5}  \
    CONFIG.C_PROBE_IN7_WIDTH  {17} \
    CONFIG.C_PROBE_IN8_WIDTH  {5}  \
    CONFIG.C_PROBE_IN9_WIDTH  {32} \
    CONFIG.C_PROBE_IN10_WIDTH {2}  \
    CONFIG.C_PROBE_OUT0_WIDTH {4}  \
    CONFIG.C_PROBE_OUT1_WIDTH {1}  \
    CONFIG.C_PROBE_OUT2_WIDTH {1}  \
    CONFIG.C_PROBE_OUT0_INIT_VAL {0x0} \
    CONFIG.C_PROBE_OUT1_INIT_VAL {0x0} \
    CONFIG.C_PROBE_OUT2_INIT_VAL {0x0} \
] [get_ips vio_0]

generate_target all [get_ips vio_0]

set_property verilog_define USE_VIO [current_fileset]
puts "vio_0 created and USE_VIO defined - re-run synthesis."
