`timescale 1ns / 1ps

// =============================================================================
// param_ctrl.v - Keypad user interface / modulation parameter registers
// =============================================================================
// Turns key events from pmod_kypd into the modulation parameters used by the
// rest of the design. All outputs are registered and in the clk (32 MHz)
// domain; `param_update` pulses for one cycle whenever any parameter changes
// (all *_fcw outputs are already valid in that cycle).
//
// ---------------------------------------------------------------- KEY MAP ----
//   [ 1 ][ 2 ][ 3 ][ A ]     0-9 : type a value for the selected parameter
//   [ 4 ][ 5 ][ 6 ][ B ]     A   : next parameter (fc > fm > beta > amp > tbase)
//   [ 7 ][ 8 ][ 9 ][ C ]     B   : modulation type (FM > PM > AM > BYPASS)
//   [ 0 ][ F ][ E ][ D ]     C   : clear typed digits
//                            D   : enter - apply typed value (clamped)
//                            E/F : step selected parameter up/down (hold = repeat)
//   Board button BTNC        : freeze / unfreeze display
//   -> To remap, edit the KEY_* localparams below. Digit keys are codes 0-9.
//
// ------------------------------------------------------------- PARAMETERS ----
//   sel | name     | typed as                | step  | range     | default
//   ----+----------+-------------------------+-------+-----------+--------
//    0  | fc_hz    | Hz                      | 50    | 100-12000 | 1000
//    1  | fm_hz    | Hz                      | 5     | 1-3000    | 50
//    2  | beta_x10 | tenths (25 -> 2.5)      | 5     | 0-200     | 20
//    3  | amp_pct  | percent                 | 5     | 0-100     | 80
//    4  | tb_log2  | 1,2,4..64 (rounded down | x2/÷2 | 0-6       | 0
//       |          | to power of 2), stored as log2              |
//   Out-of-range values are clamped and the status LED fast-blinks.
//
// --------------------------------------------------------------- KP_LEDS -----
//   [7] status : slow blink = typing, 200 ms ON = applied, fast blink = clamped
//   [6:5] mode : 00 FM, 01 PM, 10 AM, 11 BYPASS
//   [4:0]      : one-hot selected parameter (LD0 fc ... LD4 timebase)
//
// ------------------------------------------------------------------- FCW -----
//   fs = CLK_HZ / SAMPLE_DIV (32 MHz / 667 ~= 47.976 kHz, matches top_module)
//   fc_fcw  = fc  * 2^32 / fs     (NCO phase increment for the carrier)
//   fm_fcw  = fm  * 2^32 / fs     (NCO phase increment for the test tone)
//   dev_fcw = beta*fm * 2^32 / fs (peak frequency deviation, delta-f = beta*fm)
// =============================================================================

module param_ctrl #(
    parameter integer CLK_HZ          = 32_000_000,
    parameter integer SAMPLE_DIV      = 667,             // clk cycles per audio sample
    parameter integer MS_TICKS        = CLK_HZ / 1000,   // clk cycles per millisecond
    parameter integer REPEAT_DELAY_MS = 400,             // hold time before auto-repeat
    parameter integer REPEAT_MS       = 100,             // auto-repeat interval
    parameter integer BTN_DEBOUNCE_MS = 20
)(
    input  wire        clk,
    input  wire        rst,

    // from pmod_kypd
    input  wire        key_valid,
    input  wire [3:0]  key_code,
    input  wire        key_held,

    // board push button (raw, asynchronous)
    input  wire        btn_freeze,

    // ---- modulation parameters (to DSP / VGA) ----
    output reg  [1:0]  mode,        // 00 FM, 01 PM, 10 AM, 11 BYPASS
    output reg  [13:0] fc_hz,
    output reg  [11:0] fm_hz,
    output reg  [7:0]  beta_x10,
    output reg  [6:0]  amp_pct,
    output reg  [2:0]  tb_log2,     // display timebase = 2^tb_log2
    output reg         freeze,
    output reg  [31:0] fc_fcw,
    output reg  [31:0] fm_fcw,
    output reg  [31:0] dev_fcw,
    output reg         param_update,

    // ---- UI state (for a VGA status line) ----
    output reg  [2:0]  sel_param,
    output wire        entry_active,
    output reg  [16:0] entry_value,
    output reg  [2:0]  entry_digits,

    // ---- LED feedback ----
    output wire [7:0]  kp_leds
);

    // -------------------------------------------------------------------------
    // Key map (edit here to remap)
    // -------------------------------------------------------------------------
    localparam [3:0] KEY_NEXT  = 4'hA;
    localparam [3:0] KEY_MODE  = 4'hB;
    localparam [3:0] KEY_CLEAR = 4'hC;
    localparam [3:0] KEY_ENTER = 4'hD;
    localparam [3:0] KEY_UP    = 4'hE;
    localparam [3:0] KEY_DOWN  = 4'hF;

    // -------------------------------------------------------------------------
    // Parameter indices, limits, steps, defaults
    // -------------------------------------------------------------------------
    localparam [2:0] P_FC = 3'd0, P_FM = 3'd1, P_BETA = 3'd2, P_AMP = 3'd3, P_TB = 3'd4;
    localparam [2:0] P_LAST = P_TB;

    localparam integer FC_MIN   = 100,  FC_MAX   = 12000, FC_STEP   = 50, FC_DEF   = 1000;
    localparam integer FM_MIN   = 1,    FM_MAX   = 3000,  FM_STEP   = 5,  FM_DEF   = 50;
    localparam integer BETA_MIN = 0,    BETA_MAX = 200,   BETA_STEP = 5,  BETA_DEF = 20;
    localparam integer AMP_MIN  = 0,    AMP_MAX  = 100,   AMP_STEP  = 5,  AMP_DEF  = 80;
    localparam integer TB_MAX   = 6,    TB_DEF   = 0;

    localparam integer MAX_DIGITS = 5;

    // FCW per Hz in Q16: 2^32/fs * 2^16 = 2^48 * SAMPLE_DIV / CLK_HZ
    localparam [63:0] FCW_K      = ((64'd1 << 48) * SAMPLE_DIV) / CLK_HZ;
    localparam [63:0] FCW_K_DIV10 = FCW_K / 10;

    // -------------------------------------------------------------------------
    // Millisecond tick + free-running ms counter (blink timing)
    // -------------------------------------------------------------------------
    localparam integer MW = (MS_TICKS > 1) ? $clog2(MS_TICKS) : 1;
    reg [MW-1:0] ms_div = 0;
    reg          ms_tick = 1'b0;
    reg [9:0]    ms_cnt = 10'd0;

    always @(posedge clk) begin
        if (rst) begin
            ms_div  <= 0;
            ms_tick <= 1'b0;
            ms_cnt  <= 10'd0;
        end else if (ms_div == MS_TICKS - 1) begin
            ms_div  <= 0;
            ms_tick <= 1'b1;
            ms_cnt  <= ms_cnt + 1'b1;
        end else begin
            ms_div  <= ms_div + 1'b1;
            ms_tick <= 1'b0;
        end
    end

    // -------------------------------------------------------------------------
    // Auto-repeat for the step keys
    // -------------------------------------------------------------------------
    wire is_step_key = (key_code == KEY_UP) || (key_code == KEY_DOWN);
    reg [9:0] rep_ms  = 10'd0;
    reg       rep_go  = 1'b0;     // 1-cycle "repeat this step" pulse

    always @(posedge clk) begin
        if (rst) begin
            rep_ms <= 10'd0;
            rep_go <= 1'b0;
        end else begin
            rep_go <= 1'b0;
            if (key_valid || !key_held || !is_step_key) begin
                rep_ms <= 10'd0;
            end else if (ms_tick) begin
                if (rep_ms == REPEAT_DELAY_MS - 1) begin
                    rep_ms <= REPEAT_DELAY_MS - REPEAT_MS;
                    rep_go <= 1'b1;
                end else begin
                    rep_ms <= rep_ms + 1'b1;
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Freeze button: sync, debounce, toggle on press
    // -------------------------------------------------------------------------
    (* ASYNC_REG = "TRUE" *) reg btn_meta = 1'b0;
    (* ASYNC_REG = "TRUE" *) reg btn_sync = 1'b0;
    reg       btn_state = 1'b0;
    reg [5:0] btn_ms    = 6'd0;

    always @(posedge clk) begin
        btn_meta <= btn_freeze;
        btn_sync <= btn_meta;
        if (rst) begin
            btn_state <= 1'b0;
            btn_ms    <= 6'd0;
            freeze    <= 1'b0;
        end else if (btn_sync == btn_state) begin
            btn_ms <= 6'd0;
        end else if (ms_tick) begin
            if (btn_ms == BTN_DEBOUNCE_MS - 1) begin
                btn_state <= btn_sync;
                btn_ms    <= 6'd0;
                if (btn_sync) freeze <= ~freeze;
            end else begin
                btn_ms <= btn_ms + 1'b1;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------
    // Clamp v to [lo, hi]; bit 17 of the result = "value was clamped"
    function [17:0] clamp;
        input [16:0] v;
        input [16:0] lo;
        input [16:0] hi;
        begin
            if (v < lo)      clamp = {1'b1, lo};
            else if (v > hi) clamp = {1'b1, hi};
            else             clamp = {1'b0, v};
        end
    endfunction

    // Step v by +/-s inside [lo, hi]; bit 17 = "hit a limit"
    function [17:0] step;
        input [16:0] v;
        input        up;
        input [16:0] s;
        input [16:0] lo;
        input [16:0] hi;
        begin
            if (up) step = (v + s >= hi) ? {(v + s > hi), hi} : {1'b0, v + s};
            else    step = (v < lo + s)  ? {1'b1, lo}           : {1'b0, v - s};
        end
    endfunction

    // floor(log2(v)) for v in 1..64
    function [2:0] flog2;
        input [6:0] v;
        begin
            if      (v[6]) flog2 = 3'd6;
            else if (v[5]) flog2 = 3'd5;
            else if (v[4]) flog2 = 3'd4;
            else if (v[3]) flog2 = 3'd3;
            else if (v[2]) flog2 = 3'd2;
            else if (v[1]) flog2 = 3'd1;
            else           flog2 = 3'd0;
        end
    endfunction

    // Current value of the selected parameter, zero-extended
    reg [16:0] cur_val;
    always @(*) begin
        case (sel_param)
            P_FC:    cur_val = {3'd0,  fc_hz};
            P_FM:    cur_val = {5'd0,  fm_hz};
            P_BETA:  cur_val = {9'd0,  beta_x10};
            P_AMP:   cur_val = {10'd0, amp_pct};
            default: cur_val = {14'd0, tb_log2};
        endcase
    end

    assign entry_active = (entry_digits != 3'd0);

    // -------------------------------------------------------------------------
    // Main UI state machine
    // -------------------------------------------------------------------------
    reg        changed  = 1'b0;   // a parameter register changed this cycle
    reg        flash    = 1'b0;   // request "applied" flash
    reg        err      = 1'b0;   // request "clamped" blink
    reg [17:0] r;                 // scratch (blocking)
    reg [16:0] tb_v;

    wire do_step = (key_valid && is_step_key) || rep_go;
    wire step_up = (key_code == KEY_UP);

    always @(posedge clk) begin
        if (rst) begin
            sel_param    <= P_FC;
            mode         <= 2'b00;
            fc_hz        <= FC_DEF;
            fm_hz        <= FM_DEF;
            beta_x10     <= BETA_DEF;
            amp_pct      <= AMP_DEF;
            tb_log2      <= TB_DEF;
            entry_value  <= 17'd0;
            entry_digits <= 3'd0;
            changed      <= 1'b1;     // publish defaults once after reset
            flash        <= 1'b0;
            err          <= 1'b0;
        end else begin
            changed <= 1'b0;
            flash   <= 1'b0;
            err     <= 1'b0;

            if (do_step) begin
                // ---------------- E / F : step (also on auto-repeat) --------
                entry_value  <= 17'd0;
                entry_digits <= 3'd0;
                changed      <= 1'b1;
                case (sel_param)
                    P_FC:    begin r = step(cur_val, step_up, FC_STEP,   FC_MIN,   FC_MAX);   fc_hz    <= r[13:0]; end
                    P_FM:    begin r = step(cur_val, step_up, FM_STEP,   FM_MIN,   FM_MAX);   fm_hz    <= r[11:0]; end
                    P_BETA:  begin r = step(cur_val, step_up, BETA_STEP, BETA_MIN, BETA_MAX); beta_x10 <= r[7:0];  end
                    P_AMP:   begin r = step(cur_val, step_up, AMP_STEP,  AMP_MIN,  AMP_MAX);  amp_pct  <= r[6:0];  end
                    default: begin r = step(cur_val, step_up, 1,         0,        TB_MAX);   tb_log2  <= r[2:0];  end
                endcase
                err <= r[17] | (cur_val == r[16:0]);   // blink if already at a limit
            end else if (key_valid) begin
                if (key_code <= 4'd9) begin
                    // ---------------- 0-9 : type digits ---------------------
                    if (entry_digits < MAX_DIGITS) begin
                        entry_value  <= entry_value * 10 + key_code;
                        entry_digits <= entry_digits + 1'b1;
                    end else begin
                        err <= 1'b1;   // too many digits
                    end
                end else case (key_code)
                    KEY_NEXT: begin
                        sel_param    <= (sel_param == P_LAST) ? P_FC : sel_param + 1'b1;
                        entry_value  <= 17'd0;
                        entry_digits <= 3'd0;
                    end
                    KEY_MODE: begin
                        mode    <= mode + 1'b1;
                        changed <= 1'b1;
                    end
                    KEY_CLEAR: begin
                        entry_value  <= 17'd0;
                        entry_digits <= 3'd0;
                    end
                    KEY_ENTER: if (entry_active) begin
                        entry_value  <= 17'd0;
                        entry_digits <= 3'd0;
                        changed      <= 1'b1;
                        case (sel_param)
                            P_FC:    begin r = clamp(entry_value, FC_MIN,   FC_MAX);   fc_hz    <= r[13:0]; end
                            P_FM:    begin r = clamp(entry_value, FM_MIN,   FM_MAX);   fm_hz    <= r[11:0]; end
                            P_BETA:  begin r = clamp(entry_value, BETA_MIN, BETA_MAX); beta_x10 <= r[7:0];  end
                            P_AMP:   begin r = clamp(entry_value, AMP_MIN,  AMP_MAX);  amp_pct  <= r[6:0];  end
                            default: begin
                                r    = clamp(entry_value, 1, 64);
                                tb_v = r[16:0];
                                tb_log2 <= flog2(tb_v[6:0]);
                                // not a power of two -> also counts as adjusted
                                r[17] = r[17] | ((tb_v & (tb_v - 1'b1)) != 17'd0);
                            end
                        endcase
                        if (r[17]) err   <= 1'b1;
                        else       flash <= 1'b1;
                    end
                    default: ;
                endcase
            end
        end
    end

    // -------------------------------------------------------------------------
    // Phase-increment (FCW) computation - one pipeline stage
    // -------------------------------------------------------------------------
    wire [63:0] fc_prod  = fc_hz * FCW_K;
    wire [63:0] fm_prod  = fm_hz * FCW_K;
    wire [19:0] dev_x10  = beta_x10 * fm_hz;          // delta-f in units of 0.1 Hz
    wire [63:0] dev_prod = dev_x10 * FCW_K_DIV10;

    always @(posedge clk) begin
        if (rst) begin
            fc_fcw       <= 32'd0;
            fm_fcw       <= 32'd0;
            dev_fcw      <= 32'd0;
            param_update <= 1'b0;
        end else begin
            fc_fcw       <= fc_prod[47:16];
            fm_fcw       <= fm_prod[47:16];
            // saturate at fs/2 (deviation that large is meaningless anyway)
            dev_fcw      <= (dev_prod[63:47] != 0) ? 32'h7FFF_FFFF : dev_prod[47:16];
            param_update <= changed;
        end
    end

    // -------------------------------------------------------------------------
    // LED feedback
    // -------------------------------------------------------------------------
    reg [9:0] flash_ms = 10'd0;   // "applied" solid-on time remaining
    reg [9:0] err_ms   = 10'd0;   // "clamped" fast-blink time remaining

    always @(posedge clk) begin
        if (rst) begin
            flash_ms <= 10'd0;
            err_ms   <= 10'd0;
        end else begin
            if (err)                          err_ms <= 10'd1000;
            else if (ms_tick && err_ms != 0)  err_ms <= err_ms - 1'b1;

            if (flash)                         flash_ms <= 10'd200;
            else if (ms_tick && flash_ms != 0) flash_ms <= flash_ms - 1'b1;
        end
    end

    wire blink_slow = ms_cnt[8];   // ~2 Hz
    wire blink_fast = ms_cnt[6];   // ~8 Hz

    wire status_led = (err_ms   != 0) ? blink_fast :
                      (flash_ms != 0) ? 1'b1       :
                      entry_active    ? blink_slow : 1'b0;

    assign kp_leds = { status_led,
                       mode,
                       (sel_param == P_TB),
                       (sel_param == P_AMP),
                       (sel_param == P_BETA),
                       (sel_param == P_FM),
                       (sel_param == P_FC) };

endmodule
