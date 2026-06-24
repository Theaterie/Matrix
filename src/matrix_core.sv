//==============================================================================
// Module:  matrix_core
// Purpose: Tiled matrix multiplication controller — orchestrates systolic_array
//          invocations to compute C[M×N] += A[M×K] × B[K×N] over arbitrary
//          matrix dimensions using fixed-size hardware tiles.
//==============================================================================
// Architecture:
//   Each systolic_array invocation computes ONE output row per K-tile:
//     partial_C[n : n+COLS-1] = A[m][k : k+ROWS-1] × B[k : k+ROWS-1][n : n+COLS-1]
//
//   Three-level tile loop (outer→inner):
//     Loop-M: iterate output rows       (m_step = 1, one row per invocation set)
//     Loop-N: iterate output columns    (n_step = COLS)
//     Loop-K: iterate reduction dim     (k_step = ROWS, accumulate across K tiles)
//
//   Tile sequence for C[M×N] = A[M×K] × B[K×N]:
//     for m in 0..M-1:
//       for n in 0, COLS, 2*COLS, .. < N:
//         C_accum[0:COLS-1] = 0
//         for k in 0, ROWS, 2*ROWS, .. < K:
//           load B[k:k+ROWS][n:n+COLS]  → PE array weights
//           load A[m][k:k+ROWS]          → act_bram
//           run systolic_array
//           C_accum += result
//         store C_accum → C[m][n:n+COLS]
//
//   Tile base addresses (row-major):
//     A_base = m * K + k
//     B_base = k * N + n
//     C_base = m * N + n
//==============================================================================

module matrix_core #(
    parameter ROWS          = 16,          // PE array rows (= K tile size)
    parameter COLS          = 16,          // PE array columns (= N tile size)
    parameter DATA_WIDTH    = 16,
    parameter ACCUM_WIDTH   = 40,
    parameter K_DEPTH       = 16,          // Must equal ROWS
    parameter BUF_ADDR_W    = 8,
    parameter BUF_DEPTH     = 256,
    parameter WT_ADDR_W     = 8,
    parameter DIM_WIDTH     = 16           // Matrix dimension bit width
) (
    input  wire                              clk,
    input  wire                              rst_n,

    // ---- Command interface ----
    input  wire                              start,            // Pulse: begin full matrix multiply
    output reg                               busy,
    output reg                               done,             // Pulse: all tiles complete

    // ---- Matrix dimensions ----
    input  wire [DIM_WIDTH-1:0]              M,                // Output rows
    input  wire [DIM_WIDTH-1:0]              N,                // Output columns
    input  wire [DIM_WIDTH-1:0]              K,                // Common reduction dimension

    // ---- Systolic array control ----
    output reg                               sa_start,         // Pulse: begin tile
    input  wire                              sa_busy,
    input  wire                              sa_done,
    output reg                               sa_use_bram_act,   // 1 = BRAM path
    output reg  [DATA_WIDTH-1:0]             sa_weight_data,
    input  wire                              sa_weight_ready,
    output reg  [BUF_ADDR_W-1:0]             sa_act_base_addr,
    output reg  [BUF_ADDR_W-1:0]             sa_res_base_addr,

    // ---- External data interfaces (host/DMA provides actual data) ----
    // Activation BRAM write (host writes A tile before each run)
    input  wire                              host_act_wr_en,
    input  wire [BUF_ADDR_W-1:0]             host_act_wr_addr,
    input  wire [DATA_WIDTH-1:0]             host_act_wr_data,

    // Weight data passthrough (host drives weight_data during WEIGHT_LOAD)
    input  wire [DATA_WIDTH-1:0]             host_weight_data,
    output reg                               host_weight_req,   // Request next weight from host

    // Result BRAM read (host reads result after each run)
    output reg                               host_res_rd_en,
    output reg  [BUF_ADDR_W-1:0]             host_res_rd_addr,
    input  wire [ACCUM_WIDTH-1:0]            host_res_rd_data,

    // ---- Tile address outputs (for DMA/memory controller) ----
    output reg  [DIM_WIDTH-1:0]              tile_m_idx,
    output reg  [DIM_WIDTH-1:0]              tile_n_idx,
    output reg  [DIM_WIDTH-1:0]              tile_k_idx,
    output reg                               tile_new_k,        // Pulse: new K-tile starting
    output reg                               tile_new_mn,       // Pulse: new (M,N) tile starting

    // ---- Debug / status ----
    output reg  [3:0]                        fsm_state
);

    //==========================================================================
    // Local parameters
    //==========================================================================
    localparam TILE_K = ROWS;     // K dimension per tile
    localparam TILE_N = COLS;     // N dimension per tile

    //==========================================================================
    // FSM states
    //==========================================================================
    localparam FSM_IDLE          = 4'd0;
    localparam FSM_K_TILE_START  = 4'd1;   // Begin new K-tile: signal host to load data
    localparam FSM_WAIT_LOAD     = 4'd2;   // Wait for host to load weights + activations
    localparam FSM_RUN_TILE      = 4'd3;   // systolic_array computing
    localparam FSM_READ_RESULT   = 4'd4;   // Read result from BRAM, signal host
    localparam FSM_NEXT_K        = 4'd5;   // Advance K, loop or advance N
    localparam FSM_NEXT_MN       = 4'd6;   // Advance N/M, loop or finish
    localparam FSM_DONE          = 4'd7;

    reg [3:0] state;

    //==========================================================================
    // Tile indices
    //==========================================================================
    reg [DIM_WIDTH-1:0] m_idx, n_idx, k_idx;

    //==========================================================================
    // Result read-back counter
    //==========================================================================
    reg [$clog2(ROWS*COLS):0] res_cnt;

    //==========================================================================
    // State register + next-state logic (all sequential for clean timing)
    //==========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= FSM_IDLE;
        end else begin
            case (state)
                FSM_IDLE: begin
                    if (start)
                        state <= FSM_K_TILE_START;
                end

                FSM_K_TILE_START: begin
                    state <= FSM_WAIT_LOAD;
                end

                FSM_WAIT_LOAD: begin
                    if (sa_weight_ready)
                        state <= FSM_RUN_TILE;
                end

                FSM_RUN_TILE: begin
                    if (sa_done)
                        state <= FSM_READ_RESULT;
                end

                FSM_READ_RESULT: begin
                    if (res_cnt == ROWS * COLS)
                        state <= FSM_NEXT_K;
                end

                FSM_NEXT_K: begin
                    if (k_idx + TILE_K < K) begin
                        // k_idx updated in datapath below
                        state <= FSM_K_TILE_START;
                    end else begin
                        state <= FSM_NEXT_MN;
                    end
                end

                FSM_NEXT_MN: begin
                    if (n_idx + TILE_N < N) begin
                        state <= FSM_K_TILE_START;
                    end else if (m_idx + 1 < M) begin
                        state <= FSM_K_TILE_START;
                    end else begin
                        state <= FSM_DONE;
                    end
                end

                FSM_DONE: begin
                    state <= FSM_IDLE;
                end

                default: state <= FSM_IDLE;
            endcase
        end
    end

    //==========================================================================
    // Datapath and outputs (sequential)
    //==========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_idx           <= 0;
            n_idx           <= 0;
            k_idx           <= 0;
            res_cnt         <= 0;
            sa_start        <= 1'b0;
            sa_use_bram_act <= 1'b1;
            sa_weight_data  <= 0;
            sa_act_base_addr<= 0;
            sa_res_base_addr<= 0;
            host_weight_req <= 1'b0;
            host_res_rd_en  <= 1'b0;
            host_res_rd_addr<= 0;
            tile_m_idx      <= 0;
            tile_n_idx      <= 0;
            tile_k_idx      <= 0;
            tile_new_k      <= 1'b0;
            tile_new_mn     <= 1'b0;
            busy            <= 1'b0;
            done            <= 1'b0;
            fsm_state       <= 0;
        end else begin
            // Default: pulse signals low
            sa_start     <= 1'b0;
            done         <= 1'b0;
            tile_new_k   <= 1'b0;
            tile_new_mn  <= 1'b0;

            case (state)

                //------------------------------------------------------------------
                // IDLE
                //------------------------------------------------------------------
                FSM_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        m_idx     <= 0;
                        n_idx     <= 0;
                        k_idx     <= 0;
                        busy      <= 1'b1;
                        tile_new_mn <= 1'b1;  // First (m,n) tile
                    end
                end

                //------------------------------------------------------------------
                // K_TILE_START — signal host to load new K-tile data
                //------------------------------------------------------------------
                FSM_K_TILE_START: begin
                    tile_new_k   <= 1'b1;
                    tile_new_mn  <= (k_idx == 0);  // New (m,n) tile if first K-tile
                    tile_m_idx   <= m_idx;
                    tile_n_idx   <= n_idx;
                    tile_k_idx   <= k_idx;
                    res_cnt      <= 0;
                    host_res_rd_en <= 1'b0;

                    // Request host to load weights
                    host_weight_req <= 1'b1;
                end

                //------------------------------------------------------------------
                // WAIT_LOAD — host loads activations into act_bram and weights
                //   into PE array (via sa_weight_data port)
                //------------------------------------------------------------------
                FSM_WAIT_LOAD: begin
                    host_weight_req <= 1'b0;
                    // Host drives sa_weight_data externally
                    // Pass through weight data from host
                    sa_weight_data <= host_weight_data;
                end

                //------------------------------------------------------------------
                // RUN_TILE — systollic_array active
                //------------------------------------------------------------------
                FSM_RUN_TILE: begin
                    if (!sa_start && !sa_busy && !sa_done) begin
                        sa_start         <= 1'b1;
                        sa_act_base_addr <= 0;  // Host always loads at BRAM base
                        sa_res_base_addr <= 0;
                    end
                end

                //------------------------------------------------------------------
                // READ_RESULT — read COLS results from last capture row
                //   Last capture row (index ROWS-1) contains full accumulations
                //------------------------------------------------------------------
                FSM_READ_RESULT: begin
                    if (res_cnt < ROWS * COLS) begin
                        host_res_rd_en   <= 1'b1;
                        host_res_rd_addr <= (ROWS - 1) * COLS + res_cnt;
                        res_cnt          <= res_cnt + 1'b1;
                    end else begin
                        host_res_rd_en <= 1'b0;
                    end
                end

                //------------------------------------------------------------------
                // NEXT_K — advance K tile index or move to next (M,N)
                //------------------------------------------------------------------
                FSM_NEXT_K: begin
                    if (k_idx + TILE_K < K) begin
                        k_idx <= k_idx + TILE_K;
                        // next_state = K_TILE_START (set combinationally)
                    end else begin
                        k_idx <= 0;
                        // Fall through to NEXT_MN
                    end
                end

                //------------------------------------------------------------------
                // NEXT_MN — advance N, then M tile indices
                //   (next-state transition handled in state register block)
                //------------------------------------------------------------------
                FSM_NEXT_MN: begin
                    if (n_idx + TILE_N < N) begin
                        n_idx <= n_idx + TILE_N;
                    end else begin
                        n_idx <= 0;
                        if (m_idx + 1 < M) begin
                            m_idx <= m_idx + 1;
                        end
                    end
                end

                //------------------------------------------------------------------
                // DONE
                //------------------------------------------------------------------
                FSM_DONE: begin
                    done <= 1'b1;
                    busy <= 1'b0;
                end

                default: begin
                    busy <= 1'b0;
                end
            endcase

            fsm_state <= state;
        end
    end

endmodule
