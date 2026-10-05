// -----------------------------------------------------------------------------
// tb_accel — self-checking testbench for the systolic accelerator (accel_top)
//
// Each test:
//   * picks a constrained-random pair of unrelated clocks (host / core) and a
//     random configuration (shift, ReLU, back-pressure on both host ports);
//   * streams 1-6 random matrix pairs in through the input CDC FIFO;
//   * checks every INT8 result row coming back through the output CDC FIFO
//     against a software matrix multiply + requantization;
//   * also checks the raw accumulators inside the array the moment a multiply
//     finishes, so a wrong sum cannot hide behind saturation.
//
// Parameters:  N (matrix size), FIFO_ADDR_W
// Plusargs:    +SEED=<n>  +NTESTS=<n>  +COV_ALL  +VERBOSE
// -----------------------------------------------------------------------------
module tb_accel;

  import tb_pkg::*;

  parameter int N           = 4;
  parameter int FIFO_ADDR_W = 3;
  localparam int DATA_W = 8;
  localparam int ACC_W  = 32;

  // accel_core state encoding
  localparam int ST_RUN = 0;
  localparam int ST_OUT = 1;

  // ---------------------------------------------------------------------------
  // Clocks
  // ---------------------------------------------------------------------------
  int unsigned host_hp = 5000, core_hp = 7000, core_phase = 1234;
  logic host_clk = 1'b0, core_clk = 1'b0;

  initial forever #(host_hp) host_clk = ~host_clk;
  initial begin
    #(core_phase);
    forever #(core_hp) core_clk = ~core_clk;
  end

  // ---------------------------------------------------------------------------
  // DUT
  // ---------------------------------------------------------------------------
  logic                  host_rst = 1'b1, core_rst = 1'b1;
  logic                  s_valid = 1'b0, s_ready;
  logic [2*N*DATA_W-1:0] s_data = '0;
  logic                  m_valid, m_ready = 1'b0;
  logic [N*8-1:0]        m_data;
  logic [4:0]            cfg_shift = '0;
  logic                  cfg_relu = 1'b0;
  logic                  core_busy;

  accel_top #(
    .N           (N),
    .DATA_W      (DATA_W),
    .ACC_W       (ACC_W),
    .FIFO_ADDR_W (FIFO_ADDR_W)
  ) dut (
    .host_clk  (host_clk),
    .host_rst  (host_rst),
    .s_valid   (s_valid),
    .s_ready   (s_ready),
    .s_data    (s_data),
    .m_valid   (m_valid),
    .m_ready   (m_ready),
    .m_data    (m_data),
    .core_clk  (core_clk),
    .core_rst  (core_rst),
    .cfg_shift (cfg_shift),
    .cfg_relu  (cfg_relu),
    .core_busy (core_busy)
  );

  // ---------------------------------------------------------------------------
  // Reference model
  // ---------------------------------------------------------------------------
  typedef int mat_t [N][N];

  function automatic bit signed [7:0] ref_requant(int acc, int unsigned shift, bit relu);
    longint r = acc;
    if (shift > 0) r = (r + (64'sd1 <<< (shift - 1))) >>> shift;   // round half up
    if (r > 127)  r = 127;
    if (r < -128) r = -128;
    if (relu && r < 0) r = 0;
    return r[7:0];
  endfunction

  function automatic int rand_elem(bit [1:0] mode);
    case (mode)
      2'd1: begin                                    // extremes
        case ($urandom_range(4))
          0: return -128;
          1: return 127;
          2: return -1;
          3: return 1;
          default: return 0;
        endcase
      end
      2'd2:    return int'($urandom_range(8)) - 4;   // small
      2'd3:    return ($urandom_range(3) == 0) ? int'($urandom_range(255)) - 128 : 0;   // sparse
      default: return int'($urandom_range(255)) - 128;
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // Scoreboard state
  // ---------------------------------------------------------------------------
  coverage     cov;
  int unsigned errors, tests_run, mults_total;
  bit          verbose;

  bit [N*8-1:0]       exp_rows [$];     // requantized rows, in output order
  bit [N*N*ACC_W-1:0] exp_raw  [$];     // raw accumulators, one entry per multiply
  int unsigned        rows_checked, rows_expected;
  int unsigned        out_stall_pct;
  bit                 monitoring;

  // ---- host side: result monitor, with random back-pressure ----
  always @(negedge host_clk) begin
    m_ready <= 1'b0;
    if (monitoring && !host_rst && ($urandom_range(99) >= out_stall_pct)) m_ready <= 1'b1;
  end

  always @(posedge host_clk) begin
    if (!host_rst && m_valid && m_ready) begin
      if (exp_rows.size() == 0) begin
        errors++;
        $display("  [MISMATCH] t=%0t unexpected result row %h", $time, m_data);
      end else begin
        automatic bit [N*8-1:0] e = exp_rows.pop_front();
        rows_checked++;
        if (m_data !== e) begin
          errors++;
          if (errors <= 10)
            $display("  [MISMATCH] t=%0t result row %0d: got %h, expected %h",
                     $time, (rows_checked - 1) % N, m_data, e);
        end
        for (int j = 0; j < N; j++) begin
          if ($signed(e[j*8 +: 8]) == 127)  cov.hit("out_saturated_high");
          if ($signed(e[j*8 +: 8]) == -128) cov.hit("out_saturated_low");
        end
      end
    end
    if (!host_rst && s_valid && !s_ready) cov.hit("input_fifo_full_backpressure");
    if (!host_rst && m_ready && !m_valid) cov.hit("host_waits_for_result");
  end

  // ---- core side: raw accumulator check at the end of each multiply ----
  logic core_was_run;
  always @(posedge core_clk) begin
    if (core_rst) begin
      core_was_run <= 1'b1;
    end else begin
      core_was_run <= (int'(dut.u_core.state) == ST_RUN);
      if (core_was_run && int'(dut.u_core.state) == ST_OUT) begin
        if (exp_raw.size() == 0) begin
          errors++;
          $display("  [MISMATCH] t=%0t multiply finished with nothing expected", $time);
        end else begin
          automatic bit [N*N*ACC_W-1:0] e = exp_raw.pop_front();
          if (dut.u_core.acc !== e) begin
            errors++;
            if (errors <= 10) begin
              $display("  [MISMATCH] t=%0t raw accumulators differ from A*B", $time);
              for (int i = 0; i < N; i++) for (int j = 0; j < N; j++)
                if (dut.u_core.acc[(i*N+j)*ACC_W +: ACC_W] !== e[(i*N+j)*ACC_W +: ACC_W])
                  $display("      C[%0d][%0d] got %0d, expected %0d", i, j,
                           $signed(dut.u_core.acc[(i*N+j)*ACC_W +: ACC_W]),
                           $signed(e[(i*N+j)*ACC_W +: ACC_W]));
            end
          end
        end
      end
      // coverage of the two stall cases and of back-to-back multiplies
      if (int'(dut.u_core.state) == ST_RUN && dut.u_core.need_word &&
          dut.u_core.step != 0 && dut.in_empty)
        cov.hit("core_waits_for_operand_mid_load");
      if (int'(dut.u_core.state) == ST_OUT && dut.out_full)
        cov.hit("core_waits_for_output_room");
      if (dut.u_core.in_pop && dut.u_core.step == 0 && !core_was_run)
        cov.hit("back_to_back_multiplies");
    end
  end

  // ---------------------------------------------------------------------------
  // Host driver
  // ---------------------------------------------------------------------------
  // Give up cleanly if the design stops accepting or producing data
  task automatic abort(string why);
    errors++;
    $display("  [MISMATCH] t=%0t %s", $time, why);
    $display(" RESULT: FAIL  (%0d mismatches, run aborted)", errors);
    $finish;
  endtask

  task automatic send_word(bit [2*N*DATA_W-1:0] word, int unsigned gap_pct);
    int unsigned guard = 0;
    while ($urandom_range(99) < gap_pct) @(negedge host_clk);
    s_valid = 1'b1;
    s_data  = word;
    // s_ready is registered, so its value now is what the next rising edge sees
    while (!s_ready) begin
      @(negedge host_clk);
      if (++guard > 100000) abort("input side stuck: s_ready never rose");
    end
    @(negedge host_clk);
    s_valid = 1'b0;
  endtask

  task automatic send_multiply(accel_cfg cfg);
    mat_t                   a, b, c;
    bit [N*N*ACC_W-1:0]     raw;
    bit [N*8-1:0]           rowbits;
    bit [2*N*DATA_W-1:0]    word;

    for (int i = 0; i < N; i++) for (int j = 0; j < N; j++) begin
      a[i][j] = rand_elem(cfg.data_mode);
      b[i][j] = rand_elem(cfg.data_mode);
    end

    // software C = A * B, then requantize
    for (int i = 0; i < N; i++) begin
      for (int j = 0; j < N; j++) begin
        c[i][j] = 0;
        for (int k = 0; k < N; k++) c[i][j] += a[i][k] * b[k][j];
        raw[(i*N+j)*ACC_W +: ACC_W] = c[i][j];
        rowbits[j*8 +: 8] = ref_requant(c[i][j], cfg.shift, cfg.relu);
        if (cfg.relu && c[i][j] < 0) cov.hit("relu_clamped_negative");
      end
      exp_rows.push_back(rowbits);
    end
    exp_raw.push_back(raw);
    rows_expected += N;

    // word k = { row k of B , column k of A }
    for (int k = 0; k < N; k++) begin
      for (int i = 0; i < N; i++) word[i*DATA_W +: DATA_W]            = a[i][k][7:0];
      for (int j = 0; j < N; j++) word[N*DATA_W + j*DATA_W +: DATA_W] = b[k][j][7:0];
      send_word(word, cfg.in_gap_pct);
    end
  endtask

  task automatic apply_reset();
    monitoring = 1'b0;
    host_rst   = 1'b1;
    core_rst   = 1'b1;
    s_valid    = 1'b0;
    repeat (4) @(negedge host_clk);
    repeat (4) @(negedge core_clk);
    exp_rows.delete();
    exp_raw.delete();
    rows_checked  = 0;
    rows_expected = 0;
    @(negedge core_clk) core_rst = 1'b0;
    @(negedge host_clk) host_rst = 1'b0;
    repeat (3) @(negedge core_clk);
    repeat (3) @(negedge host_clk);
  endtask

  task automatic run_test(int unsigned t, ratio_e ratio, clock_cfg ck, accel_cfg cfg);
    int unsigned err_before = errors;
    int unsigned guard;

    host_hp    = ck.a_hp;
    core_hp    = ck.b_hp;
    core_phase = ck.b_phase;
    apply_reset();

    // configuration is applied while the core is idle
    @(negedge core_clk);
    cfg_shift     = cfg.shift;
    cfg_relu      = cfg.relu;
    out_stall_pct = cfg.out_stall_pct;
    monitoring    = 1'b1;
    @(negedge host_clk);

    for (int m = 0; m < int'(cfg.n_mults); m++) send_multiply(cfg);
    mults_total += cfg.n_mults;

    // wait for every result row
    guard = 0;
    while (rows_checked < rows_expected && guard < 200000) begin
      @(negedge host_clk);
      guard++;
    end
    repeat (8) @(negedge host_clk);
    repeat (8) @(negedge core_clk);

    if (rows_checked != rows_expected) begin
      errors++;
      $display("  [MISMATCH] received %0d of %0d result rows", rows_checked, rows_expected);
    end
    if (core_busy || m_valid || exp_raw.size() != 0) begin
      errors++;
      $display("  [MISMATCH] not idle at end of test: busy=%0b m_valid=%0b pending=%0d",
               core_busy, m_valid, exp_raw.size());
    end

    case (ratio)
      RATIO_WR_FAST: cov.hit("ratio_host_fast");
      RATIO_RD_FAST: cov.hit("ratio_core_fast");
      RATIO_NEAR:    cov.hit("ratio_near_equal");
      default:       cov.hit("ratio_any");
    endcase
    cov.hit($sformatf("data_mode_%0d", cfg.data_mode));
    cov.hit(cfg.shift == 0 ? "shift_zero" : "shift_nonzero");
    cov.hit(cfg.relu ? "relu_on" : "relu_off");
    if (cfg.n_mults > 1) cov.hit("several_multiplies_queued");

    tests_run++;
    if (verbose || errors != err_before)
      $display("[%s] test %0d  host %0d ps  core %0d ps  shift %0d relu %0b  %0d multiplies",
               errors == err_before ? "PASS" : "FAIL", t, 2 * host_hp, 2 * core_hp,
               cfg.shift, cfg.relu, cfg.n_mults);
  endtask

  // ---------------------------------------------------------------------------
  // Directed case with a hand-computed answer (N >= 2):
  //   A = identity scaled by 3, B[i][j] = i - j   =>   C[i][j] = 3 * (i - j)
  // ---------------------------------------------------------------------------
  task automatic run_directed();
    bit [2*N*DATA_W-1:0] word;
    bit [N*N*ACC_W-1:0]  raw;
    bit [N*8-1:0]        rowbits;
    int unsigned         err_before = errors;
    int unsigned         guard;
    int                  v;

    apply_reset();
    @(negedge core_clk);
    cfg_shift     = 5'd0;
    cfg_relu      = 1'b0;
    out_stall_pct = 0;
    monitoring    = 1'b1;
    @(negedge host_clk);

    // expected values written out directly, not through the reference model
    for (int i = 0; i < N; i++) begin
      for (int j = 0; j < N; j++) begin
        v = 3 * (i - j);
        raw[(i*N+j)*ACC_W +: ACC_W] = v;
        rowbits[j*8 +: 8]           = v[7:0];
      end
      exp_rows.push_back(rowbits);
    end
    exp_raw.push_back(raw);
    rows_expected = N;

    for (int k = 0; k < N; k++) begin
      word = '0;
      word[k*DATA_W +: DATA_W] = 8'd3;                                  // A[k][k] = 3
      for (int j = 0; j < N; j++) begin
        v = k - j;
        word[N*DATA_W + j*DATA_W +: DATA_W] = v[7:0];                   // B[k][j] = k - j
      end
      send_word(word, 0);
    end

    guard = 0;
    while (rows_checked < rows_expected && guard < 20000) begin
      @(negedge host_clk);
      guard++;
    end
    if (rows_checked != rows_expected) begin
      errors++;
      $display("  [MISMATCH] directed: received %0d of %0d rows", rows_checked, rows_expected);
    end
    $display("[%s] directed  C = 3I * (i - j)", errors == err_before ? "PASS" : "FAIL");
  endtask

  // ---------------------------------------------------------------------------
  // Main
  // ---------------------------------------------------------------------------
  initial begin
    clock_cfg    ck;
    accel_cfg    cfg;
    ratio_e      ratio;
    int unsigned seed, ntests;

    if (!$value$plusargs("SEED=%d", seed))     seed   = 1;
    if (!$value$plusargs("NTESTS=%d", ntests)) ntests = 60;
    verbose = $test$plusargs("VERBOSE");
    void'($urandom(seed));

    cov = new();
    cov.define_bin("ratio_host_fast");
    cov.define_bin("ratio_core_fast");
    cov.define_bin("ratio_near_equal");
    cov.define_bin("ratio_any");
    for (int m = 0; m < 4; m++) cov.define_bin($sformatf("data_mode_%0d", m));
    cov.define_bin("shift_zero");
    cov.define_bin("shift_nonzero");
    cov.define_bin("relu_on");
    cov.define_bin("relu_off");
    cov.define_bin("relu_clamped_negative");
    cov.define_bin("out_saturated_high");
    cov.define_bin("out_saturated_low");
    cov.define_bin("several_multiplies_queued");
    cov.define_bin("back_to_back_multiplies");
    cov.define_bin("input_fifo_full_backpressure");
    cov.define_bin("host_waits_for_result");
    cov.define_bin("core_waits_for_operand_mid_load");
    cov.define_bin("core_waits_for_output_room");

    $display("=====================================================================");
    $display(" systolic accelerator testbench   N=%0d  FIFO depth=%0d  seed=%0d  tests=%0d",
             N, 1 << FIFO_ADDR_W, seed, ntests);
    $display("=====================================================================");

    run_directed();

    ck  = new();
    cfg = new();
    ck.srandom(seed);
    cfg.srandom(seed + 32'h1000_0000);
    for (int unsigned t = 0; t < ntests; t++) begin
      case (t % 4)
        0:       ratio = RATIO_WR_FAST;
        1:       ratio = RATIO_RD_FAST;
        2:       ratio = RATIO_NEAR;
        default: ratio = RATIO_ANY;
      endcase
      ck.ratio = ratio;
      if (!ck.randomize())  $fatal(1, "randomize(clock_cfg) failed");
      if (!cfg.randomize()) $fatal(1, "randomize(accel_cfg) failed");
      run_test(t, ratio, ck, cfg);
    end

    $display("=====================================================================");
    cov.report($test$plusargs("COV_ALL"));
    $display(" tests: %0d    matrix multiplies: %0d", tests_run, mults_total);
    if (errors == 0) $display(" RESULT: PASS");
    else             $display(" RESULT: FAIL  (%0d mismatches)", errors);
    $display("=====================================================================");
    $finish;
  end

endmodule
