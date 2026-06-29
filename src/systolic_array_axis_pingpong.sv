`timescale 1ns / 1ps

//==============================================================================
// Module:  systolic_array_axis_pingpong
// Purpose: Wraps systolic_array_pingpong with AXI4-Stream interfaces.
//          Combines double-buffering (ping-pong) with AXI4-Stream I/O for
//          SoC/DMA integration with hidden data-load latency.
//
// Encapsulation chain:
//   mac_unit → pe → pe_array → systolic_array → exposed → pingpong → THIS
//
// Interfaces:
//   S_AXIS_WEIGHT  — Slave:  weight data stream (1 beat per weight, WEIGHT_LOAD)
//   S_AXIS_ACT     — Slave:  activation data stream (writes to INACTIVE buffer)
//   M_AXIS_RESULT  — Master: result data stream (reads from INACTIVE result BRAM)
//
// Ping-pong operation (auto_swap=1):
//   1. Host streams activations to inactive buffer via S_AXIS_ACT (before start)
//   2. Host streams weights via S_AXIS_WEIGHT (during WEIGHT_LOAD)
//   3. start → SA computes using active buffer
//   4. While SA is busy, host can preload next tile's activations to inactive buffer
//   5. After done: auto_swap toggles buf_sel, results become readable via M_AXIS_RESULT
//   6. Repeat from step 2 for next tile
//
// Bootstrap note:
//   On the very first run (buf_sel=0, buffer A active), A is empty.
//   Host writes tile 0 activations to B (inactive). After the first done+swap,
//   B becomes active and tile 0 is computed on the second run.
//   Alternatively, use use_bram_act=0 (direct path) for the first tile.
//==============================================================================

module systolic_array_axis_pingpong #(
    parameter ROWS          = 16,
    parameter COLS          = 16,
    parameter DATA_WIDTH    = 16,
    parameter ACCUM_WIDTH   = 40,
    parameter K_DEPTH       = 16,
    parameter BUF_ADDR_W    = 8,
    parameter BUF_DEPTH     = 256,
    parameter WT_ADDR_W     = 8
) (
    input  wire                              clk,
    input  wire                              rst_n,

    // ---- AXI4-Stream Weight Slave (S_AXIS_WEIGHT) ----
    input  wire                              s_axis_weight_tvalid,
    output wire                              s_axis_weight_tready,
    input  wire [DATA_WIDTH-1:0]             s_axis_weight_tdata,
    input  wire                              s_axis_weight_tlast,

    // ---- AXI4-Stream Activation Slave (S_AXIS_ACT) ----
    //   Each beat = one activation value; TLAST marks end of tile's activations.
    //   Written to the INACTIVE ping-pong buffer before start.
    input  wire                              s_axis_act_tvalid,
    output wire                              s_axis_act_tready,
    input  wire [DATA_WIDTH-1:0]             s_axis_act_tdata,
    input  wire                              s_axis_act_tlast,

    // ---- AXI4-Stream Result Master (M_AXIS_RESULT) ----
    //   Results streamed out after done (read from inactive result BRAM).
    output wire                              m_axis_result_tvalid,
    input  wire                              m_axis_result_tready,
    output wire [ACCUM_WIDTH-1:0]            m_axis_result_tdata,
    output wire                              m_axis_result_tlast,

    // ---- Control ----
    input  wire                              start,            // Pulse: begin tile computation
    output wire                              busy,
    output wire                              done,             // Pulse: tile complete
    input  wire                              auto_swap,        // 1 = auto-toggle buf_sel after done
    output wire                              buf_sel,          // Current active buffer (0=A, 1=B)

    // ---- Direct activation input (bypass BRAM, for test) ----
    input  wire                              use_bram_act,
    input  wire [DATA_WIDTH-1:0]             act_data [0:ROWS-1],
    input  wire                              act_valid,

    // ---- Raw result output (for debug/monitoring) ----
    output wire [ACCUM_WIDTH-1:0]            result_data [0:COLS-1],
    output wire                              result_valid,

    // ---- Tile base addresses ----
    input  wire [BUF_ADDR_W-1:0]             act_base_addr,
    input  wire [BUF_ADDR_W-1:0]             res_base_addr
);

    //==========================================================================
    // Local parameters
    //==========================================================================
    localparam WEIGHT_COUNT = ROWS * COLS;
    localparam ACT_COUNT    = ROWS * K_DEPTH;
    localparam RESULT_COUNT = ROWS * COLS;

    //==========================================================================
    // Weight loading state
    //==========================================================================
    reg [$clog2(WEIGHT_COUNT):0] weight_beat_cnt;
    wire                         weight_streaming;
    wire                         weight_last_beat;

    assign weight_streaming = (weight_beat_cnt < WEIGHT_COUNT);
    assign weight_last_beat = (weight_beat_cnt == WEIGHT_COUNT - 1);

    // s_axis_weight_tready: accept when systolic_array is in WEIGHT_LOAD phase
    //   and we haven't received all weights yet.
    wire sa_weight_ready;

    assign s_axis_weight_tready = sa_weight_ready && weight_streaming;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            weight_beat_cnt <= 0;
        end else begin
            if (start) begin
                weight_beat_cnt <= 0;
            end else if (s_axis_weight_tvalid && s_axis_weight_tready) begin
                if (weight_last_beat)
                    weight_beat_cnt <= 0;
                else
                    weight_beat_cnt <= weight_beat_cnt + 1'b1;
            end
        end
    end

    //==========================================================================
    // Activation loading state (write to INACTIVE ping-pong buffer)
    //==========================================================================
    reg  [$clog2(ACT_COUNT):0] act_beat_cnt;
    wire                        act_streaming;
    wire                        act_last_beat;
    reg                         act_preload_done;
    // Explicit zero-extend to BUF_ADDR_W (avoid sim port-width issues)
    wire [BUF_ADDR_W-1:0]       act_wr_addr = {{(BUF_ADDR_W-$bits(act_beat_cnt)){1'b0}}, act_beat_cnt};

    assign act_streaming  = (act_beat_cnt < ACT_COUNT);
    assign act_last_beat  = (act_beat_cnt == ACT_COUNT - 1);

    // Accept activations when preloading (before start)
    assign s_axis_act_tready = act_streaming && !act_preload_done;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            act_beat_cnt      <= 0;
            act_preload_done  <= 1'b0;
        end else begin
            if (start) begin
                act_beat_cnt     <= 0;
                act_preload_done <= 1'b0;
            end else if (s_axis_act_tvalid && s_axis_act_tready) begin
                if (act_last_beat) begin
                    act_beat_cnt     <= 0;
                    act_preload_done <= 1'b1;
                end else begin
                    act_beat_cnt <= act_beat_cnt + 1'b1;
                end
            end
        end
    end

    //==========================================================================
    // Result streaming state (read from INACTIVE result BRAM after done)
    //==========================================================================
    reg  [$clog2(RESULT_COUNT):0] result_beat_cnt;
    reg                            result_streaming;
    reg                            result_last_beat;
    reg  [ACCUM_WIDTH-1:0]        result_fifo [0:RESULT_COUNT-1];
    reg  [ACCUM_WIDTH-1:0]        result_tdata_r;
    reg                            result_tvalid_r;
    reg                            result_tlast_r;

    // Result read-back from inactive BRAM
    reg  [BUF_ADDR_W-1:0]         res_read_addr;
    reg                            res_read_en;
    wire [ACCUM_WIDTH-1:0]         res_read_data;

    //==========================================================================
    // Systolic array ping-pong instantiation
    //==========================================================================
    systolic_array_pingpong #(
        .ROWS        (ROWS),
        .COLS        (COLS),
        .DATA_WIDTH  (DATA_WIDTH),
        .ACCUM_WIDTH (ACCUM_WIDTH),
        .K_DEPTH     (K_DEPTH),
        .BUF_ADDR_W  (BUF_ADDR_W),
        .BUF_DEPTH   (BUF_DEPTH),
        .WT_ADDR_W   (WT_ADDR_W)
    ) u_sa_pp (
        .clk                (clk),
        .rst_n              (rst_n),
        .start              (start),
        .weight_preloaded   (1'b0),           // Always load weights via AXI-S
        .prefetch_start     (1'b0),
        .busy               (busy),
        .done               (done),
        .auto_swap          (auto_swap),
        .buf_sel            (buf_sel),
        // Weight data from AXI-S stream
        .weight_data        (s_axis_weight_tdata),
        .weight_ready       (sa_weight_ready),
        // Activation write to inactive buffer (from AXI-S stream)
        .host_act_wr_en     (s_axis_act_tvalid && s_axis_act_tready),
        .host_act_wr_addr   (act_wr_addr),
        .host_act_wr_data   (s_axis_act_tdata),
        .host_act_base_addr (act_base_addr),
        // Direct activation path (test bypass)
        .use_bram_act       (use_bram_act),
        .act_data           (act_data),
        .act_valid          (act_valid),
        // Result read from inactive buffer
        .host_res_rd_en     (res_read_en),
        .host_res_rd_addr   (res_read_addr),
        .host_res_rd_data   (res_read_data),
        // Raw result output (debug)
        .result_data        (result_data),
        .result_valid       (result_valid),
        // Tile base addresses
        .act_base_addr      (act_base_addr),
        .res_base_addr      (res_base_addr)
    );

    //==========================================================================
    // Result read-back FSM — read results from inactive BRAM after done
    //
    // After done + auto_swap, the buffer that SA just wrote results to becomes
    // inactive and is readable via host_res_rd_*.  We read all RESULT_COUNT
    // entries into a FIFO, then stream them out via AXI4-Stream master.
    //==========================================================================
    reg [1:0] res_state;
    reg                          read_data_valid;  // 1-cycle delayed to match BRAM latency
    localparam RES_IDLE   = 2'd0;
    localparam RES_READ   = 2'd1;
    localparam RES_STREAM = 2'd2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            res_state        <= RES_IDLE;
            res_read_en      <= 1'b0;
            res_read_addr    <= 0;
            result_beat_cnt  <= 0;
            result_streaming <= 1'b0;
            result_tvalid_r  <= 1'b0;
            result_tlast_r   <= 1'b0;
            result_tdata_r   <= 0;
            read_data_valid  <= 1'b0;
        end else begin
            case (res_state)
                RES_IDLE: begin
                    result_tvalid_r <= 1'b0;
                    read_data_valid <= 1'b0;
                    if (done) begin
                        res_state       <= RES_READ;
                        res_read_en     <= 1'b1;
                        res_read_addr   <= 0;
                        result_beat_cnt <= 0;
                    end
                end

                RES_READ: begin
                    // BRAM has 1-cycle read latency: data for addr N appears
                    // on res_read_data one cycle after the read is issued.
                    // read_data_valid delays capture by 1 cycle to align.
                    read_data_valid <= res_read_en;

                    if (read_data_valid) begin
                        result_fifo[result_beat_cnt] <= res_read_data;
                        if (result_beat_cnt == RESULT_COUNT - 1) begin
                            res_read_en      <= 1'b0;
                            result_streaming <= 1'b1;
                            result_beat_cnt  <= 0;
                            res_state        <= RES_STREAM;
                        end else begin
                            result_beat_cnt <= result_beat_cnt + 1'b1;
                        end
                    end

                    // Advance read address one cycle ahead of capture
                    if (res_read_en && (result_beat_cnt < RESULT_COUNT - 1)) begin
                        res_read_addr <= res_read_addr + 1'b1;
                    end
                end

                RES_STREAM: begin
                    // Stream results via AXI4-Stream master
                    if (m_axis_result_tready || !result_tvalid_r) begin
                        if (result_beat_cnt == RESULT_COUNT) begin
                            // All results streamed
                            result_tvalid_r  <= 1'b0;
                            result_tlast_r   <= 1'b0;
                            result_streaming <= 1'b0;
                            res_state        <= RES_IDLE;
                        end else begin
                            result_tdata_r   <= result_fifo[result_beat_cnt];
                            result_tvalid_r  <= 1'b1;
                            result_tlast_r   <= (result_beat_cnt == RESULT_COUNT - 1);
                            result_beat_cnt  <= result_beat_cnt + 1'b1;
                        end
                    end
                end

                default: res_state <= RES_IDLE;
            endcase
        end
    end

    assign m_axis_result_tvalid = result_tvalid_r;
    assign m_axis_result_tdata  = result_tdata_r;
    assign m_axis_result_tlast  = result_tlast_r;

endmodule
