# Systolic MAC accelerator — simulation
#
#   make sim                 accelerator testbench, N=4 (Verilator)
#   make sim N=8 SEED=3      another size / seed
#   make fifo                async FIFO testbench
#   make regress             FIFO at 3 depths + accelerator at N = 2, 3, 4, 8, several seeds
#   make lint
#   make xsim                accelerator testbench under Vivado XSim
#   make clean
#
# Needs a recent Verilator 5 (tested with 5.048); its constraint solver needs
# z3 on the PATH.

N        ?= 4
SEED     ?= 1
NTESTS   ?= 60
PLUSARGS ?=

RTL := rtl/sync_2ff.sv rtl/async_fifo.sv rtl/mac_pe.sv rtl/systolic_array.sv \
       rtl/requant.sv rtl/accel_core.sv rtl/accel_top.sv
TB_ACCEL := tb/tb_pkg.sv tb/async_fifo_sva.sv tb/accel_core_sva.sv tb/tb_accel.sv
TB_FIFO  := tb/tb_pkg.sv tb/async_fifo_sva.sv tb/tb_async_fifo.sv

VERILATOR ?= verilator
VFLAGS := --binary --timing --assert -j 0 --timescale 1ps/1ps --output-split 0 \
          -Wno-fatal -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-UNUSEDSIGNAL -Wno-IMPLICITSTATIC -Wno-ZERODLY \
          -CFLAGS "-std=c++20 -fcoroutines"

.PHONY: sim fifo regress lint xsim clean

build/accel_n%/sim: $(RTL) $(TB_ACCEL)
	@mkdir -p $(dir $@)
	$(VERILATOR) $(VFLAGS) -GN=$* --top-module tb_accel -Mdir $(dir $@) $(RTL) $(TB_ACCEL) -o sim

build/fifo_a%/sim: $(RTL) $(TB_FIFO)
	@mkdir -p $(dir $@)
	$(VERILATOR) $(VFLAGS) -GADDR_W=$* --top-module tb_async_fifo -Mdir $(dir $@) rtl/sync_2ff.sv rtl/async_fifo.sv $(TB_FIFO) -o sim

sim: build/accel_n$(N)/sim
	./build/accel_n$(N)/sim +SEED=$(SEED) +NTESTS=$(NTESTS) $(PLUSARGS)

fifo: build/fifo_a3/sim
	./build/fifo_a3/sim +SEED=$(SEED) +NTESTS=$(NTESTS) $(PLUSARGS)

regress: build/fifo_a2/sim build/fifo_a3/sim build/fifo_a5/sim \
         build/accel_n2/sim build/accel_n3/sim build/accel_n4/sim build/accel_n8/sim
	@mkdir -p build/logs; fail=0; \
	for s in 1 2 3 4 5; do \
	  for b in fifo_a2 fifo_a3 fifo_a5 accel_n2 accel_n3 accel_n4 accel_n8; do \
	    ./build/$$b/sim +SEED=$$s +NTESTS=60 > build/logs/$${b}_seed$$s.log 2>&1; \
	    if grep -q "RESULT: PASS" build/logs/$${b}_seed$$s.log; then echo "$$b seed $$s: PASS"; \
	    else echo "$$b seed $$s: FAILED (see build/logs/$${b}_seed$$s.log)"; fail=1; fi; \
	  done; \
	done; exit $$fail

lint:
	$(VERILATOR) --lint-only -Wall $(RTL) --top-module accel_top

xsim:
	mkdir -p build/xsim && cd build/xsim && \
	xvlog -sv $(addprefix ../../,$(RTL) $(TB_ACCEL)) && \
	xelab tb_accel -generic_top N=$(N) -s tb_accel_sim -timescale 1ps/1ps && \
	xsim tb_accel_sim -runall -testplusarg SEED=$(SEED) -testplusarg NTESTS=$(NTESTS)

clean:
	rm -rf build obj_dir *.vcd xsim.dir vivado_proj *.jou *.log *.pb
