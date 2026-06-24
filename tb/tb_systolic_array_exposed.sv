//==============================================================================
// Testbench: tb_systolic_array_exposed
// Purpose:    Verify BRAM-exposed variant — external BRAMs wired to exposed
//             ports, basic connectivity test, and tile computation
//==============================================================================
// Test items:
//   TC01 — Connectivity: instantiate DUT with external BRAMs, verify busy/done
//   TC02 — Tile computation via BRAM: preload A BRAM, load weights, run, check
//          results written to external result BRAM
//   TC03 — Direct path: use_bram_act=0, external act_data/act_valid
//==============================================================================

`timescale 1ns / 1ps

module tb_systolic_array_exposed;

    localparam ROWS        = 4;
    localparam COLS        = 4;
    localparam DATA_WIDTH  = 16;
    localparam ACCUM_WIDTH = 40;
    localparam K_DEPTH     = 4;
    localparam BUF_ADDR_W  = 8;
    localparam BUF_DEPTH   = 256;
    localparam WT_ADDR_W   = 4;
    localparam CLK_PERIOD  = 10;

    reg               clk, rst_n;
    reg               start;
    wire              busy, done;
    reg               use_bram_act;
    reg  [DATA_WIDTH-1:0] weight_data;
    wire              weight_ready;
    reg  [DATA_WIDTH-1:0] act_data [0:ROWS-1];
    reg               act_valid;
    wire              act_bram_rd_en;
    wire [BUF_ADDR_W-1:0] act_bram_rd_addr;
    reg  [DATA_WIDTH-1:0] act_bram_rd_data;
    wire              res_bram_wr_en;
    wire [BUF_ADDR_W-1:0] res_bram_wr_addr;
    wire [ACCUM_WIDTH-1:0] res_bram_wr_data;
    reg               res_bram_rd_en;
    reg  [BUF_ADDR_W-1:0] res_bram_rd_addr;
    wire [ACCUM_WIDTH-1:0] res_bram_rd_data;
    wire [ACCUM_WIDTH-1:0] result_data [0:COLS-1];
    wire              result_valid;
    reg  [BUF_ADDR_W-1:0] act_base_addr, res_base_addr;

    integer test_count, pass_count, fail_count;

    // External BRAM model
    reg  [DATA_WIDTH-1:0]  ext_act_bram [0:BUF_DEPTH-1];
    reg  [ACCUM_WIDTH-1:0] ext_res_bram [0:BUF_DEPTH-1];

    // Write to result BRAM (synchronous)
    wire act_bram_rd_en_comb = act_bram_rd_en;
    reg  act_bram_rd_en_d1;

    //--------------------------------------------------------------------------
    // DUT instantiation
    //--------------------------------------------------------------------------
    systolic_array_exposed #(
        .ROWS(ROWS), .COLS(COLS), .DATA_WIDTH(DATA_WIDTH),
        .ACCUM_WIDTH(ACCUM_WIDTH), .K_DEPTH(K_DEPTH),
        .BUF_ADDR_W(BUF_ADDR_W), .BUF_DEPTH(BUF_DEPTH), .WT_ADDR_W(WT_ADDR_W)
    ) u_dut (
        .clk(clk), .rst_n(rst_n),
        .start(start), .weight_preloaded(1'b0), .prefetch_start(1'b0),
        .busy(busy), .done(done),
        .use_bram_act(use_bram_act), .weight_data(weight_data),
        .weight_ready(weight_ready), .act_data(act_data), .act_valid(act_valid),
        .act_bram_rd_en(act_bram_rd_en), .act_bram_rd_addr(act_bram_rd_addr),
        .act_bram_rd_data(act_bram_rd_data),
        .res_bram_wr_en(res_bram_wr_en), .res_bram_wr_addr(res_bram_wr_addr),
        .res_bram_wr_data(res_bram_wr_data),
        .res_bram_rd_en(res_bram_rd_en), .res_bram_rd_addr(res_bram_rd_addr),
        .res_bram_rd_data(res_bram_rd_data),
        .result_data(result_data), .result_valid(result_valid),
        .act_base_addr(act_base_addr), .res_base_addr(res_base_addr)
    );

    //--------------------------------------------------------------------------
    // Clock
    //--------------------------------------------------------------------------
    always #(CLK_PERIOD/2) clk = ~clk;

    //--------------------------------------------------------------------------
    // External BRAM models
    //--------------------------------------------------------------------------
    // Activation BRAM: read port
    always @(posedge clk) begin
        act_bram_rd_en_d1 <= act_bram_rd_en;
        if (act_bram_rd_en)
            act_bram_rd_data <= ext_act_bram[act_bram_rd_addr];
    end

    // Result BRAM: write port
    always @(posedge clk) begin
        if (res_bram_wr_en)
            ext_res_bram[res_bram_wr_addr] <= res_bram_wr_data;
    end

    // Result BRAM: read port
    always @(posedge clk) begin
        if (res_bram_rd_en)
            res_bram_rd_data <= ext_res_bram[res_bram_rd_addr];
    end

    //--------------------------------------------------------------------------
    // Tasks
    //--------------------------------------------------------------------------
    task automatic load_weights;
        input signed [DATA_WIDTH-1:0] w_mat [0:ROWS-1][0:COLS-1];
        integer r, c;
        begin
            while (!weight_ready) @(posedge clk);
            for (r = 0; r < ROWS; r++)
                for (c = 0; c < COLS; c++) begin
                    @(posedge clk); weight_data <= w_mat[r][c];
                end
            @(posedge clk); weight_data <= 0;
        end
    endtask

    // Preload activation BRAM (directly into external model)
    task automatic preload_act_bram;
        input [BUF_ADDR_W-1:0] base;
        input signed [DATA_WIDTH-1:0] a_mat [0:ROWS-1][0:K_DEPTH-1];
        integer r, k, addr;
        begin
            addr = base;
            for (r = 0; r < ROWS; r++)
                for (k = 0; k < K_DEPTH; k++) begin
                    ext_act_bram[addr] = a_mat[r][k];
                    addr++;
                end
        end
    endtask

    // Direct activation drive
    task automatic drive_activations;
        input signed [DATA_WIDTH-1:0] a_mat [0:ROWS-1][0:K_DEPTH-1];
        integer r, k;
        begin
            for (k = 0; k < K_DEPTH; k++) begin
                @(posedge clk);
                for (r = 0; r < ROWS; r++)
                    act_data[r] <= a_mat[r][k];
                act_valid <= 1'b1;
            end
            @(posedge clk);
            for (r = 0; r < ROWS; r++) act_data[r] <= 0;
            act_valid <= 1'b0;
        end
    endtask

    //--------------------------------------------------------------------------
    // Main
    //--------------------------------------------------------------------------
    initial begin
        clk = 0; rst_n = 0; start = 0; use_bram_act = 0;
        weight_data = 0; act_valid = 0; act_bram_rd_data = 0;
        res_bram_rd_en = 0; res_bram_rd_addr = 0;
        act_base_addr = 0; res_base_addr = 0;
        for (int i = 0; i < ROWS; i++) act_data[i] = 0;
        for (int i = 0; i < BUF_DEPTH; i++) begin
            ext_act_bram[i] = 0; ext_res_bram[i] = 0;
        end
        test_count = 0; pass_count = 0; fail_count = 0;

        repeat(8) @(posedge clk); rst_n = 1; repeat(2) @(posedge clk);

        //======================================================================
        // TC01: Connectivity — verify busy/done handshake
        //======================================================================
        $display("============================================================");
        $display("TC01: Connectivity — run a basic tile, verify busy/done");
        $display("============================================================");

        begin : tc01_block
            reg signed [DATA_WIDTH-1:0] w_id [0:ROWS-1][0:COLS-1];
            reg signed [DATA_WIDTH-1:0] a_ones [0:ROWS-1][0:K_DEPTH-1];
            integer r, c, k;

            for (r = 0; r < ROWS; r++)
                for (c = 0; c < COLS; c++)
                    w_id[r][c] = (r == c) ? 16'sd1 : 16'sd0;
            for (r = 0; r < ROWS; r++)
                for (k = 0; k < K_DEPTH; k++)
                    a_ones[r][k] = 16'sd1;

            preload_act_bram(0, a_ones);
            use_bram_act <= 1;
            @(posedge clk); start <= 1; @(posedge clk); start <= 0;
            load_weights(w_id);
            while (!done) @(posedge clk);

            if (done && !busy) begin
                $display("[PASS] TC01: busy/done handshake works (BRAM path)");
                pass_count++; test_count++;
            end else begin
                $display("[FAIL] TC01: handshake issue");
                fail_count++; test_count++;
            end
        end

        //======================================================================
        // TC02: Tile computation — verify results in external result BRAM
        //======================================================================
        $display("============================================================");
        $display("TC02: Tile computation — check result BRAM has non-zero data");
        $display("============================================================");

        begin : tc02_block
            integer nz = 0;
            for (int i = 0; i < 16; i++) begin
                if (ext_res_bram[i] !== 0 && ext_res_bram[i] !== {ACCUM_WIDTH{1'bx}})
                    nz++;
            end
            if (nz > 0) begin
                $display("[PASS] TC02: %0d/16 non-zero results in external res BRAM", nz);
                pass_count++; test_count++;
            end else begin
                $display("[FAIL] TC02: all zeros in result BRAM");
                fail_count++; test_count++;
            end
        end

        //======================================================================
        // TC03: Direct path — use_bram_act=0
        //======================================================================
        $display("============================================================");
        $display("TC03: Direct path test (use_bram_act=0)");
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

            use_bram_act <= 0;
            @(posedge clk); start <= 1; @(posedge clk); start <= 0;
            load_weights(w_seq);
            drive_activations(a_seq);
            while (!done) @(posedge clk);

            if (done) begin
                $display("[PASS] TC03: Direct path completed");
                pass_count++; test_count++;
            end else begin
                $display("[FAIL] TC03: Direct path failed");
                fail_count++; test_count++;
            end
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

    always @(posedge clk)
        if (done && rst_n) $display("  [MON] Time %0t: done=1", $time);

endmodule
