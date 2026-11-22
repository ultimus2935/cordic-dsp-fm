`timescale 1ns / 1ps

// =============================================================================
// clk_wiz_0_sim.v - behavioural stand-in for the clk_wiz_0 IP (iverilog only)
// =============================================================================
// Lets tb_top.v run in Icarus Verilog without the Xilinx IP. Do NOT add this
// file to the Vivado project: Vivado uses the real clk_wiz_0 and its own model.
// 100 MHz in -> 32 MHz out, `locked` rises 2 us after reset is released.
// =============================================================================

module clk_wiz_0 (
    input  wire clk_in1,
    input  wire reset,
    output reg  locked,
    output reg  clk_out1
);
    initial begin
        clk_out1 = 1'b0;
        locked   = 1'b0;
    end

    always #15.625 clk_out1 = ~clk_out1;      // 32 MHz

    always @(posedge reset) locked <= 1'b0;
    always @(negedge reset) begin
        #2000;
        if (!reset) locked <= 1'b1;
    end

    initial begin
        #2000;
        if (!reset) locked = 1'b1;
    end
endmodule
