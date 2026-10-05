// -----------------------------------------------------------------------------
// accel_core_sva — assertions for the accelerator sequencer, bound into accel_core
// -----------------------------------------------------------------------------
module accel_core_sva #(
  parameter int N      = 4,
  parameter int ACC_W  = 32,
  parameter int STEP_W = 4
) (
  input logic                   clk,
  input logic                   rst,
  input logic                   in_run,      // state == S_RUN
  input logic [STEP_W-1:0]      step,
  input logic [31:0]            row,
  input logic                   advance,
  input logic                   in_empty,
  input logic                   in_pop,
  input logic                   out_full,
  input logic                   out_push,
  input logic                   arr_clr,
  input logic [N*N*ACC_W-1:0]   acc,
  input logic                   busy,
  input logic [4:0]             cfg_shift,
  input logic                   cfg_relu
);

  localparam int LAST_STEP = 3*N - 3;

  // Words popped / rows pushed since the last clear
  int unsigned pops, pushes;
  always_ff @(posedge clk) begin
    if (rst || arr_clr) begin
      pops   <= 0;
      pushes <= 0;
    end else begin
      if (in_pop)   pops   <= pops + 1;
      if (out_push) pushes <= pushes + 1;
    end
  end

  // ---- FIFO handshakes ----
  a_pop_only_when_data: assert property (@(posedge clk) disable iff (rst)
      in_pop |-> !in_empty)
    else $error("SVA a_pop_only_when_data: popped an empty input FIFO");

  a_push_only_when_room: assert property (@(posedge clk) disable iff (rst)
      out_push |-> !out_full)
    else $error("SVA a_push_only_when_room: pushed a full output FIFO");

  // ---- sequencing ----
  a_step_in_range: assert property (@(posedge clk) disable iff (rst)
      int'(step) <= LAST_STEP)
    else $error("SVA a_step_in_range: step counter ran past the last step");

  a_row_in_range: assert property (@(posedge clk) disable iff (rst)
      int'(row) < N)
    else $error("SVA a_row_in_range: output row index out of range");

  a_pop_only_in_load_steps: assert property (@(posedge clk) disable iff (rst)
      in_pop |-> in_run && int'(step) < N)
    else $error("SVA a_pop_only_in_load_steps: popped outside the N load steps");

  a_push_only_in_out: assert property (@(posedge clk) disable iff (rst)
      out_push |-> !in_run)
    else $error("SVA a_push_only_in_out: pushed a result while still computing");

  a_advance_only_in_run: assert property (@(posedge clk) disable iff (rst)
      advance |-> in_run)
    else $error("SVA a_advance_only_in_run: array stepped during output");

  // A load step never advances without an operand word.
  a_load_step_needs_word: assert property (@(posedge clk) disable iff (rst)
      advance && int'(step) < N |-> in_pop)
    else $error("SVA a_load_step_needs_word: load step advanced without data");

  a_out_follows_last_step: assert property (@(posedge clk) disable iff (rst)
      $fell(in_run) |-> $past(advance) && int'($past(step)) == LAST_STEP)
    else $error("SVA a_out_follows_last_step: entered output before the last step");

  // Exactly N words in and N rows out per multiply.
  a_n_words_per_multiply: assert property (@(posedge clk) disable iff (rst)
      !in_run |-> pops == N)
    else $error("SVA a_n_words_per_multiply: wrong number of operand words consumed");

  a_n_rows_per_multiply: assert property (@(posedge clk) disable iff (rst)
      arr_clr |-> pushes == N - 1)
    else $error("SVA a_n_rows_per_multiply: wrong number of result rows produced");

  a_clear_only_on_last_row: assert property (@(posedge clk) disable iff (rst)
      arr_clr |-> out_push && int'(row) == N - 1)
    else $error("SVA a_clear_only_on_last_row: array cleared before all rows were written");

  // ---- array state ----
  a_clear_zeroes_acc: assert property (@(posedge clk) disable iff (rst)
      arr_clr |=> acc == '0)
    else $error("SVA a_clear_zeroes_acc: accumulators not zero after clear");

  a_acc_holds_when_paused: assert property (@(posedge clk) disable iff (rst)
      !advance && !arr_clr |=> acc == $past(acc))
    else $error("SVA a_acc_holds_when_paused: accumulators changed while paused");

  a_idle_means_clean: assert property (@(posedge clk) disable iff (rst)
      !busy |-> acc == '0)
    else $error("SVA a_idle_means_clean: accumulators non-zero while idle");

  // ---- environment assumption ----
  a_cfg_stable_while_busy: assert property (@(posedge clk) disable iff (rst)
      busy && $past(busy) |-> cfg_shift == $past(cfg_shift) && cfg_relu == $past(cfg_relu))
    else $error("SVA a_cfg_stable_while_busy: configuration changed mid-multiply");

  // ---- cover ----
  c_wait_for_input:  cover property (@(posedge clk) disable iff (rst)
      in_run && int'(step) < N && int'(step) > 0 && in_empty);
  c_wait_for_output: cover property (@(posedge clk) disable iff (rst) !in_run && out_full);
  c_back_to_back:    cover property (@(posedge clk) disable iff (rst) arr_clr ##1 in_pop);

endmodule

bind accel_core accel_core_sva #(.N(N), .ACC_W(ACC_W), .STEP_W(STEP_W)) u_sva (
  .clk       (clk),
  .rst       (rst),
  .in_run    (state == S_RUN),
  .step      (step),
  .row       (32'(row)),
  .advance   (advance),
  .in_empty  (in_empty),
  .in_pop    (in_pop),
  .out_full  (out_full),
  .out_push  (out_push),
  .arr_clr   (arr_clr),
  .acc       (acc),
  .busy      (busy),
  .cfg_shift (cfg_shift),
  .cfg_relu  (cfg_relu)
);
