// -----------------------------------------------------------------------------
// tb_async_fifo — self-checking testbench for the dual-clock FIFO
//
// Each test picks a constrained-random pair of unrelated clocks, then runs
// three phases:
//
//   1. fill   reader idle, writer pushes until full: exactly DEPTH words must
//             be accepted — no more (overflow) and no fewer (false full).
//   2. drain  writer idle, reader pops until empty: every word must come back,
//             in order.
//   3. mix    both sides run with random duty cycles.
//
// The scoreboard is a queue: a word is appended when the write is accepted and
// compared when it is read. True occupancy (writes - reads) is checked against
// DEPTH throughout.
//
// Plusargs:  +SEED=<n>  +NTESTS=<n>  +COV_ALL
// -----------------------------------------------------------------------------
module tb_async_fifo;

  import tb_pkg::*;

  parameter int WIDTH  = 16;
  parameter int ADDR_W = 3;
  localparam int DEPTH = 1 << ADDR_W;

  // ---------------------------------------------------------------------------
  // Clocks (half-periods are variables so each test can change them)
  // ---------------------------------------------------------------------------
  int unsigned wr_hp = 5000, rd_hp = 7000, rd_phase = 1234;
  logic wr_clk = 1'b0, rd_clk = 1'b0;

  initial forever #(wr_hp) wr_clk = ~wr_clk;
  initial begin
    #(rd_phase);
    forever #(rd_hp) rd_clk = ~rd_clk;
  end

  // ---------------------------------------------------------------------------
  // DUT
  // ---------------------------------------------------------------------------
  logic             wr_rst = 1'b1, rd_rst = 1'b1;
  logic             wr_en = 1'b0, rd_en = 1'b0;
  logic [WIDTH-1:0] wr_data = '0, rd_data;
  logic             wr_full, rd_empty;

  async_fifo #(
    .WIDTH  (WIDTH),
    .ADDR_W (ADDR_W)
  ) dut (
    .wr_clk   (wr_clk),
    .wr_rst   (wr_rst),
    .wr_en    (wr_en),
    .wr_data  (wr_data),
    .wr_full  (wr_full),
    .rd_clk   (rd_clk),
    .rd_rst   (rd_rst),
    .rd_en    (rd_en),
    .rd_data  (rd_data),
    .rd_empty (rd_empty)
  );

  // ---------------------------------------------------------------------------
  // Stimulus + scoreboard
  //
  // Both sides are driven on the falling edge of their own clock. Flags are
  // registered, so the value seen at the falling edge is the value the next
  // rising edge will act on.
  // ---------------------------------------------------------------------------
  coverage          cov;
  logic [WIDTH-1:0] expected [$];
  int unsigned      errors, n_written, n_read;
  int unsigned      wr_pct, rd_pct;       // % of cycles each side is active
  bit               running;
  ratio_e           cur_ratio;

  always @(negedge wr_clk) begin
    wr_en <= 1'b0;
    if (running && !wr_rst && ($urandom_range(99) < wr_pct)) begin
      wr_en   <= 1'b1;
      wr_data <= $urandom();
      if (wr_full) cov.hit("write_attempt_while_full");
    end
  end

  // An accepted write is committed on the rising edge.
  always @(posedge wr_clk) begin
    if (!wr_rst && wr_en && !wr_full) begin
      expected.push_back(wr_data);
      n_written++;
    end
    if (!wr_rst && wr_full) cov.hit("full");
  end

  always @(negedge rd_clk) begin
    rd_en <= 1'b0;
    if (running && !rd_rst && ($urandom_range(99) < rd_pct)) begin
      rd_en <= 1'b1;
      if (rd_empty) cov.hit("read_attempt_while_empty");
    end
  end

  always @(posedge rd_clk) begin
    if (!rd_rst && rd_en && !rd_empty) begin
      n_read++;
      if (expected.size() == 0) begin
        errors++;
        $display("  [MISMATCH] t=%0t read %h but the FIFO should be empty", $time, rd_data);
      end else begin
        automatic logic [WIDTH-1:0] e = expected.pop_front();
        if (rd_data !== e) begin
          errors++;
          if (errors <= 10)
            $display("  [MISMATCH] t=%0t read %h, expected %h", $time, rd_data, e);
        end
      end
    end
    if (!rd_rst && rd_empty && n_read > 0) cov.hit("empty_after_data");
  end

  // True occupancy never exceeds the depth.
  always @(posedge wr_clk) begin
    if (!wr_rst && expected.size() > DEPTH) begin
      errors++;
      if (errors <= 10)
        $display("  [MISMATCH] t=%0t occupancy %0d exceeds depth %0d", $time, expected.size(), DEPTH);
    end
    if (!wr_rst && wr_en && !wr_full && rd_en && !rd_empty) cov.hit("write_and_read_overlap");
  end

  // ---------------------------------------------------------------------------
  // Test sequence
  // ---------------------------------------------------------------------------
  task automatic wait_wr(int n); repeat (n) @(negedge wr_clk); endtask
  task automatic wait_rd(int n); repeat (n) @(negedge rd_clk); endtask

  task automatic apply_reset();
    running = 1'b0;
    wr_rst  = 1'b1;
    rd_rst  = 1'b1;
    wait_wr(4);
    wait_rd(4);
    expected.delete();
    n_written = 0;
    n_read    = 0;
    // release the two resets at unrelated times
    @(negedge wr_clk) wr_rst = 1'b0;
    @(negedge rd_clk) rd_rst = 1'b0;
    wait_wr(3);
    wait_rd(3);
  endtask

  task automatic run_test(int unsigned t, clock_cfg ck);
    int unsigned err_before = errors;
    int unsigned guard;

    wr_hp    = ck.a_hp;
    rd_hp    = ck.b_hp;
    rd_phase = ck.b_phase;
    apply_reset();

    if (!rd_empty || wr_full) begin
      errors++;
      $display("  [MISMATCH] after reset: rd_empty=%0b wr_full=%0b", rd_empty, wr_full);
    end

    // ---- 1. fill: exactly DEPTH words go in ----
    wr_pct = 100; rd_pct = 0; running = 1'b1;
    guard = 0;
    while (!wr_full && guard < 4 * DEPTH) begin wait_wr(1); guard++; end
    wait_wr(DEPTH);                      // keep pushing against full
    if (n_written != DEPTH) begin
      errors++;
      $display("  [MISMATCH] fill: %0d words accepted, expected exactly %0d", n_written, DEPTH);
    end

    // ---- 2. drain: everything comes back out ----
    wr_pct = 0; rd_pct = 100;
    wait_wr(2);
    guard = 0;
    while (n_read < n_written && guard < 16 * DEPTH) begin wait_rd(1); guard++; end
    wait_rd(4);                          // keep popping against empty
    if (n_read != n_written || !rd_empty) begin
      errors++;
      $display("  [MISMATCH] drain: read %0d of %0d words, rd_empty=%0b", n_read, n_written, rd_empty);
    end

    // ---- 3. mix: random duty cycles on both sides ----
    repeat (4) begin
      wr_pct = $urandom_range(10, 100);
      rd_pct = $urandom_range(10, 100);
      wait_wr($urandom_range(40, 160));
    end

    // ---- flush and check nothing was lost ----
    wr_pct = 0; rd_pct = 100;
    wait_wr(2);
    guard = 0;
    while (n_read < n_written && guard < 64 * DEPTH) begin wait_rd(1); guard++; end
    wait_rd(4);
    running = 1'b0;
    if (n_read != n_written || expected.size() != 0) begin
      errors++;
      $display("  [MISMATCH] end: wrote %0d, read %0d, %0d left in scoreboard",
               n_written, n_read, expected.size());
    end

    case (cur_ratio)
      RATIO_WR_FAST: cov.hit("ratio_write_fast");
      RATIO_RD_FAST: cov.hit("ratio_read_fast");
      RATIO_NEAR:    cov.hit("ratio_near_equal");
      default:       cov.hit("ratio_any");
    endcase
    if (n_written > 2 * DEPTH) cov.hit("pointers_wrapped");

    $display("[%s] fifo test %0d  wr %0d ps  rd %0d ps  %0d words",
             errors == err_before ? "PASS" : "FAIL", t, 2 * wr_hp, 2 * rd_hp, n_written);
  endtask

  initial begin
    clock_cfg    ck;
    int unsigned seed, ntests;

    if (!$value$plusargs("SEED=%d", seed))     seed   = 1;
    if (!$value$plusargs("NTESTS=%d", ntests)) ntests = 40;
    void'($urandom(seed));

    cov = new();
    cov.define_bin("ratio_write_fast");
    cov.define_bin("ratio_read_fast");
    cov.define_bin("ratio_near_equal");
    cov.define_bin("ratio_any");
    cov.define_bin("full");
    cov.define_bin("empty_after_data");
    cov.define_bin("write_attempt_while_full");
    cov.define_bin("read_attempt_while_empty");
    cov.define_bin("write_and_read_overlap");
    cov.define_bin("pointers_wrapped");

    $display("=====================================================================");
    $display(" async_fifo testbench   WIDTH=%0d DEPTH=%0d  seed=%0d  tests=%0d", WIDTH, DEPTH, seed, ntests);
    $display("=====================================================================");

    ck = new();
    ck.srandom(seed);
    for (int unsigned t = 0; t < ntests; t++) begin
      case (t % 4)
        0:       cur_ratio = RATIO_WR_FAST;
        1:       cur_ratio = RATIO_RD_FAST;
        2:       cur_ratio = RATIO_NEAR;
        default: cur_ratio = RATIO_ANY;
      endcase
      ck.ratio = cur_ratio;
      if (!ck.randomize()) $fatal(1, "randomize(clock_cfg) failed");
      run_test(t, ck);
    end

    $display("=====================================================================");
    cov.report($test$plusargs("COV_ALL"));
    if (errors == 0) $display(" RESULT: PASS");
    else             $display(" RESULT: FAIL  (%0d mismatches)", errors);
    $display("=====================================================================");
    $finish;
  end

endmodule
