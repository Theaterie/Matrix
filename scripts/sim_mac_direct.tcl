#==============================================================================
# sim_mac_direct.tcl — Direct xsim flow in Vivado Tcl mode
#==============================================================================
set work_dir [file dirname [file normalize [info script]]]/..
cd $work_dir

puts "============================================================"
puts "  Compiling MAC unit..."
puts "============================================================"

# Use exec to run xvlog (Vivado's Tcl shell has the environment set up)
if {[catch {exec xvlog --sv --incr --relax src/mac_unit.v tb/tb_mac_unit.v} result]} {
    puts "ERROR: xvlog failed: $result"
    exit 1
}
puts $result

puts ""
puts "============================================================"
puts "  Elaborating..."
puts "============================================================"

if {[catch {exec xelab --incr --debug typical tb_mac_unit} result]} {
    puts "ERROR: xelab failed: $result"
    exit 1
}
puts $result

puts ""
puts "============================================================"
puts "  Running simulation..."
puts "============================================================"

# xsim returns non-zero on $finish, so catch is expected to trigger
set sim_status [catch {exec xsim tb_mac_unit --runall} result]
if {$sim_status != 0} {
    # xsim often returns non-zero even on success (due to $finish)
    puts "xsim exited with code $sim_status"
}
puts $result

puts ""
puts "============================================================"
puts "  MAC unit simulation done!"
puts "============================================================"
