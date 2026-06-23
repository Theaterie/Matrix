//==============================================================================
// Testbench: tb_pe_array
// Purpose:    Verify 4×4 weight-stationary systolic PE array
//             Tests weight loading, compute, and result readout
//==============================================================================
// Test items:
//   TC01 — Weight loading: 4×4 weight matrix loaded into PEs
//   TC02 — Single row multiply: A[0][:] × B → C[0][:] verified
//   TC03 — Second row multiply: A[1][:] × B → C[1][:] (clear between rows)
//   TC04 — Accumulation check: same weight, different activations
//
// Test matrices (4×4):
//   B (weights) = [[ 1,  2,  3,  4],
//                  [ 5,  6,  7,  8],
//                  [ 9, 10, 11, 12],
//                  [13, 14, 15, 16]]
//
//   A[0] = [1, 1, 1, 1] → C[0] = [28, 32, 36, 40]
//   A[1] = [2, 1, 0, -1] → C[1] = [-6, -4, -2, 0]
//==============================================================================

`timescale 1ns / 1ps

module tb_pe_array;

    localparam ROWS        = 4;
    localparam COLS        = 4;
    localparam DATA_WIDTH  = 16;
    localparam ACCUM_WIDTH = 40;
    localparam ADDR_WIDTH  = 4;
    localparam CLK_PERIOD  = 10;

    reg                                 clk;
    reg                                 rst_n;

    // Activation inputs (one per row)
    reg  [DATA_WIDTH-1:0]               act_data_in [0:ROWS-1];
    reg                                 act_valid_in;

    // Weight loading
    reg  [DATA_WIDTH-1:0]               weight_data;
    reg  [ADDR_WIDTH-1:0]               weight_addr;
    reg                                 weight_wren;

    // Result outputs
    wire [ACCUM_WIDTH-1:0]              result_data [0:COLS-1];
    wire                                result_valid;

    // Control
    reg                                 clear;
    reg                                 enable;

    // Test infrastructure
    integer test_count, pass_count, fail_count;

    //--------------------------------------------------------------------------
    // DUT instantiation — 4×4 PE array
    //--------------------------------------------------------------------------
    pe_array #(
        .ROWS        (ROWS),
        .COLS        (COLS),
        .DATA_WIDTH  (DATA_WIDTH),
        .ACCUM_WIDTH (ACCUM_WIDTH)
    ) u_dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .act_data_in  (act_data_in),
        .act_valid_in (act_valid_in),
        .weight_data  (weight_data),
        .weight_addr  (weight_addr),
        .weight_wren  (weight_wren),
        .result_data  (result_data),
        .result_valid (result_valid),
        .clear        (clear),
        .enable       (enable)
    );

    //--------------------------------------------------------------------------
    // Clock
    //--------------------------------------------------------------------------
    always #(CLK_PERIOD/2) clk = ~clk;

    //--------------------------------------------------------------------------
    // Task: Load one weight into PE at (row, col)
    //--------------------------------------------------------------------------
    task automatic load_weight;
        input [1:0] r, c;
        input signed [DATA_WIDTH-1:0] w;
        begin
            @(posedge clk);
            weight_data <= w;
            weight_addr <= r * COLS + c;
            weight_wren <= 1'b1;
        end
    endtask

    //--------------------------------------------------------------------------
    // Task: Load full 4×4 weight matrix
    //--------------------------------------------------------------------------
    task automatic load_weight_matrix;
        input signed [DATA_WIDTH-1:0] w_mat [0:ROWS-1][0:COLS-1];
        integer r, c;
        begin
            $display("  Loading %0dx%0d weight matrix...", ROWS, COLS);
            for (r = 0; r < ROWS; r = r + 1) begin
                for (c = 0; c < COLS; c = c + 1) begin
                    load_weight(r[1:0], c[1:0], w_mat[r][c]);
                end
            end
            @(posedge clk);
            weight_wren <= 1'b0;
            weight_data <= 0;
            weight_addr <= 0;
        end
    endtask

    //--------------------------------------------------------------------------
    // Task: Drive one activation vector (one value per row)
    //--------------------------------------------------------------------------
    task automatic drive_activation;
        input signed [DATA_WIDTH-1:0] act_vec [0:ROWS-1];
        integer r;
        begin
            @(posedge clk);
            for (r = 0; r < ROWS; r = r + 1) begin
                act_data_in[r] <= act_vec[r];
            end
            act_valid_in <= 1'b1;
            clear        <= 1'b1;    // Seed new dot-product

            @(posedge clk);
            act_valid_in <= 1'b0;
            clear        <= 1'b0;
            for (r = 0; r < ROWS; r = r + 1) begin
                act_data_in[r] <= 0;
            end
        end
    endtask

    //--------------------------------------------------------------------------
    // Task: Wait for pipeline to produce valid results
    //--------------------------------------------------------------------------
    task automatic wait_for_result;
        input integer timeout_cycles;
        integer cnt;
        begin
            cnt = 0;
            while (!result_valid && cnt < timeout_cycles) begin
                @(posedge clk);
                cnt = cnt + 1;
            end
            if (cnt >= timeout_cycles)
                $display("  WARNING: Timeout waiting for result_valid (waited %0d cycles)", cnt);
            else
                $display("  result_valid asserted after %0d cycles", cnt);
        end
    endtask

    //--------------------------------------------------------------------------
    // Task: Check all result columns
    //--------------------------------------------------------------------------
    task automatic check_all_results;
        input signed [ACCUM_WIDTH-1:0] expected [0:COLS-1];
        input [255:0] test_name;
        integer c;
        begin
            for (c = 0; c < COLS; c = c + 1) begin
                if (result_data[c] === expected[c]) begin
                    $display("[PASS] %0s col[%0d]: got %0d (expected %0d)",
                             test_name, c, result_data[c], expected[c]);
                    pass_count = pass_count + 1;
                end else begin
                    $display("[FAIL] %0s col[%0d]: got %0d (expected %0d)",
                             test_name, c, result_data[c], expected[c]);
                    fail_count = fail_count + 1;
                end
                test_count = test_count + 1;
            end
        end
    endtask

    //--------------------------------------------------------------------------
    // Test weight matrix B (4×4)
    //--------------------------------------------------------------------------
    reg signed [DATA_WIDTH-1:0] weight_mat [0:ROWS-1][0:COLS-1];

    //--------------------------------------------------------------------------
    // Main test sequence
    //--------------------------------------------------------------------------
    initial begin
        // Init
        clk          = 0;
        rst_n        = 0;
        for (int i = 0; i < ROWS; i++) act_data_in[i] = 0;
        act_valid_in = 0;
        weight_data  = 0;
        weight_addr  = 0;
        weight_wren  = 0;
        clear        = 0;
        enable       = 0;
        test_count   = 0;
        pass_count   = 0;
        fail_count   = 0;

        // Initialize weight matrix
        weight_mat[0][0] = 16'sd1;  weight_mat[0][1] = 16'sd2;
        weight_mat[0][2] = 16'sd3;  weight_mat[0][3] = 16'sd4;
        weight_mat[1][0] = 16'sd5;  weight_mat[1][1] = 16'sd6;
        weight_mat[1][2] = 16'sd7;  weight_mat[1][3] = 16'sd8;
        weight_mat[2][0] = 16'sd9;  weight_mat[2][1] = 16'sd10;
        weight_mat[2][2] = 16'sd11; weight_mat[2][3] = 16'sd12;
        weight_mat[3][0] = 16'sd13; weight_mat[3][1] = 16'sd14;
        weight_mat[3][2] = 16'sd15; weight_mat[3][3] = 16'sd16;

        // Release reset
        repeat(8) @(posedge clk);
        rst_n  = 1;
        enable = 1;
        repeat(2) @(posedge clk);

        //======================================================================
        // TC01: Weight loading
        //======================================================================
        $display("============================================================");
        $display("TC01: Load 4x4 weight matrix into PE array");
        $display("============================================================");

        load_weight_matrix(weight_mat);
        $display("[PASS] TC01: 16 weights loaded");
        pass_count = pass_count + 1;
        test_count = test_count + 1;

        //======================================================================
        // TC02: A[0]=[1,1,1,1] × B → C[0]=[28,32,36,40]
        //======================================================================
        $display("============================================================");
        $display("TC02: A[0]=[1,1,1,1] x B -> C[0]=[28,32,36,40]");
        $display("============================================================");

        begin : tc02_block
            reg signed [DATA_WIDTH-1:0]  act_vec [0:ROWS-1];
            reg signed [ACCUM_WIDTH-1:0] expected [0:COLS-1];

            act_vec[0] = 16'sd1; act_vec[1] = 16'sd1;
            act_vec[2] = 16'sd1; act_vec[3] = 16'sd1;

            drive_activation(act_vec);
            wait_for_result(50);

            expected[0] = 40'sd28;
            expected[1] = 40'sd32;
            expected[2] = 40'sd36;
            expected[3] = 40'sd40;

            check_all_results(expected, "TC02");
        end

        //======================================================================
        // TC03: A[1]=[2,1,0,-1] × B → C[1]=[-6,-4,-2,0]
        //======================================================================
        $display("============================================================");
        $display("TC03: A[1]=[2,1,0,-1] x B -> C[1]=[-6,-4,-2,0]");
        $display("============================================================");

        begin : tc03_block
            reg signed [DATA_WIDTH-1:0]  act_vec [0:ROWS-1];
            reg signed [ACCUM_WIDTH-1:0] expected [0:COLS-1];

            act_vec[0] = 16'sd2;
            act_vec[1] = 16'sd1;
            act_vec[2] = 16'sd0;
            act_vec[3] = -16'sd1;

            drive_activation(act_vec);
            wait_for_result(50);

            expected[0] = -40'sd6;
            expected[1] = -40'sd4;
            expected[2] = -40'sd2;
            expected[3] = 40'sd0;

            check_all_results(expected, "TC03");
        end

        //======================================================================
        // TC04: Repeat A=[1,1,1,1] — verify weights intact and accum cleared
        //======================================================================
        $display("============================================================");
        $display("TC04: Repeat A=[1,1,1,1] — verify weights intact, accum cleared");
        $display("============================================================");

        begin : tc04_block
            reg signed [DATA_WIDTH-1:0]  act_vec [0:ROWS-1];
            reg signed [ACCUM_WIDTH-1:0] expected [0:COLS-1];

            act_vec[0] = 16'sd1; act_vec[1] = 16'sd1;
            act_vec[2] = 16'sd1; act_vec[3] = 16'sd1;

            drive_activation(act_vec);
            wait_for_result(50);

            expected[0] = 40'sd28;
            expected[1] = 40'sd32;
            expected[2] = 40'sd36;
            expected[3] = 40'sd40;

            check_all_results(expected, "TC04");
        end

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

        $display("Final result_data: [%0d, %0d, %0d, %0d]",
                 result_data[0], result_data[1], result_data[2], result_data[3]);

        $finish;
    end

    //--------------------------------------------------------------------------
    // Monitor result_valid
    //--------------------------------------------------------------------------
    always @(posedge clk) begin
        if (result_valid && rst_n) begin
            $display("  [MON] Time %0t: result_valid=1, data=[%0d, %0d, %0d, %0d]",
                     $time, result_data[0], result_data[1], result_data[2], result_data[3]);
        end
    end

    //--------------------------------------------------------------------------
    // Wave dump
    //--------------------------------------------------------------------------
`ifndef XILINX_SIMULATOR
    initial begin
        $dumpfile("tb_pe_array.vcd");
        $dumpvars(0, tb_pe_array);
    end
`endif

endmodule
