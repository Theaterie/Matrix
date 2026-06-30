//==============================================================================
// Testbench: tb_controller_preloaded
// Purpose:    Verify weight_preloaded optimization path
//   TC16 — weight_preloaded=1 skips weight loading, goes straight to COMPUTE
//          once deser_ready=1. weight_wren stays 0, weight_cnt stays 0.
//==============================================================================

`timescale 1ns / 1ps

module tb_controller_preloaded;

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
        // TC16: weight_preloaded=1 — skip WEIGHT_LOAD phase
        //   With weight_preloaded=1, the controller should:
        //   - Enter WEIGHT_LOAD after start (phase=1)
        //   - Keep weight_wren=0 (no writes)
        //   - Keep weight_cnt=0 (no counting)
        //   - Transition to COMPUTE as soon as deser_ready=1
        //======================================================================
        $display("============================================================");
        $display("TC16: weight_preloaded=1 — skip WEIGHT_LOAD");
        $display("============================================================");
        begin : tc16_block
            weight_preloaded <= 1'b1;
            deser_ready      <= 1'b1;
            @(posedge clk);
            start <= 1'b1;
            @(posedge clk);
            start <= 1'b0;
            #1ps;

            check_signal("TC16a: busy=1 after start", busy == 1, $sformatf("busy=%b", busy));
            check_signal("TC16b: phase=1 (WEIGHT_LOAD entered)", phase == 3'd1, $sformatf("phase=%0d", phase));
            check_signal("TC16c: weight_wren=0 (skipped)", weight_wren == 0, $sformatf("weight_wren=%b", weight_wren));
            check_signal("TC16d: weight_cnt=0 (no counting)", u_dut.weight_cnt == 0,
                $sformatf("weight_cnt=%0d", u_dut.weight_cnt));

            // With deser_ready=1 + weight_preloaded, next posedge → COMPUTE
            @(posedge clk); #1ps;
            check_signal("TC16e: immediate transition to COMPUTE", phase == 3'd2, $sformatf("phase=%0d", phase));
            check_signal("TC16f: busy still 1", busy == 1, $sformatf("busy=%b", busy));
            check_signal("TC16g: pe_clear=1 on first COMPUTE cycle", pe_clear == 1, $sformatf("pe_clear=%b", pe_clear));

            // Run through COMPUTE → READOUT → SERIALIZE → DONE
            wait_done(200, "TC16 run");
            @(posedge clk); #1ps;
            check_signal("TC16h: completed, back to IDLE",
                phase == 3'd0 && !busy, $sformatf("phase=%0d busy=%b", phase, busy));
        end

        weight_preloaded <= 1'b0;
        deser_ready      <= 1'b0;

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
        $dumpfile("tb_controller_preloaded.vcd");
        $dumpvars(0, tb_controller_preloaded);
    end
    `endif

endmodule
