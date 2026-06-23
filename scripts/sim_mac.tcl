#==============================================================================
# sim_mac.tcl  —  Vivado behavioral simulation script (MAC unit)
#==============================================================================
# Usage:
#   vivado -mode batch -source scripts/sim_mac.tcl
#==============================================================================

#------------------------------------------------------------------------------
# 0. Clean up previous run
#------------------------------------------------------------------------------
set project_name  sim_mac_unit
set project_dir   ./sim_build

if {[file exists $project_dir]} {
    file delete -force $project_dir
}

#------------------------------------------------------------------------------
# 1. Create project
#------------------------------------------------------------------------------
create_project $project_name $project_dir -part xcux35-vsva1365-3-e

#------------------------------------------------------------------------------
# 2. Add design sources
#------------------------------------------------------------------------------
add_files -norecurse mac_unit.v
set_property file_type Verilog [get_files mac_unit.v]

#------------------------------------------------------------------------------
# 3. Add simulation sources
#------------------------------------------------------------------------------
add_files -fileset sim_1 -norecurse tb/tb_mac_unit.v
set_property file_type Verilog [get_files -of_objects [get_filesets sim_1] tb/tb_mac_unit.v]

#------------------------------------------------------------------------------
# 4. Set simulation top
#------------------------------------------------------------------------------
set_property top tb_mac_unit [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]

#------------------------------------------------------------------------------
# 5. Simulation settings
#    - runtime: 0ns = run until $finish
#    - log_all_signals: capture all waveforms
#------------------------------------------------------------------------------
set_property -name {xsim.simulate.runtime}        -value {0ns}    -objects [get_filesets sim_1]
set_property -name {xsim.simulate.log_all_signals} -value {true}   -objects [get_filesets sim_1]
set_property -name {xsim.elaborate.debug_level}    -value {typical} -objects [get_filesets sim_1]

#------------------------------------------------------------------------------
# 6. Launch simulation
#------------------------------------------------------------------------------
puts "============================================================"
puts "  Starting behavioral simulation..."
puts "============================================================"

launch_simulation
run all

#------------------------------------------------------------------------------
# 7. Close simulation
#------------------------------------------------------------------------------
close_sim

puts "============================================================"
puts "  Simulation done — check Tcl Console for PASS/FAIL results"
puts "============================================================"

#------------------------------------------------------------------------------
# 8. Close project
#------------------------------------------------------------------------------
close_project
