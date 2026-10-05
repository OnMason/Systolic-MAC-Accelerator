// -----------------------------------------------------------------------------
// tb_pkg — shared testbench classes
//
//   * clock_cfg  : constrained-random pair of clock periods for a CDC test
//   * accel_cfg  : constrained-random configuration of one accelerator test
//   * coverage   : named functional-coverage bins with a text report
// -----------------------------------------------------------------------------
package tb_pkg;

  // How the two clocks relate in a test. Rotated by the test loop (not
  // randomized) so every regression covers all four.
  typedef enum int {
    RATIO_WR_FAST,    // write/host clock at least 3x faster
    RATIO_RD_FAST,    // read/core clock at least 3x faster
    RATIO_NEAR,       // almost the same frequency: phase drifts slowly
    RATIO_ANY
  } ratio_e;

  // ---------------------------------------------------------------------------
  // Two unrelated clocks. Half-periods in picoseconds.
  // ---------------------------------------------------------------------------
  class clock_cfg;
    ratio_e           ratio = RATIO_ANY;
    rand int unsigned a_hp;      // write / host clock
    rand int unsigned b_hp;      // read / core clock
    rand int unsigned b_phase;   // start offset of clock b

    constraint c_range {
      a_hp inside {[1500:12000]};
      b_hp inside {[1500:12000]};
      b_phase < 12000;
    }

    constraint c_ratio {
      (ratio == RATIO_WR_FAST) -> b_hp >= 3 * a_hp;
      (ratio == RATIO_RD_FAST) -> a_hp >= 3 * b_hp;
      (ratio == RATIO_NEAR)    -> (a_hp >= b_hp) ? (a_hp - b_hp <= 25) : (b_hp - a_hp <= 25);
      // Never exactly equal: identical periods would lock the phase and hide
      // the crossings this is meant to exercise.
      a_hp != b_hp;
    }
  endclass

  // ---------------------------------------------------------------------------
  // One accelerator test
  // ---------------------------------------------------------------------------
  class accel_cfg;
    rand bit [4:0] shift;         // requantization shift
    rand bit       relu;
    rand bit [2:0] n_mults;       // matrix multiplies in this test
    rand bit [1:0] data_mode;     // 0 random, 1 extremes, 2 small, 3 sparse
    rand bit [6:0] in_gap_pct;    // % of cycles the host withholds s_valid
    rand bit [6:0] out_stall_pct; // % of cycles the host withholds m_ready

    constraint c_shift { shift inside {[5'd0:5'd14]}; }
    constraint c_mults { n_mults inside {[3'd1:3'd6]}; }
    constraint c_flow {
      in_gap_pct    dist { 7'd0 := 3, 7'd25 := 2, 7'd60 := 2, 7'd90 := 1 };
      out_stall_pct dist { 7'd0 := 3, 7'd25 := 2, 7'd60 := 2, 7'd97 := 1 };
    }
  endclass

  // ---------------------------------------------------------------------------
  // Functional coverage: named bins with hit counters
  // ---------------------------------------------------------------------------
  class coverage;
    int unsigned hits [string];
    string       order [$];

    function void define_bin(string name);
      if (!hits.exists(name)) begin
        hits[name] = 0;
        order.push_back(name);
      end
    endfunction

    function void hit(string name);
      if (!hits.exists(name)) define_bin(name);
      hits[name]++;
    endfunction

    function int unsigned num_hit();
      int unsigned n = 0;
      foreach (order[i]) if (hits[order[i]] > 0) n++;
      return n;
    endfunction

    function void report(bit show_all = 0);
      $display("---------------- functional coverage ----------------");
      foreach (order[i]) begin
        if (show_all || hits[order[i]] == 0)
          $display("  %-36s %0d%s", order[i], hits[order[i]],
                   hits[order[i]] == 0 ? "   <-- NOT HIT" : "");
      end
      $display("  bins hit: %0d / %0d", num_hit(), order.size());
      $display("-----------------------------------------------------");
    endfunction
  endclass

endpackage
