module top (
    input wire sys_clk,     // 100 MHz PL clock
    input wire rst,         // system reset
    input wire btn_freeze,  // Freeze/unfreeze display -> BTNC

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
    wire clk_locked;

    clk_wiz_0 clk_wiz (
        .clk_in1(sys_clk),
        .reset(rst),            // Clocking Wizard 'reset' input (enabled by default in the IP)
        .locked(clk_locked),    // Clocking Wizard 'locked' output (enabled by default in the IP)
        .clk_out1(clk_32mhz)
    );

    // ==========================================
    // Reset synchroniser
    // ==========================================
    // Asserts immediately on BTNR or while the clock is not locked, and releases
    // synchronously to clk_32mhz so every module leaves reset on the same cycle.
    wire rst_async = rst | ~clk_locked;
    (* ASYNC_REG = "TRUE" *) reg [2:0] rst_sync = 3'b111;

    always @(posedge clk_32mhz or posedge rst_async) begin
        if (rst_async) rst_sync <= 3'b111;
        else           rst_sync <= {rst_sync[1:0], 1'b0};
    end

    wire sys_rst = rst_sync[2];     // use this everywhere instead of rst

    // Generate 48kHz trigger: 667-cycle period -> 32 MHz / 667 = 47.976 kHz
    // NOTE: param_ctrl SAMPLE_DIV must match this period (currently 667)
    reg [9:0] timer = 0;
    reg trigger_48khz = 0;
    
    always @(posedge clk_32mhz) begin
        if (sys_rst) begin
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
        .rst(sys_rst),
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
        if (sys_rst) begin
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
        .rst(sys_rst),
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
        .rst(sys_rst),
        .sample_tick(data_valid),      
        .audio_data(mic_audio_data),
        .vu_level(vu_level)
    );

    // ==========================================
    // Keypad (PMOD KYPD) + parameter control
    // ==========================================
    wire       key_valid;           // 1-cycle pulse per key press
    wire [3:0] key_code;            // key label (0-9, A-F)
    wire       key_held;            // a single key is being held

    pmod_kypd kypd_inst (
        .clk(clk_32mhz),
        .rst(sys_rst),
        .kp_col(kp_col),
        .kp_row(kp_row),
        .key_valid(key_valid),
        .key_code(key_code),
        .key_held(key_held)
    );

    // Modulation parameters (all registered, clk_32mhz domain) -> CORDIC / VGA
    wire [1:0]  mod_type;           // 00 FM, 01 PM, 10 AM, 11 bypass
    wire [13:0] fc_hz;              // carrier frequency, Hz
    wire [11:0] fm_hz;              // modulating tone frequency, Hz
    wire [7:0]  beta_x10;           // modulation index x10 (25 = 2.5)
    wire [6:0]  amp_pct;            // output amplitude, 0-100 %
    wire [2:0]  tb_log2;            // VGA timebase = 2^tb_log2
    wire        disp_freeze;        // freeze VGA capture (BTNC toggles)
    wire [31:0] fc_fcw;             // carrier NCO phase increment (fc * 2^32 / fs)
    wire [31:0] fm_fcw;             // modulating-tone NCO phase increment
    wire [31:0] dev_fcw;            // peak deviation (beta * fm) as phase increment
    wire        param_update;       // 1-cycle pulse when any parameter changes

    // UI state for a VGA status line
    wire [2:0]  sel_param;          // 0 fc, 1 fm, 2 beta, 3 amp, 4 timebase
    wire        entry_active;       // user is typing a value
    wire [16:0] entry_value;        // digits typed so far
    wire [2:0]  entry_digits;       // number of digits typed

    wire [7:0]  kp_leds;            // [7] status, [6:5] mod type, [4:0] selected param

    param_ctrl param_ctrl_inst (
        .clk(clk_32mhz),
        .rst(sys_rst),
        .key_valid(key_valid),
        .key_code(key_code),
        .key_held(key_held),
        .btn_freeze(btn_freeze),
        .mode(mod_type),
        .fc_hz(fc_hz),
        .fm_hz(fm_hz),
        .beta_x10(beta_x10),
        .amp_pct(amp_pct),
        .tb_log2(tb_log2),
        .freeze(disp_freeze),
        .fc_fcw(fc_fcw),
        .fm_fcw(fm_fcw),
        .dev_fcw(dev_fcw),
        .param_update(param_update),
        .sel_param(sel_param),
        .entry_active(entry_active),
        .entry_value(entry_value),
        .entry_digits(entry_digits),
        .kp_leds(kp_leds)
    );

    assign leds = led_func ? vu_level : kp_leds;  // Display VU meter level or keypad status

endmodule
