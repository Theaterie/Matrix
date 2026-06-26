#==============================================================================
# sim_numerical.tcl — Run numerical verification test
#==============================================================================
set work_dir [file dirname [file normalize [info script]]]/..
cd $work_dir

set top "tb_systolic_array_numerical"
set srcs [list \
    "src/mac_unit.v" "src/pe.sv" "src/pe_array.sv" \
    "src/controller.sv" "src/address_generator.sv" \
    "src/buffer_ram.sv" "src/act_deserializer.sv" \
    "src/result_serializer.sv" "src/systolic_array.sv" \
    "tb/tb_systolic_array_numerical.sv"]

puts "################################################################"
puts "#  Numerical Verification Test"
puts "################################################################"

catch {file delete -force xsim.dir}

puts "  Compiling..."
set xvlog_args [concat [list --incr --relax --sv] $srcs]
if {[catch {exec xvlog {*}$xvlog_args} result]} {
    puts "FAIL: xvlog: $result"
    exit 1
}

puts "  Elaborating..."
if {[catch {exec xelab --incr --debug typical $top} result]} {
    puts "FAIL: xelab: $result"
    exit 1
}

puts "  Simulating..."
set sim_status [catch {exec xsim $top --runall} result]

# Print all relevant lines
foreach line [split $result "\n"] {
    if {[string match {*PASS*} $line] || [string match {*FAIL*} $line] || \
        [string match {*Summary:*} $line] || [string match {*ALL TESTS*} $line] || \
        [string match {*SOME TESTS*} $line] || [string match {*TC0*} $line]} {
        puts "    $line"
    }
}
