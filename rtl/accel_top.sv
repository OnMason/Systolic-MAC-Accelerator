// -----------------------------------------------------------------------------
// accel_top — systolic matrix-multiply accelerator with a clock-domain crossing
//             on each side
//
//        host_clk domain            |            core_clk domain
//                                   |
//   s_valid/s_ready/s_data ──► async_fifo ──► accel_core ──┐
//                                   |        (systolic     │
//   m_valid/m_ready/m_data ◄── async_fifo ◄── array) ◄─────┘
//                                   |
//
// The host streams N operand words per multiply and reads back N result rows.
// The two clocks may be completely unrelated.
// -----------------------------------------------------------------------------
module accel_top #(
  parameter int N           = 4,
  parameter int DATA_W      = 8,
  parameter int ACC_W       = 32,
  parameter int FIFO_ADDR_W = 3      // each FIFO holds 2**FIFO_ADDR_W words
) (
  // ---- host domain ----
  input  logic                    host_clk,
  input  logic                    host_rst,

  input  logic                    s_valid,   // operand word in
  output logic                    s_ready,
  input  logic [2*N*DATA_W-1:0]   s_data,

  output logic                    m_valid,   // result row out
  input  logic                    m_ready,
  output logic [N*8-1:0]          m_data,

  // ---- core domain ----
  input  logic                    core_clk,
  input  logic                    core_rst,
  input  logic [4:0]              cfg_shift, // quasi-static: change only when idle
  input  logic                    cfg_relu,
  output logic                    core_busy
);

  logic                  in_full, in_empty, in_pop;
  logic [2*N*DATA_W-1:0] in_data;
  logic                  out_full, out_empty, out_push;
  logic [N*8-1:0]        out_data;

  assign s_ready = !in_full;
  assign m_valid = !out_empty;

  async_fifo #(
    .WIDTH  (2*N*DATA_W),
    .ADDR_W (FIFO_ADDR_W)
  ) u_fifo_in (
    .wr_clk   (host_clk),
    .wr_rst   (host_rst),
    .wr_en    (s_valid),
    .wr_data  (s_data),
    .wr_full  (in_full),
    .rd_clk   (core_clk),
    .rd_rst   (core_rst),
    .rd_en    (in_pop),
    .rd_data  (in_data),
    .rd_empty (in_empty)
  );

  accel_core #(
    .N      (N),
    .DATA_W (DATA_W),
    .ACC_W  (ACC_W)
  ) u_core (
    .clk       (core_clk),
    .rst       (core_rst),
    .cfg_shift (cfg_shift),
    .cfg_relu  (cfg_relu),
    .in_empty  (in_empty),
    .in_data   (in_data),
    .in_pop    (in_pop),
    .out_full  (out_full),
    .out_data  (out_data),
    .out_push  (out_push),
    .busy      (core_busy)
  );

  async_fifo #(
    .WIDTH  (N*8),
    .ADDR_W (FIFO_ADDR_W)
  ) u_fifo_out (
    .wr_clk   (core_clk),
    .wr_rst   (core_rst),
    .wr_en    (out_push),
    .wr_data  (out_data),
    .wr_full  (out_full),
    .rd_clk   (host_clk),
    .rd_rst   (host_rst),
    .rd_en    (m_ready),
    .rd_data  (m_data),
    .rd_empty (out_empty)
  );

endmodule
