`timescale 1ns / 1ps

// =============================================================================
// pmod_kypd.v - Digilent PMOD KYPD (4x4 matrix keypad) scanner
// =============================================================================
// Scans the keypad one column at a time, debounces the whole 16-key frame and
// emits a single 1-cycle `key_valid` pulse per key press.
//
// Physical layout (Digilent PMOD KYPD)      Port mapping (see zedboard.xdc)
//
//         COL1 COL2 COL3 COL4                kp_col[0] = COL1 ... kp_col[3] = COL4
//   ROW1 [ 1 ][ 2 ][ 3 ][ A ]                kp_row[0] = ROW1 ... kp_row[3] = ROW4
//   ROW2 [ 4 ][ 5 ][ 6 ][ B ]
//   ROW3 [ 7 ][ 8 ][ 9 ][ C ]
//   ROW4 [ 0 ][ F ][ E ][ D ]
//
// `key_code` is the hex value printed on the key (key "7" -> 4'h7, "C" -> 4'hC),
// so what each key DOES is decided entirely in param_ctrl.v.
//
// Scanning: the active column is driven LOW, the other three are left high-Z
// (so pressing two keys in one row can never short a driven-high pin to a
// driven-low pin). Rows have pull-ups (XDC), so a LOW row = key pressed.
// Each column is held for COL_TICKS clocks and rows are sampled at the END of
// the window, giving the lines plenty of time to settle.
//
// Debounce: a full 4-column frame must read identically DEBOUNCE_SCANS times
// in a row before it is accepted (defaults: 1 ms/column -> 4 ms/frame,
// 4 frames -> ~16 ms).
//
// Multi-key: the keypad has no diodes, so 3+ keys can "ghost" a 4th. Any frame
// with more than one key down is treated as "no valid key". A new press is only
// reported after all keys have been released (no roll-over).
// =============================================================================

module pmod_kypd #(
    parameter integer COL_TICKS      = 32000,  // clocks per column (1 ms @ 32 MHz)
    parameter integer DEBOUNCE_SCANS = 4       // identical frames needed
)(
    input  wire       clk,          // 32 MHz system clock
    input  wire       rst,          // active-high synchronous reset

    output wire [3:0] kp_col,       // to PMOD KYPD columns (active LOW / high-Z)
    input  wire [3:0] kp_row,       // from PMOD KYPD rows  (active LOW, pulled up)

    output reg        key_valid,    // 1-cycle pulse on a new key press
    output reg  [3:0] key_code,     // label of the key (valid with key_valid, held while key_held)
    output reg        key_held      // HIGH while exactly one key is held down (debounced)
);

    // -------------------------------------------------------------------------
    // Key label lookup: frame bit index = row*4 + col
    // -------------------------------------------------------------------------
    function [3:0] key_label;
        input [3:0] idx;
        begin
            case (idx)
                4'd0:  key_label = 4'h1;  4'd1:  key_label = 4'h2;
                4'd2:  key_label = 4'h3;  4'd3:  key_label = 4'hA;
                4'd4:  key_label = 4'h4;  4'd5:  key_label = 4'h5;
                4'd6:  key_label = 4'h6;  4'd7:  key_label = 4'hB;
                4'd8:  key_label = 4'h7;  4'd9:  key_label = 4'h8;
                4'd10: key_label = 4'h9;  4'd11: key_label = 4'hC;
                4'd12: key_label = 4'h0;  4'd13: key_label = 4'hF;
                4'd14: key_label = 4'hE;  default: key_label = 4'hD;
            endcase
        end
    endfunction

    // -------------------------------------------------------------------------
    // Column drive (one column LOW, others high-Z)
    // -------------------------------------------------------------------------
    reg [1:0] col_sel = 2'd0;

    assign kp_col[0] = (col_sel == 2'd0) ? 1'b0 : 1'bz;
    assign kp_col[1] = (col_sel == 2'd1) ? 1'b0 : 1'bz;
    assign kp_col[2] = (col_sel == 2'd2) ? 1'b0 : 1'bz;
    assign kp_col[3] = (col_sel == 2'd3) ? 1'b0 : 1'bz;

    // -------------------------------------------------------------------------
    // 2-FF synchroniser for the asynchronous row inputs
    // -------------------------------------------------------------------------
    (* ASYNC_REG = "TRUE" *) reg [3:0] row_meta = 4'hF;
    (* ASYNC_REG = "TRUE" *) reg [3:0] row_sync = 4'hF;

    always @(posedge clk) begin
        row_meta <= kp_row;
        row_sync <= row_meta;
    end

    // -------------------------------------------------------------------------
    // Scan: sample rows at the end of each column window, build a 16-bit frame
    // -------------------------------------------------------------------------
    localparam integer CW = (COL_TICKS > 1) ? $clog2(COL_TICKS) : 1;

    reg [CW-1:0] col_timer  = 0;
    reg [15:0]   frame_acc  = 16'd0;   // frame being built (1 = pressed)
    reg [15:0]   frame      = 16'd0;   // last complete frame
    reg          frame_done = 1'b0;    // 1-cycle pulse when `frame` updates

    // Rows seen while column `col_sel` is driven, placed at bits row*4+col
    wire [3:0]  pressed_rows = ~row_sync;
    wire [15:0] col_bits = {3'b000, pressed_rows[3], 3'b000, pressed_rows[2],
                            3'b000, pressed_rows[1], 3'b000, pressed_rows[0]} << col_sel;
    // (bit layout: row0 -> bit col, row1 -> bit 4+col, row2 -> 8+col, row3 -> 12+col)

    always @(posedge clk) begin
        if (rst) begin
            col_sel    <= 2'd0;
            col_timer  <= 0;
            frame_acc  <= 16'd0;
            frame      <= 16'd0;
            frame_done <= 1'b0;
        end else begin
            frame_done <= 1'b0;
            if (col_timer == COL_TICKS - 1) begin
                col_timer <= 0;
                col_sel   <= col_sel + 1'b1;
                if (col_sel == 2'd3) begin
                    frame      <= frame_acc | col_bits;
                    frame_acc  <= 16'd0;
                    frame_done <= 1'b1;
                end else begin
                    frame_acc  <= frame_acc | col_bits;
                end
            end else begin
                col_timer <= col_timer + 1'b1;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Frame debounce
    // -------------------------------------------------------------------------
    localparam integer DW = (DEBOUNCE_SCANS > 1) ? $clog2(DEBOUNCE_SCANS + 1) : 1;

    reg [15:0]   frame_prev   = 16'd0;
    reg [DW-1:0] stable_cnt   = 0;
    reg [15:0]   stable       = 16'd0;  // debounced key state
    reg          stable_upd   = 1'b0;

    always @(posedge clk) begin
        if (rst) begin
            frame_prev <= 16'd0;
            stable_cnt <= 0;
            stable     <= 16'd0;
            stable_upd <= 1'b0;
        end else begin
            stable_upd <= 1'b0;
            if (frame_done) begin
                frame_prev <= frame;
                if (frame != frame_prev) begin
                    stable_cnt <= 0;
                end else if (stable_cnt < DEBOUNCE_SCANS - 1) begin
                    stable_cnt <= stable_cnt + 1'b1;
                end else begin
                    stable     <= frame;
                    stable_upd <= 1'b1;
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Decode: exactly-one-key detection and press-edge generation
    // -------------------------------------------------------------------------
    function [4:0] count_down;              // number of keys down
        input [15:0] f;
        integer k;
        begin
            count_down = 5'd0;
            for (k = 0; k < 16; k = k + 1)
                count_down = count_down + f[k];
        end
    endfunction

    function [3:0] first_down;              // index of (the) key down
        input [15:0] f;
        integer k;
        begin
            first_down = 4'd0;
            for (k = 15; k >= 0; k = k - 1)
                if (f[k]) first_down = k[3:0];
        end
    endfunction

    wire [4:0] n_down   = count_down(stable);
    wire [3:0] down_idx = first_down(stable);

    reg was_released = 1'b1;   // all keys were up at the last stable update

    always @(posedge clk) begin
        if (rst) begin
            key_valid    <= 1'b0;
            key_code     <= 4'd0;
            key_held     <= 1'b0;
            was_released <= 1'b1;
        end else begin
            key_valid <= 1'b0;
            if (stable_upd) begin
                if (n_down == 5'd1) begin
                    if (was_released) begin
                        // clean new press
                        key_valid <= 1'b1;
                        key_held  <= 1'b1;
                        key_code  <= key_label(down_idx);
                    end else if (!(key_held && key_code == key_label(down_idx))) begin
                        // left over from a multi-key press: not a valid hold
                        key_held  <= 1'b0;
                    end
                    was_released <= 1'b0;
                end else begin
                    // none down -> armed for the next press;
                    // several down -> invalid, and stays disarmed until all are released
                    key_held     <= 1'b0;
                    was_released <= (n_down == 5'd0);
                end
            end
        end
    end

endmodule
