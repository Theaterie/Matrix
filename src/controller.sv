`timescale 1ns / 1ps

//==============================================================================
// Module:  controller
// Purpose: Finite State Machine for weight-stationary systolic array
//          Orchestrates weight loading, compute, pipeline drain, and result
//          serialization phases
//==============================================================================
// FSM states:
//   IDLE         (3'd0) — Wait for start pulse
//   WEIGHT_LOAD  (3'd1) — Load ROWS*COLS weights into PE array (serial)
//   COMPUTE      (3'd2) — Stream K activation vectors, accumulate partial sums
//   READOUT      (3'd3) — Drain pipeline, capture results from bottom edge
//   SERIALIZE    (3'd4) — Serialize captured results into result BRAM
//   DONE         (3'd5) — Pulse done, return to IDLE
//
// Timing (ROWS=4, COLS=4, K_DEPTH=4):
//   Weight load: 16 cycles (0 if weight_preloaded=1)
//   Compute:      4 cycles (one activation vector per cycle)
//   Readout:     16 cycles (drain 2*(ROWS+COLS) pipeline stages)
//   Serialize:   16 cycles (ROWS*COLS results, one per cycle)
//
// weight_preloaded optimization:
//   When weights are already in the PE array (reused across M rows with
//   same (K,N) tile), skip weight loading entirely.  The controller still
//   waits for deser_ready (prefetch from BRAM) before entering COMPUTE.
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
    input  wire                          weight_preloaded, // 1 = weights already in PE array
    output reg                           busy,             // High during operation
    output reg                           done,             // Pulse: computation complete

    // ---- PE array control (broadcast) ----
    output reg                           pe_clear,         // Reset accumulation (first COMPUTE cycle)
    output reg                           pe_enable,        // Pipeline enable (low = stall)

    // ---- Weight loading interface ----
    output reg                           weight_wren,      // Weight write enable
    output reg  [ADDR_WIDTH-1:0]         weight_addr,      // Weight destination address

    // ---- Phase indicators (for address_generator) ----
    output reg  [2:0]                    phase,            // 0=IDLE, 1=WEIGHT_LOAD, 2=COMPUTE, 3=READOUT, 4=SERIALIZE, 5=DONE
    output reg  [$clog2(K_DEPTH):0]      compute_cycle,    // Current cycle within COMPUTE phase
    output reg  [$clog2(2*(ROWS+COLS)):0] readout_cycle,   // Current cycle within READOUT phase
    output reg  [$clog2(ROWS*COLS):0]    serialize_cycle,   // Current cycle within SERIALIZE phase

    // ---- Activation deserializer handshake ----
    input  wire                          deser_ready       // act_deserializer prefetch complete
);

//==============================================================================
// State encoding
//==============================================================================
localparam STATE_IDLE        = 3'd0;
localparam STATE_WEIGHT_LOAD = 3'd1;
localparam STATE_COMPUTE     = 3'd2;
localparam STATE_READOUT     = 3'd3;
localparam STATE_SERIALIZE   = 3'd4;
localparam STATE_DONE        = 3'd5;

reg [2:0] state, next_state;

//==============================================================================
// Cycle counters
//==============================================================================
localparam WEIGHT_LOAD_CYCLES = ROWS * COLS;               // e.g. 256
localparam COMPUTE_CYCLES     = K_DEPTH;                   // K activation vectors
localparam READOUT_CYCLES     = 2 * (ROWS + COLS);         // e.g. 64 — pipeline drain
localparam SERIALIZE_CYCLES   = ROWS * COLS;               // e.g. 256 — serialized results

reg [$clog2(WEIGHT_LOAD_CYCLES):0] weight_cnt;     // 0..256
reg [$clog2(COMPUTE_CYCLES):0]     compute_cnt;     // 0..K_DEPTH
reg [$clog2(READOUT_CYCLES):0]     readout_cnt;     // 0..64
reg [$clog2(SERIALIZE_CYCLES):0]   serialize_cnt;   // 0..256

//==============================================================================
// Sequential block — state and counters in ONE block
// eliminates inter-block race conditions.
//==============================================================================
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state         <= STATE_IDLE;
        weight_cnt    <= 0;
        compute_cnt   <= 0;
        readout_cnt   <= 0;
        serialize_cnt <= 0;
    end else begin
        // ---- State transition ----
        // Transitions are decided here using stable REGISTERED counter values
        // (committed by the previous clock's NBA), NOT via the combo next_state
        // block.  This avoids a race where the combo evaluates AFTER the
        // sequential block at the same posedge and its output is missed.
        if (state == STATE_WEIGHT_LOAD && !weight_preloaded &&
            weight_cnt >= WEIGHT_LOAD_CYCLES - 1 && deser_ready)
            state <= STATE_COMPUTE;
        else if (state == STATE_COMPUTE && compute_cnt >= COMPUTE_CYCLES - 1)
            state <= STATE_READOUT;
        else if (state == STATE_READOUT && readout_cnt >= READOUT_CYCLES - 1)
            state <= STATE_SERIALIZE;
        else if (state == STATE_SERIALIZE && serialize_cnt >= SERIALIZE_CYCLES - 1)
            state <= STATE_DONE;
        else
            state <= next_state;  // IDLE→WEIGHT_LOAD, DONE→IDLE, stalls

        // ---- Cycle counters (driven by OLD state, the state we are LEAVING) ----
        // Gated by cnt < CYCLES-1 so we stop incrementing on the LAST cycle
        // of each phase — the transition fires on that same cycle (see above).
        case (state)
            STATE_WEIGHT_LOAD: begin
                if (!weight_preloaded && weight_cnt < WEIGHT_LOAD_CYCLES - 1)
                    weight_cnt <= weight_cnt + 1'b1;
            end

            STATE_COMPUTE: begin
                if (compute_cnt < COMPUTE_CYCLES - 1)
                    compute_cnt <= compute_cnt + 1'b1;
            end

            STATE_READOUT: begin
                if (readout_cnt < READOUT_CYCLES - 1)
                    readout_cnt <= readout_cnt + 1'b1;
            end

            STATE_SERIALIZE: begin
                if (serialize_cnt < SERIALIZE_CYCLES - 1)
                    serialize_cnt <= serialize_cnt + 1'b1;
            end

            default: begin
                weight_cnt    <= 0;
                compute_cnt   <= 0;
                readout_cnt   <= 0;
                serialize_cnt <= 0;
            end
        endcase
    end
end

//==============================================================================
// Next-state logic (combinational)
//==============================================================================
always @(*) begin
    next_state = state;
    case (state)
        STATE_IDLE: begin
            if (start)
                next_state = STATE_WEIGHT_LOAD;
        end

        STATE_WEIGHT_LOAD: begin
            if (weight_preloaded) begin
                if (deser_ready)
                    next_state = STATE_COMPUTE;
            end else begin
                if (weight_cnt >= WEIGHT_LOAD_CYCLES - 1 && deser_ready)
                    next_state = STATE_COMPUTE;
            end
        end

        STATE_COMPUTE: begin
            if (compute_cnt == COMPUTE_CYCLES - 1)
                next_state = STATE_READOUT;
        end

        STATE_READOUT: begin
            if (readout_cnt >= READOUT_CYCLES - 1)
                next_state = STATE_SERIALIZE;
        end

        STATE_SERIALIZE: begin
            if (serialize_cnt >= SERIALIZE_CYCLES - 1)
                next_state = STATE_DONE;
        end

        STATE_DONE: begin
            next_state = STATE_IDLE;
        end

        default: next_state = STATE_IDLE;
    endcase
end

//==============================================================================
// Combinational output logic
//   — All outputs are purely combinational from state + counters.
//     No registered delays — values are valid at @(posedge clk).
//==============================================================================
always @(*) begin
    // Defaults
    busy            = 1'b0;
    done            = 1'b0;
    pe_clear        = 1'b0;
    pe_enable       = 1'b0;
    weight_wren     = 1'b0;
    weight_addr     = {ADDR_WIDTH{1'b0}};
    phase           = 3'b000;
    compute_cycle   = 0;
    readout_cycle   = 0;
    serialize_cycle = 0;

    case (state)
        STATE_IDLE: begin
            // All outputs at default (idle)
        end

        STATE_WEIGHT_LOAD: begin
            busy      = 1'b1;
            pe_enable = 1'b1;
            phase     = 3'b001;
            if (!weight_preloaded) begin
                weight_wren = 1'b1;
                weight_addr = weight_cnt[ADDR_WIDTH-1:0];
            end
        end

        STATE_COMPUTE: begin
            busy          = 1'b1;
            pe_enable     = 1'b1;
            pe_clear      = (compute_cnt == 0);
            phase         = 3'b010;
            compute_cycle = compute_cnt;
        end

        STATE_READOUT: begin
            busy          = 1'b1;
            pe_enable     = 1'b1;
            phase         = 3'b011;
            readout_cycle = readout_cnt;
        end

        STATE_SERIALIZE: begin
            busy            = 1'b1;
            pe_enable       = 1'b1;
            phase           = 3'b100;
            serialize_cycle = serialize_cnt;
        end

        STATE_DONE: begin
            done  = 1'b1;
            phase = 3'b101;
        end

        default: begin
            // Safe defaults already set
        end
    endcase
end

endmodule
