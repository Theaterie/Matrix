open_vcd tb_controller.vcd
log_vcd tb_controller/uut/state
log_vcd tb_controller/uut/weight_cnt
log_vcd tb_controller/uut/next_state
log_vcd tb_controller/uut/weight_wren
log_vcd tb_controller/uut/phase
run 2000ns
close_vcd
exit
