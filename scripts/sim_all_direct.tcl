#==============================================================================
# sim_all_direct.tcl — Run all testbenches in Vivado Tcl mode
#==============================================================================
set work_dir [file dirname [file normalize [info script]]]/..
cd $work_dir

# List of testbenches: {top label files...}
set tests [list \
    [list "tb_pe" "PE Unit" \
        "src/mac_unit.v" "src/pe.sv" "tb/tb_pe.sv"] \
    [list "tb_pe_array" "PE Array (4x4)" \
        "src/mac_unit.v" "src/pe.sv" "src/pe_array.sv" \
        "src/controller.sv" "src/address_generator.sv" \
        "src/buffer_ram.sv" "src/act_deserializer.sv" \
        "src/result_serializer.sv" "tb/tb_pe_array.sv"] \
    [list "tb_systolic_array" "Systolic Array (BRAM)" \
        "src/mac_unit.v" "src/pe.sv" "src/pe_array.sv" \
        "src/controller.sv" "src/address_generator.sv" \
        "src/buffer_ram.sv" "src/act_deserializer.sv" \
        "src/result_serializer.sv" "src/systolic_array.sv" \
        "tb/tb_systolic_array.sv"] \
    [list "tb_systolic_array_numerical" "SA Numerical Verify" \
        "src/mac_unit.v" "src/pe.sv" "src/pe_array.sv" \
        "src/controller.sv" "src/address_generator.sv" \
        "src/buffer_ram.sv" "src/act_deserializer.sv" \
        "src/result_serializer.sv" "src/systolic_array.sv" \
        "tb/tb_systolic_array_numerical.sv"] \
]

set all_pass 1

foreach test $tests {
    set top    [lindex $test 0]
    set label  [lindex $test 1]
    set srcs   [lrange $test 2 end]

    puts ""
    puts "################################################################"
    puts "#  $label ($top)"
    puts "################################################################"

    # Clean previous snapshot
    catch {file delete -force xsim.dir}

    # Compile
    puts "  Compiling..."
    set xvlog_args [concat [list --incr --relax --sv] $srcs]
    if {[catch {exec xvlog {*}$xvlog_args} result]} {
        puts "  FAIL: xvlog error:"
        puts $result
        set all_pass 0
        continue
    }

    # Elaborate
    puts "  Elaborating..."
    if {[catch {exec xelab --incr --debug typical $top} result]} {
        puts "  FAIL: xelab error:"
        puts $result
        set all_pass 0
        continue
    }

    # Run simulation
    puts "  Simulating..."
    set sim_status [catch {exec xsim $top --runall} result]

    # Print relevant output lines
    set pass_cnt 0
    set fail_cnt 0
    foreach line [split $result "\n"] {
        if {[string match {*PASS*} $line] || [string match {*FAIL*} $line] || \
            [string match {*Summary:*} $line] || [string match {*ALL TESTS*} $line] || \
            [string match {*SOME TESTS*} $line]} {
            puts "    $line"
        }
        if {[string match {*ALL TESTS PASSED*} $line]} { set pass_cnt 1 }
        if {[string match {*SOME TESTS FAILED*} $line]} { set fail_cnt 1 }
    }

    if {$fail_cnt} {
        puts "  >> RESULT: FAIL"
        set all_pass 0
    } elseif {$pass_cnt} {
        puts "  >> RESULT: PASS"
    } else {
        puts "  >> RESULT: CHECK MANUALLY"
    }
}

puts ""
puts "################################################################"
if {$all_pass} {
    puts "#  ALL TESTBENCHES PASSED!"
} else {
    puts "#  SOME TESTBENCHES FAILED — see above"
}
puts "################################################################"
