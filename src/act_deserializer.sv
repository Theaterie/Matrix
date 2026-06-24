`timescale 1ns / 1ps

//==============================================================================
// Module:  act_deserializer
// Purpose: Bridges activation BRAM (16b scalar read port) to PE array
//          (ROWS-wide unpacked array). Pre-fetches all activations from BRAM
//          into a flip-flop buffer, then streams ROWS values per cycle during
//          COMPUTE.
//==============================================================================
// Architecture:
//   1. PREFETCH phase: reads ROWS*K_DEPTH values sequentially from BRAM
//      (one 16b word per cycle), stores in buffer[row][k].
//   2. STREAMING phase: during COMPUTE, outputs buffer[*][k] on cycle k
//      -- all ROWS activations for that cycle in parallel.
//
// BRAM data layout (row-major, written by external host):
//   BRAM[0]            = A[0][0]   (row 0, cycle 0)
//   BRAM[1]            = A[0][1]   (row 0, cycle 1)
//   ...
//   BRAM[K_DEPTH-1]    = A[0][K_DEPTH-1]
//   BRAM[K_DEPTH]      = A[1][0]
//   ...
//   BRAM[ROWS*K_DEPTH-1] = A[ROWS-1][K_DEPTH-1]
//
// Timing (16x16 tile):
//   - PREFETCH starts 1 cycle before WEIGHT_LOAD (on 'start' pulse)
//   - PREFETCH issues 256 reads (addr 0..255) in 256 cycles
//   - Data arrives with 1-cycle BRAM latency: writes span cycles 1..256
//   - Both PREFETCH and WEIGHT_LOAD complete at the same time
//   - COMPUTE begins next cycle; deserializer starts streaming immediately
//==============================================================================

module act_deserializer #(
    parameter ROWS        = 16,          // PE array rows
    parameter K_DEPTH     = 16,          // Activations per row (COMPUTE cycles)
    parameter DATA_WIDTH  = 16,          // Activation data width
    parameter ADDR_WIDTH  = 8            // BRAM address width
) (
    input  wire                          clk,
    input  wire                          rst_n,           // Async reset, active low

    // ---- BRAM read interface (master) ----
    output reg                           bram_rd_en,
    output reg  [ADDR_WIDTH-1:0]         bram_rd_addr,
    input  wire [DATA_WIDTH-1:0]         bram_rd_data,

    // ---- PE array interface (per-row unpacked array) ----
    output wire [DATA_WIDTH-1:0]         act_data_out [0:ROWS-1],
    output wire                          act_valid_out,  // Combinational — aligned with act_data_out

    // ---- Control ----
    input  wire [ADDR_WIDTH-1:0]         act_base_addr,   // BRAM base address for current tile
    input  wire                          prefetch_start,  // Pulse: start prefetch (tied to 'start')
    input  wire                          stream_en,       // COMPUTE phase: stream out
    output wire                          prefetch_done,   // High: buffer full, ready to stream
    output reg                           stream_done      // Pulse: all K_DEPTH vectors streamed
);

    //==========================================================================
    // Local parameters
    //==========================================================================
    localparam TOTAL_ENTRIES   = ROWS * K_DEPTH;          // 256
    localparam PTR_WIDTH       = $clog2(TOTAL_ENTRIES);   // 8
    localparam K_WID           = $clog2(K_DEPTH);         // 4
    localparam ROW_WID         = $clog2(ROWS);            // 4

    //==========================================================================
    // FSM states
    //==========================================================================
    localparam FSM_IDLE      = 2'd0;
    localparam FSM_PREFETCH  = 2'd1;
    localparam FSM_READY     = 2'd2;
    localparam FSM_STREAMING = 2'd3;

    reg [1:0] state, next_state;

    //==========================================================================
    // Activation buffer: buffer[row][k]
    //==========================================================================
    reg [DATA_WIDTH-1:0] act_buffer [0:ROWS-1][0:K_DEPTH-1];

    //==========================================================================
    // Pointers and counters
    //==========================================================================
    reg [PTR_WIDTH-1:0]  wr_ptr;         // Write pointer (0..TOTAL_ENTRIES)
    reg [K_WID-1:0]      stream_cnt;     // Current streaming cycle (0..K_DEPTH-1)
    reg                  rd_active;       // BRAM read was active last cycle
    reg                  pf_done_r;       // Registered prefetch_done flag

    // Derived row/k from write pointer
    wire [ROW_WID-1:0] wr_row = wr_ptr[PTR_WIDTH-1:K_WID];
    wire [K_WID-1:0]   wr_k   = wr_ptr[K_WID-1:0];

    // Combinational prefetch-done (for immediate next-state transition)
    //   True when last data (addr TOTAL_ENTRIES-1) is being written to buffer
    wire pf_done_comb = (wr_ptr == TOTAL_ENTRIES - 1) && rd_active;

    genvar g_row;

    //==========================================================================
    // State register
    //==========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            state <= FSM_IDLE;
        else
            state <= next_state;
    end

    //==========================================================================
    // Next-state logic (uses combinational pf_done_comb for zero-latency transition)
    //==========================================================================
    always @(*) begin
        next_state = state;
        case (state)
            FSM_IDLE: begin
                if (prefetch_start)
                    next_state = FSM_PREFETCH;
            end

            FSM_PREFETCH: begin
                // When buffer is full AND COMPUTE has started, go directly to
                // STREAMING (skip READY) to avoid losing a COMPUTE cycle
                if (pf_done_comb && stream_en)
                    next_state = FSM_STREAMING;
                else if (pf_done_comb)
                    next_state = FSM_READY;
            end

            FSM_READY: begin
                if (stream_en)
                    next_state = FSM_STREAMING;
            end

            FSM_STREAMING: begin
                if (stream_done)
                    next_state = FSM_IDLE;
            end

            default: next_state = FSM_IDLE;
        endcase
    end

    //==========================================================================
    // Datapath
    //==========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bram_rd_en    <= 1'b0;
            bram_rd_addr  <= {ADDR_WIDTH{1'b0}};
            wr_ptr        <= {PTR_WIDTH{1'b0}};
            rd_active     <= 1'b0;
            pf_done_r     <= 1'b0;
            stream_cnt    <= {K_WID{1'b0}};
                        stream_done   <= 1'b0;
        end else begin
            // Default: pulse signals
            stream_done <= 1'b0;

            case (state)

                //------------------------------------------------------------------
                // IDLE
                //------------------------------------------------------------------
                FSM_IDLE: begin
                    bram_rd_en    <= 1'b0;
                    bram_rd_addr  <= {ADDR_WIDTH{1'b0}};
                    wr_ptr        <= {PTR_WIDTH{1'b0}};
                    rd_active     <= 1'b0;
                    pf_done_r     <= 1'b0;
                    stream_cnt    <= {K_WID{1'b0}};
                    
                    // Start first BRAM read immediately on prefetch_start
                    if (prefetch_start) begin
                        bram_rd_en   <= 1'b1;
                        bram_rd_addr <= act_base_addr;  // addr = base + 0
                    end
                end

                //------------------------------------------------------------------
                // PREFETCH -- sequentially read BRAM, buffer incoming data
                //------------------------------------------------------------------
                FSM_PREFETCH: begin
                    // Track rd_en for data-valid gating
                    rd_active <= bram_rd_en;

                    // Store data from PREVIOUS cycle's read
                    if (rd_active && (wr_ptr < TOTAL_ENTRIES)) begin
                        act_buffer[wr_row][wr_k] <= bram_rd_data;
                        wr_ptr <= wr_ptr + 1'b1;
                    end

                    // Issue reads: base+0 .. base+TOTAL_ENTRIES-1
                    //   A small local counter tracks progress within the tile
                    //   to avoid wide comparators
                    if (bram_rd_addr < act_base_addr + TOTAL_ENTRIES - 1) begin
                        bram_rd_addr <= bram_rd_addr + 1'b1;
                        bram_rd_en   <= 1'b1;
                    end else begin
                        bram_rd_en <= 1'b0;
                    end

                    // Registered prefetch_done flag
                    pf_done_r <= pf_done_comb;

                    // Streaming handover: if buffer is full AND COMPUTE has started,
                    // output the first activation vector THIS cycle (combinational
                    // act_valid_out term handles this). Advance stream_cnt to 1 so
                    // the next cycle (STREAMING) outputs buffer[*][1], NOT buffer[*][0]
                    // again — avoids double-output of the first activation vector.
                    if (pf_done_comb && stream_en) begin
                        stream_cnt <= 1'b1;  // Skip index 0 — already output now
                    end else begin
                                            end
                end

                //------------------------------------------------------------------
                // READY -- buffer full, waiting for COMPUTE to begin
                //------------------------------------------------------------------
                FSM_READY: begin
                    bram_rd_en   <= 1'b0;
                    bram_rd_addr <= {ADDR_WIDTH{1'b0}};
                    rd_active    <= 1'b0;

                    // If COMPUTE starts this cycle, stream first vector immediately
                    // via combinational act_valid_out term. Advance stream_cnt to 1
                    // so the next cycle (STREAMING) outputs buffer[*][1], preventing
                    // double-output of the first activation.
                    if (stream_en) begin
                        stream_cnt <= 1'b1;  // Skip index 0 — already output now
                    end else begin
                        stream_cnt <= {K_WID{1'b0}};
                    end
                end

                //------------------------------------------------------------------
                // STREAMING -- output act_buffer[*][stream_cnt] each cycle
                //------------------------------------------------------------------
                FSM_STREAMING: begin
                    bram_rd_en   <= 1'b0;
                    bram_rd_addr <= {ADDR_WIDTH{1'b0}};
                    rd_active    <= 1'b0;
                    pf_done_r    <= 1'b0;
                    
                    if (stream_cnt == K_DEPTH - 1) begin
                        // Last vector output this cycle — done
                        stream_done   <= 1'b1;
                        stream_cnt    <= {K_WID{1'b0}};
                        wr_ptr        <= {PTR_WIDTH{1'b0}};
                        pf_done_r     <= 1'b0;
                    end else begin
                        stream_cnt    <= stream_cnt + 1'b1;
                    end
                end

                default: begin
                    bram_rd_en    <= 1'b0;
                    bram_rd_addr  <= {ADDR_WIDTH{1'b0}};
                    wr_ptr        <= {PTR_WIDTH{1'b0}};
                    rd_active     <= 1'b0;
                    pf_done_r     <= 1'b0;
                    stream_cnt    <= {K_WID{1'b0}};
                                    end
            endcase
        end
    end

    //==========================================================================
    // Combinational outputs
    //==========================================================================
    // act_valid_out: asserted when streaming activation vectors to PE array.
    //   Combinational so it aligns with act_data_out (also combinational).
    //   Both are available in the SAME cycle that the FSM enters a streaming
    //   state, avoiding the 1-cycle NBA delay mismatch.
    assign act_valid_out = (state == FSM_STREAMING) ||
                            ((state == FSM_PREFETCH) && pf_done_comb && stream_en) ||
                            ((state == FSM_READY) && stream_en);

    // act_data_out: per-row activation read from buffer[g_row][stream_cnt]
    generate
        for (g_row = 0; g_row < ROWS; g_row = g_row + 1) begin : gen_act_out
            assign act_data_out[g_row] = act_buffer[g_row][stream_cnt];
        end
    endgenerate

    //==========================================================================
    // Registered prefetch_done output (for external use, e.g. controller gating)
    //==========================================================================
    assign prefetch_done = pf_done_r;

endmodule
