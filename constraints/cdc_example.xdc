# Example timing constraints for the two clock domains of accel_top.
#
# NOT YET RUN THROUGH VIVADO — a starting point, to be checked against the
# timing and CDC reports (report_cdc, report_clock_interaction) on a real build.

# Two clocks with no fixed phase relationship. Adjust periods to the design.
create_clock -name host_clk -period 10.000 [get_ports host_clk]
create_clock -name core_clk -period  8.000 [get_ports core_clk]

# Every path between the domains goes through an async_fifo:
#   * Gray-coded pointers into the two-flop synchronizers (sync_2ff)
#   * FIFO memory, written in one domain and read in the other; an entry is
#     only read after its write pointer has crossed, so the data is stable
#
# Simplest correct option: tell the tools the clocks are unrelated.
set_clock_groups -asynchronous -group [get_clocks host_clk] -group [get_clocks core_clk]

# Stricter alternative (use INSTEAD of set_clock_groups): keep the paths timed
# but bound their delay, so the bits of a Gray pointer cannot arrive more than
# one source-clock period apart.
#
# set_max_delay -datapath_only -from [get_clocks host_clk] -to [get_clocks core_clk]  8.000
# set_max_delay -datapath_only -from [get_clocks core_clk] -to [get_clocks host_clk]  8.000
