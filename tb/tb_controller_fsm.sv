//==============================================================================
// Testbench: tb_controller_fsm
// Purpose:    Verify basic FSM linear flow TC01-TC12
//   IDLE → WEIGHT_LOAD → COMPUTE → READOUT → SERIALIZE → DONE → IDLE
//
// Sampling convention: every check is done after @(posedge clk); #1ps;
// so NBA-updated registers and the combinational outputs are both stable.
// Counter loops use "check current cycle, THEN advance" so the final
// @(posedge) inside the loop triggers the phase transition cleanly.
//==============================================================================

`timescale 1ns / 1ps

module tb_controller_fsm;

    localparam ROWS        = 4;
    localparam COLS        = 4;
    localparam K_DEPTH     = 4;
    localparam ADDR_WIDTH  = 4;
    localparam CLK_PERIOD  = 10;

    localparam WEIGHT_LOAD_CYCLES = ROWS * COLS;       // 16
    localparam COMPUTE_CYCLES     = K_DEPTH;           // 4
    localparam READOUT_CYCLES     = 2 * (ROWS + COLS); // 16
    localparam SERIALIZE_CYCLES   = ROWS * COLS;       // 16

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
    // Lightweight state-change trace (debug aid, not a check)
    //   state is reg [2:0], not an enum, so we map to names manually.
    //   0=IDLE 1=WEIGHT_LOAD 2=COMPUTE 3=READOUT 4=SERIALIZE 5=DONE
    //--------------------------------------------------------------------------
    function string state_name;
        input [2:0] s;
        case (s)
            3'd0: state_name = "IDLE";
            3'd1: state_name = "WEIGHT_LOAD";
            3'd2: state_name = "COMPUTE";
            3'd3: state_name = "READOUT";
            3'd4: state_name = "SERIALIZE";
            3'd5: state_name = "DONE";
            default: state_name = "UNKNOWN";
        endcase
    endfunction

    reg [2:0] prev_state;
    always @(posedge clk) begin
        if (u_dut.state != prev_state) begin
            $display("[%0t] FSM: %0s -> %0s",
                     $time, state_name(prev_state), state_name(u_dut.state));
            prev_state <= u_dut.state;
        end
    end

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
        clk               = 0;
        rst_n             = 0;
        start             = 0;
        deser_ready       = 0;
        weight_preloaded  = 0;
        test_count        = 0;
        pass_count        = 0;
        fail_count        = 0;
        prev_state        = 3'd0;
        prev_state        = 3'd0;

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
        @(posedge clk); #1ps;
        check_signal("TC01a: busy=0",      busy == 0, $sformatf("busy=%b", busy));
        check_signal("TC01b: done=0",      done == 0, $sformatf("done=%b", done));
        check_signal("TC01c: phase=0",     phase == 0, $sformatf("phase=%0d", phase));
        check_signal("TC01d: pe_enable=0", pe_enable == 0, $sformatf("pe_enable=%b", pe_enable));
        check_signal("TC01e: pe_clear=0",  pe_clear == 0, $sformatf("pe_clear=%b", pe_clear));

        //======================================================================
        // TC02: start pulse → IDLE → WEIGHT_LOAD
        //   After start pulse, state=WEIGHT_LOAD, weight_cnt=0
        //======================================================================
        $display("============================================================");
        $display("TC02: start pulse triggers IDLE → WEIGHT_LOAD");
        $display("============================================================");
        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;
        #1ps;
        check_signal("TC02a: busy=1 after start", busy == 1, $sformatf("busy=%b", busy));
        check_signal("TC02b: phase=1 (WEIGHT_LOAD)", phase == 3'd1, $sformatf("phase=%0d", phase));
        check_signal("TC02c: pe_enable=1", pe_enable == 1, $sformatf("pe_enable=%b", pe_enable));
        check_signal("TC02d: weight_wren=1", weight_wren == 1, $sformatf("weight_wren=%b", weight_wren));

        //======================================================================
        // TC03: WEIGHT_LOAD cycle counting (weight_cnt 0..15, addr 0..15)
        //   Entry: state=WEIGHT_LOAD, weight_cnt=0
        //   Pattern: check current, then advance. Last advance keeps cnt=15
        //   (held because deser_ready=0 → no transition).
        //======================================================================
        $display("============================================================");
        $display("TC03: WEIGHT_LOAD — weight_addr 0..%0d, weight_wren", WEIGHT_LOAD_CYCLES-1);
        $display("============================================================");
        begin : tc03_block
            integer i;
            for (i = 0; i < WEIGHT_LOAD_CYCLES; i = i + 1) begin
                check_signal($sformatf("TC03[%0d]: weight_addr=%0d", i, i),
                    weight_addr == i[ADDR_WIDTH-1:0],
                    $sformatf("weight_addr=%0d", weight_addr));
                check_signal($sformatf("TC03[%0d]: weight_wren=1", i),
                    weight_wren == 1'b1, $sformatf("weight_wren=%b", weight_wren));
                @(posedge clk); #1ps;
            end
        end
        // Now weight_cnt=15, deser_ready=0 → still in WEIGHT_LOAD, wren still 1.
        // (weight_wren only deasserts after leaving WEIGHT_LOAD — see TC05.)

        //======================================================================
        // TC04: WEIGHT_LOAD stalls when deser_ready=0
        //======================================================================
        $display("============================================================");
        $display("TC04: WEIGHT_LOAD stalls with deser_ready=0");
        $display("============================================================");
        check_signal("TC04a: phase still WEIGHT_LOAD (stalled)",
            phase == 3'd1, $sformatf("phase=%0d", phase));
        check_signal("TC04b: busy still 1", busy == 1, $sformatf("busy=%b", busy));
        check_signal("TC04c: weight_wren still 1", weight_wren == 1, $sformatf("weight_wren=%b", weight_wren));

        //======================================================================
        // TC05: WEIGHT_LOAD → COMPUTE when deser_ready=1
        //   Asserting deser_ready lets the FSM advance on the next posedge.
        //======================================================================
        $display("============================================================");
        $display("TC05: WEIGHT_LOAD → COMPUTE with deser_ready=1");
        $display("============================================================");
        deser_ready <= 1'b1;
        @(posedge clk);
        deser_ready <= 1'b0;
        #1ps;
        check_signal("TC05a: phase=2 (COMPUTE)", phase == 3'd2, $sformatf("phase=%0d", phase));
        check_signal("TC05b: weight_wren=0 after leaving WEIGHT_LOAD",
            weight_wren == 0, $sformatf("weight_wren=%b", weight_wren));
        check_signal("TC05c: compute_cycle=0", compute_cycle == 0, $sformatf("compute_cycle=%0d", compute_cycle));

        //======================================================================
        // TC06: COMPUTE phase — pe_clear on cycle 0, compute_cnt 0..3
        //   Entry: state=COMPUTE, compute_cnt=0
        //   Last advance (after k=3 check) triggers COMPUTE→READOUT.
        //======================================================================
        $display("============================================================");
        $display("TC06: COMPUTE phase — pe_clear on first cycle, compute_cnt 0..%0d", COMPUTE_CYCLES-1);
        $display("============================================================");
        begin : tc06_block
            integer k;
            for (k = 0; k < COMPUTE_CYCLES; k = k + 1) begin
                check_signal($sformatf("TC06[%0d]: compute_cycle=%0d", k, k),
                    compute_cycle == k, $sformatf("compute_cycle=%0d", compute_cycle));
                if (k == 0) begin
                    check_signal("TC06a: pe_clear=1 on first COMPUTE cycle",
                        pe_clear == 1, $sformatf("pe_clear=%b", pe_clear));
                end else begin
                    check_signal($sformatf("TC06b[%0d]: pe_clear=0", k),
                        pe_clear == 0, $sformatf("pe_clear=%b", pe_clear));
                end
                @(posedge clk); #1ps;
            end
        end

        //======================================================================
        // TC07: COMPUTE → READOUT transition
        //   The last advance of TC06 already moved us into READOUT.
        //======================================================================
        $display("============================================================");
        $display("TC07: COMPUTE → READOUT transition");
        $display("============================================================");
        check_signal("TC07: phase=3 (READOUT)", phase == 3'd3, $sformatf("phase=%0d", phase));
        check_signal("TC07: readout_cycle=0", readout_cycle == 0, $sformatf("readout_cycle=%0d", readout_cycle));

        //======================================================================
        // TC08: READOUT phase — readout_cycle 0..15
        //   Entry: state=READOUT, readout_cnt=0
        //   Last advance (after d=15 check) triggers READOUT→SERIALIZE.
        //======================================================================
        $display("============================================================");
        $display("TC08: READOUT phase — readout_cycle 0..%0d", READOUT_CYCLES-1);
        $display("============================================================");
        begin : tc08_block
            integer d;
            for (d = 0; d < READOUT_CYCLES; d = d + 1) begin
                check_signal($sformatf("TC08[%0d]: pe_enable=1", d),
                    pe_enable == 1, $sformatf("pe_enable=%b", pe_enable));
                check_signal($sformatf("TC08[%0d]: readout_cycle=%0d", d, d),
                    readout_cycle == d, $sformatf("readout_cycle=%0d", readout_cycle));
                @(posedge clk); #1ps;
            end
        end

        //======================================================================
        // TC09: READOUT → SERIALIZE transition
        //======================================================================
        $display("============================================================");
        $display("TC09: READOUT → SERIALIZE transition");
        $display("============================================================");
        check_signal("TC09: phase=4 (SERIALIZE)", phase == 3'd4, $sformatf("phase=%0d", phase));
        check_signal("TC09: serialize_cycle=0", serialize_cycle == 0, $sformatf("serialize_cycle=%0d", serialize_cycle));

        //======================================================================
        // TC10: SERIALIZE phase — serialize_cycle 0..15
        //   Entry: state=SERIALIZE, serialize_cnt=0
        //   Last advance (after s=15 check) triggers SERIALIZE→DONE.
        //======================================================================
        $display("============================================================");
        $display("TC10: SERIALIZE phase — serialize_cycle 0..%0d", SERIALIZE_CYCLES-1);
        $display("============================================================");
        begin : tc10_block
            integer s;
            for (s = 0; s < SERIALIZE_CYCLES; s = s + 1) begin
                check_signal($sformatf("TC10[%0d]: serialize_cycle=%0d", s, s),
                    serialize_cycle == s, $sformatf("serialize_cycle=%0d", serialize_cycle));
                check_signal($sformatf("TC10[%0d]: pe_enable=1", s),
                    pe_enable == 1, $sformatf("pe_enable=%b", pe_enable));
                @(posedge clk); #1ps;
            end
        end

        //======================================================================
        // TC11: SERIALIZE → DONE transition
        //======================================================================
        $display("============================================================");
        $display("TC11: SERIALIZE → DONE transition");
        $display("============================================================");
        check_signal("TC11: phase=5 (DONE)", phase == 3'd5, $sformatf("phase=%0d", phase));

        //======================================================================
        // TC12: DONE is single-cycle pulse, returns to IDLE
        //======================================================================
        $display("============================================================");
        $display("TC12: DONE single-cycle pulse, return to IDLE");
        $display("============================================================");
        check_signal("TC12a: done=1", done == 1'b1, $sformatf("done=%b", done));
        @(posedge clk); #1ps;
        check_signal("TC12b: phase=0 (back to IDLE)", phase == 3'd0, $sformatf("phase=%0d", phase));
        check_signal("TC12c: done=0 (single cycle)", done == 0, $sformatf("done=%b", done));
        check_signal("TC12d: busy=0", busy == 0, $sformatf("busy=%b", busy));

        //======================================================================
        // Summary
        //======================================================================
        $display("============================================================");
        $display("Summary: %0d/%0d PASS, %0d FAIL", pass_count, test_count, fail_count);
        $display("============================================================");
        if (fail_count == 0) $display("ALL TESTS PASSED!");
        else                 $display("SOME TESTS FAILED!");

        $finish;
    end

    //--------------------------------------------------------------------------
    // Wave dump
    //--------------------------------------------------------------------------
    `ifndef XILINX_SIMULATOR
    initial begin
        $dumpfile("tb_controller_fsm.vcd");
        $dumpvars(0, tb_controller_fsm);
    end
    `endif

endmodule
