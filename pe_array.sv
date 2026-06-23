//==============================================================================
// Module:  pe_array
// Purpose: 2D systolic array of processing elements (weight-stationary dataflow)
//          ROWS × COLS grid; each PE wraps mac_unit for multiply-accumulate
//==============================================================================
// Architecture:
//   - Weights are pre-loaded into each PE and remain stationary
//   - Activations flow left -> right (horizontal), 2-cycle delay per PE
//   - Partial sums flow top -> bottom (vertical), 2-cycle delay per PE
//   - Row r has 2*r cycles of activation skew at left boundary for systolic
//     alignment: partial sum from PE(r,c) meets the right activation at PE(r+1,c)
//
// Configuration: default ROWS=16, COLS=16 -> 256 PEs, 256 weight regs
//==============================================================================

module pe_array #(
    parameter ROWS        = 16,          // Number of PE rows
    parameter COLS        = 16,          // Number of PE columns
    parameter DATA_WIDTH  = 16,          // Input operand width
    parameter ACCUM_WIDTH = 40           // Accumulator width
) (
    input  wire                                   clk,
    input  wire                                   rst_n,          // Async reset, active low

    // ---- Activation inputs (left edge, one per row) ----
    input  wire [DATA_WIDTH-1:0]                  act_data_in  [0:ROWS-1],   // One activation per row
    input  wire                                   act_valid_in,              // Activation valid (broadcast all rows)

    // ---- Weight loading (serial, per-PE addressable) ----
    input  wire [DATA_WIDTH-1:0]                  weight_data,               // Weight value to load
    input  wire [$clog2(ROWS*COLS)-1:0]           weight_addr,               // Target PE address (0..ROWS*COLS-1)
    input  wire                                   weight_wren,               // Weight write enable

    // ---- Result outputs (bottom edge, one per column) ----
    output wire [ACCUM_WIDTH-1:0]                 result_data [0:COLS-1],    // Partial sum output per column
    output wire                                   result_valid,              // Result valid flag

    // ---- Control (broadcast to all PEs) ----
    input  wire                                   clear,                     // Reset accumulation
    input  wire                                   enable                     // Pipeline stall
);

//==============================================================================
// Local parameters
//==============================================================================
localparam MAX_SKEW_DEPTH = 2 * (ROWS - 1);   // Max skew depth = 30 for 16 rows
localparam ADDR_WIDTH     = $clog2(ROWS*COLS); // Address width = 8 for 256 PEs

genvar r, c;

//==============================================================================
// Activation skew registers (left boundary)
//   Row r: delay activation by 2*r cycles via shift register chain
//   This ensures systolic alignment: activation arrives at PE(r,c) at the
//   same time as the partial sum propagated down from PE(r-1,c)
//==============================================================================

// Skew shift-register chains — one per row, varying depth
reg  [DATA_WIDTH-1:0] skew_data_reg [0:ROWS-1][0:MAX_SKEW_DEPTH-1];
reg                   skew_val_reg  [0:ROWS-1][0:MAX_SKEW_DEPTH-1];

// Skewed activation & valid at each row's left boundary
wire [DATA_WIDTH-1:0] act_skewed [0:ROWS-1];
wire                  valid_skewed [0:ROWS-1];

generate
    for (r = 0; r < ROWS; r = r + 1) begin : gen_skew_chain
        localparam SKEW_DEPTH = 2 * r;

        if (SKEW_DEPTH == 0) begin : gen_no_skew
            // Row 0: no skew, direct pass-through
            assign act_skewed[r]   = act_data_in[r];
            assign valid_skewed[r] = act_valid_in;
        end else begin : gen_skew
            // Shift register chain: depth = 2*r
            integer d;

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    for (d = 0; d < SKEW_DEPTH; d = d + 1) begin
                        skew_data_reg[r][d] <= {DATA_WIDTH{1'b0}};
                        skew_val_reg [r][d] <= 1'b0;
                    end
                end else if (enable) begin
                    // First stage: capture from input
                    skew_data_reg[r][0] <= act_data_in[r];
                    skew_val_reg [r][0] <= act_valid_in;
                    // Shift chain
                    for (d = 1; d < SKEW_DEPTH; d = d + 1) begin
                        skew_data_reg[r][d] <= skew_data_reg[r][d-1];
                        skew_val_reg [r][d] <= skew_val_reg [r][d-1];
                    end
                end
            end

            // Tap at the last stage
            assign act_skewed[r]   = skew_data_reg[r][SKEW_DEPTH-1];
            assign valid_skewed[r] = skew_val_reg [r][SKEW_DEPTH-1];
        end
    end
endgenerate

//==============================================================================
// PE grid interconnect wires
//==============================================================================

// Horizontal: activation & valid flow left -> right
//   act_net[r][c] = activation at row r, AFTER column c-1
//   So act_net[r][0] = skewed input, act_net[r][COLS] = rightmost output
wire [DATA_WIDTH-1:0] act_net   [0:ROWS-1][0:COLS];
wire                  valid_net [0:ROWS-1][0:COLS];

// Vertical: partial sum flow top -> bottom
//   psum_net[r][c] = partial sum at column c, AFTER row r-1
//   So psum_net[0][c] = 0 (top boundary), psum_net[ROWS][c] = result
wire [ACCUM_WIDTH-1:0] psum_net       [0:ROWS][0:COLS-1];
wire                   psum_valid_net [0:ROWS][0:COLS-1];

//==============================================================================
// Weight enable decode (one-hot per PE from linear address)
//==============================================================================
wire weight_en [0:ROWS-1][0:COLS-1];

generate
    for (r = 0; r < ROWS; r = r + 1) begin : gen_weight_sel_row
        for (c = 0; c < COLS; c = c + 1) begin : gen_weight_sel_col
            assign weight_en[r][c] = weight_wren && (weight_addr == (r * COLS + c));
        end
    end
endgenerate

//==============================================================================
// Boundary conditions
//==============================================================================
generate
    // Top boundary: partial sum inputs are zero
    for (c = 0; c < COLS; c = c + 1) begin : gen_top_psum
        assign psum_net[0][c]       = {ACCUM_WIDTH{1'b0}};
        assign psum_valid_net[0][c] = 1'b0;
    end

    // Left boundary: activation = skewed input
    for (r = 0; r < ROWS; r = r + 1) begin : gen_left_act
        assign act_net[r][0]   = act_skewed[r];
        assign valid_net[r][0] = valid_skewed[r];
    end
endgenerate

//==============================================================================
// PE grid instantiation (ROWS × COLS)
//==============================================================================
generate
    for (r = 0; r < ROWS; r = r + 1) begin : gen_pe_row
        for (c = 0; c < COLS; c = c + 1) begin : gen_pe_col

            pe #(
                .DATA_WIDTH (DATA_WIDTH),
                .ACCUM_WIDTH(ACCUM_WIDTH)
            ) u_pe (
                .clk         (clk),
                .rst_n       (rst_n),

                // Activation: left -> right
                .act_in      (act_net[r][c]),
                .valid_in    (valid_net[r][c]),
                .act_out     (act_net[r][c+1]),
                .valid_out   (valid_net[r][c+1]),

                // Partial sum: top -> bottom
                .psum_in     (psum_net[r][c]),
                .psum_out    (psum_net[r+1][c]),
                .psum_valid  (psum_valid_net[r+1][c]),

                // Control
                .weight_load (weight_en[r][c]),
                .clear       (clear),
                .enable      (enable)
            );

        end
    end
endgenerate

//==============================================================================
// Result outputs (bottom edge)
//==============================================================================
generate
    for (c = 0; c < COLS; c = c + 1) begin : gen_result
        assign result_data[c] = psum_net[ROWS][c];
    end
endgenerate

// Bottom-right PE's psum_valid signals when results are valid
assign result_valid = psum_valid_net[ROWS][COLS-1];

endmodule
