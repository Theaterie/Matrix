//==============================================================================
// Testbench: tb_pe_dual_int8
// Purpose:    Verify dual-issue INT8 PE — two independent INT8 dot-products
//             in one 16-bit datapath (packed format)
//==============================================================================
// Test items:
//   TC01 — Weight load (packed: {w_hi, w_lo})
//   TC02 — Lower INT8 MAC: psum_out_lo = psum_in_lo + act_lo * w_lo
//   TC03 — Upper INT8 MAC: psum_out_hi = psum_in_hi + act_hi * w_hi
//   TC04 — Dual simultaneous MAC (both halves active)
//   TC05 — Activation pass-through (2-cycle delay, 16-bit packed)
//   TC06 — Clear accumulator on both streams
//   TC07 — Enable stall (pipeline freeze)
//   TC08 — Signed negative values on both halves
//   TC09 — psum_valid timing alignment
//==============================================================================

`timescale 1ns / 1ps

module tb_pe_dual_int8;

    localparam ACCUM_WIDTH_LO = 24;
    localparam ACCUM_WIDTH_HI = 24;
    localparam CLK_PERIOD     = 10;

    reg               clk;
    reg               rst_n;
    reg  signed [15:0] act_in;
    reg               valid_in;
    reg  signed [ACCUM_WIDTH_LO-1:0] psum_in_lo;
    reg  signed [ACCUM_WIDTH_HI-1:0] psum_in_hi;
    reg               weight_load;
    reg               clear;
    reg               enable;

    wire signed [15:0] act_out;
    wire              valid_out;
    wire signed [ACCUM_WIDTH_LO-1:0] psum_out_lo;
    wire signed [ACCUM_WIDTH_HI-1:0] psum_out_hi;
    wire              psum_valid;

    integer test_count, pass_count, fail_count;

    //--------------------------------------------------------------------------
    // DUT instantiation
    //--------------------------------------------------------------------------
    pe_dual_int8 #(
        .ACCUM_WIDTH_LO (ACCUM_WIDTH_LO),
        .ACCUM_WIDTH_HI (ACCUM_WIDTH_HI)
    ) u_dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .act_in      (act_in),
        .valid_in    (valid_in),
        .act_out     (act_out),
        .valid_out   (valid_out),
        .psum_in_lo  (psum_in_lo),
        .psum_in_hi  (psum_in_hi),
        .psum_out_lo (psum_out_lo),
        .psum_out_hi (psum_out_hi),
        .psum_valid  (psum_valid),
        .weight_load (weight_load),
        .clear       (clear),
        .enable      (enable)
    );

    //--------------------------------------------------------------------------
    // Clock
    //--------------------------------------------------------------------------
    always #(CLK_PERIOD/2) clk = ~clk;

    //--------------------------------------------------------------------------
    // Helper: pack two INT8 into 16-bit
    //--------------------------------------------------------------------------
    function automatic [15:0] pack_int8;
        input [7:0] hi;
        input [7:0] lo;
        begin
            pack_int8 = {hi, lo};
        end
    endfunction

    //--------------------------------------------------------------------------
    // Check task
    //--------------------------------------------------------------------------
    task automatic check_eq;
        input [255:0] test_name;
        input integer actual;
        input integer expected;
        input [255:0] sig_name;
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
    // Task: Drive PE inputs (NBA after posedge)
    //--------------------------------------------------------------------------
    task automatic drive_pe;
        input [15:0] act_val;
        input        valid_val;
        input [ACCUM_WIDTH_LO-1:0] psum_lo;
        input [ACCUM_WIDTH_HI-1:0] psum_hi;
        input        wt_load;
        input        clr;
        begin
            @(posedge clk);
            act_in       <= act_val;
            valid_in     <= valid_val;
            psum_in_lo   <= psum_lo;
            psum_in_hi   <= psum_hi;
            weight_load  <= wt_load;
            clear        <= clr;
        end
    endtask

    //--------------------------------------------------------------------------
    // Main test sequence
    //--------------------------------------------------------------------------
    initial begin
        clk         = 0;
        rst_n       = 0;
        act_in      = 0;
        valid_in    = 0;
        psum_in_lo  = 0;
        psum_in_hi  = 0;
        weight_load = 0;
        clear       = 0;
        enable      = 0;
        test_count  = 0;
        pass_count  = 0;
        fail_count  = 0;

        repeat(8) @(posedge clk);
        rst_n  = 1;
        enable = 1;
        repeat(2) @(posedge clk);

        //======================================================================
        // TC01: Weight load — packed {w_hi, w_lo} = {0xFE(-2), 0x05(5)}
        //======================================================================
        $display("============================================================");
        $display("TC01: Weight load — packed w_hi=-2, w_lo=5");
        $display("============================================================");

        @(posedge clk);
        act_in      <= pack_int8(8'sd(-2), 8'sd5);
        valid_in    <= 1'b0;  // not a MAC op
        weight_load <= 1'b1;

        @(posedge clk);
        weight_load <= 1'b0;

        //======================================================================
        // TC02: Lower INT8 MAC — act_lo=3, w_lo=5 → 15
        //======================================================================
        $display("============================================================");
        $display("TC02: Lower INT8 MAC — act_lo=3 * w_lo=5 = 15");
        $display("============================================================");

        drive_pe(pack_int8(8'sd0, 8'sd3), 1'b1, 0, 0, 1'b0, 1'b1);
        @(posedge clk);
        valid_in <= 1'b0;
        clear    <= 1'b0;
        @(posedge clk);
        @(posedge clk);
        check_eq("TC02a: psum_out_lo=15", psum_out_lo, 15, "psum_out_lo");
        check_eq("TC02b: psum_out_hi=0 (act_hi=0)", psum_out_hi, 0, "psum_out_hi");

        //======================================================================
        // TC03: Upper INT8 MAC — act_hi=4, w_hi=-2 → -8
        //======================================================================
        $display("============================================================");
        $display("TC03: Upper INT8 MAC — act_hi=4 * w_hi=-2 = -8");
        $display("============================================================");

        drive_pe(pack_int8(8'sd4, 8'sd0), 1'b1, 0, 0, 1'b0, 1'b1);
        @(posedge clk);
        valid_in <= 1'b0;
        @(posedge clk);
        @(posedge clk);
        check_eq("TC03a: psum_out_hi=-8", psum_out_hi, -8, "psum_out_hi");
        check_eq("TC03b: psum_out_lo=0 (act_lo=0)", psum_out_lo, 0, "psum_out_lo");

        //======================================================================
        // TC04: Dual simultaneous MAC
        //   act_lo=3, w_lo=5 → 15; act_hi=7, w_hi=-2 → -14
        //======================================================================
        $display("============================================================");
        $display("TC04: Dual simultaneous MAC — lo: 3*5=15, hi: 7*(-2)=-14");
        $display("============================================================");

        drive_pe(pack_int8(8'sd7, 8'sd3), 1'b1, 0, 0, 1'b0, 1'b1);
        @(posedge clk);
        valid_in <= 1'b0;
        @(posedge clk);
        @(posedge clk);
        check_eq("TC04a: psum_out_lo=15", psum_out_lo, 15, "psum_out_lo");
        check_eq("TC04b: psum_out_hi=-14", psum_out_hi, -14, "psum_out_hi");

        //======================================================================
        // TC05: Activation pass-through (2-cycle delay)
        //   drive act_in = {0x07, 0x03}, check act_out after 2 cycles
        //======================================================================
        $display("============================================================");
        $display("TC05: Activation pass-through — 2-cycle delay");
        $display("============================================================");

        drive_pe(pack_int8(8'sd7, 8'sd3), 1'b1, 0, 0, 1'b0, 1'b1);
        @(posedge clk);
        valid_in <= 1'b0;
        @(posedge clk);  // act_d1 = act_in
        @(posedge clk);  // act_d2 = act_d1 → act_out
        check_eq("TC05: act_out = 0x0703 after 2 cycles", act_out, 16'h0703, "act_out");
        check_eq("TC05v: valid_out=1", valid_out, 1, "valid_out");

        //======================================================================
        // TC06: Clear accumulator — seed new dot-product
        //   weight loaded: w_lo=5, w_hi=-2. clear=1 resets accumulator
        //======================================================================
        $display("============================================================");
        $display("TC06: Clear accumulator — new dot-product");
        $display("============================================================");

        // First: accumulate something
        drive_pe(pack_int8(8'sd0, 8'sd4), 1'b1, 20, 10, 1'b0, 1'b0);
        @(posedge clk);
        valid_in <= 1'b0;
        @(posedge clk);
        @(posedge clk);
        // lo: 20 + 4*5 = 40; hi: 10 + 0*(-2) = 10
        check_eq("TC06a: psum_out_lo=40 (accumulated)", psum_out_lo, 40, "psum_out_lo");

        // Now: fresh start with clear=1
        drive_pe(pack_int8(8'sd0, 8'sd2), 1'b1, 100, 200, 1'b0, 1'b1);
        @(posedge clk);
        valid_in <= 1'b0;
        clear    <= 1'b0;
        @(posedge clk);
        @(posedge clk);
        // lo: 0 + 2*5 = 10 (NOT 100 + 10 = 110 because clear=1)
        check_eq("TC06b: psum_out_lo=10 (cleared, fresh start)", psum_out_lo, 10, "psum_out_lo");
        // hi: 0 + 0*(-2) = 0 (NOT 200 + 0)
        check_eq("TC06c: psum_out_hi=0 (cleared)", psum_out_hi, 0, "psum_out_hi");

        //======================================================================
        // TC07: Enable stall
        //======================================================================
        $display("============================================================");
        $display("TC07: Enable stall — pipeline freeze");
        $display("============================================================");

        // Produce known result: 3*5=15 (lo) with clear
        drive_pe(pack_int8(8'sd0, 8'sd3), 1'b1, 0, 0, 1'b0, 1'b1);
        @(posedge clk);
        valid_in <= 1'b0;
        clear    <= 1'b0;

        // Stall before result emerges
        @(posedge clk);
        enable <= 1'b0;

        repeat(3) @(posedge clk);
        check_eq("TC07: psum_out_lo holds (stalled)", psum_out_lo, 15, "psum_out_lo");

        // Re-enable
        enable <= 1'b1;
        repeat(3) @(posedge clk);

        //======================================================================
        // TC08: Signed negative — both halves
        //   w_lo=5, w_hi=-2; act_lo=-6, act_hi=8
        //   lo: -6*5 = -30; hi: 8*(-2) = -16
        //======================================================================
        $display("============================================================");
        $display("TC08: Signed negative — lo: (-6)*5=-30, hi: 8*(-2)=-16");
        $display("============================================================");

        drive_pe(pack_int8(8'sd8, -8'sd6), 1'b1, 0, 0, 1'b0, 1'b1);
        @(posedge clk);
        valid_in <= 1'b0;
        @(posedge clk);
        @(posedge clk);
        check_eq("TC08a: psum_out_lo=-30", psum_out_lo, -30, "psum_out_lo");
        check_eq("TC08b: psum_out_hi=-16", psum_out_hi, -16, "psum_out_hi");

        //======================================================================
        // TC09: psum_valid timing
        //======================================================================
        $display("============================================================");
        $display("TC09: psum_valid timing — aligned with psum outputs");
        $display("============================================================");

        drive_pe(pack_int8(8'sd1, 8'sd1), 1'b1, 0, 0, 1'b0, 1'b1);
        @(posedge clk);
        valid_in <= 1'b0;
        @(posedge clk);
        // psum_valid still not valid yet (in pipeline)
        @(posedge clk);
        check_eq("TC09: psum_valid=1 when psum_out ready", psum_valid, 1, "psum_valid");

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
        $dumpfile("tb_pe_dual_int8.vcd");
        $dumpvars(0, tb_pe_dual_int8);
    end
`endif

endmodule
