module top (
    input wire sys_clk,     // 100 MHz PL clock
    input wire rst,         // system reset

    input wire da2_func,        // Select DA2 function -> SW7
    input wire led_func,        // Select LED function -> SW0
    output wire [7:0] leds,     // LEDs -> LD0 - LD7

    // PMOD JA – Digilent PMOD KYPD
    output wire [3:0] kp_col,   // KYPD Columns - > JA1 - JA4 (active low)
    input  wire [3:0] kp_row,   // KYPD Rows - > JA7 - JA10 (active low)

    // PMOD JC – Digilent PMOD DA2
    output wire da_sync_n,  // Chip Select -> JC1 (active low)
    output wire da_sclk,    // Serial Clock -> JC4
    output wire da_mosi1,   // Serial Data (MOSI) -> JC3
    output wire da_mosi2,   // Serial Data (MOSI) -> JC2

    // PMOD JD – Digilent PMOD Mic
    output wire mic_cs_n,   // Chip Select -> JD1 (active low)
    input wire mic_miso,    // Serial Data (MISO) -> JD3
    output wire mic_sclk    // Serial Clock -> JD4
);
    // Explicitly declare 32MHz wire from Clocking Wizard
    wire clk_32mhz;

    clk_wiz_0 clk_wiz (
        .clk_in1(sys_clk),
        .clk_out1(clk_32mhz)
    );

    // Prevent floating undriven outputs for unused keypad columns (active-low inactive)
    assign kp_col = 4'b1111;

    // Generate 48kHz trigger (32,000,000 / 48000 = 666.67)
    reg [9:0] timer = 0;
    reg trigger_48khz = 0;
    
    always @(posedge clk_32mhz) begin
        if (rst) begin
            timer <= 0;
            trigger_48khz <= 0;
        end else if (timer >= 666) begin
            timer <= 0;
            trigger_48khz <= 1;
        end else begin
            timer <= timer + 1;
            trigger_48khz <= 0;
        end
    end

    wire [11:0] mic_audio_data;     // 12-bit audio sample

    // Instantiate MIC3 SPI Controller
    pmod_mic3_spi mic3_spi_inst (
        .clk(clk_32mhz),
        .rst(rst),
        .start_sample(trigger_48khz),
        .cs(mic_cs_n),
        .sclk(mic_sclk),
        .miso(mic_miso),
        .dc_audio_data(mic_audio_data)
    );

    // ==========================================
    // Synchronization (Trigger VU and DA2 when MIC3 finishes)
    // ==========================================
    reg mic_cs_prev = 1;
    reg data_valid = 0;
    
    always @(posedge clk_32mhz) begin
        if (rst) begin
            mic_cs_prev <= 1;
            data_valid <= 0;
        end else begin
            mic_cs_prev <= mic_cs_n;
            
            // mic3_spi.v pulls cs high one cycle after the SPI read is complete.
            // We detect this rising edge to immediately latch the captured data into the VU meter.
            if (mic_cs_prev == 0 && mic_cs_n == 1) data_valid <= 1;
            else data_valid <= 0;
        end
    end

    wire [11:0] da_audio_data;      // 12-bit audio sample for DA2

    // Instantiate DA2 SPI Transmitter
    pmod_da2_spi da2_spi_inst (
        .clk(clk_32mhz),
        .rst(rst),
        .start_transmit(data_valid),
        .audio_data(da_audio_data),
        .sync(da_sync_n),
        .sclk(da_sclk),
        .mosi1(da_mosi1),
        .mosi2(da_mosi2)
    );

    wire [11:0] mod_audio_data = 12'd2048;  // Default to silence (mid-scale DC offset)

    assign da_audio_data = da2_func ? mic_audio_data : mod_audio_data;   // Pass through MIC3 audio or play modulated audio 

    wire [7:0] vu_level;                    // 8-bit audio level output from VU meter

    // Instantiate VU Meter
    vu_meter vu_meter_inst (
        .clk(clk_32mhz),
        .rst(rst),
        .sample_tick(data_valid),      
        .audio_data(mic_audio_data),
        .vu_level(vu_level)
    );

    wire [3:0] param_selected = 4'd0;       // User parameter selection from keypad

    assign leds = led_func ? vu_level : {4'd0, param_selected};  // Display VU meter level or user parameter being set

endmodule
