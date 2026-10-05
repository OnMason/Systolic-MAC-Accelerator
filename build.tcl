# build.tcl — create the Vivado project and run the accelerator testbench in XSim.
#
#   vivado -mode batch -source build.tcl
#
# The part is the Basys 3 (XC7A35T); change it to match your board.

set proj_name systolic_accel
set proj_dir  ./vivado_proj
set part      xc7a35tcpg236-1

create_project $proj_name $proj_dir -part $part -force

add_files -norecurse [list \
  ./rtl/sync_2ff.sv \
  ./rtl/async_fifo.sv \
  ./rtl/mac_pe.sv \
  ./rtl/systolic_array.sv \
  ./rtl/requant.sv \
  ./rtl/accel_core.sv \
  ./rtl/accel_top.sv ]
set_property top accel_top [current_fileset]

add_files -fileset constrs_1 -norecurse ./constraints/cdc_example.xdc

add_files -fileset sim_1 -norecurse [list \
  ./tb/tb_pkg.sv \
  ./tb/async_fifo_sva.sv \
  ./tb/accel_core_sva.sv \
  ./tb/tb_accel.sv \
  ./tb/tb_async_fifo.sv ]
set_property top tb_accel [get_filesets sim_1]

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

set_property -name {xsim.simulate.runtime} -value {all} -objects [get_filesets sim_1]
set_property -name {xsim.simulate.xsim.more_options} \
             -value {-testplusarg SEED=1 -testplusarg NTESTS=60} -objects [get_filesets sim_1]
launch_simulation
