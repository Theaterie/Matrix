`timescale 1ns / 1ps

//==============================================================================
// Module:  pe (Processing Element)
// Purpose: Weight-stationary systolic array processing element
//          Stores one weight value; computes psum_out = psum_in + weight * act_in
//==============================================================================
// Architecture:
//   1. Wraps mac_unit for signed multiply-accumulate (2-stage DSP48 pipeline)
//   2. Weight register: captures act_in when weight_load=1 (weight-stationary)
//   3. Activation pass-through: 2-deep shift register matches mac_unit latency
//   4. Valid pass-through: 2-deep shift register for correct systolic alignment
//   5. Partial sum: psum_in -> mac_unit.acc_in, mac_unit.acc_out -> psum_out
//
// Latency: 2 cycles from input to output (determined by mac_unit pipeline)
//   Cycle 0: act_in/psum_in captured in mac_unit Stage1, product computed
//   Cycle 1: product + psum_in accumulated in mac_unit Stage2
//   Cycle 2: psum_out valid; act_out = act_in (delayed 2 cycles)
//==============================================================================

module pe #(
    parameter DATA_WIDTH  = 16,       // Input operand width
    parameter ACCUM_WIDTH = 40        // Accumulator width
) (
    input  wire                             clk,
    input  wire                             rst_n,          // Async reset, active low

    // ---- Activation path (left -> right) ----
    input  wire signed [DATA_WIDTH-1:0]     act_in,         // Activation from left neighbor
    input  wire                             valid_in,       // Activation valid flag
    output wire signed [DATA_WIDTH-1:0]     act_out,        // Activation to right neighbor
    output wire                             valid_out,      // Delayed valid (aligned to act_out)

    // ---- Partial sum path (top -> bottom) ----
    input  wire signed [ACCUM_WIDTH-1:0]    psum_in,        // Partial sum from above neighbor
    output wire signed [ACCUM_WIDTH-1:0]    psum_out,       // Partial sum to below neighbor
    output wire                             psum_valid,     // Partial sum valid flag

    // ---- Control ----
    input  wire                             weight_load,    // Load weight from act_in
    input  wire                             clear,          // Reset accumulator (new dot-product)
    input  wire                             enable          // Pipeline stall (active high)
);

//==============================================================================
// Local registers
//==============================================================================
reg signed [DATA_WIDTH-1:0]  weight_r;      // Stationary weight register
reg signed [DATA_WIDTH-1:0]  act_d1, act_d2; // Activation shift register (2-deep)
reg                          valid_d1, valid_d2; // Valid shift register (2-deep)

//==============================================================================
// Weight register
//   - Loaded from act_in when weight_load=1
//   - Holds value indefinitely (weight-stationary dataflow)
//==============================================================================
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        weight_r <= {DATA_WIDTH{1'b0}};
    end else if (enable && weight_load) begin
        weight_r <= act_in;
    end
    // else: weight_r holds (stationary)
end

//==============================================================================
// Activation & valid pass-through (2-deep shift register)
//   - Matches mac_unit's 2-stage pipeline latency
//   - Ensures activation arrives at next PE aligned with partial sum
//==============================================================================
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        act_d1   <= {DATA_WIDTH{1'b0}};
        act_d2   <= {DATA_WIDTH{1'b0}};
        valid_d1 <= 1'b0;
        valid_d2 <= 1'b0;
    end else if (enable) begin
        act_d1   <= act_in;
        act_d2   <= act_d1;
        valid_d1 <= valid_in;
        valid_d2 <= valid_d1;
    end
    // else: stalled, hold values
end

assign act_out   = act_d2;
assign valid_out = valid_d2;

//==============================================================================
// MAC unit instantiation
//   a_in  = act_in       (activation from left)
//   b_in  = weight_r     (stored weight, stationary)
//   acc_in = psum_in     (partial sum from above)
//   acc_out = psum_out   (partial sum to below)
//==============================================================================
mac_unit #(
    .DATA_WIDTH (DATA_WIDTH),
    .ACCUM_WIDTH(ACCUM_WIDTH)
) u_mac (
    .clk        (clk),
    .rst_n      (rst_n),
    .a_in       (act_in),
    .b_in       (weight_r),
    .acc_in     (psum_in),
    .valid_in   (valid_in),
    .clear      (clear),
    .enable     (enable),
    .acc_out    (psum_out),
    .valid_out  (psum_valid)
);

endmodule
