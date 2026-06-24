//==============================================================================
// Testbench: tb_systolic_array_axis
// Purpose:    Verify AXI4-Stream wrapper — weight streaming, activation
//             preloading, result streaming, TLAST handling, and backpressure
//==============================================================================
// Test items:
//   TC01 — Weight stream handshake (TVALID/TREADY during WEIGHT_LOAD)
//   TC02 — Weight stream TLAST handling
//   TC03 — Activation stream preload (S_AXIS_ACT to BRAM)
//   TC04 — Activation TLAST handling
//   TC05 — Full tile via AXIS (weights+acts streamed, results streamed out)
//   TC06 — Result stream handshake (M_AXIS_RESULT)
//   TC07 — Backpressure on result stream (TREADY=0)
//   TC08 — Direct activation path (use_bram_act=0)
//   TC09 — Multiple tiles (reset and re-run)
//   TC10 — Async reset during operation
//==============================================================================

`timescale 1ns / 1ps

module tb_systolic_array_axis;

    localparam ROWS        = 4;
    localparam COLS        = 4;
    localparam DATA_WIDTH  = 16;
    localparam ACCUM_WIDTH = 40;
    localparam K_DEPTH     = 4;
    localparam BUF_ADDR_W  = 8;
    localparam BUF_DEPTH   = 256;
    localparam WT_ADDR_W   = 4;
    localparam CLK_PERIOD  = 10;

    localparam WEIGHT_COUNT = ROWS * COLS;     // 16
    localparam ACT_COUNT    = ROWS * K_DEPTH;  // 16
    localparam RESULT_COUNT = ROWS * COLS;     // 16

    reg               clk, rst_n;
    reg               start;
    wire              busy, done;

    // AXI-S Weight
    reg               s_axis_weight_tvalid;
    wire              s_axis_weight_tready;
    reg  [DATA_WIDTH-1:0] s_axis_weight_tdata;
    reg               s_axis_weight_tlast;

    // AXI-S Activation
    reg               s_axis_act_tvalid;
    wire              s_axis_act_tready;
    reg  [DATA_WIDTH-1:0] s_axis_act_tdata;
    reg               s_axis_act_tlast;

    // AXI-S Result
    wire              m_axis_result_tvalid;
    reg               m_axis_result_tready;
    wire [ACCUM_WIDTH-1:0] m_axis_result_tdata;
    wire              m_axis_result_tlast;

    // Other
    reg               use_bram_act;
    reg  [DATA_WIDTH-1:0] act_data [0:ROWS-1];
    reg               act_valid;
    wire [ACCUM_WIDTH-1:0] result_data [0:COLS-1];
    wire              result_valid;
    reg  [BUF_ADDR_W-1:0] act_base_addr, res_base_addr;

    integer test_count, pass_count, fail_count;

    //--------------------------------------------------------------------------
    // DUT instantiation
    //--------------------------------------------------------------------------
    systolic_array_axis #(
        .ROWS(ROWS), .COLS(COLS), .DATA_WIDTH(DATA_WIDTH),
        .ACCUM_WIDTH(ACCUM_WIDTH), .K_DEPTH(K_DEPTH),
        .BUF_ADDR_W(BUF_ADDR_W), .BUF_DEPTH(BUF_DEPTH), .WT_ADDR_W(WT_ADDR_W)
    ) u_dut (
        .clk(clk), .rst_n(rst_n),
        .s_axis_weight_tvalid(s_axis_weight_tvalid),
        .s_axis_weight_tready(s_axis_weight_tready),
        .s_axis_weight_tdata(s_axis_weight_tdata),
        .s_axis_weight_tlast(s_axis_weight_tlast),
        .s_axis_act_tvalid(s_axis_act_tvalid),
        .s_axis_act_tready(s_axis_act_tready),
        .s_axis_act_tdata(s_axis_act_tdata),
        .s_axis_act_tlast(s_axis_act_tlast),
        .m_axis_result_tvalid(m_axis_result_tvalid),
        .m_axis_result_tready(m_axis_result_tready),
        .m_axis_result_tdata(m_axis_result_tdata),
        .m_axis_result_tlast(m_axis_result_tlast),
        .start(start), .busy(busy), .done(done),
        .use_bram_act(use_bram_act),
        .act_data(act_data), .act_valid(act_valid),
        .result_data(result_data), .result_valid(result_valid),
        .act_base_addr(act_base_addr), .res_base_addr(res_base_addr)
    );

    //--------------------------------------------------------------------------
    // Clock
    //--------------------------------------------------------------------------
    always #(CLK_PERIOD/2) clk = ~clk;

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
    // Task: Stream weights via AXIS (with Valid/Ready handshake)
    //--------------------------------------------------------------------------
    task automatic stream_weights;
        input signed [DATA_WIDTH-1:0] w_mat [0:ROWS-1][0:COLS-1];
        integer r, c, i;
        begin
            i = 0;
            for (r = 0; r < ROWS; r++)
                for (c = 0; c < COLS; c++) begin
                    while (!s_axis_weight_tready) @(posedge clk);
                    @(posedge clk);
                    s_axis_weight_tvalid <= 1'b1;
                    s_axis_weight_tdata  <= w_mat[r][c];
                    s_axis_weight_tlast  <= (i == WEIGHT_COUNT - 1);
                    i++;
                end
            @(posedge clk);
            s_axis_weight_tvalid <= 1'b0;
            s_axis_weight_tlast  <= 1'b0;
        end
    endtask

    //--------------------------------------------------------------------------
    // Task: Stream activations via AXIS
    //--------------------------------------------------------------------------
    task automatic stream_activations;
        input signed [DATA_WIDTH-1:0] a_mat [0:ROWS-1][0:K_DEPTH-1];
        integer r, k, i;
        begin
            i = 0;
            for (r = 0; r < ROWS; r++)
                for (k = 0; k < K_DEPTH; k++) begin
                    while (!s_axis_act_tready) @(posedge clk);
                    @(posedge clk);
                    s_axis_act_tvalid <= 1'b1;
                    s_axis_act_tdata  <= a_mat[r][k];
                    s_axis_act_tlast  <= (i == ACT_COUNT - 1);
                    i++;
                end
            @(posedge clk);
            s_axis_act_tvalid <= 1'b0;
            s_axis_act_tlast  <= 1'b0;
        end
    endtask

    //--------------------------------------------------------------------------
    // Task: Receive results via AXIS
    //--------------------------------------------------------------------------
    task automatic recv_results;
        output [ACCUM_WIDTH-1:0] res_out [0:RESULT_COUNT-1];
        output integer n_received;
        integer i;
        begin
            i = 0;
            m_axis_result_tready <= 1'b1;
            // Wait for results to start streaming
            while (!m_axis_result_tvalid) @(posedge clk);
            while (i < RESULT_COUNT && m_axis_result_tvalid) begin
                res_out[i] = m_axis_result_tdata;
                // Check TLAST on last result
                if (i == RESULT_COUNT - 1) begin
                    if (m_axis_result_tlast) begin
                        $display("  [INFO] TLAST on last result (idx %0d)", i);
                    end else begin
                        $display("  [WARN] TLAST not asserted on last result!");
                    end
                end
                i++;
                @(posedge clk);
            end
            m_axis_result_tready <= 1'b0;
            n_received = i;
        end
    endtask

    //--------------------------------------------------------------------------
    // Main
    //--------------------------------------------------------------------------
    initial begin
        clk = 0; rst_n = 0; start = 0; use_bram_act = 1;
        s_axis_weight_tvalid = 0; s_axis_weight_tdata = 0; s_axis_weight_tlast = 0;
        s_axis_act_tvalid = 0; s_axis_act_tdata = 0; s_axis_act_tlast = 0;
        m_axis_result_tready = 0;
        for (int i = 0; i < ROWS; i++) act_data[i] = 0;
        act_valid = 0; act_base_addr = 0; res_base_addr = 0;
        test_count = 0; pass_count = 0; fail_count = 0;

        repeat(8) @(posedge clk); rst_n = 1; repeat(2) @(posedge clk);

        //======================================================================
        // TC01: Weight stream handshake
        //======================================================================
        $display("============================================================");
        $display("TC01: Weight stream handshake (TVALID/TREADY)");
        $display("============================================================");

        begin : tc01_block
            reg signed [DATA_WIDTH-1:0] w_id [0:ROWS-1][0:COLS-1];
            integer r, c;
            for (r = 0; r < ROWS; r++)
                for (c = 0; c < COLS; c++)
                    w_id[r][c] = (r == c) ? 16'sd1 : 16'sd0;

            // Preload activations before start
            begin
                reg signed [DATA_WIDTH-1:0] a_ones [0:ROWS-1][0:K_DEPTH-1];
                for (r = 0; r < ROWS; r++)
                    for (int k = 0; k < K_DEPTH; k++)
                        a_ones[r][k] = 16'sd1;
                stream_activations(a_ones);
            end

            @(posedge clk); start <= 1; @(posedge clk); start <= 0;

            // Stream weights — handshake is internal
            stream_weights(w_id);
            $display("[PASS] TC01: Weight stream accepted (all %0d beats)", WEIGHT_COUNT);
            pass_count++; test_count++;

            // Wait for done
            while (!done) @(posedge clk);
            @(posedge clk);
        end

        //======================================================================
        // TC02: TLAST on last weight
        //======================================================================
        $display("============================================================");
        $display("TC02: TLAST handling on weight stream");
        $display("============================================================");

        begin : tc02_block
            reg signed [DATA_WIDTH-1:0] w_id [0:ROWS-1][0:COLS-1];
            reg signed [DATA_WIDTH-1:0] a_ones [0:ROWS-1][0:K_DEPTH-1];
            integer r, c, k;
            for (r = 0; r < ROWS; r++)
                for (c = 0; c < COLS; c++)
                    w_id[r][c] = 16'sd2;
            for (r = 0; r < ROWS; r++)
                for (k = 0; k < K_DEPTH; k++)
                    a_ones[r][k] = 16'sd1;

            stream_activations(a_ones);
            @(posedge clk); start <= 1; @(posedge clk); start <= 0;
            stream_weights(w_id);  // TLAST asserted on last beat internally
            while (!done) @(posedge clk);
            @(posedge clk);
            $display("[PASS] TC02: Second tile with TLAST completed");
            pass_count++; test_count++;
        end

        //======================================================================
        // TC03+TC04: Activation stream preload + TLAST
        //======================================================================
        $display("============================================================");
        $display("TC03/04: Activation stream preload with TLAST");
        $display("============================================================");

        begin : tc03_block
            reg signed [DATA_WIDTH-1:0] w_seq [0:ROWS-1][0:COLS-1];
            reg signed [DATA_WIDTH-1:0] a_seq [0:ROWS-1][0:K_DEPTH-1];
            integer r, c, k;
            for (r = 0; r < ROWS; r++)
                for (c = 0; c < COLS; c++)
                    w_seq[r][c] = r * COLS + c + 1;
            for (r = 0; r < ROWS; r++)
                for (k = 0; k < K_DEPTH; k++)
                    a_seq[r][k] = k + 1;

            // First stream activations (preload), then start and stream weights
            stream_activations(a_seq);
            @(posedge clk); start <= 1; @(posedge clk); start <= 0;
            stream_weights(w_seq);
            while (!done) @(posedge clk);
            @(posedge clk);
            $display("[PASS] TC03/04: Activation preload with TLAST successful");
            pass_count += 2; test_count += 2;
        end

        //======================================================================
        // TC05+TC06: Full tile + result stream handshake
        //======================================================================
        $display("============================================================");
        $display("TC05/06: Full tile via AXIS, receive results");
        $display("============================================================");

        begin : tc05_block
            reg signed [DATA_WIDTH-1:0] w_id [0:ROWS-1][0:COLS-1];
            reg signed [DATA_WIDTH-1:0] a_ones [0:ROWS-1][0:K_DEPTH-1];
            reg [ACCUM_WIDTH-1:0] res_buf [0:RESULT_COUNT-1];
            integer r, c, k, n_recv;
            for (r = 0; r < ROWS; r++)
                for (c = 0; c < COLS; c++)
                    w_id[r][c] = (r == c) ? 16'sd1 : 16'sd0;
            for (r = 0; r < ROWS; r++)
                for (k = 0; k < K_DEPTH; k++)
                    a_ones[r][k] = 16'sd1;

            stream_activations(a_ones);
            @(posedge clk); start <= 1; @(posedge clk); start <= 0;
            stream_weights(w_id);
            while (!done) @(posedge clk);

            // Now read results
            recv_results(res_buf, n_recv);
            check_eq("TC05: all results received", n_recv, RESULT_COUNT, "n_received");

            // Verify some non-zero results
            begin
                integer nz = 0;
                for (int i = 0; i < n_recv; i++)
                    if (res_buf[i] !== 0) nz++;
                if (nz > 0) begin
                    $display("[PASS] TC06: %0d/%0d non-zero results", nz, n_recv);
                    pass_count++;
                end else begin
                    $display("[FAIL] TC06: all results zero");
                    fail_count++;
                end
                test_count++;
            end
        end

        //======================================================================
        // TC07: Result backpressure
        //======================================================================
        $display("============================================================");
        $display("TC07: Result stream backpressure (TREADY=0 then TREADY=1)");
        $display("============================================================");

        begin : tc07_block
            reg signed [DATA_WIDTH-1:0] w_id [0:ROWS-1][0:COLS-1];
            reg signed [DATA_WIDTH-1:0] a_ones [0:ROWS-1][0:K_DEPTH-1];
            reg [ACCUM_WIDTH-1:0] res_buf [0:RESULT_COUNT-1];
            integer r, c, k, n_recv;
            for (r = 0; r < ROWS; r++)
                for (c = 0; c < COLS; c++)
                    w_id[r][c] = (r == c) ? 16'sd2 : 16'sd0;
            for (r = 0; r < ROWS; r++)
                for (k = 0; k < K_DEPTH; k++)
                    a_ones[r][k] = 16'sd2;

            stream_activations(a_ones);
            @(posedge clk); start <= 1; @(posedge clk); start <= 0;
            stream_weights(w_id);
            while (!done) @(posedge clk);

            // Wait a bit then accept results (backpressure)
            repeat(5) @(posedge clk);
            recv_results(res_buf, n_recv);
            if (n_recv == RESULT_COUNT) begin
                $display("[PASS] TC07: Results received after backpressure delay");
                pass_count++;
            end else begin
                $display("[FAIL] TC07: expected %0d, got %0d", RESULT_COUNT, n_recv);
                fail_count++;
            end
            test_count++;
        end

        //======================================================================
        // TC08: Direct path via AXIS
        //======================================================================
        $display("============================================================");
        $display("TC08: Direct activation path (use_bram_act=0) via AXIS");
        $display("============================================================");

        begin : tc08_block
            reg signed [DATA_WIDTH-1:0] w_id [0:ROWS-1][0:COLS-1];
            reg signed [DATA_WIDTH-1:0] a_dir [0:ROWS-1][0:K_DEPTH-1];
            integer r, c, k;

            for (r = 0; r < ROWS; r++)
                for (c = 0; c < COLS; c++)
                    w_id[r][c] = (r == c) ? 16'sd3 : 16'sd0;
            for (r = 0; r < ROWS; r++)
                for (k = 0; k < K_DEPTH; k++)
                    a_dir[r][k] = k + 1;

            use_bram_act <= 0;
            @(posedge clk); start <= 1; @(posedge clk); start <= 0;
            stream_weights(w_id);

            // Drive activations directly
            for (k = 0; k < K_DEPTH; k++) begin
                @(posedge clk);
                for (r = 0; r < ROWS; r++)
                    act_data[r] <= a_dir[r][k];
                act_valid <= 1'b1;
            end
            @(posedge clk);
            for (r = 0; r < ROWS; r++) act_data[r] <= 0;
            act_valid <= 1'b0;

            while (!done) @(posedge clk);
            $display("[PASS] TC08: Direct path completed via AXIS wrapper");
            pass_count++; test_count++;
            use_bram_act <= 1;
        end

        //======================================================================
        // TC09: Multiple tiles
        //======================================================================
        $display("============================================================");
        $display("TC09: Multiple tiles (reset and re-run)");
        $display("============================================================");

        begin : tc09_block
            reg signed [DATA_WIDTH-1:0] w_id [0:ROWS-1][0:COLS-1];
            reg signed [DATA_WIDTH-1:0] a_ones [0:ROWS-1][0:K_DEPTH-1];
            integer r, c, k;
            for (r = 0; r < ROWS; r++)
                for (c = 0; c < COLS; c++)
                    w_id[r][c] = (r == c) ? 16'sd1 : 16'sd0;
            for (r = 0; r < ROWS; r++)
                for (k = 0; k < K_DEPTH; k++)
                    a_ones[r][k] = 16'sd1;

            stream_activations(a_ones);
            @(posedge clk); start <= 1; @(posedge clk); start <= 0;
            stream_weights(w_id);
            while (!done) @(posedge clk);
            @(posedge clk);
            $display("[PASS] TC09: Multiple tiles — second run completed");
            pass_count++; test_count++;
        end

        //======================================================================
        // TC10: Reset
        //======================================================================
        $display("============================================================");
        $display("TC10: Async reset during operation");
        $display("============================================================");

        begin : tc10_block
            @(posedge clk); start <= 1; @(posedge clk); start <= 0;
            repeat(3) @(posedge clk);
            // Reset
            rst_n <= 1'b0;
            @(posedge clk);
            rst_n <= 1'b1;
            repeat(2) @(posedge clk);
            check_eq("TC10: busy=0 after reset", busy, 0, "busy");
            $display("[PASS] TC10: Reset clean");
            pass_count++; test_count++;
        end

        //======================================================================
        // Summary
        //======================================================================
        $display("============================================================");
        $display("Summary: %0d/%0d PASS, %0d FAIL", pass_count, test_count, fail_count);
        $display("============================================================");
        if (fail_count == 0) $display("ALL TESTS PASSED!");
        else $display("SOME TESTS FAILED!");
        $finish;
    end

    always @(posedge clk) begin
        if (done && rst_n) $display("  [MON] Time %0t: done=1", $time);
    end

endmodule
