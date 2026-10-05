// -----------------------------------------------------------------------------
// async_fifo — dual-clock FIFO for clock-domain crossing
//
//   * Depth = 2**ADDR_W entries. Pointers are ADDR_W+1 bits so that full and
//     empty can be told apart.
//   * Each pointer is kept in binary (to address the memory) and in Gray code
//     (to cross domains). Gray code changes one bit per increment, so a
//     pointer sampled mid-change resolves to either the old or the new value,
//     never to something unrelated.
//   * full is computed in the write domain from a synchronized copy of the
//     read pointer; empty in the read domain from a synchronized copy of the
//     write pointer. A synchronized pointer is always a little stale, which
//     makes both flags conservative: full may stay high a few cycles after a
//     read, empty a few cycles after a write, but neither is ever missed.
//   * First-word fall-through: rd_data is valid whenever rd_empty is low.
//
// Both resets are synchronous to their own clock and must be asserted
// together (and held for a few cycles of the slower clock).
// -----------------------------------------------------------------------------
module async_fifo #(
  parameter int WIDTH  = 8,
  parameter int ADDR_W = 4      // >= 2
) (
  // write domain
  input  logic             wr_clk,
  input  logic             wr_rst,
  input  logic             wr_en,     // ignored while wr_full
  input  logic [WIDTH-1:0] wr_data,
  output logic             wr_full,

  // read domain
  input  logic             rd_clk,
  input  logic             rd_rst,
  input  logic             rd_en,     // ignored while rd_empty
  output logic [WIDTH-1:0] rd_data,
  output logic             rd_empty
);

  localparam int DEPTH = 1 << ADDR_W;

  logic [WIDTH-1:0] mem [0:DEPTH-1];

  // ---------------------------------------------------------------------------
  // Write domain
  // ---------------------------------------------------------------------------
  logic [ADDR_W:0] wbin, wbin_next, wgray, wgray_next;
  logic [ADDR_W:0] rgray_wr;            // read pointer, synchronized into wr_clk
  logic            do_write;

  assign do_write   = wr_en && !wr_full;
  assign wbin_next  = wbin + {{ADDR_W{1'b0}}, do_write};
  assign wgray_next = (wbin_next >> 1) ^ wbin_next;

  always_ff @(posedge wr_clk) begin
    if (wr_rst) begin
      wbin    <= '0;
      wgray   <= '0;
      wr_full <= 1'b0;
    end else begin
      wbin    <= wbin_next;
      wgray   <= wgray_next;
      // Full when the write pointer is exactly one lap ahead of the read
      // pointer: in Gray code, the top two bits differ and the rest match.
      wr_full <= (wgray_next == {~rgray_wr[ADDR_W:ADDR_W-1], rgray_wr[ADDR_W-2:0]});
    end
  end

  always_ff @(posedge wr_clk) begin
    if (do_write) mem[wbin[ADDR_W-1:0]] <= wr_data;
  end

  // ---------------------------------------------------------------------------
  // Read domain
  // ---------------------------------------------------------------------------
  logic [ADDR_W:0] rbin, rbin_next, rgray, rgray_next;
  logic [ADDR_W:0] wgray_rd;            // write pointer, synchronized into rd_clk
  logic            do_read;

  assign do_read    = rd_en && !rd_empty;
  assign rbin_next  = rbin + {{ADDR_W{1'b0}}, do_read};
  assign rgray_next = (rbin_next >> 1) ^ rbin_next;

  always_ff @(posedge rd_clk) begin
    if (rd_rst) begin
      rbin     <= '0;
      rgray    <= '0;
      rd_empty <= 1'b1;
    end else begin
      rbin     <= rbin_next;
      rgray    <= rgray_next;
      // Empty when the read pointer has caught up with the write pointer.
      rd_empty <= (rgray_next == wgray_rd);
    end
  end

  assign rd_data = mem[rbin[ADDR_W-1:0]];

  // ---------------------------------------------------------------------------
  // Pointer synchronizers
  // ---------------------------------------------------------------------------
  sync_2ff #(.WIDTH(ADDR_W + 1)) u_sync_r2w (
    .clk (wr_clk),
    .rst (wr_rst),
    .d   (rgray),
    .q   (rgray_wr)
  );

  sync_2ff #(.WIDTH(ADDR_W + 1)) u_sync_w2r (
    .clk (rd_clk),
    .rst (rd_rst),
    .d   (wgray),
    .q   (wgray_rd)
  );

endmodule
