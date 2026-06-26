//==============================================================================
// Testbench: tb_controller
// Purpose:    Verify FSM state transitions, phase outputs, cycle counting,
//             deser_ready handshake, and done pulse timing
//==============================================================================
// Test items:
//   TC01 — IDLE defaults (all outputs at safe state)
//   TC02 — start pulse triggers IDLE → WEIGHT_LOAD
//   TC03 — WEIGHT_LOAD cycle counting and weight_wren/weight_addr
//   TC04 — WEIGHT_LOAD stalls when deser_ready=0
//   TC05 — WEIGHT_LOAD → COMPUTE transition (deser_ready=1)
//   TC06 — COMPUTE phase: pe_clear on first cycle, compute_cnt increments
//   TC07 — COMPUTE → READOUT transition
//   TC08 — READOUT phase: phase=011, pe_enable=1
//   TC09 — READOUT → SERIALIZE transition
//   TC10 — SERIALIZE phase: correct cycle counting
//   TC11 — SERIALIZE → DONE transition
//   TC12 — DONE is a single-cycle pulse, returns to IDLE
//   TC13 — Full end-to-end state traversal
//   TC14 — Async reset during WEIGHT_LOAD returns to IDLE
//   TC15 — Fast restart: start pulses again after DONE
//   TC16 — weight_preloaded=1: skip WEIGHT_LOAD, immediate COMPUTE
//==============================================================================

`timescale 1ns / 1ps

module tb_controller;

    localparam ROWS        = 4;
    localparam COLS        = 4;
    localparam K_DEPTH     = 4;
    localparam ADDR_WIDTH  = 4;
    localparam CLK_PERIOD  = 10;

    // Derived from controller
    localparam WEIGHT_LOAD_CYCLES = ROWS * COLS;   // 16
    localparam COMPUTE_CYCLES     = K_DEPTH;        // 4
    localparam READOUT_CYCLES     = 2 * (ROWS + COLS); // 16
    localparam SERIALIZE_CYCLES   = ROWS * COLS;    // 16

    reg               clk;
    reg               rst_n;
    reg               start;
    wire              busy;
    wire              done;
    wire              pe_clear;
    wire              pe_enable;
    wire              weight_wren;
    wire [ADDR_WIDTH-1:0] weight_addr;
    wire [2:0]        phase;
    wire [$clog2(K_DEPTH):0]   compute_cycle;
    wire [$clog2(2*(ROWS+COLS)):0] readout_cycle;
    wire [$clog2(ROWS*COLS):0] serialize_cycle;
    reg               deser_ready;
    reg               weight_preloaded;

    integer test_count, pass_count, fail_count;

    //--------------------------------------------------------------------------
    // DUT instantiation
    //--------------------------------------------------------------------------
    controller #(
        .ROWS       (ROWS),
        .COLS       (COLS),
        .K_DEPTH    (K_DEPTH),
        .ADDR_WIDTH (ADDR_WIDTH)
    ) u_dut (
        .clk             (clk),
        .rst_n           (rst_n),
        .start           (start),
        .weight_preloaded(weight_preloaded),
        .busy            (busy),
        .done            (done),
        .pe_clear        (pe_clear),
        .pe_enable       (pe_enable),
        .weight_wren     (weight_wren),
        .weight_addr     (weight_addr),
        .phase           (phase),
        .compute_cycle   (compute_cycle),
        .readout_cycle   (readout_cycle),
        .serialize_cycle (serialize_cycle),
        .deser_ready     (deser_ready)
    );

    //--------------------------------------------------------------------------
    // Clock
    //--------------------------------------------------------------------------
    always #(CLK_PERIOD/2) clk = ~clk;

    //--------------------------------------------------------------------------
    // Check task
    //--------------------------------------------------------------------------
    task automatic check_signal;
        input string test_name;
        input integer cond;
        input string  msg;
        begin
            if (cond) begin
                $display("[PASS] %0s: %0s", test_name, msg);
                pass_count = pass_count + 1;
            end else begin
                $display("[FAIL] %0s: %0s", test_name, msg);
                fail_count = fail_count + 1;
            end
            test_count = test_count + 1;
        end
    endtask

    //--------------------------------------------------------------------------
    // Main test sequence
    //--------------------------------------------------------------------------
    initial begin
        // Init
        clk         = 0;
        rst_n       = 0;
        start       = 0;
        deser_ready = 0;
        weight_preloaded = 0;
        test_count  = 0;
        pass_count  = 0;
        fail_count  = 0;

        // Release reset
        repeat(8) @(posedge clk);
        rst_n = 1;
        repeat(2) @(posedge clk);

        //======================================================================
        // TC01: IDLE defaults
        //======================================================================
        $display("============================================================");
        $display("TC01: IDLE defaults — verify all outputs at reset");
        $display("============================================================");

        @(posedge clk);
        check_signal("TC01a: busy=0",      busy == 0, $sformatf("busy=%b", busy));
        check_signal("TC01b: done=0",      done == 0, $sformatf("done=%b", done));
        check_signal("TC01c: phase=0",     phase == 0, $sformatf("phase=%0d", phase));
        check_signal("TC01d: pe_enable=0", pe_enable == 0, $sformatf("pe_enable=%b", pe_enable));
        check_signal("TC01e: pe_clear=0",  pe_clear == 0, $sformatf("pe_clear=%b", pe_clear));

        //======================================================================
        // TC02: start pulse → IDLE → WEIGHT_LOAD
        //======================================================================
        $display("============================================================");
        $display("TC02: start pulse triggers IDLE → WEIGHT_LOAD");
        $display("============================================================");

        @(posedge clk);
        start <= 1'b1;

        @(posedge clk);
        start <= 1'b0;
        #1ps;
        check_signal("TC02a: busy=1 after start", busy == 1, $sformatf("busy=%b", busy));
        check_signal("TC02b: phase=1 (WEIGHT_LOAD)", phase == 3'd1, $sformatf("phase=%0d", phase));
        check_signal("TC02c: pe_enable=1", pe_enable == 1, $sformatf("pe_enable=%b", pe_enable));

        //======================================================================
        // TC03: WEIGHT_LOAD cycle counting
        //======================================================================
        $display("============================================================");
        $display("TC03: WEIGHT_LOAD — weight_cnt 0..%0d, weight_wren, weight_addr", WEIGHT_LOAD_CYCLES-1);
        $display("============================================================");

        begin : tc03_block
            integer i;
            for (i = 0; i < WEIGHT_LOAD_CYCLES; i = i + 1) begin
                @(posedge clk);
                check_signal($sformatf("TC03[%0d]: weight_wren=1", i),
                    weight_wren == 1'b1,
                    $sformatf("weight_wren=%b, weight_addr=%0d", weight_wren, weight_addr));
                check_signal($sformatf("TC03[%0d]: weight_addr=%0d", i, i),
                    weight_addr == i[ADDR_WIDTH-1:0],
                    $sformatf("weight_addr=%0d", weight_addr));
            end
            // After last weight, weight_wren deasserts
            @(posedge clk);
            check_signal("TC03z: weight_wren deasserted after last weight",
                weight_wren == 0, $sformatf("weight_wren=%b", weight_wren));
        end

        // TC04: WEIGHT_LOAD stalls when deser_ready=0 (already 0)
        //   weight_cnt is now at max (15), deser_ready=0, so state holds
        //======================================================================
        $display("============================================================");
        $display("TC04: WEIGHT_LOAD stalls with deser_ready=0");
        $display("============================================================");

        @(posedge clk);
        check_signal("TC04: phase still WEIGHT_LOAD (stalled)",
            phase == 3'd1, $sformatf("phase=%0d", phase));
        check_signal("TC04: busy still 1", busy == 1, $sformatf("busy=%b", busy));

        //======================================================================
        // TC05: WEIGHT_LOAD → COMPUTE when deser_ready=1
        //======================================================================
        $display("============================================================");
        $display("TC05: WEIGHT_LOAD → COMPUTE with deser_ready=1");
        $display("============================================================");

        deser_ready <= 1'b1;
        @(posedge clk);
        deser_ready <= 1'b0;
        #1ps;
        check_signal("TC05: phase=2 (COMPUTE)", phase == 3'd2, $sformatf("phase=%0d", phase));

        //======================================================================
        // TC06: COMPUTE phase — pe_clear on cycle 0, compute_cnt
        //======================================================================
        $display("============================================================");
        $display("TC06: COMPUTE phase — pe_clear on first cycle, compute_cnt 0..%0d", COMPUTE_CYCLES-1);
        $display("============================================================");

        begin : tc06_block
            integer k;
            for (k = 0; k < COMPUTE_CYCLES; k = k + 1) begin
                @(posedge clk);
                check_signal($sformatf("TC06[%0d]: compute_cycle=%0d", k, k),
                    compute_cycle == k, $sformatf("compute_cycle=%0d", compute_cycle));
                if (k == 0) begin
                    check_signal("TC06a: pe_clear=1 on first COMPUTE cycle",
                        pe_clear == 1, $sformatf("pe_clear=%b", pe_clear));
                end else begin
                    check_signal($sformatf("TC06b[%0d]: pe_clear=0", k),
                        pe_clear == 0, $sformatf("pe_clear=%b", pe_clear));
                end
            end
        end

        //======================================================================
        // TC07: COMPUTE → READOUT transition
        //======================================================================
        $display("============================================================");
        $display("TC07: COMPUTE → READOUT transition");
        $display("============================================================");

        @(posedge clk);
        check_signal("TC07: phase=3 (READOUT)", phase == 3'd3, $sformatf("phase=%0d", phase));

        //======================================================================
        // TC08: READOUT phase
        //======================================================================
        $display("============================================================");
        $display("TC08: READOUT phase — readout_cycle 0..%0d", READOUT_CYCLES-1);
        $display("============================================================");

        begin : tc08_block
            integer d;
            for (d = 0; d < READOUT_CYCLES; d = d + 1) begin
                @(posedge clk);
                #1ps;
                check_signal($sformatf("TC08[%0d]: pe_enable=1", d),
                    pe_enable == 1, $sformatf("pe_enable=%b", pe_enable));
                check_signal($sformatf("TC08[%0d]: readout_cycle=%0d", d, d),
                    readout_cycle == d, $sformatf("readout_cycle=%0d", readout_cycle));
            end
        end

        //======================================================================
        // TC09: READOUT → SERIALIZE transition
        //======================================================================
        $display("============================================================");
        $display("TC09: READOUT → SERIALIZE transition");
        $display("============================================================");

        @(posedge clk);
        check_signal("TC09: phase=4 (SERIALIZE)", phase == 3'd4, $sformatf("phase=%0d", phase));

        //======================================================================
        // TC10: SERIALIZE phase
        //======================================================================
        $display("============================================================");
        $display("TC10: SERIALIZE phase — serialize_cycle 0..%0d", SERIALIZE_CYCLES-1);
        $display("============================================================");

        begin : tc10_block
            integer s;
            for (s = 0; s < SERIALIZE_CYCLES; s = s + 1) begin
                @(posedge clk);
                #1ps;
                check_signal($sformatf("TC10[%0d]: serialize_cycle=%0d", s, s),
                    serialize_cycle == s, $sformatf("serialize_cycle=%0d", serialize_cycle));
            end
        end

        //======================================================================
        // TC11: SERIALIZE → DONE transition
        //======================================================================
        $display("============================================================");
        $display("TC11: SERIALIZE → DONE transition");
        $display("============================================================");

        @(posedge clk);
        #1ps;
        check_signal("TC11: phase=5 (DONE)", phase == 3'd5, $sformatf("phase=%0d", phase));

        //======================================================================
        // TC12: DONE is single-cycle pulse
        //======================================================================
        $display("============================================================");
        $display("TC12: DONE single-cycle pulse, return to IDLE");
        $display("============================================================");

        check_signal("TC12a: done=1",
            done == 1'b1, $sformatf("done=%b", done));

        @(posedge clk);
        #1ps;
        check_signal("TC12b: phase=0 (back to IDLE)",
            phase == 3'd0, $sformatf("phase=%0d", phase));
        check_signal("TC12c: done=0 (single cycle)",
            done == 0, $sformatf("done=%b", done));
        check_signal("TC12d: busy=0",
            busy == 0, $sformatf("busy=%b", busy));

        //======================================================================
        // TC13: Full end-to-end traversal (verify all phases seen)
        //======================================================================
        $display("============================================================");
        $display("TC13: Full end-to-end with deser_ready=1 (no stall)");
        $display("============================================================");

        begin : tc13_block
            reg [2:0] phases_seen;
            phases_seen = 0;

            deser_ready <= 1'b1;  // Pre-assert so no stall
            @(posedge clk);
            start <= 1'b1;
            @(posedge clk);
            start <= 1'b0;

            // Wait through all states, tracking phases
            while (!done) begin
                @(posedge clk);
                #1ps;
                phases_seen = phases_seen | (1 << phase);
            end
            @(posedge clk);
            #1ps;

            check_signal("TC13a: saw WEIGHT_LOAD (phase=1)",
                phases_seen & (1 << 1), "");
            check_signal("TC13b: saw COMPUTE (phase=2)",
                phases_seen & (1 << 2), "");
            check_signal("TC13c: saw READOUT (phase=3)",
                phases_seen & (1 << 3), "");
            check_signal("TC13d: saw SERIALIZE (phase=4)",
                phases_seen & (1 << 4), "");
            check_signal("TC13e: saw DONE (phase=5)",
                phases_seen & (1 << 5), "");
            check_signal("TC13f: ended at IDLE",
                phase == 3'd0, $sformatf("phase=%0d", phase));

            deser_ready <= 1'b0;
        end

        //======================================================================
        // TC14: Async reset during operation
        //======================================================================
        $display("============================================================");
        $display("TC14: Async reset during WEIGHT_LOAD");
        $display("============================================================");

        @(posedge clk);
        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;

        // Wait a few cycles in WEIGHT_LOAD
        repeat(3) @(posedge clk);
        check_signal("TC14a: in WEIGHT_LOAD before reset",
            phase == 3'd1, $sformatf("phase=%0d", phase));

        // Assert reset
        rst_n <= 1'b0;
        @(posedge clk);
        check_signal("TC14b: IDLE after reset", phase == 3'd0, $sformatf("phase=%0d", phase));
        check_signal("TC14c: busy=0 after reset", busy == 0, $sformatf("busy=%b", busy));

        rst_n <= 1'b1;
        repeat(2) @(posedge clk);

        //======================================================================
        // TC15: Fast restart after DONE
        //======================================================================
        $display("============================================================");
        $display("TC15: Fast restart — start again after DONE");
        $display("============================================================");

        begin : tc15_block
            deser_ready <= 1'b1;
            @(posedge clk);
            start <= 1'b1;
            @(posedge clk);
            start <= 1'b0;
            while (!done) @(posedge clk);
            @(posedge clk);  // past DONE

            check_signal("TC15a: first run done, back to IDLE",
                phase == 3'd0 && !busy, $sformatf("phase=%0d busy=%b", phase, busy));

            // Start again immediately
            deser_ready <= 1'b1;
            @(posedge clk);
            start <= 1'b1;
            @(posedge clk);
            start <= 1'b0;
            #1ps;

            check_signal("TC15b: second run started (busy=1)",
                busy == 1, $sformatf("busy=%b", busy));
            check_signal("TC15c: second run in WEIGHT_LOAD",
                phase == 3'd1, $sformatf("phase=%0d", phase));

            deser_ready <= 1'b0;
            while (!done) @(posedge clk);
            @(posedge clk);
            check_signal("TC15d: second run complete",
                phase == 3'd0 && !busy, $sformatf("phase=%0d busy=%b", phase, busy));
        end

        //======================================================================
        // TC16: weight_preloaded=1 — skip WEIGHT_LOAD phase
        //   With weight_preloaded=1, the controller should:
        //   - Enter WEIGHT_LOAD after start
        //   - Skip weight_wren/weight_addr generation
        //   - Transition to COMPUTE as soon as deser_ready=1
        //======================================================================
        $display("============================================================");
        $display("TC16: weight_preloaded=1 — skip WEIGHT_LOAD");
        $display("============================================================");

        begin : tc16_block
            integer wt_cycles;

            weight_preloaded <= 1'b1;
            deser_ready      <= 1'b1;
            @(posedge clk);
            start <= 1'b1;
            @(posedge clk);
            start <= 1'b0;
            #1ps;
            check_signal("TC16a: busy=1 after start", busy == 1, $sformatf("busy=%b", busy));
            check_signal("TC16b: phase=1 (WEIGHT_LOAD) entered", phase == 3'd1, $sformatf("phase=%0d", phase));
            check_signal("TC16c: weight_wren=0 (skipped)", weight_wren == 0, $sformatf("weight_wren=%b", weight_wren));

            // With deser_ready=1, should transition to COMPUTE immediately
            @(posedge clk);
            #1ps;
            check_signal("TC16d: immediate transition to COMPUTE", phase == 3'd2, $sformatf("phase=%0d", phase));
            check_signal("TC16e: busy still 1", busy == 1, $sformatf("busy=%b", busy));

            // Run through COMPUTE, READOUT, SERIALIZE
            while (!done) @(posedge clk);
            @(posedge clk);
            #1ps;
            check_signal("TC16f: completed, back to IDLE", phase == 3'd0 && !busy, $sformatf("phase=%0d busy=%b", phase, busy));
        end

        deser_ready      <= 1'b0;
        weight_preloaded <= 1'b0;

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
        $dumpfile("tb_controller.vcd");
        $dumpvars(0, tb_controller);
    end
`endif

endmodule
