`timescale 1ns / 1ps

//==============================================================================
// Module:  mac_unit (Multiply-Accumulate Unit)
// Purpose: Matrix multiplication IP core — lowest-level arithmetic unit
//          Computes acc_out = a_in × b_in + acc_in
//==============================================================================
// Design notes:
//   1. Signed integer multiply, product width = 2×DATA_WIDTH
//   2. Accumulator width = ACCUM_WIDTH, sized to prevent overflow over K sums
//   3. 2-stage pipeline — Stage1=multiply, Stage2=accumulate (maps to DSP48)
//   4. clear: resets accumulator for a new dot-product
//   5. enable=0 stalls the entire pipeline (all registers hold)
//   6. valid propagates as a shift register through pipeline stages
//==============================================================================

module mac_unit #(
    parameter DATA_WIDTH  = 16,   // Input data bit width
    parameter ACCUM_WIDTH = 40    // Accumulator bit width (>= 2*DATA_WIDTH + log2(Kmax))
) (
    input  wire                       clk,
    input  wire                       rst_n,       // Async reset, active low

    // ---- Data inputs ----
    input  wire signed [DATA_WIDTH-1:0] a_in,      // Operand A
    input  wire signed [DATA_WIDTH-1:0] b_in,      // Operand B
    input  wire signed [ACCUM_WIDTH-1:0] acc_in,   // Upstream accumulated value

    // ---- Control ----
    input  wire                       valid_in,    // Input data valid
    input  wire                       clear,       // Reset accumulator (start of new dot-product)
    input  wire                       enable,      // MAC enable (pipeline-wide stall when low)

    // ---- Data output ----
    output wire signed [ACCUM_WIDTH-1:0] acc_out,  // Accumulated result
    output wire                       valid_out    // Output valid (aligned to pipeline latency)
);

//==============================================================================
// Pipeline stage registers
//==============================================================================

// Stage 1 registers (multiply input stage)
reg  signed [2*DATA_WIDTH-1:0]  mult_result_r;    // Registered product
reg  signed [ACCUM_WIDTH-1:0]   acc_d1;           // Delayed accumulator
reg                             valid_s1;          // Valid flag for stage 1
reg                             clear_d1;          // Delayed clear

// Stage 2 registers (accumulate output stage)
reg  signed [ACCUM_WIDTH-1:0]   acc_out_r;        // Registered result
reg                             valid_s2;          // Valid flag for stage 2

//==============================================================================
// Stage 1: Signed multiply (DSP input-register stage)
//==============================================================================
// When enable=1: capture new data, advance pipeline
// When enable=0: stall — all registers hold current values
//==============================================================================
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        mult_result_r <= {(2*DATA_WIDTH){1'b0}};
        acc_d1        <= {ACCUM_WIDTH{1'b0}};
        valid_s1      <= 1'b0;
        clear_d1      <= 1'b0;
    end else if (enable) begin
        mult_result_r <= a_in * b_in;
        acc_d1        <= acc_in;
        valid_s1      <= valid_in;
        clear_d1      <= clear;
    end
    // else: pipeline stalled, hold all values
end

//==============================================================================
// Stage 2: Accumulate (DSP output-register stage)
//==============================================================================
// clear_d1=1  → result = sign-extended product (first beat of new dot-product)
// clear_d1=0  → result = acc_d1 + sign-extended product (continue accumulating)
//==============================================================================
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        acc_out_r <= {ACCUM_WIDTH{1'b0}};
        valid_s2  <= 1'b0;
    end else if (enable) begin
        if (valid_s1) begin
            if (clear_d1) begin
                // New dot-product: seed with first product
                acc_out_r <= {{(ACCUM_WIDTH - 2*DATA_WIDTH){mult_result_r[2*DATA_WIDTH-1]}},
                               mult_result_r};
            end else begin
                // Continue accumulation
                acc_out_r <= acc_d1 +
                             {{(ACCUM_WIDTH - 2*DATA_WIDTH){mult_result_r[2*DATA_WIDTH-1]}},
                              mult_result_r};
            end
        end
        // valid_s2 follows valid_s1 as a shift register
        valid_s2 <= valid_s1;
    end
    // else: pipeline stalled, hold all values
end

//==============================================================================
// Output assignment
//==============================================================================
assign acc_out   = acc_out_r;
assign valid_out = valid_s2;

endmodule
