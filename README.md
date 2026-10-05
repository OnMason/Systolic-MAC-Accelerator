# Systolic MAC Accelerator with CDC FIFOs

> A parameterized N×N systolic array that multiplies INT8 matrices and requantizes the result back to INT8, wrapped in dual-clock FIFOs so the host and the compute core can run on unrelated clocks. Written in SystemVerilog and verified with constrained-random testbenches, a software reference model, and SystemVerilog assertions.

![HDL](https://img.shields.io/badge/HDL-SystemVerilog-blue)
![Simulation](https://img.shields.io/badge/sim-Verilator%20%7C%20Vivado%20XSim-orange)
![License](https://img.shields.io/badge/license-MIT-lightgrey)

The matrix multiply `C = A × B` followed by a shift, saturate, and optional ReLU is the core operation of a quantized fully-connected neural-network layer. This project builds that datapath as a systolic array — a grid of identical multiply-accumulate cells with only nearest-neighbour wiring — and puts a clock-domain crossing on each side of it.

---

## Overview

| | |
|---|---|
| **Compute** | N×N output-stationary systolic array, one MAC cell per output element (N² multipliers) |
| **Data** | INT8 signed operands, 32-bit accumulators, INT8 output after requantization |
| **Requantization** | round-half-up right shift (0–31), saturate to [−128, 127], optional ReLU |
| **Latency** | 3N−2 array steps per multiply, plus N cycles to write the result rows |
| **Clocking** | two unrelated clocks (host, core) bridged by Gray-pointer asynchronous FIFOs |
| **Parameters** | `N`, `DATA_W`, `ACC_W`, `FIFO_ADDR_W` |
| **Verification** | 2 self-checking testbenches, 30 SVA assertions, tested at N = 2, 3, 4, 8 and FIFO depths 4, 8, 32 |

---

## Architecture

```
        host_clk domain            ║             core_clk domain
                                   ║
  s_valid ─┐                       ║
  s_ready ◄┤   ┌──────────────┐    ║    ┌───────────────────────────────┐
  s_data  ─┴──►│  async_fifo  │────╫───►│ accel_core                    │
               └──────────────┘    ║    │   sequencer                   │
                                   ║    │   ┌───────────────────────┐   │
                                   ║    │   │ systolic_array  N × N │   │
                                   ║    │   │   mac_pe  mac_pe  ... │   │
                                   ║    │   │   mac_pe  mac_pe  ... │   │
                                   ║    │   └───────────────────────┘   │
  m_valid ◄┐   ┌──────────────┐    ║    │   requant × N (one row)       │
  m_ready ─┤◄──│  async_fifo  │◄───╫────│                               │
  m_data  ◄┘   └──────────────┘    ║    └───────────────────────────────┘
                                   ║
```

### The systolic array

Each cell (`mac_pe`) does the same thing every step: multiply the operand arriving from the west by the operand arriving from the north, add the product to its accumulator, and pass both operands on — `a` to the east, `b` to the south — one step later.

Operands are streamed in N steps. At step *k* the array receives column *k* of A and row *k* of B. For `A[i][k]` and `B[k][j]` to reach cell (i, j) on the same step, row *i*'s input is delayed by *i* steps and column *j*'s input by *j* steps:

```
                b[k][0]   b[k][1]   b[k][2]        row k of B, column j delayed j steps
                   │         │         │
                   ▼         ▼         ▼
  a[0][k] ──────► PE00 ───► PE01 ───► PE02
                   │         │         │
  a[1][k] ─[z]──► PE10 ───► PE11 ───► PE12        [z] = one-step delay
                   │         │         │
  a[2][k] ─[z][z]► PE20 ───► PE21 ───► PE22
```

The pair meets at step *k + i + j*, so cell (i, j) accumulates `Σₖ A[i][k]·B[k][j] = C[i][j]`. The last product lands at step 3N−3; after the N data steps the sequencer feeds zeros while the remaining products drain through.

Because the whole array shares one clock enable, a late operand word simply pauses the computation — the array never has to drop or buffer anything itself.

### The sequencer (`accel_core`)

| Phase | Cycles | What happens |
|---|---|---|
| RUN | 3N−2 steps | The first N steps each pop one operand word from the input FIFO, waiting if it is empty. The remaining 2N−2 steps feed zeros. |
| OUT | N | Each cycle requantizes one row of accumulators and pushes it to the output FIFO, waiting if it is full. The last push clears the array. |

### The clock-domain crossing (`async_fifo`)

The FIFO is the classic dual-clock design:

- **Gray-coded pointers.** Each side keeps its pointer in binary to address the memory and in Gray code to send across. Gray code changes exactly one bit per increment, so a pointer sampled in the middle of a change resolves to either the old or the new value — never to an unrelated one.
- **Two-flop synchronizers** (`sync_2ff`) carry each Gray pointer into the other domain. The flops are tagged `ASYNC_REG` for Vivado.
- **Conservative flags.** `full` is computed in the write domain from a slightly stale read pointer, and `empty` in the read domain from a slightly stale write pointer. Stale means pessimistic: `full` can stay high a few cycles after a read and `empty` a few cycles after a write, but neither is ever missed, so the FIFO cannot overflow or underflow.
- **One extra pointer bit** distinguishes full from empty. In Gray code, full is "top two bits differ, the rest match."
- **Memory data never needs synchronizing.** An entry is only read after the write pointer that covers it has crossed, by which time the data has been stable for at least two read clocks.

---

## Interface

**Operand stream (host → accelerator).** N words per multiply, valid/ready handshake. Word *k* (k = 0…N−1) carries column *k* of A in the low half and row *k* of B in the high half:

```
s_data = { B[k][N-1], …, B[k][0],  A[N-1][k], …, A[0][k] }      each element 8 bits, signed
```

**Result stream (accelerator → host).** N words per multiply, one per row of C:

```
m_data = { C[r][N-1], …, C[r][0] }                              each element 8 bits, signed
```

**Configuration.** `cfg_shift[4:0]` and `cfg_relu` are in the core clock domain and are treated as quasi-static: change them only while `core_busy` is low. They are not synchronized.

**Reset.** `host_rst` and `core_rst` are synchronous to their own clocks. Assert both together and hold them for several cycles of the slower clock.

---

## Verification

Everything here was run with Verilator 5.x. The testbenches are standard SystemVerilog and a Vivado XSim flow is included (`make xsim`, `build.tcl`).

### Async FIFO testbench (`tb/tb_async_fifo.sv`)

Each test draws a constrained-random pair of unrelated clocks and runs three phases:

1. **Fill** — reader idle, writer pushes until full. Exactly `DEPTH` words must be accepted: one more is an overflow, one fewer is a false full.
2. **Drain** — writer idle, reader pops until empty. Every word must come back, in order.
3. **Mix** — both sides active with random duty cycles.

A queue scoreboard checks data and ordering, and true occupancy (writes − reads) is checked against the depth on every write clock.

### Accelerator testbench (`tb/tb_accel.sv`)

Each test draws random clocks and a random configuration (shift, ReLU, back-pressure on both host ports), then streams 1–6 matrix pairs through the design. Checks:

- every INT8 result row against a software `A × B` plus requantization;
- the raw 32-bit accumulators inside the array at the moment each multiply finishes, so a wrong sum cannot hide behind saturation;
- one directed case with a hand-written expected result, independent of the reference model.

Operand data comes from four generators: uniform random, extremes (−128, 127, ±1, 0), small values, and sparse.

### Clock relationships

The clock pair is constrained-random and the relationship rotates across tests so each regression covers all of them:

| Mode | Constraint |
|---|---|
| host/write fast | read period ≥ 3× write period |
| core/read fast | write period ≥ 3× read period |
| near-equal | periods within 50 ps of each other but never identical, so the phase drifts slowly through every alignment |
| any | both anywhere in 3–24 ns |

### Assertions

Bound into the RTL with `bind`:

- **`async_fifo_sva` (14)** — Gray pointers change at most one bit per cycle; Gray and binary pointers agree; accepted writes/reads advance the pointer and nothing else does; no pointer movement while full/empty; `full` and `empty` exactly match each side's view of the fill level; fill level never exceeds depth.
- **`accel_core_sva` (16)** — never pop an empty FIFO or push a full one; pops only during the N load steps; a load step never advances without data; exactly N words in and N rows out per multiply; output only after the last step; accumulators hold while paused, are zero after a clear and while idle; configuration stable while busy.

### Results

| Check | Result |
|---|---|
| FIFO regression: depths 4, 8, 32 × 5 seeds × 60 tests | 900 tests, 0 mismatches |
| Accelerator regression: N = 2, 3, 4, 8 × 5 seeds × 60 tests | 1,200 tests, 4,198 matrix multiplies, 0 mismatches |
| Functional coverage | all bins hit in every run (10 FIFO, 21 accelerator) |
| SVA assertions | 0 failures |
| Verilator lint (`-Wall`) on the RTL | clean |

### Does the testbench catch bugs?

To check that a passing run means something, 24 single-line bugs were injected into the RTL one at a time and both testbenches rerun. 22 were caught:

| Injected bug | Caught by scoreboard | Assertion that fired |
|---|---|---|
| FIFO: full compare without the two-bit inversion | yes | `a_full_exact` |
| FIFO: full compare inverting only the top bit | yes | `a_full_exact` |
| FIFO: empty computed from the current, not next, pointer | yes | `a_empty_exact` |
| FIFO: write accepted while full | yes | `a_level_wr_in_range` |
| FIFO: read accepted while empty | yes | `a_level_rd_in_range` |
| FIFO: binary pointer sent across instead of Gray | yes | `a_wgray_is_gray_of_bin` |
| FIFO: read data taken from the next pointer | yes | — |
| Sequencer: one step too few | yes | `a_out_follows_last_step` |
| Sequencer: ignores input-FIFO empty | yes | `a_load_step_needs_word` |
| Sequencer: ignores output-FIFO full | yes | `a_push_only_when_room` |
| Sequencer: never clears the array | yes | `a_idle_means_clean` |
| Sequencer: wrong row select, A and B swapped | yes | — |
| Array: skew register stuck, B skew removed, B not passed south | yes | — |
| Cell: unsigned multiply, product zero-extended | yes | — |
| Requantizer: no rounding, no upper clamp, ReLU ignored, logical shift | yes | — |

The two that were not caught are both informative:

- **Feeding FIFO data instead of zeros on the B input during the drain steps** changes nothing observable. Any B value entering after the N data steps can only ever meet an A value that also entered after them, and those are zero. Zeroing either input is sufficient; the design zeroes both.
- **A one-flop synchronizer instead of two** passes everything — see the next section.

### What simulation does not prove

RTL simulation has no metastability: a flop that samples a changing input just takes the old or new value. So these tests show the FIFO is *functionally* correct for arbitrary clock ratios and phases, but they cannot show the synchronizers are *sufficient*. Concretely, replacing the two-flop synchronizer with a single flop still passes every test here. That part of the design rests on structure (two flops, Gray code, `ASYNC_REG`), on timing constraints, and on Vivado's CDC report — see `constraints/cdc_example.xdc` and the next section.

---

## Limitations and next steps

- **Not yet synthesized.** No resource, Fmax, or CDC-report numbers. `constraints/cdc_example.xdc` is a starting point that has not been through Vivado.
- **On a Basys 3** there is one 100 MHz oscillator, so two clocks from the same MMCM would be related, not truly asynchronous. A real second clock source (or treating them as asynchronous anyway) is needed to exercise the crossing in hardware.
- **Multipliers.** The array uses N² 8×8 multipliers: 16 at N = 4, 64 at N = 8. The XC7A35T has 90 DSP slices, so N = 16 (256) would need LUT multipliers or time-sharing.
- **No bias add or per-channel scale** in the requantizer, and configuration is two static ports rather than a register interface.
- **No host bus.** The ports are raw valid/ready streams; a UART or AXI-Stream wrapper is the natural next step for board bring-up.

---

## Repository structure

```
├── rtl/
│   ├── sync_2ff.sv          # two-flop synchronizer
│   ├── async_fifo.sv        # dual-clock FIFO, Gray pointers
│   ├── mac_pe.sv            # one multiply-accumulate cell
│   ├── systolic_array.sv    # N×N cells + input skew
│   ├── requant.sv           # round, shift, saturate, ReLU
│   ├── accel_core.sv        # sequencer (single clock)
│   └── accel_top.sv         # core + two CDC FIFOs
├── tb/
│   ├── tb_pkg.sv            # random clock/test configuration, coverage
│   ├── async_fifo_sva.sv    # FIFO assertions + bind
│   ├── accel_core_sva.sv    # sequencer assertions + bind
│   ├── tb_async_fifo.sv     # FIFO testbench
│   └── tb_accel.sv          # accelerator testbench
├── constraints/
│   └── cdc_example.xdc      # example clock + CDC constraints (untested)
├── Makefile
└── build.tcl
```

---

## How to run

### Verilator

Needs a recent Verilator 5 (tested with 5.048) and `z3` on the PATH, which Verilator uses to solve constraints.

```bash
make sim                     # accelerator, N=4, 60 tests
make sim N=8 SEED=3          # another size and seed
make sim PLUSARGS=+VERBOSE   # print every test's clocks and configuration
make fifo                    # async FIFO testbench
make regress                 # FIFO at 3 depths + accelerator at 4 sizes, 5 seeds each
make lint
```

### Vivado

```bash
vivado -mode batch -source build.tcl     # creates the project, runs tb_accel in XSim
make xsim
```
