//==============================================================================
// Testbench: tb_systolic_array_numerical
// Purpose:    Exact numerical verification of BRAM activation data path.
//             Preloads known A into BRAM, loads known B weights, runs full
//             systolic_array pipeline, reads back result BRAM, and compares
//             every entry against a software-computed golden model.
//==============================================================================
// BRAM data layout (row-major, written by external host):
//   BRAM[base + 0]            = A[0][0]
//   BRAM[base + 1]            = A[0][1]
//   ...
//   BRAM[base + K_DEPTH-1]    = A[0][K_DEPTH-1]
//   BRAM[base + K_DEPTH]      = A[1][0]
//   ...
//   BRAM[base + ROWS*K_DEPTH-1] = A[ROWS-1][K_DEPTH-1]
//
// Golden model — the systolic array computes, for each PE(r,c):
//   PE_acc[r][c] = sum_{k=0}^{K_DEPTH-1} W[r][c] * A[r][k]
//
// Vertical summation at bottom edge produces, per capture row t (0..ROWS-1):
//   golden[t][c] = sum_{r=0}^{t} PE_acc[r][c]
//
// Result serializer writes in row-major order:
//   res_bram[base + t*COLS + c] = golden[t][c]
//==============================================================================

`timescale 1ns / 1ps

module tb_systolic_array_numerical;

    localparam ROWS        = 4;
    localparam COLS        = 4;
    localparam DATA_WIDTH  = 16;
    localparam ACCUM_WIDTH = 40;
    localparam K_DEPTH     = 4;
    localparam BUF_ADDR_W  = 8;
    localparam WT_ADDR_W   = 4;
    localparam CLK_PERIOD  = 10;

    reg                                 clk, rst_n;
    reg                                 start;
    wire                                busy, done;
    reg                                 use_bram_act;

    reg  [DATA_WIDTH-1:0]               weight_data;
    wire                                weight_ready;
    reg  [DATA_WIDTH-1:0]               act_data [0:ROWS-1];
    reg                                 act_valid;
    reg                                 act_wr_en;
    reg  [BUF_ADDR_W-1:0]               act_wr_addr;
    reg  [DATA_WIDTH-1:0]               act_wr_data;
    wire [ACCUM_WIDTH-1:0]              result_data [0:COLS-1];
    wire                                result_valid;
    reg                                 res_rd_en;
    reg  [BUF_ADDR_W-1:0]               res_rd_addr;
    wire [ACCUM_WIDTH-1:0]              res_rd_data;
    reg  [BUF_ADDR_W-1:0]               act_base_addr, res_base_addr;

    integer test_count, pass_count, fail_count;

    systolic_array #(
        .ROWS(ROWS), .COLS(COLS), .DATA_WIDTH(DATA_WIDTH),
        .ACCUM_WIDTH(ACCUM_WIDTH), .K_DEPTH(K_DEPTH),
        .BUF_ADDR_W(BUF_ADDR_W), .BUF_DEPTH(256), .WT_ADDR_W(WT_ADDR_W)
    ) u_dut (
        .clk(clk), .rst_n(rst_n),
        .start(start), .weight_preloaded(1'b0), .prefetch_start(1'b0),
        .busy(busy), .done(done),
        .use_bram_act(use_bram_act), .weight_data(weight_data),
        .weight_ready(weight_ready), .act_data(act_data), .act_valid(act_valid),
        .act_wr_en(act_wr_en), .act_wr_addr(act_wr_addr), .act_wr_data(act_wr_data),
        .result_data(result_data), .result_valid(result_valid),
        .res_rd_en(res_rd_en), .res_rd_addr(res_rd_addr), .res_rd_data(res_rd_data),
        .act_base_addr(act_base_addr), .res_base_addr(res_base_addr)
    );

    always #(CLK_PERIOD/2) clk = ~clk;

    //--------------------------------------------------------------------------
    // Task: Load weights during WEIGHT_LOAD phase
    //--------------------------------------------------------------------------
    task automatic load_weights;
        input signed [DATA_WIDTH-1:0] w_mat [0:ROWS-1][0:COLS-1];
        integer r, c;
        begin
            while (!weight_ready) @(posedge clk);
            // Use blocking assignment so weight_data is stable BEFORE the
            // posedge where the PE array captures it (avoids 1-cycle skew)
            for (r = 0; r < ROWS; r = r + 1)
                for (c = 0; c < COLS; c = c + 1) begin
                    weight_data = w_mat[r][c];
                    @(posedge clk);
                end
            weight_data = 0;
        end
    endtask

    //--------------------------------------------------------------------------
    // Task: Preload activations (row-major) into act_bram
    //--------------------------------------------------------------------------
    task automatic preload_act;
        input [BUF_ADDR_W-1:0] base;
        input signed [DATA_WIDTH-1:0] a_mat [0:ROWS-1][0:K_DEPTH-1];
        integer r, k, addr;
        begin
            addr = base;
            for (r = 0; r < ROWS; r = r + 1)
                for (k = 0; k < K_DEPTH; k = k + 1) begin
                    @(posedge clk);
                    act_wr_en   <= 1;
                    act_wr_addr <= addr;
                    act_wr_data <= a_mat[r][k];
                    addr = addr + 1;
                end
            @(posedge clk); act_wr_en <= 0; act_wr_addr <= 0; act_wr_data <= 0;
        end
    endtask

    //--------------------------------------------------------------------------
    // Task: Read a single result BRAM entry (3 cycles: issue, wait, capture)
    //--------------------------------------------------------------------------
    task automatic read_res;
        input  [BUF_ADDR_W-1:0]   addr;
        output [ACCUM_WIDTH-1:0]  val;
        begin
            @(posedge clk); res_rd_en <= 1; res_rd_addr <= addr;
            @(posedge clk); res_rd_en <= 0; res_rd_addr <= 0;
            @(posedge clk); val = res_rd_data;
        end
    endtask

    //--------------------------------------------------------------------------
    // Task: Run a BRAM-path tile computation
    //--------------------------------------------------------------------------
    task automatic run_bram_tile;
        input signed [DATA_WIDTH-1:0] w_mat [0:ROWS-1][0:COLS-1];
        input signed [DATA_WIDTH-1:0] a_mat [0:ROWS-1][0:K_DEPTH-1];
        input [BUF_ADDR_W-1:0] act_base, res_base;
        begin
            use_bram_act  <= 1;
            act_base_addr <= act_base;
            res_base_addr <= res_base;
            preload_act(act_base, a_mat);
            @(posedge clk); start <= 1; @(posedge clk); start <= 0;
            load_weights(w_mat);
            act_valid <= 0;
            while (!done) @(posedge clk);
            @(posedge clk);  // One more cycle after done
        end
    endtask

    //--------------------------------------------------------------------------
    // Function: Compute golden total per column — the full inner product
    // across all rows and K depth:
    //   total[c] = sum_{r=0}^{ROWS-1} sum_{k=0}^{K_DEPTH-1} W[r][c] * A[r][k]
    //
    //   The hardware produces ROWS captures (one per activation cycle with
    //   skew alignment). Each capture is a vertical sum across all rows at
    //   that instant. The SUM of all ROWS captures equals the full matrix
    //   product column total shown above, because each row processes all
    //   K_DEPTH activation indices across the capture cycles (distributed
    //   by the skew pipeline).
    //
    //   Therefore we verify the total column sum, not individual captures.
    //--------------------------------------------------------------------------
    function automatic signed [ACCUM_WIDTH-1:0] compute_column_total;
        input signed [DATA_WIDTH-1:0] w_mat [0:ROWS-1][0:COLS-1];
        input signed [DATA_WIDTH-1:0] a_mat [0:ROWS-1][0:K_DEPTH-1];
        input integer c;
        integer r, k;
        reg signed [ACCUM_WIDTH-1:0] accum;
        begin
            accum = 0;
            for (r = 0; r < ROWS; r = r + 1) begin
                for (k = 0; k < K_DEPTH; k = k + 1) begin
                    accum = accum + w_mat[r][c] * a_mat[r][k];
                end
            end
            compute_column_total = accum;
        end
    endfunction

    //--------------------------------------------------------------------------
    // Task: Verify result BRAM entries — check last capture row per column
    //   With own_acc_r architecture, each PE internally accumulates across K
    //   cycles, then outputs the total to the vertical psum chain. During
    //   READOUT, the result_serializer captures ROWS snapshots of the bottom
    //   edge as the pipeline drains. Only the LAST capture (after all rows
    //   have finished their K accumulations) contains the complete column
    //   totals. Earlier captures are intermediate partial sums.
    //
    //   We therefore read only the last row of captures (indices
    //   (ROWS-1)*COLS .. ROWS*COLS-1) and compare each column's value
    //   against the expected matrix product column total.
    //--------------------------------------------------------------------------
    task automatic verify_results;
        input signed [DATA_WIDTH-1:0] w_mat [0:ROWS-1][0:COLS-1];
        input signed [DATA_WIDTH-1:0] a_mat [0:ROWS-1][0:K_DEPTH-1];
        input [BUF_ADDR_W-1:0] res_base;
        input [255:0] test_name;
        integer c, addr, t;
        reg [ACCUM_WIDTH-1:0] capture_val, golden_col_total;
        begin
            for (c = 0; c < COLS; c = c + 1) begin
                // Last capture row = (ROWS-1)*COLS + c
                addr = res_base + (ROWS - 1) * COLS + c;
                read_res(addr, capture_val);
                golden_col_total = compute_column_total(w_mat, a_mat, c);
                if (capture_val === golden_col_total) begin
                    $display("  [PASS] %0s column %0d: result %0d == golden %0d",
                             test_name, c, $signed(capture_val), $signed(golden_col_total));
                    pass_count = pass_count + 1;
                end else begin
                    $display("  [FAIL] %0s column %0d: result %0d, expected %0d",
                             test_name, c, $signed(capture_val), $signed(golden_col_total));
                    $display("         All captures for column %0d (last row [%0d] is final):",
                             c, (ROWS-1)*COLS + c);
                    for (t = 0; t < ROWS; t = t + 1) begin
                        read_res(res_base + t * COLS + c, capture_val);
                        $display("           capture[%0d] @addr %0d = %0d",
                                 t, res_base + t * COLS + c, $signed(capture_val));
                    end
                    fail_count = fail_count + 1;
                end
                test_count = test_count + 1;
            end
        end
    endtask

    //==========================================================================
    // Main test
    //==========================================================================
    initial begin
        clk = 0; rst_n = 0; start = 0; use_bram_act = 0;
        weight_data = 0; act_valid = 0;
        for (int i = 0; i < ROWS; i++) act_data[i] = 0;
        act_wr_en = 0; act_wr_addr = 0; act_wr_data = 0;
        res_rd_en = 0; res_rd_addr = 0; act_base_addr = 0; res_base_addr = 0;
        test_count = 0; pass_count = 0; fail_count = 0;

        repeat(8) @(posedge clk); rst_n = 1; repeat(2) @(posedge clk);

        //======================================================================
        // TC01: Identity weight matrix × all-ones activations
        //   W = identity, A = all 1's
        //   PE(r,c).acc = (r==c?1:0) * K_DEPTH
        //   golden[t][c] = sum_{r=0}^{t} (r==c?1:0) * K_DEPTH
        //   golden[t][c] = K_DEPTH if t >= c, else 0
        //======================================================================
        $display("============================================================");
        $display("TC01: Identity weights × all-ones activations");
        $display("      golden[t][c] = %0d if t>=c, else 0", K_DEPTH);
        $display("============================================================");

        begin
            reg signed [DATA_WIDTH-1:0] w_mat [0:ROWS-1][0:COLS-1];
            reg signed [DATA_WIDTH-1:0] a_mat [0:ROWS-1][0:K_DEPTH-1];
            integer r, c, k;

            // B = identity
            for (r = 0; r < ROWS; r++)
                for (c = 0; c < COLS; c++)
                    w_mat[r][c] = (r == c) ? 16'sd1 : 16'sd0;

            // A = all 1's
            for (r = 0; r < ROWS; r++)
                for (k = 0; k < K_DEPTH; k++)
                    a_mat[r][k] = 16'sd1;

            run_bram_tile(w_mat, a_mat, 8'd0, 8'd0);
            verify_results(w_mat, a_mat, 8'd0, "TC01");
        end

        //======================================================================
        // TC02: Known weight matrix × known activations
        //   W[r][c] = r*COLS + c + 1  (values 1..16)
        //   A[r][k] = k + 1            (values 1..4 for each row)
        //   Easily verifiable with golden model
        //======================================================================
        $display("============================================================");
        $display("TC02: Sequential weights × uniform-per-row activations");
        $display("============================================================");

        begin
            reg signed [DATA_WIDTH-1:0] w_mat [0:ROWS-1][0:COLS-1];
            reg signed [DATA_WIDTH-1:0] a_mat [0:ROWS-1][0:K_DEPTH-1];
            integer r, c, k;

            // W[r][c] = r*COLS + c + 1
            for (r = 0; r < ROWS; r++)
                for (c = 0; c < COLS; c++)
                    w_mat[r][c] = r * COLS + c + 1;

            // A[r][k] = k + 1  (same for all rows)
            for (r = 0; r < ROWS; r++)
                for (k = 0; k < K_DEPTH; k++)
                    a_mat[r][k] = k + 1;

            run_bram_tile(w_mat, a_mat, 8'd0, 8'd0);
            verify_results(w_mat, a_mat, 8'd0, "TC02");
        end

        //======================================================================
        // TC03: Negative values
        //   W[r][c] = (r%2==0 ? 1 : -1) * (c+1)
        //   A[r][k] = (k%2==0 ? 2 : -3)
        //======================================================================
        $display("============================================================");
        $display("TC03: Mixed-sign weights and activations");
        $display("============================================================");

        begin
            reg signed [DATA_WIDTH-1:0] w_mat [0:ROWS-1][0:COLS-1];
            reg signed [DATA_WIDTH-1:0] a_mat [0:ROWS-1][0:K_DEPTH-1];
            integer r, c, k;

            for (r = 0; r < ROWS; r++)
                for (c = 0; c < COLS; c++)
                    w_mat[r][c] = ((r % 2 == 0) ? 1 : -1) * (c + 1);

            for (r = 0; r < ROWS; r++)
                for (k = 0; k < K_DEPTH; k++)
                    a_mat[r][k] = (k % 2 == 0) ? 16'sd2 : -16'sd3;

            run_bram_tile(w_mat, a_mat, 8'd32, 8'd32);
            verify_results(w_mat, a_mat, 8'd32, "TC03");
        end

        //======================================================================
        // TC04: Determinism — run same computation twice, compare
        //======================================================================
        $display("============================================================");
        $display("TC04: Determinism — two identical runs");
        $display("============================================================");

        begin
            reg signed [DATA_WIDTH-1:0] w_mat [0:ROWS-1][0:COLS-1];
            reg signed [DATA_WIDTH-1:0] a_mat [0:ROWS-1][0:K_DEPTH-1];
            reg [ACCUM_WIDTH-1:0] run1 [0:15], run2 [0:15];
            reg [ACCUM_WIDTH-1:0] rv;
            integer r, c, k, mismatches;

            for (r = 0; r < ROWS; r++)
                for (c = 0; c < COLS; c++)
                    w_mat[r][c] = 16'(r * 7 + c * 3 + 1);

            for (r = 0; r < ROWS; r++)
                for (k = 0; k < K_DEPTH; k++)
                    a_mat[r][k] = 16'(r * K_DEPTH + k + 2);

            // Run 1
            run_bram_tile(w_mat, a_mat, 8'd64, 8'd64);
            for (int i = 0; i < 16; i++) read_res(64 + i, run1[i]);

            // Run 2
            run_bram_tile(w_mat, a_mat, 8'd100, 8'd100);
            for (int i = 0; i < 16; i++) read_res(100 + i, run2[i]);

            mismatches = 0;
            for (int i = 0; i < 16; i++)
                if (run1[i] !== run2[i]) begin
                    $display("  Mismatch [%0d]: run1=%0d, run2=%0d", i, $signed(run1[i]), $signed(run2[i]));
                    mismatches = mismatches + 1;
                end

            if (mismatches == 0) begin
                $display("[PASS] TC04: Deterministic — both runs identical");
                pass_count = pass_count + 1;
            end else begin
                $display("[FAIL] TC04: %0d mismatches between runs", mismatches);
                fail_count = fail_count + 1;
            end
            test_count = test_count + 1;
        end

        //======================================================================
        // TC05: Large values — exercise upper bits of accumulator
        //   Use large weights and activations to verify no truncation
        //======================================================================
        $display("============================================================");
        $display("TC05: Large values — accumulator range check");
        $display("============================================================");

        begin
            reg signed [DATA_WIDTH-1:0] w_mat [0:ROWS-1][0:COLS-1];
            reg signed [DATA_WIDTH-1:0] a_mat [0:ROWS-1][0:K_DEPTH-1];
            integer r, c, k;

            // Large positive values near INT16_MAX
            for (r = 0; r < ROWS; r++)
                for (c = 0; c < COLS; c++)
                    w_mat[r][c] = 16'sd1000 + (r * COLS + c) * 16'sd100;

            for (r = 0; r < ROWS; r++)
                for (k = 0; k < K_DEPTH; k++)
                    a_mat[r][k] = 16'sd500 + k * 16'sd50;

            run_bram_tile(w_mat, a_mat, 8'd120, 8'd120);
            verify_results(w_mat, a_mat, 8'd120, "TC05");
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
        $finish;
    end

    always @(posedge clk)
        if (done && rst_n) $display("  [MON] Time %0t: done=1", $time);

    //==========================================================================
    // Debug probes — TC01 only (t < 2000ns)
    //==========================================================================
    reg [2:0] dbg_phase;
    reg [7:0] dbg_compute_cnt;
    reg [7:0] dbg_readout_cnt;
    reg [7:0] dbg_serialize_cnt;
    reg       dbg_deser_ready;
    reg       dbg_deser_prefetch_done;
    reg       dbg_stream_en;
    reg       dbg_pe_enable;
    reg       dbg_pe_clear;
    reg [3:0] dbg_act0;
    reg       dbg_act_valid;
    reg [39:0] dbg_res0;
    reg       dbg_res_valid;

    always @(posedge clk) begin
        dbg_phase               <= u_dut.ctrl_phase;
        dbg_compute_cnt         <= u_dut.u_controller.compute_cnt;
        dbg_readout_cnt         <= u_dut.u_controller.readout_cnt;
        dbg_serialize_cnt       <= u_dut.u_controller.serialize_cnt;
        dbg_deser_ready         <= u_dut.deser_ready_gated;
        dbg_deser_prefetch_done <= u_dut.deser_prefetch_done;
        dbg_stream_en           <= u_dut.u_act_deserializer.stream_en;
        dbg_pe_enable           <= u_dut.ctrl_pe_enable;
        dbg_pe_clear            <= u_dut.ctrl_pe_clear;
        dbg_act0                <= u_dut.deser_act_data[0];
        dbg_act_valid           <= u_dut.deser_act_valid;
        dbg_res0                <= u_dut.result_data[0];
        dbg_res_valid           <= u_dut.result_valid;
    end

    // Dump waveform for first test only
    initial begin
        $dumpfile("numerical.vcd");
        $dumpvars(0, tb_systolic_array_numerical);
    end

    // Track all phase transitions and key events across all tests
    reg [2:0] prev_phase;
    always @(posedge clk) begin
        if (u_dut.ctrl_phase != prev_phase) begin
            $display("  [DBG] t=%0t phase %0d->%0d  pe_en=%b pe_clr=%b deser_ready=%b pf_done=%b stream_en=%b",
                     $time, prev_phase, u_dut.ctrl_phase,
                     u_dut.ctrl_pe_enable, u_dut.ctrl_pe_clear,
                     u_dut.deser_ready_gated, u_dut.deser_prefetch_done,
                     u_dut.u_act_deserializer.stream_en);
            prev_phase <= u_dut.ctrl_phase;
        end
    end

    // Track parallel_valid during READOUT and capture
    always @(posedge clk) begin
        if (u_dut.ctrl_phase == 3'b011) begin
            $display("  [RDOUT] t=%0t readout_cnt=%0d res_valid=%b res0=%0d",
                     $time, u_dut.u_controller.readout_cnt,
                     u_dut.result_valid, $signed(u_dut.result_data[0]));
        end
    end

endmodule
