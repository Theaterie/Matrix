# wave_numerical.tcl — Run numerical testbench with waveform logging
# Usage: xsim tb_systolic_array_numerical -tclbatch scripts/wave_numerical.tcl
# Or first run: xvlog --incr --relax --sv src/mac_unit.v src/pe.sv src/pe_array.sv src/controller.sv src/address_generator.sv src/buffer_ram.sv src/act_deserializer.sv src/result_serializer.sv src/systolic_array.sv tb/tb_systolic_array_numerical.sv
# Then: xelab --incr --debug typical tb_systolic_array_numerical

# Log all signals in the DUT hierarchy
log_wave -recursive u_dut/*

# Also log top-level testbench signals
log_wave -recursive {clk rst_n start busy done}
log_wave -recursive {result_valid result_data}
log_wave -recursive {act_wr_en act_wr_addr act_wr_data}
log_wave -recursive {res_rd_en res_rd_addr res_rd_data}

# Run simulation
run -all

# Save waveform database
save_wavecfg tb_sa_num_snap.wcfg
