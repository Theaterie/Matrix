//==============================================================================
// Module:  systolic_array_pingpong
// Purpose: Wraps systolic_array with dual (ping-pong) activation & result
//          buffers to overlap host data load with array computation.
//==============================================================================
// Architecture:
//   Two buffer sets (A/B), each containing:
//     - Activation BRAM (DATA_WIDTH×BUF_DEPTH)
//     - Result BRAM     (ACCUM_WIDTH×BUF_DEPTH)
//
//   Operation:
//     1. Host loads activations into inactive buffer via host_act_* ports
//     2. Host loads weights into PE array via weight_* ports (single-buffered)
//     3. Pulse start → systolic_array computes using active buffer set
//     4. While array is busy, host can preload next tile's data into inactive set
//     5. When done: host reads results from active result BRAM via host_res_* ports
//     6. buf_sel auto-toggles after done (configurable)
//
//   Buffer selection:
//     - active_set (buf_sel) connects to systolic_array's BRAM ports
//     - inactive_set (~buf_sel) connects to host ports
//==============================================================================

module systolic_array_pingpong #(
    parameter ROWS          = 16,
    parameter COLS          = 16,
    parameter DATA_WIDTH    = 16,
    parameter ACCUM_WIDTH   = 40,
    parameter K_DEPTH       = 16,
    parameter BUF_ADDR_W    = 8,
    parameter BUF_DEPTH     = 256,
    parameter WT_ADDR_W     = 8
) (
    input  wire                                clk,
    input  wire                                rst_n,

    // ---- Control ----
    input  wire                                start,            // Pulse: begin tile computation
    input  wire                                weight_preloaded, // 1 = weights already loaded (skip load)
    input  wire                                prefetch_start,   // Pulse: start BRAM prefetch early
    output wire                                busy,
    output wire                                done,
    input  wire                                auto_swap,        // 1 = auto-toggle buf_sel after done
    output wire                                buf_sel,          // Current active buffer (0=A, 1=B)

    // ---- Weight input (single-buffered, passes through to systolic_array) ----
    input  wire [DATA_WIDTH-1:0]               weight_data,
    output wire                                weight_ready,

    // ---- Activation input (to INACTIVE buffer) ----
    input  wire                                host_act_wr_en,
    input  wire [BUF_ADDR_W-1:0]               host_act_wr_addr,
    input  wire [DATA_WIDTH-1:0]               host_act_wr_data,
    input  wire [BUF_ADDR_W-1:0]               host_act_base_addr, // Base address for next tile

    // ---- Direct activation input (test/bypass, to ACTIVE buffer region) ----
    input  wire                                use_bram_act,
    input  wire [DATA_WIDTH-1:0]               act_data [0:ROWS-1],
    input  wire                                act_valid,

    // ---- Result output (from ACTIVE result BRAM) ----
    input  wire                                host_res_rd_en,
    input  wire [BUF_ADDR_W-1:0]               host_res_rd_addr,
    output wire [ACCUM_WIDTH-1:0]              host_res_rd_data,

    // ---- Raw result output (for debug/monitoring) ----
    output wire [ACCUM_WIDTH-1:0]              result_data [0:COLS-1],
    output wire                                result_valid,

    // ---- Tile base addresses ----
    input  wire [BUF_ADDR_W-1:0]               act_base_addr,
    input  wire [BUF_ADDR_W-1:0]               res_base_addr
);

    //==========================================================================
    // Buffer select register
    //==========================================================================
    reg  sel;           // 0 = buffer A active, 1 = buffer B active
    wire sel_inv = ~sel;

    assign buf_sel = sel;

    // Auto-swap after done
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sel <= 1'b0;
        end else if (done && auto_swap) begin
            sel <= sel_inv;
        end
    end

    //==========================================================================
    // MUXed BRAM signals — route active set to systolic_array, inactive to host
    //==========================================================================

    // ---- Activation BRAM A ----
    wire                 act_bram_a_wr_en;
    wire [BUF_ADDR_W-1:0] act_bram_a_wr_addr;
    wire [DATA_WIDTH-1:0] act_bram_a_wr_data;
    wire                 act_bram_a_rd_en;
    wire [BUF_ADDR_W-1:0] act_bram_a_rd_addr;
    wire [DATA_WIDTH-1:0] act_bram_a_rd_data;

    // ---- Activation BRAM B ----
    wire                 act_bram_b_wr_en;
    wire [BUF_ADDR_W-1:0] act_bram_b_wr_addr;
    wire [DATA_WIDTH-1:0] act_bram_b_wr_data;
    wire                 act_bram_b_rd_en;
    wire [BUF_ADDR_W-1:0] act_bram_b_rd_addr;
    wire [DATA_WIDTH-1:0] act_bram_b_rd_data;

    // ---- Result BRAM A ----
    wire                 res_bram_a_wr_en;
    wire [BUF_ADDR_W-1:0] res_bram_a_wr_addr;
    wire [ACCUM_WIDTH-1:0] res_bram_a_wr_data;
    wire                 res_bram_a_rd_en;
    wire [BUF_ADDR_W-1:0] res_bram_a_rd_addr;
    wire [ACCUM_WIDTH-1:0] res_bram_a_rd_data;

    // ---- Result BRAM B ----
    wire                 res_bram_b_wr_en;
    wire [BUF_ADDR_W-1:0] res_bram_b_wr_addr;
    wire [ACCUM_WIDTH-1:0] res_bram_b_wr_data;
    wire                 res_bram_b_rd_en;
    wire [BUF_ADDR_W-1:0] res_bram_b_rd_addr;
    wire [ACCUM_WIDTH-1:0] res_bram_b_rd_data;

    //==========================================================================
    // MUX: route systolic_array ↔ active buffer, host ↔ inactive buffer
    //==========================================================================

    // Activation write: host → inactive buffer
    assign act_bram_a_wr_en   = (sel == 1'b0) ? 1'b0 : host_act_wr_en;
    assign act_bram_a_wr_addr = (sel == 1'b0) ? {BUF_ADDR_W{1'b0}} : host_act_wr_addr;
    assign act_bram_a_wr_data = (sel == 1'b0) ? {DATA_WIDTH{1'b0}} : host_act_wr_data;

    assign act_bram_b_wr_en   = (sel == 1'b1) ? 1'b0 : host_act_wr_en;
    assign act_bram_b_wr_addr = (sel == 1'b1) ? {BUF_ADDR_W{1'b0}} : host_act_wr_addr;
    assign act_bram_b_wr_data = (sel == 1'b1) ? {DATA_WIDTH{1'b0}} : host_act_wr_data;

    // Activation read: deserializer ← active buffer
    //   (These are driven by act_deserializer inside systolic_array;
    //    we instantiate the BRAMs here and connect the read ports)
    //   → systolic_array's internal act_bram is replaced by these external BRAMs.

    //==========================================================================
    // Systolic array instantiation (WITHOUT internal BRAMs)
    //   We expose the BRAM interface so we can insert ping-pong MUXes.
    //==========================================================================

    // Internal systolic_array signals (BRAM interfaces broken out)
    wire                 sa_act_bram_rd_en;
    wire [BUF_ADDR_W-1:0] sa_act_bram_rd_addr;
    wire [DATA_WIDTH-1:0] sa_act_bram_rd_data;
    wire                 sa_res_bram_wr_en;
    wire [BUF_ADDR_W-1:0] sa_res_bram_wr_addr;
    wire [ACCUM_WIDTH-1:0] sa_res_bram_wr_data;
    wire                 sa_res_bram_rd_en;
    wire [BUF_ADDR_W-1:0] sa_res_bram_rd_addr;
    wire [ACCUM_WIDTH-1:0] sa_res_bram_rd_data;

    //==========================================================================
    // Modified systolic_array with BRAM interfaces exposed
    //==========================================================================
    systolic_array_exposed #(
        .ROWS        (ROWS),
        .COLS        (COLS),
        .DATA_WIDTH  (DATA_WIDTH),
        .ACCUM_WIDTH (ACCUM_WIDTH),
        .K_DEPTH     (K_DEPTH),
        .BUF_ADDR_W  (BUF_ADDR_W),
        .BUF_DEPTH   (BUF_DEPTH),
        .WT_ADDR_W   (WT_ADDR_W)
    ) u_sa (
        .clk              (clk),
        .rst_n            (rst_n),
        .start            (start),
        .weight_preloaded (weight_preloaded),
        .prefetch_start   (prefetch_start),
        .busy             (busy),
        .done             (done),
        .use_bram_act     (use_bram_act),
        .weight_data      (weight_data),
        .weight_ready     (weight_ready),
        .act_data         (act_data),
        .act_valid        (act_valid),
        // Activation BRAM read port (→ deserializer)
        .act_bram_rd_en   (sa_act_bram_rd_en),
        .act_bram_rd_addr (sa_act_bram_rd_addr),
        .act_bram_rd_data (sa_act_bram_rd_data),
        // Result BRAM write port (← serializer)
        .res_bram_wr_en   (sa_res_bram_wr_en),
        .res_bram_wr_addr (sa_res_bram_wr_addr),
        .res_bram_wr_data (sa_res_bram_wr_data),
        // Result BRAM read port (← host)
        .res_bram_rd_en   (sa_res_bram_rd_en),
        .res_bram_rd_addr (sa_res_bram_rd_addr),
        .res_bram_rd_data (sa_res_bram_rd_data),
        .result_data      (result_data),
        .result_valid     (result_valid),
        .act_base_addr    (act_base_addr),
        .res_base_addr    (res_base_addr)
    );

    //==========================================================================
    // Activation BRAM read MUX: systolic_array ← active buffer
    //==========================================================================
    assign sa_act_bram_rd_data = sel ? act_bram_b_rd_data : act_bram_a_rd_data;

    assign act_bram_a_rd_en   = (sel == 1'b0) ? sa_act_bram_rd_en   : 1'b0;
    assign act_bram_a_rd_addr = (sel == 1'b0) ? sa_act_bram_rd_addr : {BUF_ADDR_W{1'b0}};

    assign act_bram_b_rd_en   = (sel == 1'b1) ? sa_act_bram_rd_en   : 1'b0;
    assign act_bram_b_rd_addr = (sel == 1'b1) ? sa_act_bram_rd_addr : {BUF_ADDR_W{1'b0}};

    //==========================================================================
    // Result BRAM write MUX: serializer → active buffer
    //==========================================================================
    assign res_bram_a_wr_en   = (sel == 1'b0) ? sa_res_bram_wr_en   : 1'b0;
    assign res_bram_a_wr_addr = (sel == 1'b0) ? sa_res_bram_wr_addr : {BUF_ADDR_W{1'b0}};
    assign res_bram_a_wr_data = (sel == 1'b0) ? sa_res_bram_wr_data : {ACCUM_WIDTH{1'b0}};

    assign res_bram_b_wr_en   = (sel == 1'b1) ? sa_res_bram_wr_en   : 1'b0;
    assign res_bram_b_wr_addr = (sel == 1'b1) ? sa_res_bram_wr_addr : {BUF_ADDR_W{1'b0}};
    assign res_bram_b_wr_data = (sel == 1'b1) ? sa_res_bram_wr_data : {ACCUM_WIDTH{1'b0}};

    //==========================================================================
    // Result BRAM read MUX: host reads from INACTIVE buffer.
    //   systolic_array_exposed's res_bram_rd_* passthrough is also routed
    //   to the inactive buffer so the host can read results through either
    //   the host_res_* ports or the sa's res_bram_rd_* passthrough.
    //==========================================================================

    // Host read data comes from the INACTIVE result buffer
    assign host_res_rd_data = sel ? res_bram_a_rd_data : res_bram_b_rd_data;

    // systolic_array_exposed result read: passthrough to inactive buffer
    assign sa_res_bram_rd_en   = 1'b0;  // SA doesn't read results — host does
    // sa_res_bram_rd_data is an output from SA, unused in ping-pong mode

    // Inactive buffer read port: connected to host
    assign res_bram_a_rd_en   = (sel == 1'b1) ? host_res_rd_en   : 1'b0;
    assign res_bram_a_rd_addr = (sel == 1'b1) ? host_res_rd_addr : {BUF_ADDR_W{1'b0}};

    assign res_bram_b_rd_en   = (sel == 1'b0) ? host_res_rd_en   : 1'b0;
    assign res_bram_b_rd_addr = (sel == 1'b0) ? host_res_rd_addr : {BUF_ADDR_W{1'b0}};

    //==========================================================================
    // Activation BRAM A
    //==========================================================================
    buffer_ram #(
        .DATA_WIDTH (DATA_WIDTH),
        .ADDR_WIDTH (BUF_ADDR_W),
        .DEPTH      (BUF_DEPTH)
    ) u_act_bram_a (
        .clk      (clk),
        .wr_en    (act_bram_a_wr_en),
        .wr_addr  (act_bram_a_wr_addr),
        .wr_data  (act_bram_a_wr_data),
        .rd_en    (act_bram_a_rd_en),
        .rd_addr  (act_bram_a_rd_addr),
        .rd_data  (act_bram_a_rd_data)
    );

    //==========================================================================
    // Activation BRAM B
    //==========================================================================
    buffer_ram #(
        .DATA_WIDTH (DATA_WIDTH),
        .ADDR_WIDTH (BUF_ADDR_W),
        .DEPTH      (BUF_DEPTH)
    ) u_act_bram_b (
        .clk      (clk),
        .wr_en    (act_bram_b_wr_en),
        .wr_addr  (act_bram_b_wr_addr),
        .wr_data  (act_bram_b_wr_data),
        .rd_en    (act_bram_b_rd_en),
        .rd_addr  (act_bram_b_rd_addr),
        .rd_data  (act_bram_b_rd_data)
    );

    //==========================================================================
    // Result BRAM A
    //==========================================================================
    buffer_ram #(
        .DATA_WIDTH (ACCUM_WIDTH),
        .ADDR_WIDTH (BUF_ADDR_W),
        .DEPTH      (BUF_DEPTH)
    ) u_res_bram_a (
        .clk      (clk),
        .wr_en    (res_bram_a_wr_en),
        .wr_addr  (res_bram_a_wr_addr),
        .wr_data  (res_bram_a_wr_data),
        .rd_en    (res_bram_a_rd_en),
        .rd_addr  (res_bram_a_rd_addr),
        .rd_data  (res_bram_a_rd_data)
    );

    //==========================================================================
    // Result BRAM B
    //==========================================================================
    buffer_ram #(
        .DATA_WIDTH (ACCUM_WIDTH),
        .ADDR_WIDTH (BUF_ADDR_W),
        .DEPTH      (BUF_DEPTH)
    ) u_res_bram_b (
        .clk      (clk),
        .wr_en    (res_bram_b_wr_en),
        .wr_addr  (res_bram_b_wr_addr),
        .wr_data  (res_bram_b_wr_data),
        .rd_en    (res_bram_b_rd_en),
        .rd_addr  (res_bram_b_rd_addr),
        .rd_data  (res_bram_b_rd_data)
    );

endmodule
