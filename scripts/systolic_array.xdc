#==============================================================================
# XDC Constraints: systolic_array
# Target:  xcux35-vsva1365-3-e (Xilinx Virtex UltraScale+)
# Clock:   200-300 MHz (5.0 ns - 3.33 ns)
#==============================================================================

#==============================================================================
# 1. Clock Constraints
#==============================================================================

# Primary clock — target 250 MHz (4.0 ns), with 200-300 MHz range
# Use 4.0 ns (250 MHz) as primary target; can tighten to 3.33 ns (300 MHz)
create_clock -period 4.000 -name clk -waveform {0.000 2.000} [get_ports clk]

#==============================================================================
# 2. Clock Uncertainty (jitter + skew margin)
#==============================================================================

# 100 ps setup uncertainty, 50 ps hold uncertainty (typical for US+)
set_clock_uncertainty -setup 0.100 [get_clocks clk]
set_clock_uncertainty -hold  0.050 [get_clocks clk]

#==============================================================================
# 3. Input Delay Constraints
#==============================================================================

# All inputs are synchronous to clk, assume 60% of period for external logic
# Input delay = 40% of clock period (external device drives after clk edge)
# Tco_ext + Troute_ext ≈ 1.6 ns at 250 MHz
set_input_delay -clock clk -max 1.600 [get_ports {start use_bram_act act_valid}]
set_input_delay -clock clk -min 0.200 [get_ports {start use_bram_act act_valid}]

# Data bus inputs
set_input_delay -clock clk -max 1.600 [get_ports {weight_data[*] act_data[*] act_wr_data[*]}]
set_input_delay -clock clk -min 0.200 [get_ports {weight_data[*] act_data[*] act_wr_data[*]}]

# Address/control inputs
set_input_delay -clock clk -max 1.600 [get_ports {act_wr_addr[*] res_rd_addr[*] act_base_addr[*] res_base_addr[*]}]
set_input_delay -clock clk -min 0.200 [get_ports {act_wr_addr[*] res_rd_addr[*] act_base_addr[*] res_base_addr[*]}]

# Write enables
set_input_delay -clock clk -max 1.600 [get_ports {act_wr_en res_rd_en}]
set_input_delay -clock clk -min 0.200 [get_ports {act_wr_en res_rd_en}]

#==============================================================================
# 4. Output Delay Constraints
#==============================================================================

# Outputs need to be valid before next capturing edge
# Output delay = 40% of period
set_output_delay -clock clk -max 1.600 [get_ports {done busy weight_ready result_valid}]
set_output_delay -clock clk -min 0.000 [get_ports {done busy weight_ready result_valid}]

# Result data outputs
set_output_delay -clock clk -max 1.600 [get_ports {result_data[*][*] res_rd_data[*]}]
set_output_delay -clock clk -min 0.000 [get_ports {result_data[*][*] res_rd_data[*]}]

#==============================================================================
# 5. Timing Exceptions
#==============================================================================

# Async reset — false path from rst_n to all registers
# (reset recovery is handled by the async reset synchronizer at top level)
set_false_path -from [get_ports rst_n]

# Cross-clock domain paths (if any) — none in this design

# Multicycle path: weight loading address is stable for one full cycle
# The controller FSM ensures weight_addr is stable before weight_wren asserts
# No multicycle needed at 250 MHz (single-cycle weight load)

#==============================================================================
# 6. DSP48 Constraints
#==============================================================================

# DSP48 blocks in the mac_unit: 2-stage pipeline
# Stage 1: multiply (MREG)
# Stage 2: accumulate (PREG/AREG)
# Ensure DSP48 uses full pipeline registers for max frequency

# Force DSP48 implementation for mac_unit multipliers
set_property USE_DSP YES [get_cells -hierarchical -filter {NAME =~ *u_mac*}]

# DSP48 pipeline register packing
set_property DSP48_PREG 1 [get_cells -hierarchical -filter {NAME =~ *u_mac*}]
set_property DSP48_AREG 2 [get_cells -hierarchical -filter {NAME =~ *u_mac*}]

#==============================================================================
# 7. BRAM Constraints
#==============================================================================

# BRAM read-first mode: read-before-write on same address returns old data
# This matches buffer_ram behavior (no write-forwarding needed)

# Enable BRAM output registers for timing
set_property BRAM_OUTPUT_REG TRUE [get_cells -hierarchical -filter {NAME =~ *u_act_bram*}]
set_property BRAM_OUTPUT_REG TRUE [get_cells -hierarchical -filter {NAME =~ *u_res_bram*}]

#==============================================================================
# 8. High-Fanout Nets
#==============================================================================

# Global control signals: pe_clear, pe_enable, weight_wren
# These fan out to ROWS*COLS PEs (up to 256 loads)
# Vivado will auto-insert BUFG/BUFR as needed

# Use global clock buffer for high-fanout control signals
set_property CLOCK_BUFFER_TYPE BUFG [get_nets -hierarchical -filter {NAME =~ *ctrl_pe_enable*}]
set_property CLOCK_BUFFER_TYPE BUFG [get_nets -hierarchical -filter {NAME =~ *ctrl_pe_clear*}]

#==============================================================================
# 9. Physical Constraints (Placement)
#==============================================================================

# P block for PE array: keep PEs in a compact region
# Create a Pblock for the 16x16 PE array to minimize routing delay
# (Uncomment for actual implementation)
# create_pblock pe_array_block
# add_cells_to_pblock pe_array_block [get_cells -hierarchical -filter {NAME =~ *u_pe_array/gen_pe_row*}] -clear_locs
# resize_pblock pe_array_block -add {SLICE_X0Y0:SLICE_X100Y100}

#==============================================================================
# 10. Operating Conditions
#==============================================================================

# UltraScale+ speed grade -3 supports these timing targets comfortably
# Set process corner analysis
set_operating_conditions -analysis_type on_chip_variation

#==============================================================================
# 11. Report Settings
#==============================================================================

# Generate detailed timing reports
# Usage in Vivado Tcl console after synthesis/implementation:
#   report_timing_summary -file timing_summary.rpt
#   report_timing -max_paths 100 -file timing_paths.rpt
#   report_clock_utilization -file clock_util.rpt

#==============================================================================
# 12. Aggressive Timing (300 MHz target — uncomment to use)
#==============================================================================

# For 300 MHz (3.333 ns period):
# create_clock -period 3.333 -name clk -waveform {0.000 1.667} [get_ports clk]
# set_clock_uncertainty -setup 0.080 [get_clocks clk]
# set_input_delay -clock clk -max 1.200 [get_ports ...]
# set_output_delay -clock clk -max 1.200 [get_ports ...]

# Additional retiming may be required for 300 MHz:
#   - Pipeline FSM outputs
#   - Add pipeline registers to skew chains
#   - Consider floorplanning PE array as a hard macro
