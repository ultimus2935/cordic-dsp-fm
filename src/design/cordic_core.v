`timescale 1ns / 1ps

// =============================================================================
// cordic_core.v - iterative rotation-mode CORDIC (sine / cosine generator)
// =============================================================================
// Rotates the vector (x0, 0) by `angle` using only shifts and adds:
//
//     cos_out ~= K * x0 * cos(angle)
//     sin_out ~= K * x0 * sin(angle)          K = 1.64676 (16 iterations)
//
// So to get a wave of peak value P, drive x0 = P / K.
//
// Angle format: unsigned, full circle = 2^ZW (0 = 0 deg, 2^(ZW-2) = 90 deg ...).
// A 32-bit NCO phase is fed in as phase[31:32-ZW].
//
// Range: plain CORDIC only converges for about +-99.9 deg, so the top two angle
// bits (the quadrant) are removed first, the remaining 0..90 deg is rotated,
// and the quadrant is put back at the end with swaps / sign flips (free).
//
// Accuracy: each step truncates (>>>), so keep ~4 spare low bits below the
// precision you need (cordic_mod uses a 2^20 peak for a 12-bit output).
//
// Timing: `start` (1 cycle) -> NIT iteration cycles -> 1 quadrant-fix cycle
// -> `done` pulses with the result. NIT + 2 cycles in total (18 for NIT = 16).
// One unit is time-shared for several sines per audio sample (667 clocks).
// =============================================================================

module cordic_core #(
    parameter integer XYW = 22,     // X/Y width, signed (keep peak |K*x0| < 2^(XYW-1))
    parameter integer ZW  = 20,     // angle width (full circle = 2^ZW), fixed by the atan table
    parameter integer NIT = 16      // iterations (~1 bit of accuracy each)
)(
    input  wire                  clk,
    input  wire                  rst,          // synchronous, active high

    input  wire                  start,        // 1-cycle pulse: latch inputs and begin
    input  wire signed [XYW-1:0] x0,           // starting length = wanted peak / K
    input  wire        [ZW-1:0]  angle,        // 0 .. 2^ZW-1  =  0 .. 360 deg

    output reg                   done,         // 1-cycle pulse: outputs valid
    output reg  signed [XYW-1:0] cos_out,
    output reg  signed [XYW-1:0] sin_out
);

    // -------------------------------------------------------------------------
    // atan(2^-i) in angle units (2^20 = 360 deg): 45, 26.57, 14.04, 7.13 ... deg
    // -------------------------------------------------------------------------
    function signed [ZW-1:0] atan_tab;
        input [4:0] i;
        begin
            case (i)
                5'd0:  atan_tab = 131072;   5'd1:  atan_tab = 77376;
                5'd2:  atan_tab = 40884;    5'd3:  atan_tab = 20753;
                5'd4:  atan_tab = 10417;    5'd5:  atan_tab = 5213;
                5'd6:  atan_tab = 2607;     5'd7:  atan_tab = 1304;
                5'd8:  atan_tab = 652;      5'd9:  atan_tab = 326;
                5'd10: atan_tab = 163;      5'd11: atan_tab = 81;
                5'd12: atan_tab = 41;       5'd13: atan_tab = 20;
                5'd14: atan_tab = 10;       5'd15: atan_tab = 5;
                default: atan_tab = 0;
            endcase
        end
    endfunction

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------
    reg                  busy  = 1'b0;     // iterating
    reg                  fix   = 1'b0;     // quadrant-fix cycle
    reg  [4:0]           it    = 5'd0;     // iteration number i
    reg  [1:0]           quad  = 2'd0;     // quadrant removed from the angle
    reg  signed [XYW-1:0] x    = 0;
    reg  signed [XYW-1:0] y    = 0;
    reg  signed [ZW-1:0]  z    = 0;        // angle still left to rotate (signed)

    wire signed [XYW-1:0] x_sh = x >>> it; // x * 2^-i  (just wiring per i)
    wire signed [XYW-1:0] y_sh = y >>> it;

    initial begin
        done    = 1'b0;
        cos_out = 0;
        sin_out = 0;
    end

    always @(posedge clk) begin
        if (rst) begin
            busy    <= 1'b0;
            fix     <= 1'b0;
            done    <= 1'b0;
            it      <= 5'd0;
        end else begin
            done <= 1'b0;

            if (start) begin
                // Split the angle: top 2 bits = quadrant, rest = 0..90 deg
                quad <= angle[ZW-1:ZW-2];
                z    <= {2'b00, angle[ZW-3:0]};
                x    <= x0;
                y    <= 0;
                it   <= 5'd0;
                busy <= 1'b1;
                fix  <= 1'b0;

            end else if (busy) begin
                // One CORDIC step: rotate by +-atan(2^-i) toward the target
                if (z[ZW-1]) begin                  // overshot (z < 0): rotate back
                    x <= x + y_sh;
                    y <= y - x_sh;
                    z <= z + atan_tab(it);
                end else begin                      // not there yet: rotate forward
                    x <= x - y_sh;
                    y <= y + x_sh;
                    z <= z - atan_tab(it);
                end
                it <= it + 1'b1;
                if (it == NIT - 1) begin
                    busy <= 1'b0;
                    fix  <= 1'b1;
                end

            end else if (fix) begin
                // Put the quadrant back: rotate the result by quad * 90 deg
                case (quad)
                    2'd0: begin cos_out <=  x; sin_out <=  y; end  //   0 deg
                    2'd1: begin cos_out <= -y; sin_out <=  x; end  //  90 deg
                    2'd2: begin cos_out <= -x; sin_out <= -y; end  // 180 deg
                    2'd3: begin cos_out <=  y; sin_out <= -x; end  // 270 deg
                endcase
                fix  <= 1'b0;
                done <= 1'b1;
            end
        end
    end

endmodule
