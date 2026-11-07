`timescale 1ns / 1ps

module tb_vu_meter();
    // Inputs
    reg clk;
    reg rst;
    reg sample_tick;
    reg [11:0] audio_data;

    // Outputs
    wire [7:0] vu_level;

    // Instantiate the Unit Under Test (UUT)
    vu_meter uut (
        .clk(clk),
        .rst(rst),
        .sample_tick(sample_tick),
        .audio_data(audio_data),
        .vu_level(vu_level)
    );

    // ==========================================
    // 1. Clock Generation (32 MHz)
    // ==========================================
    // 1 / 32MHz = 31.25 ns period (15.625 ns half-period)
    initial begin
        clk = 0;
        forever #15.625 clk = ~clk;
    end

    // ==========================================
    // 2. Sample Tick Generation (48 kHz)
    // ==========================================
    // 32,000,000 / 48,000 = ~666 clock cycles per tick
    integer tick_counter = 0;
    always @(posedge clk) begin
        if (tick_counter >= 665) begin
            tick_counter <= 0;
            sample_tick <= 1;
        end else begin
            tick_counter <= tick_counter + 1;
            sample_tick <= 0;
        end
    end

    // Helper Task: Wait for N sample ticks
    task wait_ticks(input integer n);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) begin
                @(posedge sample_tick);
            end
        end
    endtask

    // ==========================================
    // 3. Stimulus Sequence
    // ==========================================
    initial begin
        // Set up waveform dumping for Vivado / GTKWave
        $dumpfile("tb_vu_meter.vcd");
        $dumpvars(0, tb_vu_meter);

        // Reset
        rst = 1;
        audio_data = 12'd2048;
        #100;
        rst = 0;

        // Initialize inputs to quiet room baseline (DC Offset = 2048)
        audio_data = 12'd2048;
        
        // Wait for system to stabilize
        wait_ticks(5);
        $display("Time: %0t | Status: Quiet room | VU Level: %b", $time, vu_level);

        // -----------------------------------------------------------
        // Test 1: Positive Loud Peak (Above 2048)
        // -----------------------------------------------------------
        // Set audio to 2048 + 40 = 2088 (AC amplitude = 40)
        // This should light up vu_level[0] (>16) and vu_level[1] (>32)
        @(negedge clk);
        audio_data = 12'd2088; 
        wait_ticks(1); 
        $display("Time: %0t | Status: Positive Peak applied | VU Level: %b", $time, vu_level);

        // Return to silence and observe decay
        @(negedge clk);
        audio_data = 12'd2048;
        
        // At AC=40, it takes 8 decrements to fall below 32 (vu_level[1] turns off)
        // 8 decrements * 15 ticks/decrement = 120 ticks
        wait_ticks(130);
        $display("Time: %0t | Status: After 130 ticks decay | VU Level: %b", $time, vu_level);

        // -----------------------------------------------------------
        // Test 2: Negative Loud Peak (Below 2048)
        // -----------------------------------------------------------
        // Set audio to 2048 - 70 = 1978 (AC amplitude = 70)
        // This should light up vu_level[0], [1], and [2] (>64)
        @(negedge clk);
        audio_data = 12'd1978;
        wait_ticks(1); 
        $display("Time: %0t | Status: Negative Peak applied | VU Level: %b", $time, vu_level);

        // Return to silence and observe decay
        @(negedge clk);
        audio_data = 12'd2048;
        
        // At AC=70, it takes 7 decrements to fall below 64 (vu_level[2] turns off)
        // 7 decrements * 15 ticks/decrement = 105 ticks
        wait_ticks(115);
        $display("Time: %0t | Status: After 115 ticks decay | VU Level: %b", $time, vu_level);

        // End Simulation
        #10000;
        $display("Simulation Complete.");
        $finish;
    end

endmodule
