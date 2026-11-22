`timescale 1ns / 1ps

// =============================================================================
// audio_storage_ram.v - FPGA Internal BRAM Audio Storage (Scope Task 4)
// =============================================================================
// Stores both original microphone audio and CORDIC modulated audio in FPGA
// internal Block RAM (BRAM) for comparison, playback, and analysis.
//
// Dual-port synchronous RAM:
//   - Port A (Write): Captures {orig_audio[11:0], mod_audio[11:0]} (24 bits)
//     synchronously on each `sample_tick` (48 kHz). Circular buffer of 2048
//     samples (~43 ms of audio at 48 kHz).
//   - Freeze: when `freeze` is asserted, recording halts, preserving the
//     current frame for inspection / comparison.
//   - Port B (Read): Synchronous read port allowing address-based readout
//     by external modules (e.g. VIO, VGA display, or DAC playback).
// =============================================================================

module audio_storage_ram #(
    parameter integer ADDR_WIDTH = 11,           // 2^11 = 2048 samples (~42.7 ms @ 48 kHz)
    parameter integer DATA_WIDTH = 24            // 12-bit orig + 12-bit mod
)(
    input  wire                  clk,            // 32 MHz system clock
    input  wire                  rst,            // Synchronous reset (sys_rst)

    // Write interface (Port A)
    input  wire                  sample_tick,    // 1-cycle strobe at 48 kHz (data_valid)
    input  wire                  freeze,         // 1 = freeze/hold buffer, 0 = circular record
    input  wire [11:0]           orig_sample,    // Captured mic audio
    input  wire [11:0]           mod_sample,     // Modulated CORDIC audio

    // Buffer status
    output reg  [ADDR_WIDTH-1:0] wr_addr,        // Current write pointer (head)
    output reg                   buffer_full,    // Stored at least one full buffer (2048 samples)

    // Read interface (Port B)
    input  wire [ADDR_WIDTH-1:0] rd_addr,        // Read address
    output reg  [11:0]           rd_orig_sample, // Stored original audio
    output reg  [11:0]           rd_mod_sample   // Stored modulated audio
);

    localparam integer DEPTH = (1 << ADDR_WIDTH);

    // Inferred 7-series Block RAM (dual-port)
    (* ram_style = "block", DONT_TOUCH = "TRUE" *) reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    // ---- Port A: Circular Write ----
    wire wr_en = sample_tick & ~freeze;
    wire [DATA_WIDTH-1:0] wr_data = {orig_sample, mod_sample};

    always @(posedge clk) begin
        if (rst) begin
            wr_addr     <= {ADDR_WIDTH{1'b0}};
            buffer_full <= 1'b0;
        end else if (wr_en) begin
            mem[wr_addr] <= wr_data;
            if (wr_addr == DEPTH - 1) begin
                wr_addr     <= {ADDR_WIDTH{1'b0}};
                buffer_full <= 1'b1;
            end else begin
                wr_addr <= wr_addr + 1'b1;
            end
        end
    end

    // ---- Port B: Synchronous Read ----
    reg [DATA_WIDTH-1:0] rd_data_reg = {DATA_WIDTH{1'b0}};

    always @(posedge clk) begin
        rd_data_reg <= mem[rd_addr];
    end

    always @(posedge clk) begin
        if (rst) begin
            rd_orig_sample <= 12'd2048;
            rd_mod_sample  <= 12'd2048;
        end else begin
            rd_orig_sample <= rd_data_reg[23:12];
            rd_mod_sample  <= rd_data_reg[11:0];
        end
    end

endmodule
