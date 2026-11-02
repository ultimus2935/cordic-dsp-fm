module top(
    input wire clk, // 100 MHz PL clock
    input wire rst, // system reset


    // PMOD JA – Digilent PMOD KYPD
    output wire [3:0] kp_col, // KYPD Columns - > JA1 - JA4 (active low)
    input  wire [3:0] kp_row, // KYPD Rows - > JA7 - JA10 (active low)

    // PMOD JC – Digilent PMOD DA2
    // PMOD JD – Digilent PMOD Mic
    output wire mic_cs_n, // Chip Select -> JD1 (active low)
    input  wire mic_miso, // Serial Data (MISO) -> JD3
    output wire mic_sclk  // Serial Clock -> JD4
)

endmodule