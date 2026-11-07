module top(
    input wire sys_clk, // 100 MHz PL clock
    input wire rst, // system reset

    input wire [1:0] led_func, // Select LED function -> SW0 - SW1
    output reg [7:0] leds, // LEDs -> LD0 - LD7

    // PMOD JA – Digilent PMOD KYPD
    output wire [3:0] kp_col, // KYPD Columns - > JA1 - JA4 (active low)
    input  wire [3:0] kp_row, // KYPD Rows - > JA7 - JA10 (active low)

    // PMOD JC – Digilent PMOD DA2
    // PMOD JD – Digilent PMOD Mic
    output wire mic_cs_n, // Chip Select -> JD1 (active low)
    input  wire mic_miso, // Serial Data (MISO) -> JD3
    output wire mic_sclk  // Serial Clock -> JD4
);
    clk_wiz_0 clk_wiz (
        .clk_in1(sys_clk),
        .clk_out1(clk_32mhz)
    );

    // Generate 48kHz trigger (32,000,000 / 48000 = 666.67)
    reg [9:0] timer = 0;
    reg trigger_48khz = 0;
    
    always @(posedge clk_32mhz) begin
        if (timer >= 666) begin
            timer <= 0;
            trigger_48khz <= 1;
        end else begin
            timer <= timer + 1;
            trigger_48khz <= 0;
        end
    end

    wire [11:0] mic_audio_data;     // 12-bit audio sample

    // Instantiate SPI Controller
    pmod_mic3_spi spi_ctrl (
        .clk(clk_32mhz),
        .start_sample(trigger_48khz),
        .cs(mic_cs),
        .sclk(mic_sclk),
        .miso(mic_miso),
        .dc_audio_data(mic_audio_data)
    );

    wire [7:0] vu_level;            // 8-bit audio level output from VU meter

    // Instantiate VU Meter
    vu_meter vu_meter_inst (
        .clk(clk_32mhz),
        .sample_tick(trigger_48khz),      
        .audio_data(mic_audio_data),
        .vu_level(vu_level)
    );

    always @(*) begin
        case (led_func)
            2'b00: begin
                // LED Function 0: Display microphone audio data on LEDs
                leds = vu_level;    // Map the upper 8 bits of the AC amplitude
            end
            2'b01: begin
                // LED Function 1: Display the user parameter that is being edited
                leds = 8'd0;        // Placeholder for LED Function 1
            end
            2'b10: begin
                // LED Function 2: Display the user parameter that is being edited
                leds = 8'd0;        // Placeholder for LED Function 2
            end
            2'b11: begin
                // LED Function 3: Display the user parameter that is being edited
                leds = 8'd0;        // Placeholder for LED Function 3
            end
            default: leds = 8'd0;   // Default: turn off all LEDs
        endcase
    end

endmodule