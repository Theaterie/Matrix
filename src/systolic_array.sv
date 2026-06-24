`timescale 1ns / 1ps

//==============================================================================
// Module:  systolic_array
// Purpose: Top-level weight-stationary systolic array for matrix multiplication
//          C[M×N] += A[M×K] × B[K×N], computed one tile at a time
//==============================================================================
// Sub-modules:
//   pe_array           — ROWS×COLS grid of PEs (each wraps mac_unit)
//   controller         — FSM: IDLE → WEIGHT_LOAD → COMPUTE → READOUT → SERIALIZE → DONE
//   address_generator  — Activation read & result write address sequencing
//   result_serializer  — Captures COLS-wide results during READOUT, serializes to BRAM
//   buffer_ram (×2)    — Activation buffer + Result buffer
//
// Dataflow (weight-stationary):
//   1. Load B tile (ROWS×COLS weights) into PE array
//   2. Stream A tile activations through array, accumulating partial sums
//   3. Drain pipeline: result_serializer captures parallel results from bottom edge
//   4. Serialize: result_serializer streams one result per cycle into result BRAM
//
// Default: ROWS=16, COLS=16, computing 16×16 matrix tiles
//==============================================================================

module systolic_array #(
    parameter ROWS          = 16,          // PE array rows (M dimension tile)
    parameter COLS          = 16,          // PE array columns (N dimension tile)
    parameter DATA_WIDTH    = 16,          // Input operand width
    parameter ACCUM_WIDTH   = 40,          // Accumulator width
    parameter K_DEPTH       = 16,          // K dimension per tile (activation vectors)
    parameter BUF_ADDR_W    = 8,           // Buffer address width (log2 of max depth)
    parameter BUF_DEPTH     = 256,         // Buffer depth
    parameter WT_ADDR_W     = 8            // Weight address width ($clog2(ROWS*COLS))
) (
    input  wire                                clk,
    input  wire                                rst_n,           // Async reset, active low

    // ---- Control ----
    input  wire                                start,            // Pulse: begin tile computation
    input  wire                                weight_preloaded, // 1 = weights already in PE array (skip load)
    input  wire                                prefetch_start,   // Pulse: start BRAM prefetch early
    output wire                                busy,             // High during operation
    output wire                                done,             // Pulse: tile computation complete

    // ---- Weight input (serial, loaded during WEIGHT_LOAD phase) ----
    input  wire [DATA_WIDTH-1:0]               weight_data,      // Weight value
    output wire                                weight_ready,     // Ready to accept weight (WEIGHT_LOAD phase)

    // ---- Activation input (one per PE row — skew handled inside pe_array) ----
    //       When use_bram_act=1: act_data/act_valid are ignored; data flows from
    //       act_bram through act_deserializer to PE array.
    //       When use_bram_act=0: act_data/act_valid drive PE array directly (test mode).
    input  wire                                use_bram_act,        // 1 = BRAM path, 0 = external act_data path
    input  wire [DATA_WIDTH-1:0]               act_data [0:ROWS-1],  // One activation per row
    input  wire                                act_valid,            // Activation valid (1 per cycle during COMPUTE)

    // ---- Activation BRAM write port (external host pre-loads activations) ----
    input  wire                                act_wr_en,            // Activation BRAM write enable
    input  wire [BUF_ADDR_W-1:0]               act_wr_addr,          // Activation BRAM write address
    input  wire [DATA_WIDTH-1:0]               act_wr_data,          // Activation BRAM write data

    // ---- Result output (one per column, for debug/monitoring) ----
    output wire [ACCUM_WIDTH-1:0]              result_data [0:COLS-1],  // Result per column
    output wire                                result_valid,         // Result valid strobe

    // ---- Result BRAM read port (external host reads computed results) ----
    input  wire                                res_rd_en,            // Result BRAM read enable
    input  wire [BUF_ADDR_W-1:0]               res_rd_addr,          // Result BRAM read address
    output wire [ACCUM_WIDTH-1:0]              res_rd_data,          // Result BRAM read data

    // ---- Tile base addresses (for tiled operation over larger matrices) ----
    input  wire [BUF_ADDR_W-1:0]               act_base_addr,    // Activation buffer base address
    input  wire [BUF_ADDR_W-1:0]               res_base_addr     // Result buffer base address
);

//==============================================================================
// Controller signals
//==============================================================================
wire                ctrl_pe_clear;
wire                ctrl_pe_enable;
wire                ctrl_weight_wren;
wire [WT_ADDR_W-1:0] ctrl_weight_addr;
wire [2:0]          ctrl_phase;
wire                addr_enable;

//==============================================================================
// Address generator signals
//==============================================================================
wire [BUF_ADDR_W-1:0] agen_act_rd_addr;
wire                  agen_act_rd_en;
wire [BUF_ADDR_W-1:0] agen_res_wr_addr;
wire                  agen_res_wr_en;
wire                  agen_act_done;
wire                  agen_res_done;

//==============================================================================
// Buffer RAM signals
//==============================================================================
wire [DATA_WIDTH-1:0]  act_bram_rd_data;    // BRAM read data

//==============================================================================
// Activation deserializer signals
//==============================================================================
wire [DATA_WIDTH-1:0]  deser_act_data [0:ROWS-1];  // Deserialized per-row activations
wire                   deser_act_valid;             // Deserializer valid
wire                   deser_prefetch_done;         // BRAM prefetch complete
wire                   deser_bram_rd_en;            // Deserializer → BRAM read enable
wire [BUF_ADDR_W-1:0]  deser_bram_rd_addr;         // Deserializer → BRAM read address

//==============================================================================
// PE array activation input mux
//   use_bram_act=1: data flows BRAM → deserializer → PE array
//   use_bram_act=0: data flows external act_data → PE array (test/bypass)
//==============================================================================
wire [DATA_WIDTH-1:0]  pe_act_data [0:ROWS-1];
wire                   pe_act_valid;

assign pe_act_data  = use_bram_act ? deser_act_data  : act_data;
assign pe_act_valid = use_bram_act ? deser_act_valid : act_valid;

//==============================================================================
// Result serializer signals
//==============================================================================
wire [ACCUM_WIDTH-1:0] ser_data;
wire                   ser_valid;
wire                   ser_done;
wire                   ser_capture_en;   // Capture during READOUT (pipeline drain)
wire                   ser_shift_en;     // Shift out during SERIALIZE

//==============================================================================
// Controller instantiation
//   deser_ready_gated: when use_bram_act=0 (direct path), bypass prefetch
//   requirement so controller can enter COMPUTE without BRAM data ready.
//==============================================================================
wire deser_ready_gated;
assign deser_ready_gated = deser_prefetch_done || !use_bram_act;

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
    .deser_ready     (deser_ready_gated)
);

// Weight ready during WEIGHT_LOAD phase (gated when preloaded)
assign weight_ready = (ctrl_phase == 3'b001) && !weight_preloaded;
assign addr_enable  = ctrl_pe_enable;

// Serializer control: capture during READOUT, shift during SERIALIZE
assign ser_capture_en = (ctrl_phase == 3'b011);
assign ser_shift_en   = (ctrl_phase == 3'b100);

//==============================================================================
// Address generator instantiation
//==============================================================================
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

//==============================================================================
// Activation deserializer — pre-fetches activations from BRAM into a flip-flop
//   buffer, then streams ROWS values per cycle to the PE array during COMPUTE.
//   PREFETCH starts on 'start' pulse (1 cycle before WEIGHT_LOAD), overlaps
//   entirely with weight loading, completes simultaneously.
//==============================================================================
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
    .bram_rd_data   (act_bram_rd_data),
    .act_data_out   (deser_act_data),
    .act_valid_out  (deser_act_valid),
    .act_base_addr  (act_base_addr),
    .prefetch_start (start || prefetch_start),
    .stream_en      (ctrl_pe_enable && (ctrl_phase == 3'b010)),  // COMPUTE phase
    .prefetch_done  (deser_prefetch_done),
    .stream_done    ()  // Not used — controller manages COMPUTE cycle count
);

//==============================================================================
// Activation buffer RAM (Port A: external write, Port B: read by deserializer)
//==============================================================================
buffer_ram #(
    .DATA_WIDTH (DATA_WIDTH),
    .ADDR_WIDTH (BUF_ADDR_W),
    .DEPTH      (BUF_DEPTH)
) u_act_bram (
    .clk      (clk),
    // Write port: external host pre-loads activations into BRAM
    .wr_en    (act_wr_en),
    .wr_addr  (act_wr_addr),
    .wr_data  (act_wr_data),
    // Read port: deserializer reads activations during PREFETCH
    .rd_en    (deser_bram_rd_en),
    .rd_addr  (deser_bram_rd_addr),
    .rd_data  (act_bram_rd_data)
);

//==============================================================================
// Result buffer RAM (Port A: write from serializer, Port B: external read)
//   Write is qualified by BOTH address generator write enable AND serializer
//   valid — ensures no garbage data is written.
//==============================================================================
buffer_ram #(
    .DATA_WIDTH (ACCUM_WIDTH),
    .ADDR_WIDTH (BUF_ADDR_W),
    .DEPTH      (BUF_DEPTH)
) u_res_bram (
    .clk      (clk),
    // Write port: serialized results from result_serializer
    .wr_en    (agen_res_wr_en && ser_valid),
    .wr_addr  (agen_res_wr_addr),
    .wr_data  (ser_data),
    // Read port: external host reads computed results
    .rd_en    (res_rd_en),
    .rd_addr  (res_rd_addr),
    .rd_data  (res_rd_data)
);

//==============================================================================
// Result serializer — captures COLS-wide results during READOUT,
//   then serializes them one entry per cycle into res_bram during SERIALIZE.
//==============================================================================
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

//==============================================================================
// PE array instantiation (16×16 weight-stationary systolic array)
//==============================================================================
pe_array #(
    .ROWS        (ROWS),
    .COLS        (COLS),
    .DATA_WIDTH  (DATA_WIDTH),
    .ACCUM_WIDTH (ACCUM_WIDTH)
) u_pe_array (
    .clk          (clk),
    .rst_n        (rst_n),

    // Activation: one value per row (skew inside pe_array)
    //   Source depends on use_bram_act: BRAM path or external port
    .act_data_in  (pe_act_data),
    .act_valid_in (pe_act_valid),

    // Weight loading
    .weight_data  (weight_data),
    .weight_addr  (ctrl_weight_addr),
    .weight_wren  (ctrl_weight_wren),

    // Results
    .result_data  (result_data),
    .result_valid (result_valid),

    // Control
    .clear        (ctrl_pe_clear),
    .enable       (ctrl_pe_enable)
);

endmodule
