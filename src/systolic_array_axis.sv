//==============================================================================
// Module:  systolic_array_axis
// Purpose: Wraps systolic_array with AXI4-Stream interfaces for clean
//          integration with AXI-based SoC interconnects and DMA engines.
//==============================================================================
// Interfaces:
//   S_AXIS_WEIGHT  — Slave:  weight data stream (1 beat per weight, WEIGHT_LOAD)
//   S_AXIS_ACT     — Slave:  activation data stream (1 beat per activation)
//   M_AXIS_RESULT  — Master: result data stream (1 beat per result, SERIALIZE)
//
// AXI4-Stream handshaking:
//   Valid before Ready:  master asserts TVALID, waits for TREADY
//   Ready before Valid:  slave asserts TREADY, waits for TVALID
//   Transfer occurs when both TVALID and TREADY are high on the same cycle.
//
// TLAST signaling:
//   S_AXIS_WEIGHT.TLAST — asserted on last weight of tile
//   S_AXIS_ACT.TLAST    — asserted on last activation of tile
//   M_AXIS_RESULT.TLAST — asserted on last result of tile
//==============================================================================

module systolic_array_axis #(
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
    //   Activation data written to act_bram before starting computation.
    //   Each beat = one activation value; TLAST marks end of tile's activations.
    input  wire                              s_axis_act_tvalid,
    output wire                              s_axis_act_tready,
    input  wire [DATA_WIDTH-1:0]             s_axis_act_tdata,
    input  wire                              s_axis_act_tlast,

    // ---- AXI4-Stream Result Master (M_AXIS_RESULT) ----
    //   Results streamed out after computation completes.
    output wire                              m_axis_result_tvalid,
    input  wire                              m_axis_result_tready,
    output wire [ACCUM_WIDTH-1:0]            m_axis_result_tdata,
    output wire                              m_axis_result_tlast,

    // ---- Control ----
    input  wire                              start,            // Pulse: begin tile computation
    output wire                              busy,
    output wire                              done,

    // ---- Direct activation input (bypass BRAM, for test) ----
    input  wire                              use_bram_act,
    input  wire [DATA_WIDTH-1:0]             act_data [0:ROWS-1],
    input  wire                              act_valid,

    // ---- Raw result output (for debug) ----
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
    // Activation loading state (write to act_bram)
    //==========================================================================
    reg  [$clog2(ACT_COUNT):0] act_beat_cnt;
    wire                        act_streaming;
    wire                        act_last_beat;
    reg                         act_preload_done;

    assign act_streaming  = (act_beat_cnt < ACT_COUNT);
    assign act_last_beat  = (act_beat_cnt == ACT_COUNT - 1);

    // Accept activations when preloading
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
    // Result streaming state (read from res_bram)
    //==========================================================================
    reg  [$clog2(RESULT_COUNT):0] result_beat_cnt;
    reg                            result_streaming;
    reg                            result_last_beat;
    reg  [ACCUM_WIDTH-1:0]        result_fifo [0:RESULT_COUNT-1];
    reg  [ACCUM_WIDTH-1:0]        result_tdata_r;
    reg                            result_tvalid_r;
    reg                            result_tlast_r;

    wire m_axis_result_tvalid_int;
    wire m_axis_result_tlast_int;

    // Result read-back from BRAM: sequential read during/after SERIALIZE
    reg  [BUF_ADDR_W-1:0]         res_read_addr;
    reg                            res_read_en;
    wire [ACCUM_WIDTH-1:0]         res_read_data;

    //==========================================================================
    // Systolic array instantiation
    //==========================================================================
    systolic_array #(
        .ROWS        (ROWS),
        .COLS        (COLS),
        .DATA_WIDTH  (DATA_WIDTH),
        .ACCUM_WIDTH (ACCUM_WIDTH),
        .K_DEPTH     (K_DEPTH),
        .BUF_ADDR_W  (BUF_ADDR_W),
        .BUF_DEPTH   (BUF_DEPTH),
        .WT_ADDR_W   (WT_ADDR_W)
    ) u_systolic_array (
        .clk           (clk),
        .rst_n         (rst_n),
        .start         (start),
        .weight_preloaded(1'b0),  // AXI-S wrapper always loads weights
        .prefetch_start(1'b0),
        .busy          (busy),
        .done          (done),
        .use_bram_act  (use_bram_act),
        .weight_data   (s_axis_weight_tdata),       // From AXI-S weight stream
        .weight_ready  (sa_weight_ready),
        .act_data      (act_data),
        .act_valid     (act_valid),
        .act_wr_en     (s_axis_act_tvalid && s_axis_act_tready),
        .act_wr_addr   (act_beat_cnt[BUF_ADDR_W-1:0]),
        .act_wr_data   (s_axis_act_tdata),
        .result_data   (result_data),
        .result_valid  (result_valid),
        .res_rd_en     (res_read_en),
        .res_rd_addr   (res_read_addr),
        .res_rd_data   (res_read_data),
        .act_base_addr (act_base_addr),
        .res_base_addr (res_base_addr)
    );

    //==========================================================================
    // Result read-back FSM — read results from res_bram after done
    //==========================================================================
    reg [1:0] res_state;
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
        end else begin
            case (res_state)
                RES_IDLE: begin
                    result_tvalid_r <= 1'b0;
                    if (done) begin
                        res_state       <= RES_READ;
                        res_read_en     <= 1'b1;
                        res_read_addr   <= 0;
                        result_beat_cnt <= 0;
                    end
                end

                RES_READ: begin
                    // Store current read data(combinational BRAM: valid same cycle)
                    if (res_read_en) begin
                        result_fifo[result_beat_cnt] <= res_read_data;
                    end

                    if (result_beat_cnt == RESULT_COUNT - 1) begin
                        // All results read from BRAM (last data stored this cycle)
                        res_read_en      <= 1'b0;
                        result_streaming <= 1'b1;
                        result_beat_cnt  <= 0;
                        res_state        <= RES_STREAM;
                    end else begin
                        res_read_addr    <= res_read_addr + 1'b1;
                        result_beat_cnt  <= result_beat_cnt + 1'b1;
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
