//==============================================================================
// Testbench: tb_address_generator
// Purpose:    Verify sequential address generation for activation and result
//             buffers during COMPUTE and SERIALIZE phases
//==============================================================================
// Test items:
//   TC01 鈥?Activation read addresses during COMPUTE (sequential, base+offset)
//   TC02 鈥?act_done pulse after TILE_K addresses
//   TC03 鈥?Enable gating during COMPUTE (enable=0 holds address)
//   TC04 鈥?Base address offset for activations
//   TC05 鈥?Result write addresses during SERIALIZE
//   TC06 鈥?res_done pulse after ROWS*COLS writes
//   TC07 鈥?READOUT resets result counter
//   TC08 鈥?Non-active phases produce no outputs
//   TC09 鈥?Async reset during operation
//==============================================================================

`timescale 1ns / 1ps

module tb_address_generator;

    localparam DATA_WIDTH  = 16;
    localparam ACCUM_WIDTH = 40;
    localparam ADDR_WIDTH  = 8;
    localparam ROWS        = 4;
    localparam COLS        = 4;
    localparam TILE_K      = 4;
    localparam TILE_M      = 4;
    localparam CLK_PERIOD  = 10;

    localparam RESULT_TOTAL = ROWS * COLS;  // 16

    reg               clk;
    reg               rst_n;
    reg  [2:0]        phase;
    reg               enable;
    reg  [ADDR_WIDTH-1:0] act_base_addr;
    reg  [ADDR_WIDTH-1:0] res_base_addr;

    wire [ADDR_WIDTH-1:0] act_rd_addr;
    wire              act_rd_en;
    wire [ADDR_WIDTH-1:0] res_wr_addr;
    wire              res_wr_en;
    wire              act_done;
    wire              res_done;

    integer test_count, pass_count, fail_count;

    //--------------------------------------------------------------------------
    // DUT instantiation
    //--------------------------------------------------------------------------
    address_generator #(
        .DATA_WIDTH  (DATA_WIDTH),
        .ACCUM_WIDTH (ACCUM_WIDTH),
        .ADDR_WIDTH  (ADDR_WIDTH),
        .ROWS        (ROWS),
        .COLS        (COLS),
        .TILE_K      (TILE_K),
        .TILE_M      (TILE_M)
    ) u_dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .phase         (phase),
        .enable        (enable),
        .act_base_addr (act_base_addr),
        .res_base_addr (res_base_addr),
        .act_rd_addr   (act_rd_addr),
        .act_rd_en     (act_rd_en),
        .res_wr_addr   (res_wr_addr),
        .res_wr_en     (res_wr_en),
        .act_done      (act_done),
        .res_done      (res_done)
    );

    //--------------------------------------------------------------------------
    // Clock
    //--------------------------------------------------------------------------
    always #(CLK_PERIOD/2) clk = ~clk;

    //--------------------------------------------------------------------------
    // Check task
    //--------------------------------------------------------------------------
    task automatic check_eq;
        input string test_name;
        input integer          actual;
        input integer          expected;
        input string sig_name;
        begin
            if (actual === expected) begin
                $display("[PASS] %0s: %0s = %0d (expected %0d)", test_name, sig_name, actual, expected);
                pass_count = pass_count + 1;
            end else begin
                $display("[FAIL] %0s: %0s = %0d (expected %0d)", test_name, sig_name, actual, expected);
                fail_count = fail_count + 1;
            end
            test_count = test_count + 1;
        end
    endtask

    //--------------------------------------------------------------------------
    // Main test sequence
    //--------------------------------------------------------------------------
    initial begin
        clk          = 0;
        rst_n        = 0;
        phase        = 3'd0;
        enable       = 0;
        act_base_addr = 8'd0;
        res_base_addr = 8'd0;
        test_count   = 0;
        pass_count   = 0;
        fail_count   = 0;

        repeat(8) @(posedge clk);
        rst_n  = 1;
        enable = 1;
        repeat(2) @(posedge clk);

        //======================================================================
        // TC01: Activation read addresses during COMPUTE (phase=2)
        //======================================================================
        $display("============================================================");
        $display("TC01: Act read addresses during COMPUTE (phase=2, base=0)");
        $display("============================================================");

        @(posedge clk);
        phase <= 3'd2;  // COMPUTE

        begin : tc01_block
            integer k;
            for (k = 0; k < TILE_K; k = k + 1) begin
                @(posedge clk);
                check_eq($sformatf("TC01[%0d]: act_rd_en", k), act_rd_en, 1, "act_rd_en");
                check_eq($sformatf("TC01[%0d]: act_rd_addr", k), act_rd_addr, k, "act_rd_addr");
            end
        end

        //======================================================================
        // TC02: act_done pulse after TILE_K cycles
        //======================================================================
        $display("============================================================");
        $display("TC02: act_done pulse after TILE_K=%0d addresses", TILE_K);
        $display("============================================================");

        @(posedge clk);
        check_eq("TC02a: act_done", act_done, 1, "act_done");
        check_eq("TC02b: counter reset", act_rd_addr, 0, "act_rd_addr (reset)");

        //======================================================================
        // TC03: Enable gating during COMPUTE
        //======================================================================
        $display("============================================================");
        $display("TC03: Enable gating 鈥?enable=0 stalls activation address");
        $display("============================================================");

        // Let it run for 2 cycles, then stall
        begin : tc03_block
            reg [ADDR_WIDTH-1:0] held_addr;
            // Wait for next COMPUTE phase cycle
            @(posedge clk);
            @(posedge clk);

            // Stall
            @(posedge clk);
            enable <= 1'b0;

            @(posedge clk);
            held_addr = act_rd_addr;
            check_eq("TC03a: act_rd_en=0 during stall", act_rd_en, 0, "act_rd_en");

            @(posedge clk);
            check_eq("TC03b: act_rd_addr holds during stall",
                act_rd_addr, held_addr, "act_rd_addr");

            // Un-stall
            enable <= 1'b1;
            @(posedge clk);
            check_eq("TC03c: act_rd_en=1 after un-stall", act_rd_en, 1, "act_rd_en");
        end

        // Reset: go back to IDLE
        phase <= 3'd0;
        @(posedge clk);
        @(posedge clk);

        //======================================================================
        // TC04: Base address offset
        //======================================================================
        $display("============================================================");
        $display("TC04: Base address offset 鈥?act_base_addr=10");
        $display("============================================================");

        act_base_addr <= 8'd10;
        @(posedge clk);
        phase <= 3'd2;  // COMPUTE

        @(posedge clk);
        check_eq("TC04a: act_rd_addr = base+0 = 10", act_rd_addr, 10, "act_rd_addr");

        @(posedge clk);
        check_eq("TC04b: act_rd_addr = base+1 = 11", act_rd_addr, 11, "act_rd_addr");

        @(posedge clk);
        check_eq("TC04c: act_rd_addr = base+2 = 12", act_rd_addr, 12, "act_rd_addr");

        @(posedge clk);
        check_eq("TC04d: act_rd_addr = base+3 = 13", act_rd_addr, 13, "act_rd_addr");

        // Reset
        phase <= 3'd0;
        act_base_addr <= 8'd0;
        @(posedge clk);
        @(posedge clk);

        //======================================================================
        // TC05: Result write addresses during SERIALIZE (phase=4)
        //======================================================================
        $display("============================================================");
        $display("TC05: Result write addresses during SERIALIZE (phase=4, base=20)");
        $display("============================================================");

        res_base_addr <= 8'd20;
        @(posedge clk);
        phase <= 3'd4;  // SERIALIZE

        begin : tc05_block
            integer i;
            for (i = 0; i < RESULT_TOTAL; i = i + 1) begin
                @(posedge clk);
                check_eq($sformatf("TC05[%0d]: res_wr_en", i), res_wr_en, 1, "res_wr_en");
                check_eq($sformatf("TC05[%0d]: res_wr_addr", i), res_wr_addr, 20 + i, "res_wr_addr");
            end
        end

        //======================================================================
        // TC06: res_done pulse after RESULT_TOTAL writes
        //======================================================================
        $display("============================================================");
        $display("TC06: res_done pulse after %0d writes", RESULT_TOTAL);
        $display("============================================================");

        @(posedge clk);
        check_eq("TC06a: res_done", res_done, 1, "res_done");
        check_eq("TC06b: counter reset", res_wr_addr, 0, "res_wr_addr");

        //======================================================================
        // TC07: READOUT (phase=3) resets result counter
        //======================================================================
        $display("============================================================");
        $display("TC07: READOUT phase resets result counter");
        $display("============================================================");

        phase <= 3'd3;  // READOUT
        @(posedge clk);
        check_eq("TC07: res_wr_en=0 during READOUT", res_wr_en, 0, "res_wr_en");

        // Back to IDLE
        phase <= 3'd0;
        res_base_addr <= 8'd0;
        @(posedge clk);
        @(posedge clk);

        //======================================================================
        // TC08: Non-active phases produce no outputs
        //======================================================================
        $display("============================================================");
        $display("TC08: IDLE/WEIGHT_LOAD/DONE phases 鈥?no address activity");
        $display("============================================================");

        // IDLE
        phase <= 3'd0;
        @(posedge clk);
        check_eq("TC08a: IDLE act_rd_en=0", act_rd_en, 0, "act_rd_en");
        check_eq("TC08b: IDLE res_wr_en=0", res_wr_en, 0, "res_wr_en");

        // WEIGHT_LOAD
        phase <= 3'd1;
        @(posedge clk);
        check_eq("TC08c: WEIGHT_LOAD act_rd_en=0", act_rd_en, 0, "act_rd_en");
        check_eq("TC08d: WEIGHT_LOAD res_wr_en=0", res_wr_en, 0, "res_wr_en");

        // DONE
        phase <= 3'd5;
        @(posedge clk);
        check_eq("TC08e: DONE act_rd_en=0", act_rd_en, 0, "act_rd_en");
        check_eq("TC08f: DONE res_wr_en=0", res_wr_en, 0, "res_wr_en");

        //======================================================================
        // TC09: Async reset during operation
        //======================================================================
        $display("============================================================");
        $display("TC09: Async reset during operation");
        $display("============================================================");

        phase <= 3'd2;  // COMPUTE
        @(posedge clk);
        @(posedge clk);
        check_eq("TC09a: act_rd_en=1 before reset", act_rd_en, 1, "act_rd_en");

        rst_n <= 1'b0;
        @(posedge clk);
        check_eq("TC09b: act_rd_en=0 after reset", act_rd_en, 0, "act_rd_en");

        rst_n <= 1'b1;
        repeat(2) @(posedge clk);

        //======================================================================
        // Summary
        //======================================================================
        $display("============================================================");
        $display("Summary: %0d/%0d PASS, %0d FAIL", pass_count, test_count, fail_count);
        $display("============================================================");

        if (fail_count == 0)
            $display("ALL TESTS PASSED!");
        else
            $display("SOME TESTS FAILED!");

        $finish;
    end

    //--------------------------------------------------------------------------
    // Wave dump
    //--------------------------------------------------------------------------
`ifndef XILINX_SIMULATOR
    initial begin
        $dumpfile("tb_address_generator.vcd");
        $dumpvars(0, tb_address_generator);
    end
`endif

endmodule
