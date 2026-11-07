`timescale 1ns / 1ps

module pmod_mic3_spi (
    input wire clk,                 // 32MHz clock from Clocking Wizard
    input wire rst,                 // Active-high synchronous reset
    input wire start_sample,        // Trigger pulse at 48kHz
    
    output reg cs,                  // SPI Chip Select (active low)
    output reg sclk,                // SPI Clock (4MHz)
    input wire miso,                // SPI MISO

    output reg [11:0] dc_audio_data // 12-bit audio sample
);

    reg active = 0;
    reg clk_div = 0;          // 1-bit divider (32MHz / 2 = 16MHz SCLK)
    reg [4:0] bit_cnt = 0;
    reg [15:0] shift_reg = 0;

    initial begin
        cs = 1;
        sclk = 1;
        dc_audio_data = 12'd2048;   // Initialize to silence (mid-scale DC offset)
    end

    always @(posedge clk) begin
        if (rst) begin
            active <= 0;
            cs <= 1;
            sclk <= 1;
            clk_div <= 0;
            bit_cnt <= 0;
            dc_audio_data <= 12'd2048;
        end else begin
            if (start_sample && !active) begin
                active <= 1;
                cs <= 0;            // Pull CS low to begin transaction
                clk_div <= 0;
                bit_cnt <= 0;
                sclk <= 1;          // Start with SCLK high (SPI mode 3 idle state)
            end else if (active) begin
                clk_div <= ~clk_div; // Toggle clk_div every 32MHz clock cycle

                // 16MHz SCLK generation from 32MHz clk (2 cycles per SCLK period):
                if (clk_div) begin
                    sclk <= 0;      // Falling edge: FPGA samples current bit, ADC shifts out next bit
                    shift_reg <= {shift_reg[14:0], miso};

                    bit_cnt <= bit_cnt + 1'b1;
                    if (bit_cnt == 5'd15) active <= 0; // Transaction complete after 16 bits (Z3..Z0, DB11..DB0)
                end else sclk <= 1;      // Rising edge returns SCLK high                   
            end else if (cs == 0) begin 
                // One cycle after SPI finishes, extract the 12 bits and raise CS
                cs <= 1;
                sclk <= 1;
                dc_audio_data <= shift_reg[11:0]; 
            end
        end
    end
endmodule
