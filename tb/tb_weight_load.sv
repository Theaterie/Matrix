//==============================================================================
// Testbench: tb_weight_load
// Purpose:    Isolate weight-loading path verification.
//             Only exercises: start -> WEIGHT_LOAD -> (wait done).
//             No activations, no COMPUTE.  Reads back every PE's weight_r via
//             hierarchical reference and compares against the expected matrix.
//             This localizes whether load_weights timing is correct, free of
//             any preload_act / deser_ready coupling.
//==============================================================================
`timescale 1ns / 1ps

module tb_weight_load;

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

    wire [DATA_WIDTH-1:0]               weight_data;
    reg  [DATA_WIDTH-1:0]               weight_hold;
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

    //==========================================================================
    // Task: drive weights following controller's weight_addr counter.
    //   weight_data is driven combinationally from wd_shift[wd_idx], so it
    //   is stable before each posedge (aligned with weight_addr which is
    //   also combinational from the registered weight_cnt).
    //==========================================================================
    // Shift buffer for weight values, loaded by the task before driving.
    reg [15:0] wd_shift [0:ROWS*COLS-1];
    reg [7:0]  wd_idx;
    reg        wd_run;
    integer wdi;
    initial begin
        wd_run = 0; wd_idx = 0; weight_hold = 0;
        for (wdi = 0; wdi < ROWS*COLS; wdi = wdi + 1) wd_shift[wdi] = 0;
    end

    task automatic load_weights;
        input signed [DATA_WIDTH-1:0] w_mat [0:ROWS-1][0:COLS-1];
        integer r, c, idx;
        reg [DATA_WIDTH-1:0] last_weight;
        begin
            // Pre-load the shift buffer and start driving BEFORE WEIGHT_LOAD
            // begins.  wd_idx only advances on WEIGHT_LOAD posedges (gated
            // by weight_ready in the assign + always), so wd_shift[0] is
            // presented at the first WEIGHT_LOAD posedge matching waddr=0.
            for (idx = 0; idx < ROWS*COLS; idx = idx + 1) begin
                r = idx / COLS;
                c = idx % COLS;
                wd_shift[idx] = w_mat[r][c];
            end
            last_weight = w_mat[ROWS-1][COLS-1];
            weight_hold = last_weight;
            wd_idx = 0;
            wd_run = 1;
            // Wait until controller enters WEIGHT_LOAD.
            while (!weight_ready) @(posedge clk);
            // Drive weight_data for ROWS*COLS WEIGHT_LOAD cycles.
            while (wd_idx < ROWS*COLS) @(posedge clk);
            wd_run = 0;
            // Hold last weight until WEIGHT_LOAD ends.
            while (weight_ready) @(posedge clk);
            weight_hold = 0;
        end
    endtask

    // Combinational weight_data driver: weight_data is combinational from
    // wd_shift[wd_idx], so it is stable BEFORE the posedge (unlike NBA).
    // Gated by weight_ready so wd_idx only advances during WEIGHT_LOAD,
    // preventing spurious increments while waiting for WEIGHT_LOAD to start.
    assign weight_data = (wd_run && weight_ready) ? wd_shift[wd_idx] : weight_hold;

    // wd_idx advances at each WEIGHT_LOAD posedge while wd_run.
    always @(posedge clk) begin
        if (wd_run && weight_ready) begin
            wd_idx <= wd_idx + 1;
        end
    end

    // Trace WEIGHT_LOAD cycles
    always @(posedge clk) if (u_dut.ctrl_phase == 3'b001) begin
        $display("  [TRC] t=%0t wcnt=%0d waddr=%0d wen=%b data=%0d pe_en=%b | PE00(load=%b actin=%0d wr=%0d)",
                 $time,
                 u_dut.u_controller.weight_cnt, u_dut.ctrl_weight_addr,
                 u_dut.ctrl_weight_wren, $signed(weight_data),
                 u_dut.ctrl_pe_enable,
                 u_dut.u_pe_array.gen_pe_row[0].gen_pe_col[0].u_pe.weight_load,
                 $signed(u_dut.u_pe_array.gen_pe_row[0].gen_pe_col[0].u_pe.act_in),
                 $signed(u_dut.u_pe_array.gen_pe_row[0].gen_pe_col[0].u_pe.weight_r));
    end

    //==========================================================================
    // Task: read back every PE's weight register via hierarchical reference
    //   and compare to the expected matrix.  Reports per-PE pass/fail.
    //   Uses a flat address index 0..ROWS*COLS-1 matching weight_addr; the
    //   generate block path is gen_pe_row[row].gen_pe_col[col].
    //==========================================================================
    task automatic verify_weights;
        input signed [DATA_WIDTH-1:0] w_mat [0:ROWS-1][0:COLS-1];
        input [255:0] test_name;
        integer r, c;
        reg signed [DATA_WIDTH-1:0] got;
        begin
            for (r = 0; r < ROWS; r = r + 1) begin
                for (c = 0; c < COLS; c = c + 1) begin
                    case ({r[1:0], c[1:0]})
                        {2'd0, 2'd0}: got = u_dut.u_pe_array.gen_pe_row[0].gen_pe_col[0].u_pe.weight_r;
                        {2'd0, 2'd1}: got = u_dut.u_pe_array.gen_pe_row[0].gen_pe_col[1].u_pe.weight_r;
                        {2'd0, 2'd2}: got = u_dut.u_pe_array.gen_pe_row[0].gen_pe_col[2].u_pe.weight_r;
                        {2'd0, 2'd3}: got = u_dut.u_pe_array.gen_pe_row[0].gen_pe_col[3].u_pe.weight_r;
                        {2'd1, 2'd0}: got = u_dut.u_pe_array.gen_pe_row[1].gen_pe_col[0].u_pe.weight_r;
                        {2'd1, 2'd1}: got = u_dut.u_pe_array.gen_pe_row[1].gen_pe_col[1].u_pe.weight_r;
                        {2'd1, 2'd2}: got = u_dut.u_pe_array.gen_pe_row[1].gen_pe_col[2].u_pe.weight_r;
                        {2'd1, 2'd3}: got = u_dut.u_pe_array.gen_pe_row[1].gen_pe_col[3].u_pe.weight_r;
                        {2'd2, 2'd0}: got = u_dut.u_pe_array.gen_pe_row[2].gen_pe_col[0].u_pe.weight_r;
                        {2'd2, 2'd1}: got = u_dut.u_pe_array.gen_pe_row[2].gen_pe_col[1].u_pe.weight_r;
                        {2'd2, 2'd2}: got = u_dut.u_pe_array.gen_pe_row[2].gen_pe_col[2].u_pe.weight_r;
                        {2'd2, 2'd3}: got = u_dut.u_pe_array.gen_pe_row[2].gen_pe_col[3].u_pe.weight_r;
                        {2'd3, 2'd0}: got = u_dut.u_pe_array.gen_pe_row[3].gen_pe_col[0].u_pe.weight_r;
                        {2'd3, 2'd1}: got = u_dut.u_pe_array.gen_pe_row[3].gen_pe_col[1].u_pe.weight_r;
                        {2'd3, 2'd2}: got = u_dut.u_pe_array.gen_pe_row[3].gen_pe_col[2].u_pe.weight_r;
                        {2'd3, 2'd3}: got = u_dut.u_pe_array.gen_pe_row[3].gen_pe_col[3].u_pe.weight_r;
                    endcase
                    if (got === w_mat[r][c]) begin
                        $display("  [PASS] %0s PE[%0d][%0d] w=%0d", test_name, r, c, $signed(got));
                        pass_count = pass_count + 1;
                    end else begin
                        $display("  [FAIL] %0s PE[%0d][%0d] got=%0d exp=%0d",
                                 test_name, r, c, $signed(got), $signed(w_mat[r][c]));
                        fail_count = fail_count + 1;
                    end
                    test_count = test_count + 1;
                end
            end
        end
    endtask

    //==========================================================================
    // Main
    //==========================================================================
    initial begin
        clk = 0; rst_n = 0; start = 0; use_bram_act = 0;
        act_valid = 0;
        for (int i = 0; i < ROWS; i++) act_data[i] = 0;
        act_wr_en = 0; act_wr_addr = 0; act_wr_data = 0;
        res_rd_en = 0; res_rd_addr = 0; act_base_addr = 0; res_base_addr = 0;
        test_count = 0; pass_count = 0; fail_count = 0;

        repeat(8) @(posedge clk); rst_n = 1; repeat(2) @(posedge clk);

        //======================================================================
        // TC01: Identity weights
        //======================================================================
        $display("============================================================");
        $display("TC01: Identity weights");
        $display("============================================================");
        begin
            reg signed [DATA_WIDTH-1:0] w_mat [0:ROWS-1][0:COLS-1];
            integer r, c;
            for (r = 0; r < ROWS; r++)
                for (c = 0; c < COLS; c++)
                    w_mat[r][c] = (r == c) ? 16'sd1 : 16'sd0;

            @(posedge clk); start <= 1; @(posedge clk); start <= 0;
            load_weights(w_mat);
            // Wait for DONE pulse so controller returns to IDLE
            while (!done) @(posedge clk);
            @(posedge clk);
            verify_weights(w_mat, "TC01");
        end

        //======================================================================
        // TC02: Sequential weights 1..16
        //======================================================================
        $display("============================================================");
        $display("TC02: Sequential weights 1..16");
        $display("============================================================");
        begin
            reg signed [DATA_WIDTH-1:0] w_mat [0:ROWS-1][0:COLS-1];
            integer r, c;
            for (r = 0; r < ROWS; r++)
                for (c = 0; c < COLS; c++)
                    w_mat[r][c] = r * COLS + c + 1;

            @(posedge clk); start <= 1; @(posedge clk); start <= 0;
            load_weights(w_mat);
            while (!done) @(posedge clk);
            @(posedge clk);
            verify_weights(w_mat, "TC02");
        end

        //======================================================================
        // TC03: Negative / mixed signs
        //======================================================================
        $display("============================================================");
        $display("TC03: Mixed-sign weights");
        $display("============================================================");
        begin
            reg signed [DATA_WIDTH-1:0] w_mat [0:ROWS-1][0:COLS-1];
            integer r, c;
            for (r = 0; r < ROWS; r++)
                for (c = 0; c < COLS; c++)
                    w_mat[r][c] = ((r % 2 == 0) ? 1 : -1) * (c + 1);

            @(posedge clk); start <= 1; @(posedge clk); start <= 0;
            load_weights(w_mat);
            while (!done) @(posedge clk);
            @(posedge clk);
            verify_weights(w_mat, "TC03");
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

    initial begin
        $dumpfile("wload.vcd");
        $dumpvars(0, tb_weight_load);
    end

endmodule
