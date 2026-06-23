#==============================================================================
# sim_mac_gui.tcl  —  Vivado GUI interactive simulation script
#==============================================================================
# Usage (in Vivado Tcl Console):
#   cd d:/VsCode/intern/Matrix
#   source scripts/sim_mac_gui.tcl
#
# This script opens the waveform window with key signals pre-added.
#==============================================================================

# 0. Clean up
set project_name  sim_mac_unit
set project_dir   ./sim_build

if {[file exists $project_dir]} {
    file delete -force $project_dir
}

# 1. Create project
create_project $project_name $project_dir -part xcux35-vsva1365-3-e

# 2. Add source files
add_files -norecurse mac_unit.v
set_property file_type Verilog [get_files mac_unit.v]

add_files -fileset sim_1 -norecurse tb/tb_mac_unit.v
set_property file_type Verilog [get_files -of_objects [get_filesets sim_1] tb/tb_mac_unit.v]

# 3. Set top
set_property top tb_mac_unit [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]

# 4. Simulation config
set_property -name {xsim.simulate.runtime}        -value {0ns}    -objects [get_filesets sim_1]
set_property -name {xsim.simulate.log_all_signals} -value {true}   -objects [get_filesets sim_1]

# 5. Launch simulation
launch_simulation

# 6. Open waveform and add key signals
open_wave_config sim/tb_mac_unit_behav.wcfg

# Top-level signals
add_wave {{/tb_mac_unit/clk}}
add_wave {{/tb_mac_unit/rst_n}}
add_wave {{/tb_mac_unit/valid_in}}
add_wave {{/tb_mac_unit/clear}}
add_wave {{/tb_mac_unit/enable}}
add_wave {{/tb_mac_unit/a_in}}
add_wave {{/tb_mac_unit/b_in}}
add_wave {{/tb_mac_unit/acc_in}}
add_wave {{/tb_mac_unit/acc_out}}
add_wave {{/tb_mac_unit/valid_out}}

# DUT internal signals (Stage 1)
add_wave {{/tb_mac_unit/u_dut/mult_result_r}}
add_wave {{/tb_mac_unit/u_dut/valid_s1}}
add_wave {{/tb_mac_unit/u_dut/clear_d1}}

# DUT internal signals (Stage 2)
add_wave {{/tb_mac_unit/u_dut/acc_out_r}}
add_wave {{/tb_mac_unit/u_dut/valid_s2}}

# Set radix to signed decimal
set_property radix signed_decimal [get_wave_objects]

puts "============================================================"
puts "  Waveform configured. Type 'run all' to start, or press F4 to step."
puts "============================================================"
