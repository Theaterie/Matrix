//==============================================================================
// Module:  controller
// Purpose: Finite State Machine for weight-stationary systolic array
//          Orchestrates weight loading, compute, and result readout phases
//==============================================================================
// FSM states:
//   IDLE         (3'd0) — Wait for start pulse
//   WEIGHT_LOAD  (3'd1) — Load ROWS*COLS weights into PE array (serial)
//   COMPUTE      (3'd2) — Stream K activation vectors, accumulate partial sums
//   READOUT      (3'd3) — Drain pipeline, latch results from bottom edge
//   DONE         (3'd4) — Pulse done, return to IDLE
//
// Timing (16x16, K=16):
//   Weight load: 256 cycles
//   Compute:     16 cycles (one activation vector per cycle)
//   Readout:     64 cycles (drain 2*(ROWS+COLS) pipeline stages)
//   Total:       ~336 cycles
//==============================================================================

module controller #(
    parameter ROWS        = 16,          // PE array rows
    parameter COLS        = 16,          // PE array columns
    parameter K_DEPTH     = 16,          // Number of activation vectors to process
    parameter ADDR_WIDTH  = 8            // Weight address width ($clog2(ROWS*COLS))
) (
    input  wire                          clk,
    input  wire                          rst_n,           // Async reset, active low

    // ---- External handshake ----
    input  wire                          start,            // Pulse: begin computation
    output reg                           busy,             // High during operation
    output reg                           done,             // Pulse: computation complete

    // ---- PE array control (broadcast) ----
    output reg                           pe_clear,         // Reset accumulation (first COMPUTE cycle)
    output reg                           pe_enable,        // Pipeline enable (low = stall)

    // ---- Weight loading interface ----
    output reg                           weight_wren,      // Weight write enable
    output reg  [ADDR_WIDTH-1:0]         weight_addr,      // Weight destination address

    // ---- Phase indicators (for address_generator) ----
    output reg  [1:0]                    phase,            // 0=IDLE, 1=WEIGHT_LOAD, 2=COMPUTE, 3=READOUT
    output reg  [$clog2(K_DEPTH):0]      compute_cycle,    // Current cycle within COMPUTE phase
    output reg  [$clog2(2*(ROWS+COLS)):0] readout_cycle    // Current cycle within READOUT phase
);

//==============================================================================
// State encoding
//==============================================================================
localparam STATE_IDLE        = 3'd0;
localparam STATE_WEIGHT_LOAD = 3'd1;
localparam STATE_COMPUTE     = 3'd2;
localparam STATE_READOUT     = 3'd3;
localparam STATE_DONE        = 3'd4;

reg [2:0] state, next_state;

//==============================================================================
// Cycle counters
//==============================================================================
localparam WEIGHT_LOAD_CYCLES = ROWS * COLS;               // 256
localparam COMPUTE_CYCLES     = K_DEPTH;                   // K activation vectors
localparam READOUT_CYCLES     = 2 * (ROWS + COLS);         // 64 — pipeline drain

reg [$clog2(WEIGHT_LOAD_CYCLES):0] weight_cnt;  // 0..256
reg [$clog2(COMPUTE_CYCLES):0]     compute_cnt;  // 0..K_DEPTH
reg [$clog2(READOUT_CYCLES):0]     readout_cnt;  // 0..64

//==============================================================================
// State register
//==============================================================================
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        state <= STATE_IDLE;
    else
        state <= next_state;
end

//==============================================================================
// Next-state logic
//==============================================================================
always @(*) begin
    next_state = state;
    case (state)
        STATE_IDLE: begin
            if (start)
                next_state = STATE_WEIGHT_LOAD;
        end

        STATE_WEIGHT_LOAD: begin
            if (weight_cnt == WEIGHT_LOAD_CYCLES)
                next_state = STATE_COMPUTE;
        end

        STATE_COMPUTE: begin
            if (compute_cnt == COMPUTE_CYCLES)
                next_state = STATE_READOUT;
        end

        STATE_READOUT: begin
            if (readout_cnt == READOUT_CYCLES)
                next_state = STATE_DONE;
        end

        STATE_DONE: begin
            next_state = STATE_IDLE;
        end

        default: next_state = STATE_IDLE;
    endcase
end

//==============================================================================
// Cycle counters
//==============================================================================
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        weight_cnt  <= 0;
        compute_cnt <= 0;
        readout_cnt <= 0;
    end else begin
        case (state)
            STATE_WEIGHT_LOAD: begin
                weight_cnt <= weight_cnt + 1'b1;
            end

            STATE_COMPUTE: begin
                compute_cnt <= compute_cnt + 1'b1;
            end

            STATE_READOUT: begin
                readout_cnt <= readout_cnt + 1'b1;
            end

            default: begin
                weight_cnt  <= 0;
                compute_cnt <= 0;
                readout_cnt <= 0;
            end
        endcase
    end
end

//==============================================================================
// Output logic (Mealy: computed from current state + counters)
//==============================================================================
always @(*) begin
    // Defaults
    busy        = 1'b0;
    done        = 1'b0;
    pe_clear    = 1'b0;
    pe_enable   = 1'b0;
    weight_wren = 1'b0;
    weight_addr = {ADDR_WIDTH{1'b0}};
    phase       = 2'b00;
    compute_cycle = 0;
    readout_cycle = 0;

    case (state)
        STATE_IDLE: begin
            // All outputs at default (idle)
        end

        STATE_WEIGHT_LOAD: begin
            busy        = 1'b1;
            pe_enable   = 1'b1;
            weight_wren = 1'b1;
            weight_addr = weight_cnt[ADDR_WIDTH-1:0];
            phase       = 2'b01;
        end

        STATE_COMPUTE: begin
            busy          = 1'b1;
            pe_enable     = 1'b1;
            pe_clear      = (compute_cnt == 0);   // Clear accumulators on first cycle
            phase         = 2'b10;
            compute_cycle = compute_cnt;
        end

        STATE_READOUT: begin
            busy         = 1'b1;
            pe_enable    = 1'b1;
            // pe_clear = 0 during readout (continue accumulating final partial sums)
            phase        = 2'b11;
            readout_cycle = readout_cnt;
        end

        STATE_DONE: begin
            done = 1'b1;
            // Pulse done for one cycle, then return to IDLE
        end

        default: begin
            // Safe defaults already set
        end
    endcase
end

endmodule
