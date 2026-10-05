// -----------------------------------------------------------------------------
// accel_core — sequencer around the systolic array (single clock domain)
//
// One matrix multiply:
//
//   RUN   3N-2 steps. The first N steps each pop one operand word from the
//         input FIFO (and simply wait if it is empty — the whole array is
//         clock-enabled, so a late word just pauses the computation). The
//         remaining 2N-2 steps feed zeros while the products finish arriving.
//   OUT   N cycles. Each pushes one requantized row of C into the output FIFO
//         (waiting if it is full). The last push clears the array.
//
// Input word  (2*N*DATA_W bits):  { B[k][N-1:0] , A[N-1:0][k] }   for k = 0..N-1
// Output word (N*8 bits):         C[r][N-1:0] as INT8             for r = 0..N-1
//
// cfg_shift / cfg_relu must be stable while a multiply is in flight.
// -----------------------------------------------------------------------------
module accel_core #(
  parameter int N      = 4,
  parameter int DATA_W = 8,
  parameter int ACC_W  = 32
) (
  input  logic                    clk,
  input  logic                    rst,

  input  logic [4:0]              cfg_shift,
  input  logic                    cfg_relu,

  // input FIFO, read side
  input  logic                    in_empty,
  input  logic [2*N*DATA_W-1:0]   in_data,
  output logic                    in_pop,

  // output FIFO, write side
  input  logic                    out_full,
  output logic [N*8-1:0]          out_data,
  output logic                    out_push,

  output logic                    busy      // a multiply has started and is not yet fully written out
);

  localparam int LAST_STEP = 3*N - 3;
  localparam int STEP_W    = $clog2(3*N - 1);
  localparam int ROW_W     = (N > 1) ? $clog2(N) : 1;

  typedef enum logic { S_RUN, S_OUT } state_e;
  state_e             state;
  logic [STEP_W-1:0]  step;
  logic [ROW_W-1:0]   row;

  // ---------------------------------------------------------------------------
  // RUN: feed the array
  // ---------------------------------------------------------------------------
  logic                   need_word;   // this step consumes an operand word
  logic                   advance;
  logic [N*DATA_W-1:0]    a_col, b_row;
  logic                   arr_clr;
  logic [N*N*ACC_W-1:0]   acc;

  assign need_word = (state == S_RUN) && (int'(step) < N);
  assign advance   = (state == S_RUN) && (!need_word || !in_empty);
  assign in_pop    = need_word && !in_empty;

  assign a_col = need_word ? in_data[0 +: N*DATA_W]        : '0;
  assign b_row = need_word ? in_data[N*DATA_W +: N*DATA_W] : '0;

  systolic_array #(
    .N      (N),
    .DATA_W (DATA_W),
    .ACC_W  (ACC_W)
  ) u_array (
    .clk   (clk),
    .rst   (rst),
    .en    (advance),
    .clr   (arr_clr),
    .a_col (a_col),
    .b_row (b_row),
    .acc   (acc)
  );

  // ---------------------------------------------------------------------------
  // OUT: requantize one row per cycle
  // ---------------------------------------------------------------------------
  logic last_row;
  assign last_row = (int'(row) == N - 1);
  assign out_push = (state == S_OUT) && !out_full;
  assign arr_clr  = out_push && last_row;

  // The row being written out
  logic [N*ACC_W-1:0] acc_row;
  assign acc_row = acc[int'(row)*N*ACC_W +: N*ACC_W];

  for (genvar j = 0; j < N; j++) begin : g_requant
    logic signed [7:0] q;

    requant #(.ACC_W(ACC_W)) u_requant (
      .acc   (acc_row[j*ACC_W +: ACC_W]),
      .shift (cfg_shift),
      .relu  (cfg_relu),
      .y     (q)
    );

    assign out_data[j*8 +: 8] = q;
  end

  // ---------------------------------------------------------------------------
  // Sequencer
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (rst) begin
      state <= S_RUN;
      step  <= '0;
      row   <= '0;
    end else begin
      unique case (state)
        S_RUN: begin
          if (advance) begin
            if (int'(step) == LAST_STEP) begin
              state <= S_OUT;
              row   <= '0;
            end else begin
              step <= step + 1'b1;
            end
          end
        end

        S_OUT: begin
          if (out_push) begin
            if (last_row) begin
              state <= S_RUN;
              step  <= '0;
            end else begin
              row <= row + 1'b1;
            end
          end
        end

        default: state <= S_RUN;
      endcase
    end
  end

  assign busy = (state == S_OUT) || (step != '0);

endmodule
