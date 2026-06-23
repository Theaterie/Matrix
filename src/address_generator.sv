`timescale 1ns / 1ps

//==============================================================================
// Module:  address_generator
// Purpose: Generates read/write addresses for activation and result buffer RAMs
//          during weight-stationary systolic array operation
//==============================================================================
// Activation read: sequential, one address per cycle during COMPUTE
//   - Base address offset for tiled operation (tile_row * K_TILE)
//   - Sequential read within tile
// Result write: sequential, one address per cycle during SERIALIZE
//   - Captured results are serialized one entry per cycle
//   - Base address offset for tiled operation (tile_col * M)
//   - Sequential write covering ROWS*COLS entries
//
// Note: During READOUT (pipeline drain), results are captured by the
//       result_serializer but NOT written to BRAM. Writes happen during
//       the subsequent SERIALIZE phase.
//==============================================================================

module address_generator #(
    parameter DATA_WIDTH    = 16,          // Activation data width
    parameter ACCUM_WIDTH   = 40,          // Result data width
    parameter ADDR_WIDTH    = 10,          // Address width (supports up to 1024 entries)
    parameter ROWS          = 16,          // PE array rows
    parameter COLS          = 16,          // PE array columns
    parameter TILE_K        = 16,          // K dimension per tile
    parameter TILE_M        = 16           // M dimension per tile
) (
    input  wire                          clk,
    input  wire                          rst_n,           // Async reset, active low

    // ---- Control from FSM ----
    input  wire [2:0]                    phase,            // 0=IDLE, 1=WEIGHT_LOAD, 2=COMPUTE, 3=READOUT, 4=SERIALIZE, 5=DONE
    input  wire                          enable,           // Advance address counter

    // ---- Tile configuration ----
    input  wire [ADDR_WIDTH-1:0]         act_base_addr,    // Activation buffer base for current tile
    input  wire [ADDR_WIDTH-1:0]         res_base_addr,    // Result buffer base for current tile

    // ---- Address outputs ----
    output reg  [ADDR_WIDTH-1:0]         act_rd_addr,      // Activation buffer read address
    output reg                           act_rd_en,        // Activation buffer read enable
    output reg  [ADDR_WIDTH-1:0]         res_wr_addr,      // Result buffer write address
    output reg                           res_wr_en,        // Result buffer write enable

    // ---- Done ----
    output reg                           act_done,         // Activation read complete (all K cycles)
    output reg                           res_done          // Result write complete
);

//==============================================================================
// Local parameters
//==============================================================================
localparam RESULT_TOTAL = ROWS * COLS;   // Total serialized results per tile

//==============================================================================
// Address counters
//==============================================================================
reg [ADDR_WIDTH-1:0] act_addr_cnt;   // 0 .. TILE_K-1
reg [ADDR_WIDTH-1:0] res_addr_cnt;   // 0 .. RESULT_TOTAL-1

//==============================================================================
// Activation read address
//   During COMPUTE: act_rd_addr = act_base_addr + act_addr_cnt
//   All other phases: idle (no reads)
//==============================================================================
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        act_addr_cnt <= {ADDR_WIDTH{1'b0}};
        act_rd_addr  <= {ADDR_WIDTH{1'b0}};
        act_rd_en    <= 1'b0;
        act_done     <= 1'b0;
    end else begin
        act_done <= 1'b0;  // default: pulse

        case (phase)
            3'b010: begin  // COMPUTE
                if (enable) begin
                    act_rd_en   <= 1'b1;
                    act_rd_addr <= act_base_addr + act_addr_cnt;
                    if (act_addr_cnt == TILE_K - 1) begin
                        act_addr_cnt <= {ADDR_WIDTH{1'b0}};
                        act_done     <= 1'b1;
                    end else begin
                        act_addr_cnt <= act_addr_cnt + 1'b1;
                    end
                end else begin
                    act_rd_en <= 1'b0;
                end
            end

            default: begin  // IDLE, WEIGHT_LOAD, READOUT, SERIALIZE, DONE
                act_addr_cnt <= {ADDR_WIDTH{1'b0}};
                act_rd_addr  <= {ADDR_WIDTH{1'b0}};
                act_rd_en    <= 1'b0;
                act_done     <= 1'b0;
            end
        endcase
    end
end

//==============================================================================
// Result write address
//   During SERIALIZE: res_wr_addr = res_base_addr + res_addr_cnt
//   One result per cycle, total RESULT_TOTAL entries per tile
//   During READOUT: no writes (results captured by serializer)
//==============================================================================
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        res_addr_cnt <= {ADDR_WIDTH{1'b0}};
        res_wr_addr  <= {ADDR_WIDTH{1'b0}};
        res_wr_en    <= 1'b0;
        res_done     <= 1'b0;
    end else begin
        res_done <= 1'b0;  // default: pulse

        case (phase)
            3'b011: begin  // READOUT — pipeline drain, no BRAM writes
                res_wr_en    <= 1'b0;
                res_addr_cnt <= {ADDR_WIDTH{1'b0}};  // Reset for upcoming SERIALIZE
                res_wr_addr  <= {ADDR_WIDTH{1'b0}};
                res_done     <= 1'b0;
            end

            3'b100: begin  // SERIALIZE — write serialized results to BRAM
                if (enable) begin
                    res_wr_en   <= 1'b1;
                    res_wr_addr <= res_base_addr + res_addr_cnt;
                    if (res_addr_cnt == RESULT_TOTAL - 1) begin
                        res_addr_cnt <= {ADDR_WIDTH{1'b0}};
                        res_done     <= 1'b1;
                    end else begin
                        res_addr_cnt <= res_addr_cnt + 1'b1;
                    end
                end else begin
                    res_wr_en <= 1'b0;
                end
            end

            default: begin  // IDLE, WEIGHT_LOAD, COMPUTE, DONE
                res_addr_cnt <= {ADDR_WIDTH{1'b0}};
                res_wr_addr  <= {ADDR_WIDTH{1'b0}};
                res_wr_en    <= 1'b0;
                res_done     <= 1'b0;
            end
        endcase
    end
end

endmodule
