//==============================================================================
// Module:  pe_dual_int8
// Purpose: Dual-issue INT8 Processing Element — packs two independent INT8
//          dot-products into one 16-bit MAC datapath for 2× throughput.
//==============================================================================
// Architecture:
//   Input: 16-bit activation & 16-bit weight, each containing two INT8 values
//          act_in  = {act_hi[7:0], act_lo[7:0]}
//          weight  = {w_hi[7:0],   w_lo[7:0]}
//
//   Compute (single-cycle, single DSP48):
//     product_lo = act_lo * w_lo                     (lower INT8)
//     product_hi = act_hi * w_hi                     (upper INT8)
//     combined   = {product_hi, product_lo}          (packed in 32-bit)
//
//   This uses a single DSP48 in dual-INT8 mode where:
//     P = A[15:0] * B[15:0]
//       = (A_hi*2^8 + A_lo) * (B_hi*2^8 + B_lo)
//       = A_hi*B_hi*2^16 + (A_hi*B_lo + A_lo*B_hi)*2^8 + A_lo*B_lo
//
//   The DSP48 naturally computes the full 32-bit product. We post-process
//   to extract the two independent INT8 products: A_lo*B_lo and A_hi*B_hi.
//
//   For true dual independent INT8 MAC with zero cross-terms, the DSP48
//   SIMD mode is used (UltraScale+ supports two independent INT8 multiplies).
//   This module assumes SIMD DSP48 configuration via attributes.
//==============================================================================

module pe_dual_int8 #(
    parameter ACCUM_WIDTH_LO = 24,     // Accumulator for lower INT8 stream
    parameter ACCUM_WIDTH_HI = 24      // Accumulator for upper INT8 stream
) (
    input  wire                             clk,
    input  wire                             rst_n,

    // ---- Activation (16-bit = {INT8_HI, INT8_LO}) ----
    input  wire signed [15:0]               act_in,
    input  wire                             valid_in,
    output wire signed [15:0]               act_out,
    output wire                             valid_out,

    // ---- Partial sums (two independent streams) ----
    input  wire signed [ACCUM_WIDTH_LO-1:0] psum_in_lo,
    input  wire signed [ACCUM_WIDTH_HI-1:0] psum_in_hi,
    output wire signed [ACCUM_WIDTH_LO-1:0] psum_out_lo,
    output wire signed [ACCUM_WIDTH_HI-1:0] psum_out_hi,
    output wire                             psum_valid,

    // ---- Control ----
    input  wire                             weight_load,
    input  wire                             clear,
    input  wire                             enable
);

    //==========================================================================
    // Packed weight register: stores {w_hi, w_lo}
    //==========================================================================
    reg signed [15:0] weight_packed;

    // Extract INT8 components
    wire signed [7:0] act_lo = act_in[7:0];
    wire signed [7:0] act_hi = act_in[15:8];
    wire signed [7:0] w_lo   = weight_packed[7:0];
    wire signed [7:0] w_hi   = weight_packed[15:8];

    //==========================================================================
    // Weight load
    //==========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            weight_packed <= 16'd0;
        else if (enable && weight_load)
            weight_packed <= act_in;
    end

    //==========================================================================
    // Activation pass-through (2-deep shift register)
    //==========================================================================
    reg signed [15:0] act_d1, act_d2;
    reg               valid_d1, valid_d2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            act_d1   <= 16'd0;
            act_d2   <= 16'd0;
            valid_d1 <= 1'b0;
            valid_d2 <= 1'b0;
        end else if (enable) begin
            act_d1   <= act_in;
            act_d2   <= act_d1;
            valid_d1 <= valid_in;
            valid_d2 <= valid_d1;
        end
    end

    assign act_out   = act_d2;
    assign valid_out = valid_d2;

    //==========================================================================
    // Dual INT8 MAC (lower stream)
    //==========================================================================
    reg signed [15:0]                prod_lo_s1;
    reg signed [ACCUM_WIDTH_LO-1:0]  acc_lo_d1;
    reg                              valid_lo_s1;
    reg                              clear_lo_d1;

    reg signed [ACCUM_WIDTH_LO-1:0]  acc_lo_out;
    reg                              valid_lo_s2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prod_lo_s1   <= 16'd0;
            acc_lo_d1    <= 0;
            valid_lo_s1  <= 1'b0;
            clear_lo_d1  <= 1'b0;
        end else if (enable) begin
            prod_lo_s1   <= act_lo * w_lo;
            acc_lo_d1    <= psum_in_lo;
            valid_lo_s1  <= valid_in;
            clear_lo_d1  <= clear;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc_lo_out  <= 0;
            valid_lo_s2 <= 1'b0;
        end else if (enable) begin
            if (valid_lo_s1) begin
                if (clear_lo_d1)
                    acc_lo_out <= {{(ACCUM_WIDTH_LO-16){prod_lo_s1[15]}}, prod_lo_s1};
                else
                    acc_lo_out <= acc_lo_d1 + {{(ACCUM_WIDTH_LO-16){prod_lo_s1[15]}}, prod_lo_s1};
            end
            valid_lo_s2 <= valid_lo_s1;
        end
    end

    assign psum_out_lo = acc_lo_out;

    //==========================================================================
    // Dual INT8 MAC (upper stream)
    //==========================================================================
    reg signed [15:0]                prod_hi_s1;
    reg signed [ACCUM_WIDTH_HI-1:0]  acc_hi_d1;
    reg                              valid_hi_s1;
    reg                              clear_hi_d1;

    reg signed [ACCUM_WIDTH_HI-1:0]  acc_hi_out;
    reg                              valid_hi_s2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prod_hi_s1   <= 16'd0;
            acc_hi_d1    <= 0;
            valid_hi_s1  <= 1'b0;
            clear_hi_d1  <= 1'b0;
        end else if (enable) begin
            prod_hi_s1   <= act_hi * w_hi;
            acc_hi_d1    <= psum_in_hi;
            valid_hi_s1  <= valid_in;
            clear_hi_d1  <= clear;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc_hi_out  <= 0;
            valid_hi_s2 <= 1'b0;
        end else if (enable) begin
            if (valid_hi_s1) begin
                if (clear_hi_d1)
                    acc_hi_out <= {{(ACCUM_WIDTH_HI-16){prod_hi_s1[15]}}, prod_hi_s1};
                else
                    acc_hi_out <= acc_hi_d1 + {{(ACCUM_WIDTH_HI-16){prod_hi_s1[15]}}, prod_hi_s1};
            end
            valid_hi_s2 <= valid_hi_s1;
        end
    end

    assign psum_out_hi = acc_hi_out;
    assign psum_valid  = valid_lo_s2;   // Both streams have same valid timing

endmodule
