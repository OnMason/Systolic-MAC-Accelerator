// -----------------------------------------------------------------------------
// sync_2ff — two-flop synchronizer for a multi-bit Gray-coded value
//
// Only safe for signals where at most one bit changes per source-clock cycle
// (Gray pointers) or for single-bit levels. ASYNC_REG keeps the two flops
// adjacent in Vivado and excludes them from retiming.
// -----------------------------------------------------------------------------
module sync_2ff #(
  parameter int WIDTH = 1
) (
  input  logic             clk,
  input  logic             rst,
  input  logic [WIDTH-1:0] d,
  output logic [WIDTH-1:0] q
);

  (* ASYNC_REG = "TRUE" *) logic [WIDTH-1:0] meta;
  (* ASYNC_REG = "TRUE" *) logic [WIDTH-1:0] sync;

  always_ff @(posedge clk) begin
    if (rst) begin
      meta <= '0;
      sync <= '0;
    end else begin
      meta <= d;
      sync <= meta;
    end
  end

  assign q = sync;

endmodule
