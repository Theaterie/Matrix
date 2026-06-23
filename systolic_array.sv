//==============================================================================
// Module:  systolic_array
// Purpose: Top-level weight-stationary systolic array for matrix multiplication
//          C[M×N] += A[M×K] × B[K×N], computed one tile at a time
//==============================================================================
// Sub-modules:
//   pe_array          — ROWS×COLS grid of PEs (each wraps mac_unit)
//   controller        — FSM: IDLE → WEIGHT_LOAD → COMPUTE → READOUT → DONE
//   address_generator — Activation read & result write address sequencing
//   buffer_ram (×2)   — Activation buffer + Result buffer
//
// Dataflow (weight-stationary):
//   1. Load B tile (ROWS×COLS weights) into PE array
//   2. Stream A tile activations through array, accumulating partial sums
//   3. Drain results from bottom edge into result buffer
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
    output wire                                busy,             // High during operation
    output wire                                done,             // Pulse: tile computation complete

    // ---- Weight input (serial, loaded during WEIGHT_LOAD phase) ----
    input  wire [DATA_WIDTH-1:0]               weight_data,      // Weight value
    output wire                                weight_ready,     // Ready to accept weight (WEIGHT_LOAD phase)

    // ---- Activation input (single value, broadcast to all rows) ----
    input  wire [DATA_WIDTH-1:0]               act_data,         // Activation value
    input  wire                                act_valid,        // Activation valid (1 per cycle during COMPUTE)

    // ---- Result output (one per column) ----
    output wire [ACCUM_WIDTH-1:0]              result_data [0:COLS-1],  // Result per column
    output wire                                result_valid,     // Result valid strobe

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
wire [1:0]          ctrl_phase;
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
wire [DATA_WIDTH-1:0]  act_bram_rd_data;
wire [ACCUM_WIDTH-1:0] res_bram_rd_data;   // Not used in current flow (write-only to res_bram)

//==============================================================================
// PE array activation input routing
//   Broadcast single act_data to all rows (skew handled inside pe_array)
//==============================================================================
wire [DATA_WIDTH-1:0] act_data_rows [0:ROWS-1];

genvar i;
generate
    for (i = 0; i < ROWS; i = i + 1) begin : gen_act_broadcast
        assign act_data_rows[i] = act_data;
    end
endgenerate

//==============================================================================
// Controller instantiation
//==============================================================================
controller #(
    .ROWS       (ROWS),
    .COLS       (COLS),
    .K_DEPTH    (K_DEPTH),
    .ADDR_WIDTH (WT_ADDR_W)
) u_controller (
    .clk           (clk),
    .rst_n         (rst_n),
    .start         (start),
    .busy          (busy),
    .done          (done),
    .pe_clear      (ctrl_pe_clear),
    .pe_enable     (ctrl_pe_enable),
    .weight_wren   (ctrl_weight_wren),
    .weight_addr   (ctrl_weight_addr),
    .phase         (ctrl_phase),
    .compute_cycle (),
    .readout_cycle ()
);

// Weight ready during WEIGHT_LOAD phase
assign weight_ready = (ctrl_phase == 2'b01);
assign addr_enable  = ctrl_pe_enable;

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
// Activation buffer RAM (Port A: external write, Port B: read to PE array)
//==============================================================================
buffer_ram #(
    .DATA_WIDTH (DATA_WIDTH),
    .ADDR_WIDTH (BUF_ADDR_W),
    .DEPTH      (BUF_DEPTH)
) u_act_bram (
    .clk      (clk),
    // Write port: external host loads activations
    .wr_en    (1'b0),               // External write not implemented yet — use act_data directly
    .wr_addr  ({BUF_ADDR_W{1'b0}}),
    .wr_data  ({DATA_WIDTH{1'b0}}),
    // Read port: address generator reads activations
    .rd_en    (agen_act_rd_en),
    .rd_addr  (agen_act_rd_addr),
    .rd_data  (act_bram_rd_data)
);

//==============================================================================
// Result buffer RAM (Port A: write from PE array, Port B: external read)
//==============================================================================
buffer_ram #(
    .DATA_WIDTH (ACCUM_WIDTH),
    .ADDR_WIDTH (BUF_ADDR_W),
    .DEPTH      (BUF_DEPTH)
) u_res_bram (
    .clk      (clk),
    // Write port: results from PE array during READOUT
    // NOTE: result_data is unpacked (COLS × ACCUM_WIDTH); buffer_ram takes single word.
    // For full implementation, a result serializer is needed between pe_array and res_bram.
    // Current: write only result_data[0] as a representative value.
    .wr_en    (agen_res_wr_en),
    .wr_addr  (agen_res_wr_addr),
    .wr_data  (result_data[0]),     // Simplified — full impl needs serializer
    // Read port: external host reads results
    .rd_en    (1'b0),               // External read not implemented yet
    .rd_addr  ({BUF_ADDR_W{1'b0}}),
    .rd_data  (res_bram_rd_data)
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

    // Activation: broadcast same value to all rows (skew inside pe_array)
    .act_data_in  (act_data_rows),
    .act_valid_in (act_valid),

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
