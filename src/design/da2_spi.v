`timescale 1ns / 1ps

module pmod_da2_spi (
    input wire clk,                 // 32MHz clock
    input wire rst,                 // Active-high synchronous reset
    input wire start_transmit,      // Triggered by MIC3 CS rising edge
    input wire [11:0] audio_a,      // 12-bit sample for channel A (VOUTA)
    input wire [11:0] audio_b,      // 12-bit sample for channel B (VOUTB)

    output reg sync,                // DA2 Sync (Chip Select, Active Low)
    output reg sclk,                // DA2 SPI Clock (16MHz)
    output wire mosi1,              // DA2 Channel A Data
    output wire mosi2               // DA2 Channel B Data
);

    reg active = 0;
    reg clk_div = 0;
    reg [3:0] bit_cnt = 0;
    reg [15:0] shift_a = 0;         // DAC121S101 frame: 2 x, 2 x PD=00, 12 data
    reg [15:0] shift_b = 0;

    assign mosi1 = shift_a[15];
    assign mosi2 = shift_b[15];

    initial begin
        sync = 1;
        sclk = 1;
    end

    always @(posedge clk) begin
        if (rst) begin
            active <= 0;
            sync <= 1;
            sclk <= 1;
            clk_div <= 0;
            bit_cnt <= 4'd0;
            shift_a <= 16'd0;
            shift_b <= 16'd0;
        end else if (start_transmit && !active) begin
            active <= 1;
            sync <= 0;
            clk_div <= 0;
            bit_cnt <= 4'd0;
            sclk <= 1;
            shift_a <= {4'b0000, audio_a};
            shift_b <= {4'b0000, audio_b};
        end else if (active) begin
            clk_div <= ~clk_div;
            
            if (clk_div) begin
                sclk <= 1; 
                shift_a <= {shift_a[14:0], 1'b0};
                shift_b <= {shift_b[14:0], 1'b0};
                bit_cnt <= bit_cnt + 1;
                
                if (bit_cnt == 4'd15) active <= 0; 
            end else sclk <= 0; 
        end else if (sync == 0) sync <= 1;
    end
endmodule
