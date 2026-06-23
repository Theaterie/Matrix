`timescale 1ns / 1ps

//==============================================================================
// Module:  buffer_ram
// Purpose: Inferred dual-port block RAM for systolic array data storage
//          Port A: write-only (store activations or results)
//          Port B: read-only  (feed activations to PE array)
//==============================================================================
// Design notes:
//   1. Simple dual-port (1 read + 1 write) — matches Xilinx BRAM primitive
//   2. Read-after-write behavior: returns OLD data when rd_addr == wr_addr
//      (read-first mode for Vivado BRAM inference)
//   3. Synthesizes to BRAM36 tiles on Xilinx UltraScale+ devices
//   4. Parameterized DATA_WIDTH and DEPTH for flexibility
//
// Usage in systolic_array:
//   - Activation buffer: DATA_WIDTH=16, DEPTH=256  (16×16 tile)
//   - Result buffer:     DATA_WIDTH=40, DEPTH=256  (16×16 tile)
//==============================================================================

module buffer_ram #(
    parameter DATA_WIDTH = 16,          // Data width in bits
    parameter ADDR_WIDTH = 8,           // Address width (log2 of DEPTH)
    parameter DEPTH      = 256          // Memory depth
) (
    input  wire                          clk,

    // ---- Write port (Port A) ----
    input  wire                          wr_en,
    input  wire [ADDR_WIDTH-1:0]         wr_addr,
    input  wire [DATA_WIDTH-1:0]         wr_data,

    // ---- Read port (Port B) ----
    input  wire                          rd_en,
    input  wire [ADDR_WIDTH-1:0]         rd_addr,
    output reg  [DATA_WIDTH-1:0]         rd_data
);

//==============================================================================
// Memory array (inferred BRAM)
//==============================================================================
reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];

//==============================================================================
// Write logic (Port A) — synchronous write
//==============================================================================
always @(posedge clk) begin
    if (wr_en)
        mem[wr_addr] <= wr_data;
end

//==============================================================================
// Read logic (Port B) — synchronous read with enable
//==============================================================================
always @(posedge clk) begin
    if (rd_en)
        rd_data <= mem[rd_addr];
    // else: rd_data holds previous value
end

endmodule
