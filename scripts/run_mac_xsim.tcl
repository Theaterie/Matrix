#==============================================================================
# run_mac_xsim.tcl — Direct xsim compilation for MAC unit
#==============================================================================
set work_dir [file dirname [file normalize [info script]]]/..
cd $work_dir

puts "============================================================"
puts "  Compiling MAC unit..."
puts "============================================================"

set xvlog "d:/2025.2/Vivado/bin/unwrapped/win64.o/xvlog.exe"
set xelab "d:/2025.2/Vivado/bin/unwrapped/win64.o/xelab.exe"
set xsim  "d:/2025.2/Vivado/bin/unwrapped/win64.o/xsim.exe"

# Compile
if {[catch {exec $xvlog --sv --incr --relax src/mac_unit.v tb/tb_mac_unit.v} result]} {
    puts "xvlog ERROR: $result"
    exit 1
}
puts $result

puts ""
puts "============================================================"
puts "  Elaborating..."
puts "============================================================"

if {[catch {exec $xelab --incr --debug typical tb_mac_unit} result]} {
    puts "xelab ERROR: $result"
    exit 1
}
puts $result

puts ""
puts "============================================================"
puts "  Running simulation..."
puts "============================================================"

if {[catch {exec $xsim tb_mac_unit --runall} result]} {
    puts "xsim ERROR: $result"
    exit 1
}
puts $result

puts ""
puts "============================================================"
puts "  MAC unit simulation done!"
puts "============================================================"
