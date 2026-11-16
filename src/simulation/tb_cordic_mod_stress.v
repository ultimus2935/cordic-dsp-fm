`timescale 1ns / 1ps

// =============================================================================
// tb_cordic_mod_stress.v - randomised stress test for cordic_mod
// =============================================================================
// Logs every accepted tick (with the parameters the DUT shadows), every tick
// that arrives while busy, every output and every reset cycle to
// cordic_mod_stress.txt; `check_cordic_mod.py --stress` replays the log through
// the bit-exact model and requires every output to match.
//   Pass 1: parameters within param_ctrl's ranges; pass 2: full input widths.
//   Phase A: ticks every 667 clocks, parameters change on random clocks
//            (including the tick cycle itself).
//   Phase B: irregular ticks (some while busy) and resets mid-computation.
// =============================================================================
module tb_cordic_mod_stress;
    reg clk = 0; always #15.625 clk = ~clk;
    reg rst = 1, tick = 0;
    reg [1:0] mode = 0; reg [31:0] fc_fcw = 0, fm_fcw = 0, dev_fcw = 0; reg [7:0] beta_x10 = 0; reg [6:0] amp_pct = 0;
    wire [11:0] sample_out; wire out_valid;
    cordic_mod dut(.clk(clk), .rst(rst), .tick(tick), .mode(mode), .fc_fcw(fc_fcw), .fm_fcw(fm_fcw), .dev_fcw(dev_fcw),
                   .beta_x10(beta_x10), .amp_pct(amp_pct), .sample_out(sample_out), .out_valid(out_valid));
    integer fd, seed = 12345, i, k, per, phase;
    integer wide; // 0: param_ctrl ranges, 1: full input-width ranges
    // log accepted ticks / outputs / resets as seen by the DUT at the clock edge
    always @(posedge clk) begin
        if (rst) $fwrite(fd, "R\n");
        else begin
            if (out_valid) $fwrite(fd, "O %0d\n", sample_out);
            if (tick && dut.state == 0) $fwrite(fd, "T %0d %0d %0d %0d %0d %0d\n", mode, fc_fcw, fm_fcw, dev_fcw, beta_x10, amp_pct);
            if (tick && dut.state != 0) $fwrite(fd, "B\n");
        end
    end
    task rnd_params; begin
        mode = $random(seed);
        if (wide) begin
            fc_fcw = $random(seed); fm_fcw = $random(seed); dev_fcw = $random(seed);
            beta_x10 = $random(seed); amp_pct = $random(seed);
            if (($random(seed) & 7) == 0) dev_fcw = 32'hFFFF_FFFF;
            if (($random(seed) & 7) == 0) begin beta_x10 = 8'd255; amp_pct = 7'd127; end
        end else begin
            fc_fcw = 32'd8952322 + ({$random(seed)} % 32'd1065326366);      // 100..12000 Hz
            fm_fcw = 32'd89523 + ({$random(seed)} % 32'd268480149);          // 1..3000 Hz
            beta_x10 = {$random(seed)} % 201; amp_pct = {$random(seed)} % 101;
            dev_fcw = {$random(seed)} & 32'h7FFF_FFFF;
            if (($random(seed) & 3) == 0) dev_fcw = 32'h7FFF_FFFF;
            if (($random(seed) & 7) == 0) amp_pct = 100;
            if (($random(seed) & 7) == 0) beta_x10 = 200;
        end
    end endtask
    initial begin
        fd = $fopen("cordic_mod_stress.txt", "w");
        for (wide = 0; wide < 2; wide = wide + 1) begin
            rst = 1; repeat (5) @(negedge clk); rst = 0;
            // phase A: regular ticks every 667, params change at random clocks (incl. the tick cycle)
            for (i = 0; i < 6000; i = i + 1) begin
                phase = {$random(seed)} % 667;
                for (k = 0; k < 667; k = k + 1) begin
                    @(negedge clk);
                    tick = (k == 0);
                    if (k == phase && ({$random(seed)} % 4) != 0) rnd_params;
                    if (k == 0 && ({$random(seed)} % 16) == 0) rnd_params;   // change exactly on the tick cycle
                end
            end
            // phase B: irregular ticks (some while busy), resets mid-computation
            for (i = 0; i < 4000; i = i + 1) begin
                per = 1 + ({$random(seed)} % 90);
                for (k = 0; k < per; k = k + 1) begin
                    @(negedge clk); tick = (k == 0);
                    if (({$random(seed)} % 2000) == 0) begin rst = 1; @(negedge clk); tick = 0; rst = 0; end
                end
                if (({$random(seed)} % 8) == 0) rnd_params;
            end
            tick = 0; repeat (100) @(negedge clk);
        end
        $fclose(fd); $display("stress done"); $finish;
    end
endmodule
