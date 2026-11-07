module vu_meter(
    input wire clk,                 // 32 MHz system clock
    input wire sample_tick,         // 1-cycle pulse at 48 kHz (from trigger or data_valid)
    input wire [11:0] audio_data,   // 12-bit audio sample from SPI
    output wire [7:0] vu_level      // 8-bit thermometer level for LEDs
);
    wire [11:0] ac_audio = audio_data[11] ? audio_data[10:0] : (12'd2048 - audio_data);

    // Synchronous 48 kHz Peak & Decay Tracker
    reg [11:0] peak_level = 12'd0;
    reg [6:0]  sample_counter = 7'd0; 

    always @(posedge clk) begin
        // Block only evaluates when a fresh 48 kHz sample pulse arrives
        if (sample_tick) begin
            if (ac_audio > peak_level) begin
                peak_level <= ac_audio; 
                sample_counter <= 7'd0;
            end else begin
                if (sample_counter >= 4'd15) begin // 15 samples at 48 kHz = 312.5 μs per decrement step
                    sample_counter <= 7'd0;
                    if (peak_level > 0) peak_level <= peak_level - 1'b1; // Slow decay
                end else sample_counter <= sample_counter + 1'b1;
            end
        end
    end

    // Thermometer Decoder (Bar Graph)
    assign vu_level = {
        (peak_level > 12'd1536), // vu_level[7]
        (peak_level > 12'd1024), // vu_level[6]
        (peak_level > 12'd512),  // vu_level[5]
        (peak_level > 12'd256),  // vu_level[4]
        (peak_level > 12'd128),  // vu_level[3]
        (peak_level > 12'd64),   // vu_level[2]
        (peak_level > 12'd32),   // vu_level[1]
        (peak_level > 12'd16)    // vu_level[0]
    };

endmodule