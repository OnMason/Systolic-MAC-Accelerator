// -----------------------------------------------------------------------------
// async_fifo_sva — assertions for async_fifo, bound into every instance
//
// Each assertion lives entirely in one clock domain. Checks that need both
// domains at once (true occupancy, data ordering) are done by the testbench
// scoreboard instead.
// -----------------------------------------------------------------------------
module async_fifo_sva #(
  parameter int ADDR_W = 4
) (
  input logic            wr_clk,
  input logic            wr_rst,
  input logic            wr_en,
  input logic            wr_full,
  input logic [ADDR_W:0] wbin,
  input logic [ADDR_W:0] wgray,
  input logic [ADDR_W:0] rgray_wr,

  input logic            rd_clk,
  input logic            rd_rst,
  input logic            rd_en,
  input logic            rd_empty,
  input logic [ADDR_W:0] rbin,
  input logic [ADDR_W:0] rgray,
  input logic [ADDR_W:0] wgray_rd
);

  localparam logic [ADDR_W:0] DEPTH = (ADDR_W+1)'(1) << ADDR_W;

  function automatic logic [ADDR_W:0] gray2bin(logic [ADDR_W:0] g);
    logic [ADDR_W:0] b;
    b[ADDR_W] = g[ADDR_W];
    for (int i = ADDR_W - 1; i >= 0; i--) b[i] = b[i+1] ^ g[i];
    return b;
  endfunction

  // Fill level as each side sees it (through its stale copy of the other pointer)
  logic [ADDR_W:0] level_wr, level_rd;
  assign level_wr = wbin - gray2bin(rgray_wr);
  assign level_rd = gray2bin(wgray_rd) - rbin;

  // ---------------------------------------------------------------------------
  // Write domain
  // ---------------------------------------------------------------------------
  // The pointer that crosses domains changes at most one bit per cycle.
  a_wgray_one_bit: assert property (@(posedge wr_clk) disable iff (wr_rst)
      $onehot0(wgray ^ $past(wgray)))
    else $error("SVA a_wgray_one_bit: write Gray pointer changed more than one bit");

  a_wgray_is_gray_of_bin: assert property (@(posedge wr_clk) disable iff (wr_rst)
      wgray == (wbin ^ (wbin >> 1)))
    else $error("SVA a_wgray_is_gray_of_bin: Gray and binary write pointers disagree");

  a_write_advances: assert property (@(posedge wr_clk) disable iff (wr_rst)
      wr_en && !wr_full |=> wbin == $past(wbin) + 1'b1)
    else $error("SVA a_write_advances: accepted write did not advance the pointer");

  a_no_write_when_full: assert property (@(posedge wr_clk) disable iff (wr_rst)
      wr_full |=> wbin == $past(wbin))
    else $error("SVA a_no_write_when_full: write pointer moved while full (overflow)");

  a_idle_write_holds: assert property (@(posedge wr_clk) disable iff (wr_rst)
      !wr_en |=> wbin == $past(wbin))
    else $error("SVA a_idle_write_holds: write pointer moved without wr_en");

  // full is registered from the previous cycle's view of the read pointer.
  a_full_exact: assert property (@(posedge wr_clk) disable iff (wr_rst)
      wr_full == ((wbin - gray2bin($past(rgray_wr))) == DEPTH))
    else $error("SVA a_full_exact: wr_full does not match the write-side fill level");

  a_level_wr_in_range: assert property (@(posedge wr_clk) disable iff (wr_rst)
      level_wr <= DEPTH)
    else $error("SVA a_level_wr_in_range: write-side fill level exceeds depth");

  // ---------------------------------------------------------------------------
  // Read domain
  // ---------------------------------------------------------------------------
  a_rgray_one_bit: assert property (@(posedge rd_clk) disable iff (rd_rst)
      $onehot0(rgray ^ $past(rgray)))
    else $error("SVA a_rgray_one_bit: read Gray pointer changed more than one bit");

  a_rgray_is_gray_of_bin: assert property (@(posedge rd_clk) disable iff (rd_rst)
      rgray == (rbin ^ (rbin >> 1)))
    else $error("SVA a_rgray_is_gray_of_bin: Gray and binary read pointers disagree");

  a_read_advances: assert property (@(posedge rd_clk) disable iff (rd_rst)
      rd_en && !rd_empty |=> rbin == $past(rbin) + 1'b1)
    else $error("SVA a_read_advances: accepted read did not advance the pointer");

  a_no_read_when_empty: assert property (@(posedge rd_clk) disable iff (rd_rst)
      rd_empty |=> rbin == $past(rbin))
    else $error("SVA a_no_read_when_empty: read pointer moved while empty (underflow)");

  a_idle_read_holds: assert property (@(posedge rd_clk) disable iff (rd_rst)
      !rd_en |=> rbin == $past(rbin))
    else $error("SVA a_idle_read_holds: read pointer moved without rd_en");

  a_empty_exact: assert property (@(posedge rd_clk) disable iff (rd_rst)
      rd_empty == (rbin == gray2bin($past(wgray_rd))))
    else $error("SVA a_empty_exact: rd_empty does not match the read-side fill level");

  a_level_rd_in_range: assert property (@(posedge rd_clk) disable iff (rd_rst)
      level_rd <= DEPTH)
    else $error("SVA a_level_rd_in_range: read-side fill level exceeds depth");

  // ---------------------------------------------------------------------------
  // Cover
  // ---------------------------------------------------------------------------
  c_full:          cover property (@(posedge wr_clk) disable iff (wr_rst) wr_full);
  c_full_released: cover property (@(posedge wr_clk) disable iff (wr_rst) $fell(wr_full));
  c_wr_wrap:       cover property (@(posedge wr_clk) disable iff (wr_rst) $fell(wbin[ADDR_W]));
  c_empty_again:   cover property (@(posedge rd_clk) disable iff (rd_rst) $rose(rd_empty));
  c_rd_wrap:       cover property (@(posedge rd_clk) disable iff (rd_rst) $fell(rbin[ADDR_W]));

endmodule

bind async_fifo async_fifo_sva #(.ADDR_W(ADDR_W)) u_sva (
  .wr_clk   (wr_clk),
  .wr_rst   (wr_rst),
  .wr_en    (wr_en),
  .wr_full  (wr_full),
  .wbin     (wbin),
  .wgray    (wgray),
  .rgray_wr (rgray_wr),
  .rd_clk   (rd_clk),
  .rd_rst   (rd_rst),
  .rd_en    (rd_en),
  .rd_empty (rd_empty),
  .rbin     (rbin),
  .rgray    (rgray),
  .wgray_rd (wgray_rd)
);
