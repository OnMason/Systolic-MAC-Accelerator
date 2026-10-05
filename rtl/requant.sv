// -----------------------------------------------------------------------------
// requant — scale a wide accumulator back to INT8 for a quantized layer output
//
//   y = saturate_int8( round( acc / 2**shift ) ),  then optional ReLU
//
// Rounding is round-half-up (add half an LSB, then arithmetic shift), the usual
// choice for fixed-point inference. Purely combinational.
// -----------------------------------------------------------------------------
module requant #(
  parameter int ACC_W = 32
) (
  input  logic signed [ACC_W-1:0] acc,
  input  logic [4:0]              shift,   // right shift, 0..31
  input  logic                    relu,    // clamp negatives to 0
  output logic signed [7:0]       y
);

  logic signed [ACC_W:0] half;      // half an output LSB, before the shift
  logic signed [ACC_W:0] rounded;   // one guard bit: the rounding add cannot overflow
  logic signed [ACC_W:0] shifted;

  always_comb begin
    half    = (shift == 5'd0) ? '0 : ((ACC_W+1)'(1) << (shift - 5'd1));
    rounded = {acc[ACC_W-1], acc} + half;
    shifted = rounded >>> shift;

    if (shifted > 127)       y = 8'sd127;
    else if (shifted < -128) y = -8'sd128;
    else                     y = shifted[7:0];

    if (relu && y[7]) y = 8'sd0;
  end

endmodule
