// -----------------------------------------------------------------------------
// mac_pe — one processing element of the systolic array
//
// Every enabled cycle it multiplies the two operands arriving from its west
// and north neighbours, adds the product to its accumulator, and passes the
// operands on (a to the east, b to the south) one cycle later.
// -----------------------------------------------------------------------------
module mac_pe #(
  parameter int DATA_W = 8,
  parameter int ACC_W  = 32
) (
  input  logic                     clk,
  input  logic                     rst,
  input  logic                     en,      // advance one step
  input  logic                     clr,     // clear accumulator and operand registers
  input  logic signed [DATA_W-1:0] a_in,    // from the west
  input  logic signed [DATA_W-1:0] b_in,    // from the north
  output logic signed [DATA_W-1:0] a_out,   // to the east
  output logic signed [DATA_W-1:0] b_out,   // to the south
  output logic signed [ACC_W-1:0]  acc
);

  logic signed [2*DATA_W-1:0] product;
  assign product = a_in * b_in;

  always_ff @(posedge clk) begin
    if (rst || clr) begin
      a_out <= '0;
      b_out <= '0;
      acc   <= '0;
    end else if (en) begin
      a_out <= a_in;
      b_out <= b_in;
      acc   <= acc + ACC_W'(product);
    end
  end

endmodule
