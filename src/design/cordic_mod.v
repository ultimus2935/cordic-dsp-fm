`timescale 1ns / 1ps

// =============================================================================
// cordic_mod.v - CORDIC-based FM / PM / AM tone modulator
// =============================================================================
// Once per audio sample (`tick`) this computes one output sample:
//
//   message   m[n]   = sin(tone_ph)                      tone at fm
//   FM        out    = A * sin(acc),  acc += fc + dev*m   (frequency follows m)
//   PM        out    = A * sin(acc + beta*m)              (phase follows m)
//   AM        out    = A * (1 + mu*m)/2 * sin(acc)        (amplitude follows m)
//   BYPASS    out    = A * sin(acc)                       (plain carrier)
//
// A = amp_pct %, beta = beta_x10 / 10 (PM, radians), mu = min(beta_x10/10, 1)
// (AM depth), and every frequency is a 32-bit phase increment (f * 2^32 / fs)
// from param_ctrl. FM's index is set by dev_fcw = beta * fm (param_ctrl).
//
// One cordic_core is time-shared: first for the message sine, then for the
// carrier. 42 of the 667 clocks per sample are used.
//
// Output: 12-bit offset binary (2048 = silence), registered and held. It is
// ready 42 clocks after `tick`, so the DAC reads it on the NEXT tick (one
// sample = 20.8 us of latency, inaudible).
//
// Parameter changes: all parameters are copied at the tick, so a change never
// lands half-way through a sample. The phase accumulators are never reset, so
// fc / fm / FM-deviation changes are click-free. Steps in PM beta, amplitude
// and the mode itself are applied instantly and can give a small click.
//
// AM: mu is capped at 1.0 (100 % depth). (1 + mu*m)/2 then stays in 0..1, so
// the envelope never clips or inverts; the /2 keeps mu = 1 inside full scale.
//
// FM limiter: the instantaneous frequency fc + dev*m is held within +-FM_LIMIT
// (default 0x6000_0000 = 0.375*fs = ~18 kHz) so it never wraps past fs/2 and
// folds back. It only acts when fc + deviation would exceed it. Sidebands can
// still pass fs/2 for large beta*fm; keeping fc +- (beta+1)*fm inside
// 0..fs/2 is up to the parameter ranges (param_ctrl). PM cannot be limited here.
// =============================================================================

module cordic_mod #(
    parameter [31:0] FM_LIMIT = 32'h6000_0000    // max |instantaneous FM increment|
)(
    input  wire        clk,            // 32 MHz
    input  wire        rst,            // synchronous, active high (sys_rst)
    input  wire        tick,           // 1-cycle pulse per audio sample (data_valid)

    // Parameters from param_ctrl
    input  wire [1:0]  mode,           // 00 FM, 01 PM, 10 AM, 11 BYPASS
    input  wire [31:0] fc_fcw,         // carrier phase increment
    input  wire [31:0] fm_fcw,         // message-tone phase increment
    input  wire [31:0] dev_fcw,        // FM peak deviation (beta * fm) as increment
    input  wire [7:0]  beta_x10,       // modulation index x10 (PM beta, AM mu)
    input  wire [6:0]  amp_pct,        // output amplitude 0..100 %

    output reg  [11:0] sample_out,     // to the DAC (mod_audio_data)
    output reg         out_valid       // 1-cycle pulse when sample_out updates
);

    localparam [1:0] M_FM = 2'b00, M_PM = 2'b01, M_AM = 2'b10, M_BYP = 2'b11;

    // -------------------------------------------------------------------------
    // Fixed-point scaling (CORDIC peak = K * x0, K = 1.64676)
    // -------------------------------------------------------------------------
    // Message sine: x0 = 2^20 / K  ->  m = sin * 2^20   (+-1.0 = +-1,048,576)
    localparam signed [21:0] TONE_X0 = 22'sd636751;
    // Carrier length per amplitude %: 100 % -> 635,200 -> peak K*x0 = 1,046,023
    // -> after >>> 9 = 2043 DAC counts (a hair under the 2047 limit)
    localparam [12:0] AMP_X0_PER_PCT = 13'd6352;
    // PM: beta*m in phase counts = beta * sin * 2^32/(2*pi)
    //     = beta_x10 * m * 2^32/(20*pi*2^20) = beta_x10 * m * 1043.04 / 2^4
    localparam [10:0] PM_K = 11'd1043;
    // AM: mu*m in 2^16 units = (beta_x10 * 6553.6) * m / 2^20
    localparam [12:0] AM_K = 13'd6554;
    localparam [7:0]  AM_BETA_MAX = 8'd10;       // mu <= 1.0

    // -------------------------------------------------------------------------
    // CORDIC (shared)
    // -------------------------------------------------------------------------
    reg                c_start = 1'b0;
    reg  signed [21:0] c_x0    = 0;
    reg         [19:0] c_angle = 0;
    wire               c_done;
    wire signed [21:0] c_cos, c_sin;

    cordic_core #(.XYW(22), .ZW(20), .NIT(16)) cordic (
        .clk(clk), .rst(rst),
        .start(c_start), .x0(c_x0), .angle(c_angle),
        .done(c_done), .cos_out(c_cos), .sin_out(c_sin)
    );

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------
    localparam [2:0] S_IDLE  = 3'd0,   // wait for tick, shadow parameters
                     S_TONE  = 3'd1,   // CORDIC #1: message sine
                     S_MUL   = 3'd2,   // FM / PM / AM products (DSP48s)
                     S_ENV   = 3'd3,   // carrier angle + length, start CORDIC #2
                     S_CARR  = 3'd4,   // CORDIC #2: carrier
                     S_OUT   = 3'd5;   // round, clip, offset-binary

    reg [2:0] state = S_IDLE;

    // Shadowed parameters
    reg [1:0]  mode_s = M_FM;
    reg [31:0] fc_s   = 0, fm_s = 0, dev_s = 0;
    reg [18:0] beta_pm_s = 0;          // beta_x10 * 1043          (<= 208,600)
    reg [16:0] beta_am_s = 0;          // min(beta_x10,10) * 6554  (<= 65,540)
    reg [19:0] amp_x0_s  = 0;          // amp_pct * 6352           (<= 635,200)

    // Phase accumulators (32-bit, wrap = one full turn)
    reg [31:0] acc     = 0;            // carrier phase
    reg [31:0] tone_ph = 0;            // message-tone phase

    // Datapath registers
    reg signed [21:0] m       = 0;     // message sample, +-2^20
    reg        [31:0] inc     = 0;     // carrier phase increment for this sample
    reg        [31:0] pm_term = 0;     // beta * m   (phase offset, wraps)
    reg signed [17:0] env     = 0;     // AM envelope 0..65536 = 0..1.0

    // ---- FM: increment = fc + dev*m, limited to +-FM_LIMIT ----
    wire signed [54:0] fm_prod = $signed({1'b0, dev_s}) * m;            // 33 x 22
    wire signed [33:0] fm_term = fm_prod >>> 20;                         // dev * sin
    wire signed [34:0] fm_inc  = $signed({3'b000, fc_s}) + fm_term;
    wire signed [34:0] lim_p   = $signed({3'b000, FM_LIMIT});
    wire signed [34:0] lim_n   = -$signed({3'b000, FM_LIMIT});
    wire        [31:0] fm_inc_lim = (fm_inc > lim_p) ? lim_p[31:0] :
                                    (fm_inc < lim_n) ? lim_n[31:0] :
                                     fm_inc[31:0];

    // ---- PM: phase offset beta*m (mod one turn) ----
    wire signed [41:0] pm_prod = $signed({1'b0, beta_pm_s}) * m;        // 20 x 22

    // ---- AM: envelope (1 + mu*m)/2 in 2^16 units ----
    wire signed [39:0] am_prod = $signed({1'b0, beta_am_s}) * m;        // 18 x 22
    wire signed [19:0] am_q    = am_prod >>> 20;                         // mu*m * 2^16
    wire signed [19:0] env_raw = (20'sd65536 + am_q) >>> 1;

    // Carrier length for this sample
    wire signed [38:0] am_x0_prod = $signed({1'b0, amp_x0_s}) * env;
    wire signed [21:0] am_x0      = am_x0_prod >>> 16;

    // ---- Output: CORDIC peak ~1,046,023 -> /512 -> ~2043, clip to +-2047 ----
    wire signed [21:0] c_round = (c_sin + 22'sd256) >>> 9;
    wire signed [11:0] c_sat   = (c_round >  22'sd2047) ?  12'sd2047 :
                                 (c_round < -22'sd2047) ? -12'sd2047 :
                                  c_round[11:0];

    initial begin
        sample_out = 12'd2048;
        out_valid  = 1'b0;
    end

    always @(posedge clk) begin
        if (rst) begin
            state      <= S_IDLE;
            c_start    <= 1'b0;
            acc        <= 0;
            tone_ph    <= 0;
            sample_out <= 12'd2048;
            out_valid  <= 1'b0;
        end else begin
            c_start   <= 1'b0;
            out_valid <= 1'b0;

            case (state)
                // -------------------------------------------------------------
                S_IDLE: if (tick) begin
                    mode_s    <= mode;
                    fc_s      <= fc_fcw;
                    fm_s      <= fm_fcw;
                    dev_s     <= dev_fcw;
                    beta_pm_s <= beta_x10 * PM_K;
                    beta_am_s <= ((beta_x10 > AM_BETA_MAX) ? AM_BETA_MAX : beta_x10) * AM_K;
                    amp_x0_s  <= amp_pct * AMP_X0_PER_PCT;
                    // CORDIC #1: message tone sine
                    c_x0      <= TONE_X0;
                    c_angle   <= tone_ph[31:12];
                    c_start   <= 1'b1;
                    state     <= S_TONE;
                end

                // -------------------------------------------------------------
                S_TONE: if (c_done) begin
                    m       <= c_sin;
                    tone_ph <= tone_ph + fm_s;
                    state   <= S_MUL;
                end

                // -------------------------------------------------------------
                S_MUL: begin
                    inc     <= (mode_s == M_FM) ? fm_inc_lim : fc_s;
                    pm_term <= pm_prod[35:4];                    // beta * sin, mod one turn
                    env     <= (env_raw > 20'sd65536) ? 18'sd65536 :
                               (env_raw < 20'sd0)     ? 18'sd0     :
                                env_raw[17:0];
                    state   <= S_ENV;
                end

                // -------------------------------------------------------------
                S_ENV: begin
                    // CORDIC #2: carrier
                    c_x0    <= (mode_s == M_AM) ? am_x0 : $signed({2'b00, amp_x0_s});
                    c_angle <= (mode_s == M_PM) ? (acc + pm_term) >> 12 : acc[31:12];
                    c_start <= 1'b1;
                    acc     <= acc + inc;                        // advance for next sample
                    state   <= S_CARR;
                end

                // -------------------------------------------------------------
                S_CARR: if (c_done) state <= S_OUT;

                // -------------------------------------------------------------
                S_OUT: begin
                    sample_out <= {~c_sat[11], c_sat[10:0]};   // signed -> offset binary
                    out_valid  <= 1'b1;
                    state      <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
