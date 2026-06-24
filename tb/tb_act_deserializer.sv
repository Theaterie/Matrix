//==============================================================================
// Testbench: tb_act_deserializer
// Purpose:    Verify BRAM activation deserializer — prefetch, buffer fill,
//             streaming, and edge cases
//==============================================================================
// Test items:
//   TC01 — PREFETCH starts on prefetch_start pulse
//   TC02 — BRAM read address sequence during PREFETCH (base..base+TOTAL-1)
//   TC03 — Buffer fill with 1-cycle BRAM latency
//   TC04 — prefetch_done timing
//   TC05 — PREFETCH → READY → STREAMING transition
//   TC06 — Direct PREFETCH → STREAMING (skip READY) when stream_en is early
//   TC07 — Streaming cycle counts (K_DEPTH cycles)
//   TC08 — Data correctness during streaming (all rows, all K cycles)
//   TC09 — Base address offset
//   TC10 — act_valid_out combinational timing
//   TC11 — Async reset during prefetch
//==============================================================================

`timescale 1ns / 1ps

module tb_act_deserializer;

    localparam ROWS        = 4;
    localparam K_DEPTH     = 4;
    localparam DATA_WIDTH  = 16;
    localparam ADDR_WIDTH  = 8;
    localparam CLK_PERIOD  = 10;
    localparam TOTAL_ENTRIES = ROWS * K_DEPTH;  // 16

    reg               clk;
    reg               rst_n;
    wire              bram_rd_en;
    wire [ADDR_WIDTH-1:0] bram_rd_addr;
    reg  [DATA_WIDTH-1:0] bram_rd_data;
    wire [DATA_WIDTH-1:0] act_data_out [0:ROWS-1];
    wire              act_valid_out;
    reg  [ADDR_WIDTH-1:0] act_base_addr;
    reg               prefetch_start;
    reg               stream_en;
    wire              prefetch_done;
    wire              stream_done;

    // BRAM behavioral model
    reg  [DATA_WIDTH-1:0] bram_mem [0:255];
    reg  [DATA_WIDTH-1:0] bram_rd_data_r;
    reg               bram_rd_en_d1;

    integer test_count, pass_count, fail_count;

    //--------------------------------------------------------------------------
    // DUT instantiation
    //--------------------------------------------------------------------------
    act_deserializer #(
        .ROWS       (ROWS),
        .K_DEPTH    (K_DEPTH),
        .DATA_WIDTH (DATA_WIDTH),
        .ADDR_WIDTH (ADDR_WIDTH)
    ) u_dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .bram_rd_en     (bram_rd_en),
        .bram_rd_addr   (bram_rd_addr),
        .bram_rd_data   (bram_rd_data),
        .act_data_out   (act_data_out),
        .act_valid_out  (act_valid_out),
        .act_base_addr  (act_base_addr),
        .prefetch_start (prefetch_start),
        .stream_en      (stream_en),
        .prefetch_done  (prefetch_done),
        .stream_done    (stream_done)
    );

    //--------------------------------------------------------------------------
    // Clock
    //--------------------------------------------------------------------------
    always #(CLK_PERIOD/2) clk = ~clk;

    //--------------------------------------------------------------------------
    // BRAM behavioral model (1-cycle read latency)
    //--------------------------------------------------------------------------
    always @(posedge clk) begin
        bram_rd_en_d1 <= bram_rd_en;
        if (bram_rd_en)
            bram_rd_data_r <= bram_mem[bram_rd_addr];
    end

    // Feed BRAM data to DUT with 1-cycle delay (matching real BRAM)
    assign bram_rd_data = bram_rd_data_r;

    //--------------------------------------------------------------------------
    // Check task
    //--------------------------------------------------------------------------
    task automatic check_eq;
        input [255:0]          test_name;
        input integer          actual;
        input integer          expected;
        input [255:0]          sig_name;
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
    // Task: Preload BRAM with row-major activation data
    //--------------------------------------------------------------------------
    task automatic preload_bram;
        input [ADDR_WIDTH-1:0] base;
        input [DATA_WIDTH-1:0] a_mat [0:ROWS-1][0:K_DEPTH-1];
        integer r, k, addr;
        begin
            addr = base;
            for (r = 0; r < ROWS; r = r + 1)
                for (k = 0; k < K_DEPTH; k = k + 1) begin
                    bram_mem[addr] = a_mat[r][k];
                    addr = addr + 1;
                end
        end
    endtask

    //--------------------------------------------------------------------------
    // Main test sequence
    //--------------------------------------------------------------------------
    initial begin
        clk       = 0;
        rst_n     = 0;
        bram_rd_data_r = 0;
        bram_rd_en_d1  = 0;
        act_base_addr = 8'd0;
        prefetch_start = 0;
        stream_en      = 0;
        test_count = 0;
        pass_count = 0;
        fail_count = 0;
        for (int i = 0; i < 256; i++) bram_mem[i] = 16'd0;

        repeat(8) @(posedge clk);
        rst_n = 1;
        repeat(2) @(posedge clk);

        //======================================================================
        // TC01: PREFETCH starts on prefetch_start pulse
        //======================================================================
        $display("============================================================");
        $display("TC01: PREFETCH starts on prefetch_start pulse");
        $display("============================================================");

        // Preload data into BRAM
        begin : tc01_preload
            reg [DATA_WIDTH-1:0] a_mat [0:ROWS-1][0:K_DEPTH-1];
            integer r, k;
            for (r = 0; r < ROWS; r++)
                for (k = 0; k < K_DEPTH; k++)
                    a_mat[r][k] = r * 100 + k;
            preload_bram(8'd0, a_mat);
        end

        @(posedge clk);
        prefetch_start <= 1'b1;

        @(posedge clk);
        prefetch_start <= 1'b0;
        check_eq("TC01a: first BRAM read issued (rd_en=1)", bram_rd_en, 1, "bram_rd_en");
        check_eq("TC01b: first BRAM read addr = base+0", bram_rd_addr, 0, "bram_rd_addr");

        //======================================================================
        // TC02: BRAM read address sequence during PREFETCH
        //======================================================================
        $display("============================================================");
        $display("TC02: BRAM read address sequence base+0 .. base+%0d", TOTAL_ENTRIES-1);
        $display("============================================================");

        begin : tc02_block
            integer i;
            for (i = 1; i < TOTAL_ENTRIES; i = i + 1) begin
                @(posedge clk);
                check_eq($sformatf("TC02[%0d]: bram_rd_addr", i), bram_rd_addr, i, "bram_rd_addr");
            end
            // After last read, rd_en deasserts
            @(posedge clk);
            check_eq("TC02z: bram_rd_en=0 after last read", bram_rd_en, 0, "bram_rd_en");
        end

        //======================================================================
        // TC03 + TC04: Buffer fill and prefetch_done timing
        //   (These are verified together since they're closely related)
        //======================================================================
        $display("============================================================");
        $display("TC03/04: Buffer fill verified via streaming; prefetch_done");
        $display("============================================================");

        // prefetch_done should be high now (buffer is full)
        check_eq("TC04: prefetch_done=1 after buffer fill", prefetch_done, 1, "prefetch_done");

        //======================================================================
        // TC05: READY → STREAMING transition
        //======================================================================
        $display("============================================================");
        $display("TC05: READY → STREAMING when stream_en asserts");
        $display("============================================================");

        @(posedge clk);
        stream_en <= 1'b1;

        @(posedge clk);
        check_eq("TC05a: act_valid_out=1 in STREAMING", act_valid_out, 1, "act_valid_out");
        // First activation vector (k=0) should be on outputs
        check_eq("TC05b: act_data_out[0]=a[0][0]=0", act_data_out[0], 0, "act_data_out[0]");
        check_eq("TC05c: act_data_out[1]=a[1][0]=100", act_data_out[1], 100, "act_data_out[1]");
        check_eq("TC05d: act_data_out[2]=a[2][0]=200", act_data_out[2], 200, "act_data_out[2]");
        check_eq("TC05e: act_data_out[3]=a[3][0]=300", act_data_out[3], 300, "act_data_out[3]");

        //======================================================================
        // TC07+TC08: Streaming cycles and data correctness
        //======================================================================
        $display("============================================================");
        $display("TC07/08: Streaming %0d cycles, all data correct", K_DEPTH);
        $display("============================================================");

        begin : tc07_block
            integer k, r;
            for (k = 1; k < K_DEPTH; k = k + 1) begin
                @(posedge clk);
                check_eq($sformatf("TC07 k=%0d valid", k), act_valid_out, 1, "act_valid_out");
                for (r = 0; r < ROWS; r = r + 1) begin
                    check_eq($sformatf("TC08 r%0d_k%0d", r, k),
                        act_data_out[r], r * 100 + k, "act_data_out");
                end
            end
            // After last K cycle, stream_done should pulse
            @(posedge clk);
            stream_en <= 1'b0;
            check_eq("TC07z: stream_done pulsed", stream_done, 1, "stream_done");
        end

        // Reset for next tests
        rst_n <= 1'b0;
        @(posedge clk);
        rst_n <= 1'b1;
        repeat(2) @(posedge clk);

        //======================================================================
        // TC06: Direct PREFETCH → STREAMING (skip READY)
        //   stream_en is asserted before/at same time as prefetch_done
        //======================================================================
        $display("============================================================");
        $display("TC06: Direct PREFETCH → STREAMING (skip READY)");
        $display("============================================================");

        begin : tc06_block
            reg [DATA_WIDTH-1:0] a_mat [0:ROWS-1][0:K_DEPTH-1];
            integer r, k;
            for (r = 0; r < ROWS; r++)
                for (k = 0; k < K_DEPTH; k++)
                    a_mat[r][k] = r * 50 + k;
            preload_bram(8'd20, a_mat);  // different base address
        end

        // Start prefetch with stream_en already high
        stream_en <= 1'b1;
        @(posedge clk);
        prefetch_start <= 1'b1;
        @(posedge clk);
        prefetch_start <= 1'b0;

        // Wait for prefetch to complete (it will transition directly to STREAMING)
        repeat(TOTAL_ENTRIES + 2) @(posedge clk);

        // Check that streaming is happening
        check_eq("TC06a: act_valid_out=1 (direct PREFETCH→STREAMING)",
            act_valid_out, 1, "act_valid_out");

        stream_en <= 1'b0;
        rst_n <= 1'b0;
        @(posedge clk);
        rst_n <= 1'b1;
        repeat(2) @(posedge clk);

        //======================================================================
        // TC09: Base address offset
        //======================================================================
        $display("============================================================");
        $display("TC09: Base address offset — act_base_addr=30");
        $display("============================================================");

        begin : tc09_block
            reg [DATA_WIDTH-1:0] a_mat [0:ROWS-1][0:K_DEPTH-1];
            integer r, k;
            for (r = 0; r < ROWS; r++)
                for (k = 0; k < K_DEPTH; k++)
                    a_mat[r][k] = 1000 + r * 100 + k;
            preload_bram(8'd30, a_mat);
        end

        act_base_addr <= 8'd30;
        @(posedge clk);
        prefetch_start <= 1'b1;
        @(posedge clk);
        prefetch_start <= 1'b0;

        // Check that BRAM reads start at base=30
        check_eq("TC09a: first read addr = base = 30", bram_rd_addr, 30, "bram_rd_addr");
        @(posedge clk);
        check_eq("TC09b: second read addr = 31", bram_rd_addr, 31, "bram_rd_addr");

        // Wait for prefetch to finish
        repeat(TOTAL_ENTRIES + 2) @(posedge clk);

        //======================================================================
        // TC10: act_valid_out timing (combinational)
        //   act_valid_out should be 1 only during appropriate states
        //======================================================================
        $display("============================================================");
        $display("TC10: act_valid_out combinational timing");
        $display("============================================================");

        // Currently in READY (Streaming just finished and we went back to IDLE)
        // act_valid_out should be 0 now
        check_eq("TC10a: act_valid_out=0 when not streaming", act_valid_out, 0, "act_valid_out");

        stream_en <= 1'b1;
        @(posedge clk);
        // Now we should be in STREAMING from READY
        check_eq("TC10b: act_valid_out=1 when streaming", act_valid_out, 1, "act_valid_out");

        stream_en <= 1'b0;
        repeat(K_DEPTH + 2) @(posedge clk);

        //======================================================================
        // TC11: Async reset during prefetch
        //======================================================================
        $display("============================================================");
        $display("TC11: Async reset during prefetch");
        $display("============================================================");

        @(posedge clk);
        prefetch_start <= 1'b1;
        @(posedge clk);
        prefetch_start <= 1'b0;

        // Wait a couple of reads
        repeat(3) @(posedge clk);

        // Assert reset
        rst_n <= 1'b0;
        @(posedge clk);
        check_eq("TC11a: bram_rd_en=0 after reset", bram_rd_en, 0, "bram_rd_en");
        check_eq("TC11b: prefetch_done=0 after reset", prefetch_done, 0, "prefetch_done");
        check_eq("TC11c: act_valid_out=0 after reset", act_valid_out, 0, "act_valid_out");

        rst_n <= 1'b1;
        repeat(2) @(posedge clk);

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
        $dumpfile("tb_act_deserializer.vcd");
        $dumpvars(0, tb_act_deserializer);
    end
`endif

endmodule
