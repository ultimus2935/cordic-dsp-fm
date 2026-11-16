`timescale 1ns / 1ps

// =============================================================================
// tb_cordic_mod.v - directed tests for cordic_mod
// =============================================================================
// Runs 9 parameter sets, NSAMP samples each, and writes every output sample to
// cordic_mod_out.txt as "<test> <n> <sample>". Checking (bit-exact model, error
// vs ideal maths, FFT / Bessel sidebands) is done by check_cordic_mod.py, whose
// TESTS table must match the run_test calls below.
//
// The tick comes every TICK_DIV clocks instead of 667 to run ~10x faster. The
// output sequence is identical: every frequency is a per-sample phase step.
//
// Frequencies sit exactly on FFT bins (no leakage), N = 4096:
//   carrier  fc_fcw = 512 << 20  -> bin 512 = fs/8  (~5997 Hz)
//   tone     fm_fcw =  43 << 20  -> bin 43          (~504 Hz)
// Like param_ctrl, dev/beta/fm are non-zero in every mode, so a mode leaking
// another mode's term is caught.
// =============================================================================

module tb_cordic_mod;

    localparam integer TICK_DIV = 64;
    localparam integer NSAMP    = 4096;
    localparam integer CHANGE_AT = 2048;     // test 8: change params mid-sample

    reg clk = 0;
    always #15.625 clk = ~clk;          // 32 MHz

    reg        rst = 1;
    reg        tick = 0;
    reg [1:0]  mode = 0;
    reg [31:0] fc_fcw = 0, fm_fcw = 0, dev_fcw = 0;
    reg [7:0]  beta_x10 = 0;
    reg [6:0]  amp_pct = 0;

    wire [11:0] sample_out;
    wire        out_valid;

    cordic_mod dut (
        .clk(clk), .rst(rst), .tick(tick),
        .mode(mode), .fc_fcw(fc_fcw), .fm_fcw(fm_fcw), .dev_fcw(dev_fcw),
        .beta_x10(beta_x10), .amp_pct(amp_pct),
        .sample_out(sample_out), .out_valid(out_valid)
    );

    // Tick generator
    integer div = 0;
    always @(posedge clk) begin
        if (div == TICK_DIV - 1) begin div <= 0; tick <= 1; end
        else begin div <= div + 1; tick <= 0; end
    end

    // Capture
    integer fd, test_id = 0, n = 0;
    always @(posedge clk) if (out_valid && !rst) begin
        $fwrite(fd, "%0d %0d %0d\n", test_id, n, sample_out);
        n = n + 1;
    end

    // Output must only change together with out_valid
    reg [11:0] last = 12'd2048;
    integer glitches = 0;
    always @(posedge clk) begin
        if (!rst && !out_valid && sample_out !== last) glitches = glitches + 1;
        if (rst)            last <= 12'd2048;
        else if (out_valid) last <= sample_out;
    end

    task set_params(input [1:0] md, input [31:0] fc, input [31:0] fm,
                    input [31:0] dev, input [7:0] beta, input [6:0] amp);
        begin
            mode = md; fc_fcw = fc; fm_fcw = fm; dev_fcw = dev;
            beta_x10 = beta; amp_pct = amp;
        end
    endtask

    // One test: reset (phases -> 0), set parameters, collect NSAMP samples
    task run_test(input integer id, input [1:0] md, input [31:0] fc, input [31:0] fm,
                  input [31:0] dev, input [7:0] beta, input [6:0] amp);
        begin
            rst = 1;
            set_params(md, fc, fm, dev, beta, amp);
            repeat (4) @(posedge clk);
            test_id = id; n = 0;
            @(negedge clk) rst = 0;
            if (id == 8) begin
                // Change everything 5 clocks after the tick of sample CHANGE_AT,
                // while that sample is being computed: it must still use the old
                // (shadowed) values; the new ones apply from the next sample.
                wait (n == CHANGE_AT);
                @(posedge tick);
                repeat (5) @(negedge clk);
                set_params(2'b01, 32'd300<<20, 32'd20<<20, 32'd0, 8'd10, 7'd80);
            end
            wait (n == NSAMP);
            @(posedge clk);
        end
    endtask

    localparam [31:0] FC = 32'd512 << 20, FMT = 32'd43 << 20, DEV24 = 32'd108213043;

    initial begin
        fd = $fopen("cordic_mod_out.txt", "w");
        //        id mode   fc_fcw        fm_fcw dev_fcw        beta    amp
        run_test(0, 2'b11, 32'd89523224, FMT,   DEV24,         8'd24,  7'd100); // bypass ~1 kHz
        run_test(1, 2'b01, FC,           FMT,   DEV24,         8'd24,  7'd100); // PM, beta 2.4
        run_test(2, 2'b00, FC,           FMT,   DEV24,         8'd24,  7'd100); // FM, dev = 2.4*fm
        run_test(3, 2'b10, FC,           FMT,   DEV24,         8'd5,   7'd60);  // AM, mu 0.5, amp 60
        run_test(4, 2'b10, FC,           FMT,   DEV24,         8'd20,  7'd100); // AM, beta 2.0 -> mu 1
        run_test(5, 2'b00, FC,           FMT,   32'h7FFF_FFFF, 8'd24,  7'd100); // FM, limiter active
        run_test(6, 2'b01, FC,           FMT,   DEV24,         8'd200, 7'd50);  // PM, beta 20, amp 50
        run_test(7, 2'b00, FC,           FMT,   DEV24,         8'd24,  7'd0);   // amp 0 -> silence
        run_test(8, 2'b00, FC,           FMT,   DEV24,         8'd24,  7'd100); // mid-sample change
        $fclose(fd);
        $display("TB done, output changes without out_valid: %0d", glitches);
        $finish;
    end

endmodule
