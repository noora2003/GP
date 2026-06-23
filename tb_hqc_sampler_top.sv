`timescale 1ns/1ps
`default_nettype none

module tb_hqc_sampler_top;

    localparam string PS     = "hqc128";
    localparam int    N      = 17_669;
    localparam int    M      = 15;
    localparam int    WEIGHT = 75;

    logic         clk           = 0;
    logic         rst_n         = 0;
    logic         start         = 0;
    logic         ready;
    logic         done;
    logic         shake_wr_en   = 0;
    logic [31:0]  shake_wr_data = 0;
    logic         shake_full;
    logic [M-1:0] P [0:WEIGHT-1];

    hqc_sampler_top #(.parameter_set(PS)) dut (.*);

    always #5 clk = ~clk;

    logic [31:0] lfsr = 32'hDEAD_BEEF;
    task automatic lfsr_next();
        lfsr = {1'b0, lfsr[31:1]} ^
               (lfsr[0] ? 32'hB400_0000 : 32'h0);
    endtask

    int pass_cnt = 0;
    int fail_cnt = 0;

    task automatic chk(input logic cond, input string msg);
        if (cond) begin $display("  PASS: %s", msg); pass_cnt++; end
        else      begin $display("  FAIL: %s", msg); fail_cnt++; end
    endtask

    initial begin
        $display("\n=== HQC Sampler Testbench [%s] ===\n", PS);

        // Reset
        rst_n = 0;
        repeat (8) @(posedge clk);
        @(negedge clk); rst_n = 1;
        repeat (2) @(posedge clk);
        chk(ready, "DUT ready after reset");

        // Pre-fill FIFO and save seeds to file
        begin
            integer seed_file;
            seed_file = $fopen("rtl_seeds.txt", "w");

            $display("\n-- Pre-filling FIFO --");
            for (int k = 0; k < (WEIGHT * 2) + 10; k++) begin
                @(negedge clk);
                while (shake_full) @(negedge clk);
                shake_wr_en   = 1;
                shake_wr_data = lfsr;
                $fdisplay(seed_file, "%0d", lfsr); // save seed
                lfsr_next();
            end
            @(negedge clk);
            shake_wr_en = 0;
            $fclose(seed_file);
            $display("  FIFO pre-filled, seeds saved to rtl_seeds.txt");
        end

        // Pulse start
        @(negedge clk); start = 1;
        @(negedge clk); start = 0;
        $display("  Start pulsed");

        // Keep feeding FIFO while sampler runs + wait done
        fork
            begin : feed
                forever begin
                    @(negedge clk);
                    if (done) disable feed;
                    if (!shake_full) begin
                        shake_wr_en   = 1;
                        shake_wr_data = lfsr;
                        lfsr_next();
                    end else
                        shake_wr_en = 0;
                end
            end
            begin : wait_done
                int cnt = 0;
                while (!done) begin
                    @(posedge clk); cnt++;
                    if (cnt >= N*5) begin
                        $display("TIMEOUT"); $finish;
                    end
                end
                shake_wr_en = 0;
                $display("  Done after %0d cycles", cnt);
                disable feed;
            end
        join

        @(posedge clk); #1;

        // Print P[]
        $display("\n-- P[] output --");
        for (int k = 0; k < WEIGHT; k++)
            $display("  P[%0d] = %0d", k, P[k]);

        // Check range
        begin
            int bad = 0;
            for (int k = 0; k < WEIGHT; k++)
                if (P[k] >= M'(N)) bad++;
            chk(bad == 0, "all indices in range [0,N)");
        end

        // Check unique
        begin
            int dups = 0;
            for (int a = 0; a < WEIGHT; a++)
                for (int b = a+1; b < WEIGHT; b++)
                    if (P[a] == P[b]) dups++;
            chk(dups == 0, "no duplicates");
        end

        // Write P[] to file
        begin
            integer f;
            f = $fopen("rtl_output.txt", "w");
            for (int k = 0; k < WEIGHT; k++)
                $fdisplay(f, "%0d", P[k]);
            $fclose(f);
            $display("\n  P[] written to rtl_output.txt");
            $display("  Seeds written to rtl_seeds.txt");
        end

        $display("\n%0d passed  %0d failed", pass_cnt, fail_cnt);
        if (fail_cnt == 0) $display("RTL OUTPUT VALID");
        else               $display("FAILED");

        $finish;
    end

    initial begin
        #(N * 5 * 10 + 200_000);
        $display("GLOBAL TIMEOUT"); $finish;
    end

endmodule

`default_nettype wire