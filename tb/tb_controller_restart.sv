//==============================================================================
// Testbench: tb_controller_restart
// Purpose:    Verify end-to-end traversal, async reset, and fast restart
//   TC13 — Full end-to-end state traversal (deser_ready=1, no stall)
//   TC14 — Async reset during WEIGHT_LOAD returns to IDLE
//   TC15 — Fast restart: two back-to-back runs
//==============================================================================

`timescale 1ns / 1ps

module tb_controller_restart;

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

    always #(CLK_PERIOD/2) clk = ~clk;

    //--------------------------------------------------------------------------
    // State name helper (state is reg [2:0], not an enum)
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

    // Wait for done with a timeout — prevents infinite stall if the FSM hangs.
    task automatic wait_done;
        input integer timeout_cycles;
        input string  label;
        integer c;
        begin
            c = 0;
            while (!done && c < timeout_cycles) begin
                @(posedge clk);
                #1ps;
                c = c + 1;
            end
            if (!done) begin
                $display("[TIMEOUT] %0s: done not asserted after %0d cycles (state=%0s, phase=%0d)",
                         label, timeout_cycles, state_name(u_dut.state), phase);
                fail_count = fail_count + 1;
                test_count = test_count + 1;
            end
        end
    endtask

    //--------------------------------------------------------------------------
    // Main test sequence
    //--------------------------------------------------------------------------
    initial begin
        clk               = 0;
        rst_n             = 0;
        start             = 0;
        deser_ready       = 0;
        weight_preloaded  = 0;
        test_count        = 0;
        pass_count        = 0;
        fail_count        = 0;

        repeat(8) @(posedge clk);
        rst_n = 1;
        repeat(2) @(posedge clk);

        //======================================================================
        // TC13: Full end-to-end traversal with deser_ready=1 (no stall)
        //======================================================================
        $display("============================================================");
        $display("TC13: Full end-to-end with deser_ready=1 (no stall)");
        $display("============================================================");
        begin : tc13_block
            reg [5:0] phases_seen;
            integer wt;
            phases_seen = 6'b0;

            deser_ready <= 1'b1;
            @(posedge clk);
            start <= 1'b1;
            @(posedge clk);
            start <= 1'b0;
            #1ps;

            // Walk through all states until done, collecting phases seen.
            wt = 0;
            while (!done && wt < 200) begin
                @(posedge clk);
                #1ps;
                phases_seen = phases_seen | (1 << phase);
                wt = wt + 1;
            end
            if (!done) begin
                $display("[TIMEOUT] TC13: done not asserted after 200 cycles (state=%0s)", state_name(u_dut.state));
                fail_count = fail_count + 1;
                test_count = test_count + 1;
            end
            @(posedge clk); #1ps;

            check_signal("TC13a: saw WEIGHT_LOAD (phase=1)", phases_seen & (1 << 1), "");
            check_signal("TC13b: saw COMPUTE (phase=2)",     phases_seen & (1 << 2), "");
            check_signal("TC13c: saw READOUT (phase=3)",     phases_seen & (1 << 3), "");
            check_signal("TC13d: saw SERIALIZE (phase=4)",   phases_seen & (1 << 4), "");
            check_signal("TC13e: saw DONE (phase=5)",        phases_seen & (1 << 5), "");
            check_signal("TC13f: ended at IDLE", phase == 3'd0, $sformatf("phase=%0d", phase));

            deser_ready <= 1'b0;
        end

        //======================================================================
        // TC14: Async reset during WEIGHT_LOAD
        //======================================================================
        $display("============================================================");
        $display("TC14: Async reset during WEIGHT_LOAD");
        $display("============================================================");
        @(posedge clk);
        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;
        repeat(3) @(posedge clk);
        #1ps;
        check_signal("TC14a: in WEIGHT_LOAD before reset",
            phase == 3'd1, $sformatf("phase=%0d", phase));

        rst_n <= 1'b0;
        @(posedge clk); #1ps;
        check_signal("TC14b: IDLE after reset", phase == 3'd0, $sformatf("phase=%0d", phase));
        check_signal("TC14c: busy=0 after reset", busy == 0, $sformatf("busy=%b", busy));
        check_signal("TC14d: counters cleared", u_dut.weight_cnt == 0 && u_dut.compute_cnt == 0,
            $sformatf("wt=%0d cp=%0d", u_dut.weight_cnt, u_dut.compute_cnt));

        rst_n <= 1'b1;
        repeat(2) @(posedge clk);

        //======================================================================
        // TC15: Fast restart — two back-to-back runs
        //   deser_ready must stay 1 so WEIGHT_LOAD can advance to COMPUTE.
        //======================================================================
        $display("============================================================");
        $display("TC15: Fast restart — two back-to-back runs");
        $display("============================================================");
        begin : tc15_block
            // ---- Run 1 ----
            deser_ready <= 1'b1;
            @(posedge clk);
            start <= 1'b1;
            @(posedge clk);
            start <= 1'b0;
            #1ps;
            check_signal("TC15a: run1 started (busy=1)", busy == 1, $sformatf("busy=%b", busy));
            wait_done(200, "TC15 run1");
            @(posedge clk); #1ps;
            check_signal("TC15b: run1 done, back to IDLE",
                phase == 3'd0 && !busy, $sformatf("phase=%0d busy=%b", phase, busy));

            // ---- Run 2 (immediate restart) ----
            deser_ready <= 1'b1;
            @(posedge clk);
            start <= 1'b1;
            @(posedge clk);
            start <= 1'b0;
            #1ps;
            check_signal("TC15c: run2 started (busy=1)", busy == 1, $sformatf("busy=%b", busy));
            check_signal("TC15d: run2 in WEIGHT_LOAD", phase == 3'd1, $sformatf("phase=%0d", phase));
            wait_done(200, "TC15 run2");
            @(posedge clk); #1ps;
            check_signal("TC15e: run2 done, back to IDLE",
                phase == 3'd0 && !busy, $sformatf("phase=%0d busy=%b", phase, busy));
        end

        deser_ready <= 1'b0;

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
        $dumpfile("tb_controller_restart.vcd");
        $dumpvars(0, tb_controller_restart);
    end
    `endif

endmodule
