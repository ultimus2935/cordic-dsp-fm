`timescale 1ns / 1ps

// =============================================================================
// tb_keypad.v - self-checking testbench for pmod_kypd + param_ctrl
// =============================================================================
// Models the PMOD KYPD matrix (pulled-up rows, key shorts row to column) with
// contact bounce, then drives key sequences through the scanner and UI.
// Timing parameters are shrunk so the sim runs in milliseconds, not seconds.
// Prints "ALL TESTS PASSED" or the number of failures at the end.
// =============================================================================

module tb_keypad;

    // ---------------------------------------------------------------- clock --
    reg clk = 0;
    always #15.625 clk = ~clk;          // 32 MHz
    reg rst = 1;

    // -------------------------------------------------------- keypad model --
    reg  [15:0] pressed = 16'd0;        // bit = row*4 + col
    wire [3:0]  kp_col;
    wire [3:0]  kp_row;

    genvar r;
    generate
        for (r = 0; r < 4; r = r + 1) begin : g_row
            assign kp_row[r] = ~( (pressed[r*4+0] & (kp_col[0] === 1'b0)) |
                                  (pressed[r*4+1] & (kp_col[1] === 1'b0)) |
                                  (pressed[r*4+2] & (kp_col[2] === 1'b0)) |
                                  (pressed[r*4+3] & (kp_col[3] === 1'b0)) );
        end
    endgenerate

    // label -> matrix position
    function [3:0] pos_of;
        input [3:0] label;
        begin
            case (label)
                4'h1: pos_of = 0;  4'h2: pos_of = 1;  4'h3: pos_of = 2;  4'hA: pos_of = 3;
                4'h4: pos_of = 4;  4'h5: pos_of = 5;  4'h6: pos_of = 6;  4'hB: pos_of = 7;
                4'h7: pos_of = 8;  4'h8: pos_of = 9;  4'h9: pos_of = 10; 4'hC: pos_of = 11;
                4'h0: pos_of = 12; 4'hF: pos_of = 13; 4'hE: pos_of = 14; default: pos_of = 15;
            endcase
        end
    endfunction

    // ------------------------------------------------------------------ DUT --
    localparam integer COL_TICKS = 8;     // 4 cols -> 32-cycle frame
    localparam integer DEB       = 3;
    localparam integer MS        = 40;    // "1 ms" = 40 clocks in sim
    localparam integer SAMPLE_DIV = 667;

    wire       key_valid, key_held;
    wire [3:0] key_code;

    pmod_kypd #(.COL_TICKS(COL_TICKS), .DEBOUNCE_SCANS(DEB)) u_kypd (
        .clk(clk), .rst(rst),
        .kp_col(kp_col), .kp_row(kp_row),
        .key_valid(key_valid), .key_code(key_code), .key_held(key_held)
    );

    reg btn_freeze = 0;
    wire [1:0]  mode;
    wire [13:0] fc_hz;
    wire [11:0] fm_hz;
    wire [7:0]  beta_x10;
    wire [6:0]  amp_pct;
    wire [2:0]  tb_log2, sel_param, entry_digits;
    wire        freeze, param_update, entry_active;
    wire [31:0] fc_fcw, fm_fcw, dev_fcw;
    wire [16:0] entry_value;
    wire [7:0]  kp_leds;

    param_ctrl #(.CLK_HZ(32_000_000), .SAMPLE_DIV(SAMPLE_DIV), .MS_TICKS(MS),
                 .REPEAT_DELAY_MS(10), .REPEAT_MS(3), .BTN_DEBOUNCE_MS(4)) u_ctrl (
        .clk(clk), .rst(rst),
        .key_valid(key_valid), .key_code(key_code), .key_held(key_held),
        .btn_freeze(btn_freeze),
        .mode(mode), .fc_hz(fc_hz), .fm_hz(fm_hz), .beta_x10(beta_x10),
        .amp_pct(amp_pct), .tb_log2(tb_log2), .freeze(freeze),
        .fc_fcw(fc_fcw), .fm_fcw(fm_fcw), .dev_fcw(dev_fcw), .param_update(param_update),
        .sel_param(sel_param), .entry_active(entry_active),
        .entry_value(entry_value), .entry_digits(entry_digits),
        .kp_leds(kp_leds)
    );

    // ----------------------------------------------------------- monitors --
    integer n_events = 0;
    reg [3:0] last_code = 0;
    integer n_updates = 0;
    always @(posedge clk) begin
        if (key_valid) begin n_events = n_events + 1; last_code = key_code; end
        if (param_update) n_updates = n_updates + 1;
    end

    integer errors = 0;
    task check;
        input cond;
        input [8*64-1:0] msg;
        begin
            if (!cond) begin
                errors = errors + 1;
                $display("  FAIL @%0t: %0s", $time, msg);
            end else
                $display("  ok   : %0s", msg);
        end
    endtask

    // ------------------------------------------------------------ stimulus --
    localparam integer FRAME = 4 * COL_TICKS;
    localparam integer SETTLE = FRAME * (DEB + 4);

    // bouncy press of one key, held for hold_cyc clocks
    task press_hold;
        input [3:0] label;
        input integer hold_cyc;
        integer k, p;
        begin
            p = pos_of(label);
            for (k = 0; k < 5; k = k + 1) begin           // contact bounce
                pressed[p] = 1; repeat (3 + k*2) @(posedge clk);
                pressed[p] = 0; repeat (5) @(posedge clk);
            end
            pressed[p] = 1;
            repeat (hold_cyc) @(posedge clk);
            for (k = 0; k < 3; k = k + 1) begin           // release bounce
                pressed[p] = 0; repeat (4) @(posedge clk);
                pressed[p] = 1; repeat (3) @(posedge clk);
            end
            pressed[p] = 0;
            repeat (SETTLE) @(posedge clk);
        end
    endtask

    task tap;
        input [3:0] label;
        begin press_hold(label, SETTLE); end
    endtask

    function integer exp_fcw;
        input real f;
        begin exp_fcw = $rtoi(f * 4294967296.0 * SAMPLE_DIV / 32.0e6); end
    endfunction

    function integer absdiff;
        input integer a, b;
        begin absdiff = (a > b) ? a - b : b - a; end
    endfunction

    integer i, ev0, upd0, beta0;
    reg [3:0] labels [0:15];

    initial begin
        $dumpfile("tb_keypad.vcd");
        $dumpvars(0, tb_keypad);
        labels[0]=4'h0; labels[1]=4'h1; labels[2]=4'h2; labels[3]=4'h3;
        labels[4]=4'h4; labels[5]=4'h5; labels[6]=4'h6; labels[7]=4'h7;
        labels[8]=4'h8; labels[9]=4'h9; labels[10]=4'hA; labels[11]=4'hB;
        labels[12]=4'hC; labels[13]=4'hD; labels[14]=4'hE; labels[15]=4'hF;

        repeat (10) @(posedge clk);
        rst = 0;
        repeat (SETTLE) @(posedge clk);

        // ------------------------------------------------------------------
        $display("[1] Reset defaults");
        check(fc_hz == 1000 && fm_hz == 50 && beta_x10 == 20 && amp_pct == 80 &&
              tb_log2 == 0 && mode == 0 && sel_param == 0, "defaults loaded");
        check(kp_leds[4:0] == 5'b00001, "LED0 lit = fc selected");
        check(absdiff(fc_fcw, exp_fcw(1000.0)) <= 2, "fc_fcw for 1000 Hz");
        check(n_updates >= 1, "param_update pulsed after reset");

        // ------------------------------------------------------------------
        $display("[2] Every key decodes to its label (with bounce), one event each");
        for (i = 0; i < 16; i = i + 1) begin
            // skip function keys that change state we test later; still verify decode
            ev0 = n_events;
            tap(labels[i]);
            if (!(n_events == ev0 + 1 && last_code == labels[i])) $display("    key %h: events=%0d code=%h", labels[i], n_events-ev0, last_code);
            check(n_events == ev0 + 1 && last_code == labels[i], "key decode");
        end
        // restore known state after pressing everything
        rst = 1; repeat (5) @(posedge clk); rst = 0; repeat (SETTLE) @(posedge clk);

        // ------------------------------------------------------------------
        $display("[3] Type 1200 + D -> fc");
        tap(4'h1); tap(4'h2);
        check(entry_active && entry_value == 12 && entry_digits == 2, "entry shows 12 while typing");
        tap(4'h0); tap(4'h0);
        upd0 = n_updates;
        tap(4'hD);
        check(fc_hz == 1200, "fc_hz = 1200");
        check(absdiff(fc_fcw, exp_fcw(1200.0)) <= 2, "fc_fcw matches 1200 Hz");
        check(!entry_active, "entry cleared after enter");
        check(n_updates == upd0 + 1, "exactly one param_update");

        // ------------------------------------------------------------------
        $display("[4] C clears typed digits without changing value");
        tap(4'h5); tap(4'h5); tap(4'hC); tap(4'hD);
        check(fc_hz == 1200 && !entry_active, "fc unchanged after 55 C D");

        // ------------------------------------------------------------------
        $display("[5] A -> fm, out-of-range value is clamped + error blink");
        tap(4'hA);
        check(sel_param == 1 && kp_leds[4:0] == 5'b00010, "fm selected, LED1 lit");
        tap(4'h9); tap(4'h9); tap(4'h9); tap(4'h9); tap(4'hD);
        check(fm_hz == 3000, "fm clamped to 3000");
        check(u_ctrl.err_ms != 0, "clamp error blink active");
        check(absdiff(fm_fcw, exp_fcw(3000.0)) <= 2, "fm_fcw matches 3000 Hz");

        // ------------------------------------------------------------------
        $display("[6] A -> beta, E/F single steps");
        tap(4'hA);
        check(sel_param == 2, "beta selected");
        tap(4'hE);
        check(beta_x10 == 25, "E: beta 2.0 -> 2.5");
        tap(4'hF); tap(4'hF);
        check(beta_x10 == 15, "F F: beta 2.5 -> 1.5");
        check(absdiff(dev_fcw, exp_fcw(1.5 * 3000.0)) <= 4, "dev_fcw = beta*fm");

        // ------------------------------------------------------------------
        $display("[7] Holding E auto-repeats");
        beta0 = beta_x10;
        press_hold(4'hE, 25 * MS);          // 10 ms delay + repeats every 3 ms
        check(beta_x10 >= beta0 + 4*5, "beta rose by >= 4 steps while held");
        check(beta_x10 % 5 == 0, "steps are whole multiples of 0.5");

        // ------------------------------------------------------------------
        $display("[8] F at minimum saturates at 0");
        tap(4'h0); tap(4'hD);
        check(beta_x10 == 0, "beta set to 0");
        tap(4'hF);
        check(beta_x10 == 0, "F at 0 stays 0");

        // ------------------------------------------------------------------
        $display("[9] Timebase rounds down to power of two");
        tap(4'hA); tap(4'hA);
        check(sel_param == 4 && kp_leds[4:0] == 5'b10000, "timebase selected, LED4 lit");
        tap(4'h1); tap(4'h0); tap(4'hD);
        check(tb_log2 == 3, "typed 10 -> x8 (log2 = 3)");
        tap(4'hE);
        check(tb_log2 == 4, "E doubles -> x16");

        // ------------------------------------------------------------------
        $display("[10] A wraps back to fc");
        tap(4'hA);
        check(sel_param == 0, "wrapped to fc");

        // ------------------------------------------------------------------
        $display("[11] B cycles modulation type");
        tap(4'hB); check(mode == 1 && kp_leds[6:5] == 2'b01, "mode PM");
        tap(4'hB); check(mode == 2, "mode AM");
        tap(4'hB); check(mode == 3, "mode BYPASS");
        tap(4'hB); check(mode == 0, "mode back to FM");

        // ------------------------------------------------------------------
        $display("[12] Two keys at once -> no event; next clean press still works");
        ev0 = n_events;
        pressed[pos_of(4'h1)] = 1; pressed[pos_of(4'h5)] = 1;
        repeat (SETTLE * 2) @(posedge clk);
        pressed[pos_of(4'h5)] = 0;            // release one -> must NOT fire "1"
        repeat (SETTLE * 2) @(posedge clk);
        pressed[pos_of(4'h1)] = 0;
        repeat (SETTLE) @(posedge clk);
        check(n_events == ev0, "no event from multi-key press");
        check(!entry_active, "no digit entered");
        tap(4'h7);
        check(n_events == ev0 + 1 && entry_value == 7, "clean press after release works");
        tap(4'hC);

        // ------------------------------------------------------------------
        $display("[13] Max 5 digits");
        tap(4'h1); tap(4'h2); tap(4'h3); tap(4'h4); tap(4'h5); tap(4'h6);
        check(entry_value == 12345 && entry_digits == 5, "6th digit ignored");
        tap(4'hD);
        check(fc_hz == 12000, "12345 clamped to 12000");

        // ------------------------------------------------------------------
        $display("[14] Freeze button (bouncy) toggles");
        for (i = 0; i < 4; i = i + 1) begin btn_freeze = ~btn_freeze; repeat (7) @(posedge clk); end
        btn_freeze = 1; repeat (8 * MS) @(posedge clk);
        btn_freeze = 0; repeat (8 * MS) @(posedge clk);
        check(freeze == 1, "freeze on after one press");
        btn_freeze = 1; repeat (8 * MS) @(posedge clk);
        btn_freeze = 0; repeat (8 * MS) @(posedge clk);
        check(freeze == 0, "freeze off after second press");

        // ------------------------------------------------------------------
        $display("[15] Columns: exactly one driven low, others high-Z");
        check(((kp_col === 4'bzzz0) || (kp_col === 4'bzz0z) ||
               (kp_col === 4'bz0zz) || (kp_col === 4'b0zzz)), "column drive pattern");

        $display("");
        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("%0d TEST(S) FAILED", errors);
        $finish;
    end

    initial begin
        #200_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
