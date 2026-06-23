`timescale 1ns / 1ps

//==============================================================================
// Module:  result_serializer
// Purpose: Captures parallel COLS-wide results from PE array bottom edge during
//          READOUT (pipeline drain), then serializes them one entry per cycle
//          to the result BRAM during the SERIALIZE phase.
//==============================================================================
// Architecture:
//   1. Capture buffer: ROWS × COLS entries (holds one full tile of results)
//   2. During capture_en=1: when parallel_valid pulses, capture all COLS entries
//      into the next available buffer row
//   3. During shift_en=1:   output one entry per cycle (row-major order),
//      asserting serial_valid; pulse done on the last entry
//   4. Pointer / count logic ensures no overflow and correct ordering
//
// Timing (16×16):
//   - READOUT captures up to ROWS=16 result rows (one per row-drain cycle)
//   - SERIALIZE outputs ROWS×COLS=256 results in 256 cycles
//==============================================================================

module result_serializer #(
    parameter ROWS        = 16,          // PE array rows (max capture rows)
    parameter COLS        = 16,          // PE array columns (results per row)
    parameter DATA_WIDTH  = 40           // Accumulator bit width
) (
    input  wire                             clk,
    input  wire                             rst_n,           // Async reset, active low

    // ---- Parallel input from PE array bottom edge ----
    input  wire [DATA_WIDTH-1:0]            parallel_in [0:COLS-1],
    input  wire                             parallel_valid,

    // ---- Serial output to result BRAM ----
    output reg  [DATA_WIDTH-1:0]            serial_data,
    output reg                              serial_valid,

    // ---- Control ----
    input  wire                             capture_en,      // READOUT phase: capture on parallel_valid
    input  wire                             shift_en,        // SERIALIZE phase: shift out one per cycle
    output reg                              done             // Pulse: last entry shifted out
);

    //==========================================================================
    // Local parameters
    //==========================================================================
    localparam ROW_WID    = $clog2(ROWS);           // 4
    localparam COL_WID    = $clog2(COLS);           // 4
    localparam COUNT_WID  = $clog2(ROWS*COLS) + 1;  // 9 (range 0..256)

    //==========================================================================
    // Capture buffer: ROWS rows × COLS columns
    //==========================================================================
    reg [DATA_WIDTH-1:0] cap_buf [0:ROWS-1][0:COLS-1];

    //==========================================================================
    // Pointers and count
    //==========================================================================
    reg [ROW_WID-1:0]    cap_row;     // Next row to capture into (0..ROWS-1)
    reg [ROW_WID-1:0]    ser_row;     // Current serialization row
    reg [COL_WID-1:0]    ser_col;     // Current serialization column
    reg [COUNT_WID-1:0]  count;       // Entries currently buffered (0..ROWS*COLS)

    integer c;  // loop variable

    //==========================================================================
    // Main logic — capture + shift (mutually exclusive in normal operation)
    //==========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cap_row      <= {ROW_WID{1'b0}};
            ser_row      <= {ROW_WID{1'b0}};
            ser_col      <= {COL_WID{1'b0}};
            count        <= {COUNT_WID{1'b0}};
            serial_data  <= {DATA_WIDTH{1'b0}};
            serial_valid <= 1'b0;
            done         <= 1'b0;
        end else begin
            done <= 1'b0;  // default: pulse

            // ---- Capture: store one full row of COLS results ----
            if (capture_en && parallel_valid && (cap_row < ROWS)) begin
                for (c = 0; c < COLS; c = c + 1) begin
                    cap_buf[cap_row][c] <= parallel_in[c];
                end
                cap_row <= cap_row + 1'b1;
                count   <= count + COLS;
            end
            // ---- Shift: output one entry per cycle (row-major order) ----
            else if (shift_en && (count > 0)) begin
                serial_data  <= cap_buf[ser_row][ser_col];
                serial_valid <= 1'b1;

                if (ser_col == (COLS - 1)) begin
                    ser_col <= {COL_WID{1'b0}};
                    ser_row <= ser_row + 1'b1;
                end else begin
                    ser_col <= ser_col + 1'b1;
                end
                count <= count - 1'b1;

                // Pulse done on the very last entry
                if (count == 1)
                    done <= 1'b1;
            end
            // ---- Idle: hold outputs, reset pointers ----
            else begin
                if (!capture_en && !shift_en) begin
                    cap_row <= {ROW_WID{1'b0}};
                    ser_row <= {ROW_WID{1'b0}};
                    ser_col <= {COL_WID{1'b0}};
                    count   <= {COUNT_WID{1'b0}};
                end
                if (!shift_en)
                    serial_valid <= 1'b0;
            end
        end
    end

endmodule
