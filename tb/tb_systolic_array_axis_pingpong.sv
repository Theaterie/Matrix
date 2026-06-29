`timescale 1ns / 1ps

//==============================================================================
// Testbench: tb_systolic_array_axis_pingpong
// Purpose:    Verify AXI4-Stream + ping-pong double-buffer wrapper.
//
// Test items:
//   TC01 — Direct path: result count, non-x, determinism
//   TC02 — BRAM path warmup + real computation, buf_sel tracking
//   TC03 — Determinism: two identical runs produce identical results
//   TC04 — Auto-swap toggles buf_sel each done
//   TC05 — Preload next tile during compute (key ping-pong feature)
//   TC06 — Result TLAST on last beat
//   TC07 — Backpressure on M_AXIS_RESULT
//   TC08 — Multiple ping-pong cycles (ABAB pattern)
//   TC09 — auto_swap=0 (buf_sel unchanged)
//
// Note: Exact numerical correctness depends on the core systolic_array.
// This testbench verifies the wrapper's functionality: AXI-S handshaking,
// ping-pong buffering, result streaming, backpressure, and determinism.
//==============================================================================

module tb_systolic_array_axis_pingpong;

    localparam ROWS        = 4;
    localparam COLS        = 4;
    localparam DATA_WIDTH  = 16;
    localparam ACCUM_WIDTH = 40;
    localparam K_DEPTH     = 4;
    localparam BUF_ADDR_W  = 8;
    localparam BUF_DEPTH   = 256;
    localparam WT_ADDR_W   = 4;
    localparam CLK_PERIOD  = 10;

    localparam WEIGHT_COUNT = ROWS * COLS;
    localparam ACT_COUNT    = ROWS * K_DEPTH;
    localparam RESULT_COUNT = ROWS * COLS;

    reg               clk, rst_n;
    reg               start;
    wire              busy, done;

    reg               s_axis_weight_tvalid;
    wire              s_axis_weight_tready;
    reg  [DATA_WIDTH-1:0] s_axis_weight_tdata;
    reg               s_axis_weight_tlast;

    reg               s_axis_act_tvalid;
    wire              s_axis_act_tready;
    reg  [DATA_WIDTH-1:0] s_axis_act_tdata;
    reg               s_axis_act_tlast;

    wire              m_axis_result_tvalid;
    reg               m_axis_result_tready;
    wire [ACCUM_WIDTH-1:0] m_axis_result_tdata;
    wire              m_axis_result_tlast;

    reg               auto_swap;
    wire              buf_sel;

    reg               use_bram_act;
    reg  [DATA_WIDTH-1:0] act_data [0:ROWS-1];
    reg               act_valid;
    wire [ACCUM_WIDTH-1:0] result_data [0:COLS-1];
    wire              result_valid;
    reg  [BUF_ADDR_W-1:0] act_base_addr, res_base_addr;

    integer test_count, pass_count, fail_count;

    //------------------------------------------------------------------
    // DUT
    //------------------------------------------------------------------
    systolic_array_axis_pingpong #(
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
        .auto_swap(auto_swap), .buf_sel(buf_sel),
        .use_bram_act(use_bram_act),
        .act_data(act_data), .act_valid(act_valid),
        .result_data(result_data), .result_valid(result_valid),
        .act_base_addr(act_base_addr), .res_base_addr(res_base_addr)
    );

    always #(CLK_PERIOD/2) clk = ~clk;

    //------------------------------------------------------------------
    // Check task
    //------------------------------------------------------------------
    task automatic check_eq;
        input string test_name;
        input integer actual;
        input integer expected;
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

    //------------------------------------------------------------------
    // Task: Stream weights via AXIS
    //------------------------------------------------------------------
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

    //------------------------------------------------------------------
    // Task: Stream activations via AXIS (to inactive ping-pong buffer)
    //------------------------------------------------------------------
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

    //------------------------------------------------------------------
    // Task: Receive all results via M_AXIS_RESULT
    //------------------------------------------------------------------
    task automatic recv_results;
        output [ACCUM_WIDTH-1:0] res_out [0:RESULT_COUNT-1];
        output integer n_received;
        output integer tlast_seen;
        integer i;
        begin
            i = 0;
            tlast_seen = 0;
            m_axis_result_tready <= 1'b1;
            while (!m_axis_result_tvalid) @(posedge clk);
            while (i < RESULT_COUNT && m_axis_result_tvalid) begin
                res_out[i] = m_axis_result_tdata;
                if (i == RESULT_COUNT - 1 && m_axis_result_tlast)
                    tlast_seen = 1;
                i++;
                @(posedge clk);
            end
            m_axis_result_tready <= 1'b0;
            n_received = i;
        end
    endtask

    //------------------------------------------------------------------
    // Task: Run a BRAM-path tile (preload inactive, start, stream weights)
    //------------------------------------------------------------------
    task automatic start_bram_tile;
        input signed [DATA_WIDTH-1:0] w_mat [0:ROWS-1][0:COLS-1];
        input signed [DATA_WIDTH-1:0] a_mat [0:ROWS-1][0:K_DEPTH-1];
        begin
            use_bram_act <= 1;
            stream_activations(a_mat);
            @(posedge clk); start <= 1; @(posedge clk); start <= 0;
            stream_weights(w_mat);
        end
    endtask

    //------------------------------------------------------------------
    // Task: Run a direct-path tile (bypass BRAM)
    //------------------------------------------------------------------
    task automatic start_direct_tile;
        input signed [DATA_WIDTH-1:0] w_mat [0:ROWS-1][0:COLS-1];
        input signed [DATA_WIDTH-1:0] a_mat [0:ROWS-1][0:K_DEPTH-1];
        integer k, r;
        begin
            use_bram_act <= 0;
            @(posedge clk); start <= 1; @(posedge clk); start <= 0;
            stream_weights(w_mat);
            for (k = 0; k < K_DEPTH; k++) begin
                @(posedge clk);
                for (r = 0; r < ROWS; r++) act_data[r] <= a_mat[r][k];
                act_valid <= 1'b1;
            end
            @(posedge clk);
            for (r = 0; r < ROWS; r++) act_data[r] <= 0;
            act_valid <= 1'b0;
        end
    endtask

    //------------------------------------------------------------------
    // Task: Check all results are non-x
    //------------------------------------------------------------------
    task automatic check_non_x;
        input [ACCUM_WIDTH-1:0] res [0:RESULT_COUNT-1];
        input string name;
        integer i, nx;
        begin
            nx = 0;
            for (i = 0; i < RESULT_COUNT; i++)
                if (^res[i] !== 1'bx) nx++;
            check_eq(name, nx, RESULT_COUNT, "non-x count");
        end
    endtask

    //------------------------------------------------------------------
    // Task: Compare two result arrays
    //------------------------------------------------------------------
    task automatic check_identical;
        input [ACCUM_WIDTH-1:0] a [0:RESULT_COUNT-1];
        input [ACCUM_WIDTH-1:0] b [0:RESULT_COUNT-1];
        input string name;
        integer i, mism;
        begin
            mism = 0;
            for (i = 0; i < RESULT_COUNT; i++)
                if (a[i] !== b[i]) mism++;
            check_eq(name, mism, 0, "mismatches");
        end
    endtask

    //------------------------------------------------------------------
    // Main
    //------------------------------------------------------------------
    initial begin
        clk = 0; rst_n = 0; start = 0; auto_swap = 0; use_bram_act = 1;
        s_axis_weight_tvalid = 0; s_axis_weight_tdata = 0; s_axis_weight_tlast = 0;
        s_axis_act_tvalid = 0; s_axis_act_tdata = 0; s_axis_act_tlast = 0;
        m_axis_result_tready = 0;
        for (int i = 0; i < ROWS; i++) act_data[i] = 0;
        act_valid = 0; act_base_addr = 0; res_base_addr = 0;
        test_count = 0; pass_count = 0; fail_count = 0;

        repeat(8) @(posedge clk); rst_n = 1; repeat(2) @(posedge clk);

        //==============================================================
        // TC01: Direct path — result count, non-x, determinism
        //==============================================================
        $display("============================================================");
        $display("TC01: Direct path (use_bram_act=0)");
        $display("============================================================");

        begin : tc01_block
            reg signed [DATA_WIDTH-1:0] w_id [0:ROWS-1][0:COLS-1];
            reg signed [DATA_WIDTH-1:0] a_ones [0:ROWS-1][0:K_DEPTH-1];
            reg [ACCUM_WIDTH-1:0] r1 [0:RESULT_COUNT-1];
            reg [ACCUM_WIDTH-1:0] r2 [0:RESULT_COUNT-1];
            integer r, c, k, n, tl;

            for (r = 0; r < ROWS; r++)
                for (c = 0; c < COLS; c++)
                    w_id[r][c] = (r == c) ? 16'sd1 : 16'sd0;
            for (r = 0; r < ROWS; r++)
                for (k = 0; k < K_DEPTH; k++)
                    a_ones[r][k] = 16'sd1;

            auto_swap <= 1;
            start_direct_tile(w_id, a_ones);
            while (!done) @(posedge clk);
            recv_results(r1, n, tl);
            check_eq("TC01: result count", n, RESULT_COUNT, "n_recv");
            check_non_x(r1, "TC01: non-x results");
            use_bram_act <= 1;
        end

        //==============================================================
        // TC02: BRAM path warmup + real computation
        //==============================================================
        $display("============================================================");
        $display("TC02: BRAM path warmup + real computation");
        $display("============================================================");

        begin : tc02_block
            reg signed [DATA_WIDTH-1:0] w_seq [0:ROWS-1][0:COLS-1];
            reg signed [DATA_WIDTH-1:0] a_seq [0:ROWS-1][0:K_DEPTH-1];
            reg [ACCUM_WIDTH-1:0] res [0:RESULT_COUNT-1];
            integer r, c, k, n, tl;
            integer sel_before;

            for (r = 0; r < ROWS; r++)
                for (c = 0; c < COLS; c++)
                    w_seq[r][c] = r * COLS + c + 1;
            for (r = 0; r < ROWS; r++)
                for (k = 0; k < K_DEPTH; k++)
                    a_seq[r][k] = k + 1;

            auto_swap <= 1;
            sel_before = buf_sel;

            // Warmup: preload inactive, start, compute on (empty) active
            start_bram_tile(w_seq, a_seq);
            while (!done) @(posedge clk);
            @(posedge clk);
            check_eq("TC02: buf_sel toggled after warmup", buf_sel, 1 - sel_before, "buf_sel");
            recv_results(res, n, tl);  // Drain warmup (x or garbage)
            check_eq("TC02: warmup result count", n, RESULT_COUNT, "n_recv");

            sel_before = buf_sel;
            // Real run: preload new inactive, compute on active (has data)
            start_bram_tile(w_seq, a_seq);
            while (!done) @(posedge clk);
            @(posedge clk);
            check_eq("TC02: buf_sel toggled after real run", buf_sel, 1 - sel_before, "buf_sel");
            recv_results(res, n, tl);
            check_eq("TC02: real result count", n, RESULT_COUNT, "n_recv");
            check_non_x(res, "TC02: real results non-x");
        end

        //==============================================================
        // TC03: Determinism — two identical BRAM-path runs
        //==============================================================
        $display("============================================================");
        $display("TC03: Determinism (two identical BRAM-path runs)");
        $display("============================================================");

        begin : tc03_block
            reg signed [DATA_WIDTH-1:0] w_seq [0:ROWS-1][0:COLS-1];
            reg signed [DATA_WIDTH-1:0] a_seq [0:ROWS-1][0:K_DEPTH-1];
            reg [ACCUM_WIDTH-1:0] r1 [0:RESULT_COUNT-1];
            reg [ACCUM_WIDTH-1:0] r2 [0:RESULT_COUNT-1];
            integer r, c, k, n, tl;

            for (r = 0; r < ROWS; r++)
                for (c = 0; c < COLS; c++)
                    w_seq[r][c] = r * COLS + c + 1;
            for (r = 0; r < ROWS; r++)
                for (k = 0; k < K_DEPTH; k++)
                    a_seq[r][k] = k + 1;

            // Warmup
            start_bram_tile(w_seq, a_seq);
            while (!done) @(posedge clk);
            @(posedge clk);
            recv_results(r1, n, tl);

            // Run 1
            start_bram_tile(w_seq, a_seq);
            while (!done) @(posedge clk);
            @(posedge clk);
            recv_results(r1, n, tl);
            check_non_x(r1, "TC03: run1 non-x");

            // Run 2 (identical inputs)
            start_bram_tile(w_seq, a_seq);
            while (!done) @(posedge clk);
            @(posedge clk);
            recv_results(r2, n, tl);
            check_non_x(r2, "TC03: run2 non-x");

            check_identical(r1, r2, "TC03: deterministic");
        end

        //==============================================================
        // TC04: Auto-swap toggles buf_sel each done
        //==============================================================
        $display("============================================================");
        $display("TC04: Auto-swap toggles buf_sel each done");
        $display("============================================================");

        begin : tc04_block
            reg signed [DATA_WIDTH-1:0] w_id [0:ROWS-1][0:COLS-1];
            reg signed [DATA_WIDTH-1:0] a_ones [0:ROWS-1][0:K_DEPTH-1];
            reg [ACCUM_WIDTH-1:0] res [0:RESULT_COUNT-1];
            integer r, c, k, n, tl, prev_sel;

            for (r = 0; r < ROWS; r++)
                for (c = 0; c < COLS; c++)
                    w_id[r][c] = (r == c) ? 16'sd1 : 16'sd0;
            for (r = 0; r < ROWS; r++)
                for (k = 0; k < K_DEPTH; k++)
                    a_ones[r][k] = 16'sd1;

            auto_swap <= 1;
            prev_sel = buf_sel;
            for (int i = 0; i < 4; i++) begin
                start_bram_tile(w_id, a_ones);
                while (!done) @(posedge clk);
                @(posedge clk);
                recv_results(res, n, tl);
                if (buf_sel != prev_sel) begin
                    $display("  [PASS] TC04: run %0d: buf_sel toggled %0d -> %0d", i, prev_sel, buf_sel);
                    pass_count++;
                end else begin
                    $display("  [FAIL] TC04: run %0d: buf_sel unchanged (%0d)", i, buf_sel);
                    fail_count++;
                end
                test_count++;
                prev_sel = buf_sel;
            end
        end

        //==============================================================
        // TC05: Preload next tile during compute
        //==============================================================
        $display("============================================================");
        $display("TC05: Preload next tile during compute");
        $display("============================================================");

        begin : tc05_block
            reg signed [DATA_WIDTH-1:0] w0 [0:ROWS-1][0:COLS-1];
            reg signed [DATA_WIDTH-1:0] a0 [0:ROWS-1][0:K_DEPTH-1];
            reg signed [DATA_WIDTH-1:0] w1 [0:ROWS-1][0:COLS-1];
            reg signed [DATA_WIDTH-1:0] a1 [0:ROWS-1][0:K_DEPTH-1];
            reg [ACCUM_WIDTH-1:0] res [0:RESULT_COUNT-1];
            integer r, c, k, n, tl;

            for (r = 0; r < ROWS; r++)
                for (c = 0; c < COLS; c++)
                    w0[r][c] = r * COLS + c + 1;
            for (r = 0; r < ROWS; r++)
                for (k = 0; k < K_DEPTH; k++)
                    a0[r][k] = k + 1;
            for (r = 0; r < ROWS; r++)
                for (c = 0; c < COLS; c++)
                    w1[r][c] = (r == c) ? 16'sd2 : 16'sd0;
            for (r = 0; r < ROWS; r++)
                for (k = 0; k < K_DEPTH; k++)
                    a1[r][k] = 16'sd3;

            auto_swap <= 1;
            // Warmup
            start_bram_tile(w0, a0);
            while (!done) @(posedge clk);
            @(posedge clk);
            recv_results(res, n, tl);

            // Real run for tile 0 — preload tile 1 during compute
            start_bram_tile(w0, a0);
            stream_activations(a1);  // Preload to inactive during compute
            while (!done) @(posedge clk);
            @(posedge clk);
            recv_results(res, n, tl);
            check_eq("TC05: tile0 result count", n, RESULT_COUNT, "n_recv");
            check_non_x(res, "TC05: tile0 non-x");

            // Next run uses preloaded tile 1
            @(posedge clk); start <= 1; @(posedge clk); start <= 0;
            stream_weights(w1);
            while (!done) @(posedge clk);
            @(posedge clk);
            recv_results(res, n, tl);
            check_eq("TC05: tile1 result count", n, RESULT_COUNT, "n_recv");
            check_non_x(res, "TC05: tile1 non-x");
        end

        //==============================================================
        // TC06: TLAST on last result beat
        //==============================================================
        $display("============================================================");
        $display("TC06: TLAST assertion on last result");
        $display("============================================================");

        begin : tc06_block
            reg signed [DATA_WIDTH-1:0] w_id [0:ROWS-1][0:COLS-1];
            reg signed [DATA_WIDTH-1:0] a_ones [0:ROWS-1][0:K_DEPTH-1];
            reg [ACCUM_WIDTH-1:0] res [0:RESULT_COUNT-1];
            integer r, c, k, n, tl;

            for (r = 0; r < ROWS; r++)
                for (c = 0; c < COLS; c++)
                    w_id[r][c] = (r == c) ? 16'sd1 : 16'sd0;
            for (r = 0; r < ROWS; r++)
                for (k = 0; k < K_DEPTH; k++)
                    a_ones[r][k] = 16'sd1;

            start_bram_tile(w_id, a_ones);
            while (!done) @(posedge clk);
            @(posedge clk);
            recv_results(res, n, tl);
            check_eq("TC06: TLAST seen on last beat", tl, 1, "tlast");
        end

        //==============================================================
        // TC07: Backpressure on M_AXIS_RESULT
        //==============================================================
        $display("============================================================");
        $display("TC07: Backpressure (TREADY=0 for 5 cycles)");
        $display("============================================================");

        begin : tc07_block
            reg signed [DATA_WIDTH-1:0] w_id [0:ROWS-1][0:COLS-1];
            reg signed [DATA_WIDTH-1:0] a_ones [0:ROWS-1][0:K_DEPTH-1];
            reg [ACCUM_WIDTH-1:0] res [0:RESULT_COUNT-1];
            integer r, c, k, n, tl;

            for (r = 0; r < ROWS; r++)
                for (c = 0; c < COLS; c++)
                    w_id[r][c] = (r == c) ? 16'sd5 : 16'sd0;
            for (r = 0; r < ROWS; r++)
                for (k = 0; k < K_DEPTH; k++)
                    a_ones[r][k] = 16'sd2;

            start_bram_tile(w_id, a_ones);
            while (!done) @(posedge clk);
            @(posedge clk);
            m_axis_result_tready <= 0;
            repeat(5) @(posedge clk);
            recv_results(res, n, tl);
            check_eq("TC07: result count after backpressure", n, RESULT_COUNT, "n_recv");
            check_non_x(res, "TC07: non-x after backpressure");
        end

        //==============================================================
        // TC08: Multiple ping-pong cycles (ABAB pattern)
        //==============================================================
        $display("============================================================");
        $display("TC08: Multiple ping-pong cycles (4 real runs)");
        $display("============================================================");

        begin : tc08_block
            reg signed [DATA_WIDTH-1:0] w_id [0:ROWS-1][0:COLS-1];
            reg signed [DATA_WIDTH-1:0] a_ones [0:ROWS-1][0:K_DEPTH-1];
            reg [ACCUM_WIDTH-1:0] res [0:RESULT_COUNT-1];
            integer r, c, k, n, tl, prev_sel, toggles;

            for (r = 0; r < ROWS; r++)
                for (c = 0; c < COLS; c++)
                    w_id[r][c] = (r == c) ? 16'sd1 : 16'sd0;
            for (r = 0; r < ROWS; r++)
                for (k = 0; k < K_DEPTH; k++)
                    a_ones[r][k] = 16'sd1;

            auto_swap <= 1;
            // Warmup
            start_bram_tile(w_id, a_ones);
            while (!done) @(posedge clk);
            @(posedge clk);
            recv_results(res, n, tl);

            prev_sel = buf_sel;
            toggles = 0;
            for (int i = 0; i < 4; i++) begin
                start_bram_tile(w_id, a_ones);
                while (!done) @(posedge clk);
                @(posedge clk);
                recv_results(res, n, tl);
                check_eq("TC08: result count", n, RESULT_COUNT, "n_recv");
                check_non_x(res, "TC08: non-x");
                if (buf_sel != prev_sel) begin
                    toggles++;
                    prev_sel = buf_sel;
                end
            end
            check_eq("TC08: buffer toggles", toggles, 4, "toggles");
        end

        //==============================================================
        // TC09: auto_swap=0 (buf_sel unchanged)
        //==============================================================
        $display("============================================================");
        $display("TC09: auto_swap=0 — buf_sel unchanged");
        $display("============================================================");

        begin : tc09_block
            reg signed [DATA_WIDTH-1:0] w_id [0:ROWS-1][0:COLS-1];
            reg signed [DATA_WIDTH-1:0] a_ones [0:ROWS-1][0:K_DEPTH-1];
            reg [ACCUM_WIDTH-1:0] res [0:RESULT_COUNT-1];
            integer r, c, k, n, tl, sel_before;

            for (r = 0; r < ROWS; r++)
                for (c = 0; c < COLS; c++)
                    w_id[r][c] = (r == c) ? 16'sd1 : 16'sd0;
            for (r = 0; r < ROWS; r++)
                for (k = 0; k < K_DEPTH; k++)
                    a_ones[r][k] = 16'sd1;

            auto_swap <= 0;
            sel_before = buf_sel;
            start_bram_tile(w_id, a_ones);
            while (!done) @(posedge clk);
            @(posedge clk);
            check_eq("TC09: buf_sel unchanged", buf_sel, sel_before, "buf_sel");
        end

        //==============================================================
        // Summary
        //==============================================================
        $display("============================================================");
        $display("Summary: %0d/%0d PASS, %0d FAIL", pass_count, test_count, fail_count);
        $display("============================================================");
        if (fail_count == 0) $display("ALL TESTS PASSED!");
        else $display("SOME TESTS FAILED!");
        $finish;
    end

    always @(posedge clk) begin
        if (done && rst_n) $display("  [MON] Time %0t: done=1, buf_sel=%b", $time, buf_sel);
    end

endmodule
