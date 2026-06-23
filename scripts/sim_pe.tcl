#==============================================================================
# sim_pe.tcl  —  Vivado behavioral simulation script (PE + PE Array)
#==============================================================================
# Usage:
#   vivado -mode batch -source scripts/sim_pe.tcl
#==============================================================================

#------------------------------------------------------------------------------
# 0. Clean up previous run
#------------------------------------------------------------------------------
set project_name  sim_pe
set project_dir   ./sim_build_pe

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

add_files -norecurse pe.sv
set_property file_type SystemVerilog [get_files pe.sv]

add_files -norecurse pe_array.sv
set_property file_type SystemVerilog [get_files pe_array.sv]

add_files -norecurse controller.sv
set_property file_type SystemVerilog [get_files controller.sv]

add_files -norecurse address_generator.sv
set_property file_type SystemVerilog [get_files address_generator.sv]

add_files -norecurse buffer_ram.sv
set_property file_type SystemVerilog [get_files buffer_ram.sv]

add_files -norecurse systolic_array.sv
set_property file_type SystemVerilog [get_files systolic_array.sv]

add_files -norecurse result_serializer.sv
set_property file_type SystemVerilog [get_files result_serializer.sv]

#------------------------------------------------------------------------------
# 3. Add simulation sources
#------------------------------------------------------------------------------
add_files -fileset sim_1 -norecurse tb/tb_pe.sv
set_property file_type SystemVerilog [get_files -of_objects [get_filesets sim_1] tb/tb_pe.sv]

add_files -fileset sim_1 -norecurse tb/tb_pe_array.sv
set_property file_type SystemVerilog [get_files -of_objects [get_filesets sim_1] tb/tb_pe_array.sv]

#------------------------------------------------------------------------------
# 4. Set simulation top
#------------------------------------------------------------------------------
set_property top tb_pe [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]

#------------------------------------------------------------------------------
# 5. Simulation settings
#------------------------------------------------------------------------------
set_property -name {xsim.simulate.runtime}        -value {0ns}    -objects [get_filesets sim_1]
set_property -name {xsim.simulate.log_all_signals} -value {true}   -objects [get_filesets sim_1]
set_property -name {xsim.elaborate.debug_level}    -value {typical} -objects [get_filesets sim_1]

#------------------------------------------------------------------------------
# 6. Launch simulation — PE testbench first
#------------------------------------------------------------------------------
puts "============================================================"
puts "  Starting PE behavioral simulation..."
puts "============================================================"

launch_simulation
run all

puts "============================================================"
puts "  PE simulation done"
puts "============================================================"

close_sim

#------------------------------------------------------------------------------
# 7. Switch top to PE Array testbench
#------------------------------------------------------------------------------
set_property top tb_pe_array [get_filesets sim_1]

puts "============================================================"
puts "  Starting PE Array (4x4) behavioral simulation..."
puts "============================================================"

launch_simulation
run all

puts "============================================================"
puts "  PE Array simulation done"
puts "============================================================"

close_sim

#------------------------------------------------------------------------------
# 8. Close project
#------------------------------------------------------------------------------
close_project

puts "============================================================"
puts "  All simulations complete — check above for PASS/FAIL"
puts "============================================================"
