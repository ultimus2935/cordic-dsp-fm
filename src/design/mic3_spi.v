`timescale 1ns / 1ps

module pmod_mic3_spi (
    input wire clk,                 // 32MHz clock from Clocking Wizard
    input wire start_sample,        // Trigger pulse at 48kHz
    
    output reg cs,                  // SPI Chip Select
    output reg sclk,                // SPI Clock (16MHz)
    input wire miso,                // SPI MISO

    output reg [11:0] dc_audio_data // 12-bit audio sample
);

    reg active = 0;
    reg clk_div = 0;            // 1-bit divider (32MHz / 2 = 16MHz SCLK)
    reg [4:0] bit_cnt = 0;
    reg [15:0] shift_reg = 0;

    initial begin
        cs = 1;
        sclk = 1;
    end

    always @(posedge clk) begin
        if (start_sample && !active) begin
            active <= 1;
            cs <= 0;            // Pull CS low to begin transaction
            clk_div <= 0;
            bit_cnt <= 0;
            sclk <= 1;          // Start with SCLK high (SPI mode 3 idle state)
        end else if (active) begin
            clk_div <= ~clk_div; // Toggle every 32MHz clock cycle
            if (clk_div == 0) sclk <= 0;  // Falling edge: ADC shifts data out

            else begin
                sclk <= 1;       // Rising edge: FPGA samples data
                shift_reg <= {shift_reg[14:0], miso};

                bit_cnt <= bit_cnt + 1; 
                if (bit_cnt == 5'd15) active <= 0; // Transaction complete after 16 SCLK cycles
            end
        end else if (cs == 0) begin 
            // One cycle after SPI finishes, extract the 12 bits and raise CS
            cs <= 1;
            dc_audio_data <= shift_reg[11:0]; 
        end
    end
endmodule