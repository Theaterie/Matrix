//==============================================================================
// Module:  address_generator
// Purpose: Generates read/write addresses for activation and result buffer RAMs
//          during weight-stationary systolic array operation
//==============================================================================
// Activation read: sequential, one address per cycle during COMPUTE+READOUT
//   - Base address offset for tiled operation (tile_row * K_TILE)
//   - Sequential read within tile
// Result write: sequential, one address per cycle during READOUT
//   - Base address offset for tiled operation (tile_col * M)
//   - Sequential write within tile
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
    input  wire [1:0]                    phase,            // 0=IDLE, 1=WEIGHT_LOAD, 2=COMPUTE, 3=READOUT
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
// Address counters
//==============================================================================
reg [ADDR_WIDTH-1:0] act_addr_cnt;   // 0 .. TILE_K-1
reg [ADDR_WIDTH-1:0] res_addr_cnt;   // 0 .. TILE_M-1 (one result per row per column)

//==============================================================================
// Activation read address
//   During COMPUTE: act_rd_addr = act_base_addr + act_addr_cnt
//   During READOUT: act_rd_addr holds (no more reads needed)
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
            2'b10: begin  // COMPUTE
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

            2'b11: begin  // READOUT
                act_rd_en <= 1'b0;  // No more activation reads during drain
            end

            default: begin  // IDLE or WEIGHT_LOAD
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
//   During READOUT: res_wr_addr = res_base_addr + res_addr_cnt
//   One result per column per valid output cycle
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
            2'b11: begin  // READOUT
                if (enable) begin
                    res_wr_en   <= 1'b1;
                    res_wr_addr <= res_base_addr + res_addr_cnt;
                    if (res_addr_cnt == TILE_M - 1) begin
                        res_addr_cnt <= {ADDR_WIDTH{1'b0}};
                        res_done     <= 1'b1;
                    end else begin
                        res_addr_cnt <= res_addr_cnt + 1'b1;
                    end
                end else begin
                    res_wr_en <= 1'b0;
                end
            end

            default: begin  // IDLE, WEIGHT_LOAD, COMPUTE
                res_addr_cnt <= {ADDR_WIDTH{1'b0}};
                res_wr_addr  <= {ADDR_WIDTH{1'b0}};
                res_wr_en    <= 1'b0;
                res_done     <= 1'b0;
            end
        endcase
    end
end

endmodule
