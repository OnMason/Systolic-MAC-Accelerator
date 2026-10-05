// -----------------------------------------------------------------------------
// systolic_array — N x N output-stationary systolic array computing C = A * B
//
// Operands are streamed in N steps. At step k the array is given
//
//     a_col = column k of A   (a_col[i] = A[i][k])
//     b_row = row    k of B   (b_row[j] = B[k][j])
//
// A values travel east along rows, B values travel south along columns, one
// PE per step. For A[i][k] and B[k][j] to arrive at PE(i,j) on the same step,
// row i's input is delayed by i steps and column j's input by j steps (the
// "skew" registers below). They then meet at step k + i + j, so the last
// product lands at step 3N-3 and a full multiply takes 3N-2 steps, with zeros
// fed in after the N data steps.
//
// PE(i,j) accumulates sum_k A[i][k] * B[k][j] = C[i][j].
// -----------------------------------------------------------------------------
module systolic_array #(
  parameter int N      = 4,
  parameter int DATA_W = 8,
  parameter int ACC_W  = 32
) (
  input  logic                      clk,
  input  logic                      rst,
  input  logic                      en,      // advance one step
  input  logic                      clr,     // clear everything for the next multiply
  input  logic [N*DATA_W-1:0]       a_col,   // element i at [i*DATA_W +: DATA_W]
  input  logic [N*DATA_W-1:0]       b_row,   // element j at [j*DATA_W +: DATA_W]
  output logic [N*N*ACC_W-1:0]      acc      // C[i][j] at [(i*N+j)*ACC_W +: ACC_W]
);

  // Operands at the west edge of each row / north edge of each column, after skew
  logic signed [DATA_W-1:0] a_edge [N];
  logic signed [DATA_W-1:0] b_edge [N];

  // ---------------------------------------------------------------------------
  // Input skew: row i and column i are delayed by i steps
  // ---------------------------------------------------------------------------
  for (genvar i = 0; i < N; i++) begin : g_skew
    if (i == 0) begin : g_none
      assign a_edge[i] = a_col[i*DATA_W +: DATA_W];
      assign b_edge[i] = b_row[i*DATA_W +: DATA_W];
    end else begin : g_delay
      logic signed [DATA_W-1:0] a_sr [i];
      logic signed [DATA_W-1:0] b_sr [i];

      always_ff @(posedge clk) begin
        if (rst || clr) begin
          for (int s = 0; s < i; s++) begin
            a_sr[s] <= '0;
            b_sr[s] <= '0;
          end
        end else if (en) begin
          a_sr[0] <= a_col[i*DATA_W +: DATA_W];
          b_sr[0] <= b_row[i*DATA_W +: DATA_W];
          for (int s = 1; s < i; s++) begin
            a_sr[s] <= a_sr[s-1];
            b_sr[s] <= b_sr[s-1];
          end
        end
      end

      assign a_edge[i] = a_sr[i-1];
      assign b_edge[i] = b_sr[i-1];
    end
  end

  // ---------------------------------------------------------------------------
  // PE grid. a_h[i][j] enters PE(i,j) from the west; b_v[i][j] from the north.
  // ---------------------------------------------------------------------------
  logic signed [DATA_W-1:0] a_h [N][N+1];
  logic signed [DATA_W-1:0] b_v [N+1][N];

  for (genvar i = 0; i < N; i++) begin : g_edge
    assign a_h[i][0] = a_edge[i];
    assign b_v[0][i] = b_edge[i];
  end

  for (genvar i = 0; i < N; i++) begin : g_row
    for (genvar j = 0; j < N; j++) begin : g_col
      logic signed [ACC_W-1:0] pe_acc;

      mac_pe #(
        .DATA_W (DATA_W),
        .ACC_W  (ACC_W)
      ) u_pe (
        .clk   (clk),
        .rst   (rst),
        .en    (en),
        .clr   (clr),
        .a_in  (a_h[i][j]),
        .b_in  (b_v[i][j]),
        .a_out (a_h[i][j+1]),
        .b_out (b_v[i+1][j]),
        .acc   (pe_acc)
      );

      assign acc[(i*N+j)*ACC_W +: ACC_W] = pe_acc;
    end
  end

endmodule
