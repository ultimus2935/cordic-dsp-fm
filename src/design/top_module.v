module top (
    input wire sys_clk,     // 100 MHz PL clock
    input wire rst,         // system reset

    input wire da2_func,        // DA2 channel swap -> SW7 (0: A = modulated, B = mic; 1: A = mic, B = modulated)
    input wire led_func,        // Select LED function -> SW0
    input wire msg_src_sw,      // Message source -> SW1 (0 = test tone, 1 = microphone)
    input wire freeze_sw,       // Audio RAM capture freeze -> SW2 (0 = circular record, 1 = freeze/hold)
    output wire [7:0] leds,     // LEDs -> LD0 - LD7

    // PMOD JA – Digilent PMOD KYPD
    output wire [3:0] kp_col,   // KYPD Columns - > JA1 - JA4 (active low)
    input  wire [3:0] kp_row,   // KYPD Rows - > JA7 - JA10 (active low)

    // PMOD JC – Digilent PMOD DA2
    output wire da_sync_n,  // Chip Select -> JC1 (active low)
    output wire da_sclk,    // Serial Clock -> JC4
    output wire da_mosi1,   // Serial Data (MOSI) -> JC2 (VOUTA)
    output wire da_mosi2,   // Serial Data (MOSI) -> JC3 (VOUTB)

    // PMOD JD – Digilent PMOD Mic
    output wire mic_cs_n,   // Chip Select -> JD1 (active low)
    input wire mic_miso,    // Serial Data (MISO) -> JD3
    output wire mic_sclk    // Serial Clock -> JD4
);
    // Explicitly declare 32MHz wire from Clocking Wizard
    wire clk_32mhz;
    wire clk_locked;                // driven by clk_wiz_0 'locked' (enable it in the IP)

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

    wire [11:0] mod_audio_data;             // Modulated audio from cordic_mod (below)
    wire        mod_out_valid;              // 1-cycle pulse when mod_audio_data updates
    wire [11:0] ram_rd_orig;
    wire [11:0] ram_rd_mod;

    // DA2 channels: one carries the modulated output, the other the original mic,
    // so both can be heard / scoped side by side. SW7 swaps which is on A (VOUTA).
    wire [11:0] da_audio_a;
    wire [11:0] da_audio_b;

    // Instantiate DA2 SPI Transmitter
    pmod_da2_spi da2_spi_inst (
        .clk(clk_32mhz),
        .rst(sys_rst),
        .start_transmit(mod_out_valid),
        .audio_a(da_audio_a),
        .audio_b(da_audio_b),
        .sync(da_sync_n),
        .sclk(da_sclk),
        .mosi1(da_mosi1),
        .mosi2(da_mosi2)
    );

    // Freeze switch (SW2): asynchronous, so synchronise it first
    (* ASYNC_REG = "TRUE" *) reg [1:0] freeze_sync = 2'b00;
    always @(posedge clk_32mhz) freeze_sync <= {freeze_sync[0], freeze_sw};
    wire freeze_active = freeze_sync[1];

    // Normal mode: live captured mic & modulated audio
    wire [11:0] da_live_a = da2_func ? mic_audio_data : mod_audio_data;
    wire [11:0] da_live_b = da2_func ? mod_audio_data : mic_audio_data;

    // Freeze mode (SW2): playback / loop stored BRAM buffer for oscilloscope inspection
    wire [11:0] da_frozen_a = da2_func ? ram_rd_orig : ram_rd_mod;
    wire [11:0] da_frozen_b = da2_func ? ram_rd_mod  : ram_rd_orig;

    assign da_audio_a = freeze_active ? da_frozen_a : da_live_a;
    assign da_audio_b = freeze_active ? da_frozen_b : da_live_b;

    wire [7:0] vu_level;                    // 8-bit audio level output from VU meter

    // ==========================================
    // VU Meter DC Baseline Tracking
    // ==========================================
    // Real microphones have DC offsets that vary from unit to unit (not exactly
    // 2048). This running-average filter tracks the actual baseline so the VU
    // meter responds only to AC audio, preventing LEDs from sticking in silence.
    // Time constant: 256 samples at 48 kHz ≈ 5.3 ms (~30 Hz high-pass).
    reg signed [21:0] vu_dc_avg = 22'sd524288;  // 2048 * 256

    always @(posedge clk_32mhz) begin
        if (sys_rst)
            vu_dc_avg <= 22'sd524288;
        else if (data_valid)
            vu_dc_avg <= vu_dc_avg + ($signed({10'b0, mic_audio_data}) - (vu_dc_avg >>> 8));
    end

    // Re-centre audio around 2048 regardless of actual DC offset
    wire signed [13:0] vu_ac_raw = $signed({2'b00, mic_audio_data}) - $signed(vu_dc_avg[21:8]);
    wire [11:0] vu_audio = (vu_ac_raw >  14'sd2047) ? 12'd4095 :
                           (vu_ac_raw < -14'sd2048) ? 12'd0    :
                           $unsigned(vu_ac_raw[11:0]) + 12'd2048;

    // Instantiate VU Meter
    vu_meter vu_meter_inst (
        .clk(clk_32mhz),
        .rst(sys_rst),
        .sample_tick(data_valid),      
        .audio_data(vu_audio),
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

    // Modulation parameters (all registered, clk_32mhz domain) -> CORDIC / DSP
    wire [1:0]  mod_type;           // 00 FM, 01 PM, 10 AM, 11 bypass
    wire [13:0] fc_hz;              // carrier frequency, Hz
    wire [11:0] fm_hz;              // modulating tone frequency, Hz
    wire [7:0]  beta_x10;           // modulation index x10 (25 = 2.5)
    wire [6:0]  amp_pct;            // output amplitude, 0-100 %
    wire [31:0] fc_fcw;             // carrier NCO phase increment (fc * 2^32 / fs)
    wire [31:0] fm_fcw;             // modulating-tone NCO phase increment
    wire [31:0] dev_fcw;            // peak deviation (beta * fm) as phase increment
    wire        param_update;       // 1-cycle pulse when any parameter changes

    // UI state (shown on LEDs / VIO)
    wire [2:0]  sel_param;          // 0 fc, 1 fm, 2 beta, 3 amp
    wire        entry_active;       // user is typing a value
    wire [16:0] entry_value;        // digits typed so far
    wire [2:0]  entry_digits;       // number of digits typed

    wire [7:0]  kp_leds;            // [7] status, [6:5] mod type, [4:0] selected param

    // Key events into param_ctrl: from the keypad, or from VIO when debugging
    wire       ui_valid;
    wire [3:0] ui_code;
    wire       ui_held;

    param_ctrl param_ctrl_inst (
        .clk(clk_32mhz),
        .rst(sys_rst),
        .key_valid(ui_valid),
        .key_code(ui_code),
        .key_held(ui_held),
        .mode(mod_type),
        .fc_hz(fc_hz),
        .fm_hz(fm_hz),
        .beta_x10(beta_x10),
        .amp_pct(amp_pct),
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

    // Message-source switch (SW1): asynchronous, so synchronise it first
    (* ASYNC_REG = "TRUE" *) reg [1:0] msg_src_sync = 2'b00;
    always @(posedge clk_32mhz) msg_src_sync <= {msg_src_sync[0], msg_src_sw};
    wire msg_src = msg_src_sync[1];

    // ==========================================
    // CORDIC modulator (FM / PM / AM / carrier only)
    // ==========================================
    // Computes one sample per data_valid; the result is registered and read by
    // the DAC on the next data_valid (one sample of latency).
    cordic_mod cordic_mod_inst (
        .clk(clk_32mhz),
        .rst(sys_rst),
        .tick(data_valid),
        .mode(mod_type),
        .fc_fcw(fc_fcw),
        .fm_fcw(fm_fcw),
        .dev_fcw(dev_fcw),
        .beta_x10(beta_x10),
        .amp_pct(amp_pct),
        .mic_sample(mic_audio_data),
        .msg_src(msg_src),
        .sample_out(mod_audio_data),
        .out_valid(mod_out_valid)
    );

    // ==========================================
    // Internal Audio Storage RAM (Scope Task 4)
    // ==========================================
    // Buffers 2048 words of {mic_audio, mod_audio} in 7-series Block RAM.
    // When SW2 (freeze_sw) is high, recording pauses, freezing the frame
    // and looping playback through Pmod DA2 for oscilloscope analysis.
    wire [10:0] ram_wr_addr;
    wire        ram_full;
    reg  [10:0] ram_playback_ptr = 11'd0;

    always @(posedge clk_32mhz) begin
        if (sys_rst) begin
            ram_playback_ptr <= 11'd0;
        end else if (mod_out_valid) begin
            if (!freeze_active)
                ram_playback_ptr <= ram_wr_addr;
            else
                ram_playback_ptr <= ram_playback_ptr + 1'b1;
        end
    end

    (* DONT_TOUCH = "TRUE" *)
    audio_storage_ram #(
        .ADDR_WIDTH(11),
        .DATA_WIDTH(24)
    ) audio_ram_inst (
        .clk(clk_32mhz),
        .rst(sys_rst),
        .sample_tick(mod_out_valid),
        .freeze(freeze_active),
        .orig_sample(mic_audio_data),
        .mod_sample(mod_audio_data),
        .wr_addr(ram_wr_addr),
        .buffer_full(ram_full),
        .rd_addr(ram_playback_ptr),
        .rd_orig_sample(ram_rd_orig),
        .rd_mod_sample(ram_rd_mod)
    );

    assign leds = led_func ? vu_level : kp_leds;  // Display VU meter level or keypad status

    // ==========================================
    // VIO debug core (optional)
    // ==========================================
    // Define USE_VIO (Vivado: Settings > General > Verilog options > Defines) and
    // create the IP with src/ip/create_vio.tcl to get a live dashboard over JTAG.
    // Without USE_VIO the keypad drives param_ctrl directly and no IP is needed.
`ifdef USE_VIO
    wire [3:0] vio_key;             // key label to inject (0-9, A-F)
    wire       vio_press;           // toggle 0 -> 1 to inject one press
    wire       vio_en;              // 1 = VIO drives param_ctrl, 0 = real keypad

    reg vio_press_d = 1'b0;
    always @(posedge clk_32mhz) vio_press_d <= vio_press;
    wire vio_valid = vio_press & ~vio_press_d;   // one-cycle pulse per 0 -> 1 toggle

    assign ui_valid = vio_en ? vio_valid : key_valid;
    assign ui_code  = vio_en ? vio_key   : key_code;
    assign ui_held  = vio_en ? 1'b0      : key_held;

    vio_0 vio_inst (
        .clk       (clk_32mhz),
        .probe_in0 (mic_audio_data),                        // 12  mic sample (2048 = silence)
        .probe_in1 (vu_level),                              // 8   VU meter bar
        .probe_in2 (fc_hz),                                 // 14  carrier, Hz
        .probe_in3 (fm_hz),                                 // 12  modulating tone, Hz
        .probe_in4 (beta_x10),                              // 8   modulation index x10
        .probe_in5 (amp_pct),                               // 7   amplitude, %
        .probe_in6 ({mod_type, sel_param}),                 // 5   [4:3] mode, [2:0] selected
        .probe_in7 (entry_value),                           // 17  digits being typed
        .probe_in8 ({key_held, key_code}),                  // 5   [4] held, [3:0] last key
        .probe_in9 (fc_fcw),                                // 32  carrier phase increment
        .probe_in10({sys_rst, clk_locked}),                 // 2   [1] reset, [0] locked
        .probe_out0(vio_key),                               // 4
        .probe_out1(vio_press),                             // 1
        .probe_out2(vio_en)                                 // 1
    );
`else
    assign ui_valid = key_valid;
    assign ui_code  = key_code;
    assign ui_held  = key_held;
`endif

endmodule
