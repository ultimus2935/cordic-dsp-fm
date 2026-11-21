`timescale 1ns / 1ps

// =============================================================================
// tb_top.v - full-system testbench (top_module + all peripherals modelled)
// =============================================================================
// Models: Pmod MIC3 ADC (ADCS7476 SPI, sine with a DC offset), Pmod DA2 receiver
// (decodes both channels), Pmod KYPD matrix, and clk_wiz_0
// (src/simulation/models/clk_wiz_0_sim.v). Checks, end to end:
//   reset/lock, sample rate, mic -> DAC channel, DAC framing, keypad -> CORDIC,
//   FM output frequency, mic DC removal, mic as the FM / AM message, VU meter,
//   keypad LEDs, SW7 channel swap.
//
// Icarus:  iverilog -g2012 -o tb_top src/simulation/tb_top.v
//            src/simulation/models/clk_wiz_0_sim.v src/design/*.v && vvp tb_top
// (keypad scan / ms timers are sped up with defparam so this runs in seconds)
// =============================================================================

module tb_top;

    // ------------------------------------------------------------- board --
    reg sys_clk = 0;
    always #5 sys_clk = ~sys_clk;                  // 100 MHz (only feeds the clk_wiz model)

    reg rst        = 1;                            // BTNR
    reg da2_func   = 0;                            // SW7
    reg led_func   = 0;                            // SW0
    reg msg_src_sw = 0;                            // SW1
    reg freeze_sw  = 0;                            // SW2
    wire [7:0] leds;

    wire [3:0] kp_col, kp_row;
    wire da_sync_n, da_sclk, da_mosi1, da_mosi2;
    wire mic_cs_n, mic_sclk;
    reg  mic_miso = 0;

    top dut (
        .sys_clk(sys_clk), .rst(rst),
        .da2_func(da2_func), .led_func(led_func), .msg_src_sw(msg_src_sw), .freeze_sw(freeze_sw), .leds(leds),
        .kp_col(kp_col), .kp_row(kp_row),
        .da_sync_n(da_sync_n), .da_sclk(da_sclk), .da_mosi1(da_mosi1), .da_mosi2(da_mosi2),
        .mic_cs_n(mic_cs_n), .mic_miso(mic_miso), .mic_sclk(mic_sclk)
    );

    // Speed up the keypad scan and the UI millisecond timer for simulation
    defparam dut.kypd_inst.COL_TICKS      = 32;
    defparam dut.param_ctrl_inst.MS_TICKS = 64;

    wire clk = dut.clk_32mhz;

    // -------------------------------------------------- Pmod MIC3 model --
    // ADCS7476: CS falling clocks out the 1st of 4 leading zeros, then one bit
    // per SCLK falling edge (12 data bits, MSB first).
    real    mic_amp  = 0.0;                        // counts
    real    mic_freq = 400.0;                      // Hz
    integer mic_dc   = 2148;                       // deliberately not 2048: tests DC removal
    reg [11:0] mic_word = 12'd2048;                // value of the current conversion
    reg [15:0] mic_frame;
    integer    mic_bit;

    always @(negedge mic_cs_n) begin
        mic_word  = mic_dc + $rtoi(mic_amp * $sin(6.283185307 * mic_freq * $realtime * 1e-9));
        mic_frame = {4'b0000, mic_word};
        mic_bit   = 0;
        #5 mic_miso = mic_frame[15];
    end
    always @(negedge mic_sclk) if (!mic_cs_n) begin
        mic_bit = mic_bit + 1;
        if (mic_bit < 16) #5 mic_miso = mic_frame[15 - mic_bit];
    end

    // ------------------------------------------------- Pmod DA2 receiver --
    // DAC121S101: data latched on SCLK falling edges while SYNC is low.
    reg [15:0] rx_a, rx_b;
    integer    rx_bits = 0, n_frames = 0, bad_frames = 0;
    reg [11:0] dac_a = 12'd2048, dac_b = 12'd2048;  // last decoded values
    reg [11:0] exp_a, exp_b;                        // what the design meant to send
    reg        new_frame = 0;

    always @(negedge da_sync_n) begin
        rx_bits = 0;
        exp_a   = dut.da_audio_a;
        exp_b   = dut.da_audio_b;
    end
    always @(negedge da_sclk) if (!da_sync_n) begin
        rx_a = {rx_a[14:0], da_mosi1};
        rx_b = {rx_b[14:0], da_mosi2};
        rx_bits = rx_bits + 1;
        if (rx_bits == 16) begin
            dac_a = rx_a[11:0];
            dac_b = rx_b[11:0];
            n_frames = n_frames + 1;
            if (rx_a[15:12] != 4'b0000 || rx_b[15:12] != 4'b0000 ||
                rx_a[11:0] != exp_a || rx_b[11:0] != exp_b)
                bad_frames = bad_frames + 1;
            new_frame = ~new_frame;
        end
    end

    // ------------------------------------------------- Pmod KYPD model --
    reg [15:0] pressed = 16'd0;                    // bit = row*4 + col
    genvar r;
    generate for (r = 0; r < 4; r = r + 1) begin : g_row
        assign kp_row[r] = ~( (pressed[r*4+0] & (kp_col[0] === 1'b0)) |
                              (pressed[r*4+1] & (kp_col[1] === 1'b0)) |
                              (pressed[r*4+2] & (kp_col[2] === 1'b0)) |
                              (pressed[r*4+3] & (kp_col[3] === 1'b0)) );
    end endgenerate

    function [3:0] pos_of;
        input [3:0] label;
        case (label)
            4'h1: pos_of = 0;  4'h2: pos_of = 1;  4'h3: pos_of = 2;  4'hA: pos_of = 3;
            4'h4: pos_of = 4;  4'h5: pos_of = 5;  4'h6: pos_of = 6;  4'hB: pos_of = 7;
            4'h7: pos_of = 8;  4'h8: pos_of = 9;  4'h9: pos_of = 10; 4'hC: pos_of = 11;
            4'h0: pos_of = 12; 4'hF: pos_of = 13; 4'hE: pos_of = 14; default: pos_of = 15;
        endcase
    endfunction

    task tap(input [3:0] label);
        begin
            pressed[pos_of(label)] = 1; repeat (1500) @(posedge clk);
            pressed[pos_of(label)] = 0; repeat (1500) @(posedge clk);
        end
    endtask

    task type_value(input integer v);       // digits of v, then D
        integer d, div;
        begin
            div = 10000;
            while (div > 1 && v < div) div = div / 10;
            while (div >= 1) begin
                d = (v / div) % 10;
                tap(d[3:0]);
                div = div / 10;
            end
            tap(4'hD);
        end
    endtask

    // ------------------------------------------------------- utilities --
    integer errors = 0;
    task check(input cond, input [8*72-1:0] msg);
        begin
            if (!cond) begin errors = errors + 1; $display("  FAIL : %0s", msg); end
            else                                   $display("  ok   : %0s", msg);
        end
    endtask

    localparam real FS        = 32.0e6 / 667.0;
    localparam real FCW_PER_HZ = 4294967296.0 / FS;

    task wait_frames(input integer n);
        integer k;
        begin for (k = 0; k < n; k = k + 1) @(new_frame); end
    endtask

    // Measure the output on one DAC channel over n samples:
    // frequency from rising crossings of mid-scale, and the peak deviation.
    real    meas_freq;
    integer meas_peak;
    task measure(input integer use_b, input integer n);
        integer k, v, prev, xing, pk;
        begin
            xing = 0; pk = 0; prev = 2048;
            for (k = 0; k < n; k = k + 1) begin
                @(new_frame);
                v = use_b ? dac_b : dac_a;
                if (prev < 2048 && v >= 2048) xing = xing + 1;
                if (v - 2048 > pk) pk = v - 2048;
                if (2048 - v > pk) pk = 2048 - v;
                prev = v;
            end
            meas_freq = xing * FS / n;
            meas_peak = pk;
        end
    endtask

    // Spread of the carrier phase increment (= instantaneous frequency, Hz)
    real inc_min, inc_max, inc_mean;
    task measure_inc(input integer n);
        integer k;
        real f, sum;
        begin
            inc_min = 1e9; inc_max = -1e9; sum = 0;
            for (k = 0; k < n; k = k + 1) begin
                @(posedge dut.cordic_mod_inst.out_valid);
                f = $itor($signed(dut.cordic_mod_inst.inc)) / FCW_PER_HZ;
                if (f < inc_min) inc_min = f;
                if (f > inc_max) inc_max = f;
                sum = sum + f;
            end
            inc_mean = sum / n;
        end
    endtask

    // Mic AC signal statistics after DC removal
    real mic_mean;
    integer mic_pk;
    task measure_mic(input integer n);
        integer k, v;
        real sum;
        begin
            sum = 0; mic_pk = 0;
            for (k = 0; k < n; k = k + 1) begin
                @(posedge dut.cordic_mod_inst.out_valid);
                v = $signed(dut.cordic_mod_inst.mic_ac);
                sum = sum + v;
                if (v > mic_pk) mic_pk = v;
                if (-v > mic_pk) mic_pk = -v;
            end
            mic_mean = sum / n;
        end
    endtask

    // ------------------------------------------------------------ tests --
    integer f0, f1, mismatch, k;
    real env_min, env_max, e;

    initial begin
        $display("tb_top: full-system test");
        #500 rst = 0;
        wait (dut.clk_locked === 1'b1);
        repeat (50) @(posedge clk);

        // --------------------------------------------------------------
        $display("[1] Clock / reset");
        check(dut.clk_locked === 1'b1 && dut.sys_rst === 1'b0, "clock locked and reset released");

        // --------------------------------------------------------------
        $display("[2] Sample rate and DAC framing");
        f0 = n_frames;
        #10_000_000;                                    // 10 ms
        f1 = n_frames;
        check(f1 - f0 >= 478 && f1 - f0 <= 481, "about 480 DAC frames in 10 ms (47.98 kHz)");
        check(bad_frames == 0, "every DAC frame decodes to the intended A and B values, PD bits 00");

        // --------------------------------------------------------------
        $display("[3] Mic -> DAC (SW7 = 1: A = mic, B = modulated)");
        mic_amp = 1000.0;
        da2_func = 1;
        wait_frames(5);
        mismatch = 0;
        for (k = 0; k < 200; k = k + 1) begin
            @(new_frame);
            if (dac_a != mic_word) mismatch = mismatch + 1;
            if (dac_b != dut.mod_audio_data && dac_b != exp_b) mismatch = mismatch + 1;
        end
        check(mismatch == 0, "channel A carries the mic sample unchanged");
        da2_func = 0;
        wait_frames(5);
        check(dac_b == mic_word, "SW7 = 0 swaps: mic moves to channel B");

        // --------------------------------------------------------------
        $display("[4] Defaults: FM, test tone, fc 1000 Hz, amp 80 %%");
        measure(0, 4800);                               // channel A = modulated (SW7 = 0)
        $display("       measured %0.1f Hz, peak %0d counts", meas_freq, meas_peak);
        check(meas_freq > 975 && meas_freq < 1025, "carrier frequency ~1000 Hz");
        check(meas_peak > 1600 && meas_peak < 1660, "amplitude ~80 % of full scale");

        // --------------------------------------------------------------
        $display("[5] Keypad -> CORDIC: type 2000 D for fc");
        type_value(2000);
        check(dut.fc_hz == 2000, "fc_hz = 2000");
        wait_frames(5);
        measure(0, 4800);
        $display("       measured %0.1f Hz", meas_freq);
        check(meas_freq > 1975 && meas_freq < 2025, "output now ~2000 Hz");
        check(leds[3:0] == 4'b0001, "LD0 lit (fc selected)");

        // --------------------------------------------------------------
        $display("[6] Mic DC removal (mic silent but offset to 2148)");
        mic_amp = 0.0;
        msg_src_sw = 1;                                 // SW1: message = mic
        wait_frames(2400);                              // 50 ms: let the running mean settle
        measure_mic(480);
        $display("       mic_ac mean %0.2f, peak %0d", mic_mean, mic_pk);
        check(mic_mean > -2.0 && mic_mean < 2.0, "DC offset removed");
        measure_inc(480);
        $display("       carrier %0.1f .. %0.1f Hz", inc_min, inc_max);
        check(inc_mean > 1998 && inc_mean < 2002 && (inc_max - inc_min) < 2,
              "silent mic leaves the carrier at fc (no shift)");

        // --------------------------------------------------------------
        $display("[7] Mic as the FM message");
        tap(4'hA);                                      // select fm
        type_value(1000);                               // fm = 1000 -> deviation = 2.0 * 1000 Hz
        check(dut.fm_hz == 1000, "fm_hz = 1000 (deviation scale)");
        mic_amp = 1000.0;                               // 1000/2048 = 0.49 of full scale
        wait_frames(1200);
        measure_mic(480);
        $display("       mic_ac mean %0.2f, peak %0d", mic_mean, mic_pk);
        check(mic_pk > 950 && mic_pk < 1050 && mic_mean > -20 && mic_mean < 20,
              "mic AC part reaches the modulator (~+-1000 counts, no DC)");
        measure_inc(480);
        $display("       carrier %0.1f .. %0.1f Hz (expect ~2000 +- 977)", inc_min, inc_max);
        check(inc_max - inc_min > 1850 && inc_max - inc_min < 2050,
              "carrier frequency swings with the mic (+-~977 Hz)");
        check(inc_mean > 1950 && inc_mean < 2050, "and is centred on fc");

        // --------------------------------------------------------------
        $display("[8] Mic as the AM message (B, B -> AM)");
        tap(4'hB); tap(4'hB);
        check(dut.mod_type == 2'b10 && leds[6:5] == 2'b10, "mode AM, LD6 on");
        wait_frames(10);
        env_min = 1e9; env_max = -1e9;
        for (k = 0; k < 480; k = k + 1) begin
            @(posedge dut.cordic_mod_inst.out_valid);
            e = $itor(dut.cordic_mod_inst.env) / 65536.0;
            if (e < env_min) env_min = e;
            if (e > env_max) env_max = e;
        end
        $display("       envelope %0.3f .. %0.3f (expect ~0.26 .. 0.74)", env_min, env_max);
        check(env_min > 0.22 && env_min < 0.30 && env_max > 0.70 && env_max < 0.78,
              "AM envelope follows the mic");

        // --------------------------------------------------------------
        $display("[9] Test tone again (SW1 = 0), carrier-only mode");
        msg_src_sw = 0;
        tap(4'hB);                                      // AM -> carrier only
        check(dut.mod_type == 2'b11, "mode carrier only");
        wait_frames(10);
        measure_inc(480);
        check((inc_max - inc_min) < 1, "carrier only: fixed frequency");

        // --------------------------------------------------------------
        $display("[10] VU meter on LEDs (SW0 = 1)");
        led_func = 1;
        mic_amp  = 1500.0;
        wait_frames(480);
        $display("       leds = %b", leds);
        check(leds[5:0] == 6'b111111, "VU bar lit for a loud mic");

        // --------------------------------------------------------------
        $display("[11] Audio Storage BRAM Buffer (Scope 4)");
        check(dut.audio_ram_inst.buffer_full === 1'b1, "BRAM buffer stored >= 2048 samples");
        freeze_sw = 1;                                  // SW2 = 1: freeze recording
        wait_frames(10);
        f0 = dut.audio_ram_inst.wr_addr;
        wait_frames(50);
        f1 = dut.audio_ram_inst.wr_addr;
        check(f0 == f1, "SW2 = 1 freezes BRAM write address");
        freeze_sw = 0;                                  // SW2 = 0: resume circular capture
        wait_frames(10);
        check(dut.audio_ram_inst.wr_addr != f0, "SW2 = 0 resumes circular recording");

        $display("");
        if (errors == 0) $display("ALL SYSTEM TESTS PASSED");
        else             $display("%0d SYSTEM TEST(S) FAILED", errors);
        $finish;
    end

    initial begin
        #2_000_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
