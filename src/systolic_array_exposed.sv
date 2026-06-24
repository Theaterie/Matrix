//==============================================================================
// Module:  systolic_array_exposed
// Purpose: Variant of systolic_array with BRAM interfaces broken out to ports.
//          Used by systolic_array_pingpong to insert ping-pong buffer MUXes
//          between the systolic_array logic and the physical BRAMs.
//==============================================================================
// Differences from systolic_array:
//   - Activation BRAM is external: _rd_en/_rd_addr/_rd_data ports replace
//     the internal buffer_ram instantiation. Host writes directly to external
//     BRAM (not through this module).
//   - Result BRAM is external: _wr_en/_wr_addr/_wr_data + _rd_en/_rd_addr/_rd_data
//     ports replace the internal buffer_ram instantiation.
//   - All other logic (controller, PE array, deserializer, serializer,
//     address generator) is identical to systolic_array.
//==============================================================================

module systolic_array_exposed #(
    parameter ROWS          = 16,
    parameter COLS          = 16,
    parameter DATA_WIDTH    = 16,
    parameter ACCUM_WIDTH   = 40,
    parameter K_DEPTH       = 16,
    parameter BUF_ADDR_W    = 8,
    parameter BUF_DEPTH     = 256,
    parameter WT_ADDR_W     = 8
) (
    input  wire                                clk,
    input  wire                                rst_n,

    // ---- Control ----
    input  wire                                start,
    input  wire                                weight_preloaded,
    input  wire                                prefetch_start,
    output wire                                busy,
    output wire                                done,

    // ---- Weight input ----
    input  wire [DATA_WIDTH-1:0]               weight_data,
    output wire                                weight_ready,

    // ---- Activation input (direct path, for test/bypass) ----
    input  wire                                use_bram_act,
    input  wire [DATA_WIDTH-1:0]               act_data [0:ROWS-1],
    input  wire                                act_valid,

    // ---- Activation BRAM read port (→ deserializer, ← external BRAM) ----
    output wire                                act_bram_rd_en,
    output wire [BUF_ADDR_W-1:0]               act_bram_rd_addr,
    input  wire [DATA_WIDTH-1:0]               act_bram_rd_data,

    // ---- Result BRAM write port (← serializer, → external BRAM) ----
    output wire                                res_bram_wr_en,
    output wire [BUF_ADDR_W-1:0]               res_bram_wr_addr,
    output wire [ACCUM_WIDTH-1:0]              res_bram_wr_data,

    // ---- Result BRAM read port (← external reader, → external BRAM) ----
    input  wire                                res_bram_rd_en,
    input  wire [BUF_ADDR_W-1:0]               res_bram_rd_addr,
    output wire [ACCUM_WIDTH-1:0]              res_bram_rd_data,

    // ---- Result output (for debug/monitoring) ----
    output wire [ACCUM_WIDTH-1:0]              result_data [0:COLS-1],
    output wire                                result_valid,

    // ---- Tile base addresses ----
    input  wire [BUF_ADDR_W-1:0]               act_base_addr,
    input  wire [BUF_ADDR_W-1:0]               res_base_addr
);

    //==========================================================================
    // Controller signals
    //==========================================================================
    wire                ctrl_pe_clear;
    wire                ctrl_pe_enable;
    wire                ctrl_weight_wren;
    wire [WT_ADDR_W-1:0] ctrl_weight_addr;
    wire [2:0]          ctrl_phase;
    wire                addr_enable;

    //==========================================================================
    // Address generator signals
    //==========================================================================
    wire [BUF_ADDR_W-1:0] agen_act_rd_addr;
    wire                  agen_act_rd_en;
    wire [BUF_ADDR_W-1:0] agen_res_wr_addr;
    wire                  agen_res_wr_en;
    wire                  agen_act_done;
    wire                  agen_res_done;

    //==========================================================================
    // Activation deserializer signals
    //==========================================================================
    wire [DATA_WIDTH-1:0]  deser_act_data [0:ROWS-1];
    wire                   deser_act_valid;
    wire                   deser_prefetch_done;
    wire                   deser_bram_rd_en;
    wire [BUF_ADDR_W-1:0]  deser_bram_rd_addr;

    //==========================================================================
    // PE array activation input mux
    //==========================================================================
    wire [DATA_WIDTH-1:0]  pe_act_data [0:ROWS-1];
    wire                   pe_act_valid;

    assign pe_act_data  = use_bram_act ? deser_act_data  : act_data;
    assign pe_act_valid = use_bram_act ? deser_act_valid : act_valid;

    //==========================================================================
    // Result serializer signals
    //==========================================================================
    wire [ACCUM_WIDTH-1:0] ser_data;
    wire                   ser_valid;
    wire                   ser_done;
    wire                   ser_capture_en;
    wire                   ser_shift_en;

    //==========================================================================
    // Controller instantiation
    //==========================================================================
    controller #(
        .ROWS       (ROWS),
        .COLS       (COLS),
        .K_DEPTH    (K_DEPTH),
        .ADDR_WIDTH (WT_ADDR_W)
    ) u_controller (
        .clk             (clk),
        .rst_n           (rst_n),
        .start           (start),
        .weight_preloaded(weight_preloaded),
        .busy            (busy),
        .done            (done),
        .pe_clear        (ctrl_pe_clear),
        .pe_enable       (ctrl_pe_enable),
        .weight_wren     (ctrl_weight_wren),
        .weight_addr     (ctrl_weight_addr),
        .phase           (ctrl_phase),
        .compute_cycle   (),
        .readout_cycle   (),
        .serialize_cycle (),
        .deser_ready     (deser_prefetch_done)
    );

    assign weight_ready = (ctrl_phase == 3'b001) && !weight_preloaded;
    assign addr_enable  = ctrl_pe_enable;
    assign ser_capture_en = (ctrl_phase == 3'b011);
    assign ser_shift_en   = (ctrl_phase == 3'b100);

    //==========================================================================
    // Address generator
    //==========================================================================
    address_generator #(
        .DATA_WIDTH  (DATA_WIDTH),
        .ACCUM_WIDTH (ACCUM_WIDTH),
        .ADDR_WIDTH  (BUF_ADDR_W),
        .ROWS        (ROWS),
        .COLS        (COLS),
        .TILE_K      (K_DEPTH),
        .TILE_M      (ROWS)
    ) u_addr_gen (
        .clk           (clk),
        .rst_n         (rst_n),
        .phase         (ctrl_phase),
        .enable        (addr_enable),
        .act_base_addr (act_base_addr),
        .res_base_addr (res_base_addr),
        .act_rd_addr   (agen_act_rd_addr),
        .act_rd_en     (agen_act_rd_en),
        .res_wr_addr   (agen_res_wr_addr),
        .res_wr_en     (agen_res_wr_en),
        .act_done      (agen_act_done),
        .res_done      (agen_res_done)
    );

    //==========================================================================
    // Activation deserializer — reads from EXTERNAL act_bram
    //==========================================================================
    act_deserializer #(
        .ROWS       (ROWS),
        .K_DEPTH    (K_DEPTH),
        .DATA_WIDTH (DATA_WIDTH),
        .ADDR_WIDTH (BUF_ADDR_W)
    ) u_act_deserializer (
        .clk            (clk),
        .rst_n          (rst_n),
        .bram_rd_en     (deser_bram_rd_en),
        .bram_rd_addr   (deser_bram_rd_addr),
        .bram_rd_data   (act_bram_rd_data),      // ← from external BRAM
        .act_data_out   (deser_act_data),
        .act_valid_out  (deser_act_valid),
        .act_base_addr  (act_base_addr),
        .prefetch_start (start || prefetch_start),
        .stream_en      (ctrl_pe_enable && (ctrl_phase == 3'b010)),
        .prefetch_done  (deser_prefetch_done),
        .stream_done    ()
    );

    // Expose deserializer BRAM read interface
    assign act_bram_rd_en   = deser_bram_rd_en;
    assign act_bram_rd_addr = deser_bram_rd_addr;

    //==========================================================================
    // Result serializer
    //==========================================================================
    result_serializer #(
        .ROWS       (ROWS),
        .COLS       (COLS),
        .DATA_WIDTH (ACCUM_WIDTH)
    ) u_result_serializer (
        .clk            (clk),
        .rst_n          (rst_n),
        .parallel_in    (result_data),
        .parallel_valid (result_valid),
        .serial_data    (ser_data),
        .serial_valid   (ser_valid),
        .capture_en     (ser_capture_en),
        .shift_en       (ser_shift_en),
        .done           (ser_done)
    );

    // Result BRAM write port: qualified write to external BRAM
    assign res_bram_wr_en   = agen_res_wr_en && ser_valid;
    assign res_bram_wr_addr = agen_res_wr_addr;
    assign res_bram_wr_data = ser_data;

    // Result BRAM read port: passthrough from external reader
    //   buffer_ram has 1-cycle read latency; external BRAM provides this
    assign res_bram_rd_data = {ACCUM_WIDTH{1'b0}};  // placeholder — reads go through external BRAM
    // NOTE: The external BRAM handles the actual read. This port provides the
    // data to the host. The host should read directly from the external BRAM's
    // read data port.

    //==========================================================================
    // PE array
    //==========================================================================
    pe_array #(
        .ROWS        (ROWS),
        .COLS        (COLS),
        .DATA_WIDTH  (DATA_WIDTH),
        .ACCUM_WIDTH (ACCUM_WIDTH)
    ) u_pe_array (
        .clk          (clk),
        .rst_n        (rst_n),
        .act_data_in  (pe_act_data),
        .act_valid_in (pe_act_valid),
        .weight_data  (weight_data),
        .weight_addr  (ctrl_weight_addr),
        .weight_wren  (ctrl_weight_wren),
        .result_data  (result_data),
        .result_valid (result_valid),
        .clear        (ctrl_pe_clear),
        .enable       (ctrl_pe_enable)
    );

endmodule
