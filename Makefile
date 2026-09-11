# AxiomaCore-328 — punto de entrada único de la construcción
# Documentación: docs/00-PLAN.md

SHELL := /bin/bash
.DEFAULT_GOAL := help

OSS_CAD  ?= $(HOME)/eda/oss-cad-suite
# La OSS CAD Suite antepone su propio Python, que no trae numpy.
PYTHON   ?= $(if $(AXIOMA_PYTHON),$(AXIOMA_PYTHON),$(shell test -x $(HOME)/eda/venv/bin/python && echo $(HOME)/eda/venv/bin/python || echo python3))
RTL_DIR  := rtl
TOP_SOC  := axioma328_soc

# Objetivo FPGA por defecto: ULX3S 25F
ECP5_DEV   ?= 25k
ECP5_PKG   ?= CABGA381
ECP5_LPF   := $(RTL_DIR)/fpga/ecp5/axioma_ulx3s.lpf
ECP5_TOP   := axioma_ulx3s_top
BUILD      := build

# Ficheros en desarrollo, excluidos del lint mientras no estén terminados.
# La lista es EXPLÍCITA a propósito: un glob de exclusión acabaría escondiendo
# ficheros de verdad rotos sin que nadie se entere.
RTL_WIP  :=
RTL_SRCS := $(filter-out $(RTL_WIP),$(shell find $(RTL_DIR) -name '*.v' 2>/dev/null))
# Los .vh viven junto a los módulos que los definen.
INCDIRS  := $(addprefix -I,$(sort $(dir $(shell find $(RTL_DIR) -name '*.vh' 2>/dev/null))))
# Mientras no exista el top del SoC (fase 2) hay varias raíces y verilator avisa
# con MULTITOP. Se lintan todos los ficheros JUNTOS a propósito: así se detectan
# fallos entre ficheros, como una guarda de inclusión que deja sin constantes al
# segundo módulo que incluye una cabecera.
LINT_TOP := $(if $(wildcard $(RTL_DIR)/soc/axioma328_soc.v),--top-module $(TOP_SOC),-Wno-MULTITOP)

GREEN := \033[0;32m
RED   := \033[0;31m
DIM   := \033[2m
BOLD  := \033[1m
NC    := \033[0m

# ---------------------------------------------------------------------- ayuda
.PHONY: help
help:
	@echo -e "$(BOLD)AxiomaCore-328$(NC)  —  microcontrolador AVR-compatible libre"
	@echo ""
	@echo -e "$(BOLD)Disponible ahora$(NC)"
	@echo "  make check-tools      verifica la cadena de herramientas"
	@echo "  make regmap           genera el mapa de registros desde iom328p.h"
	@echo "  make regmap-check     falla si el mapa está desactualizado (CI)"
	@echo "  make lpf              regenera las constraints de la ULX3S"
	@echo "  make diagrams         regenera las figuras del README"
	@echo "  make lint             lint del RTL con verilator"
	@echo "  make synth-check      sintesis con yosys: sin latches, y area medida"
	@echo "  make clean            limpia los artefactos de construcción"
	@echo ""
	@echo -e "$(BOLD)Fase 1$(NC)  $(DIM)núcleo ISA$(NC)"
	@echo "  make sim-alu          verificación exhaustiva de la ALU"
	@echo "  make sim-sreg         prueba dirigida del registro de estado"
	@echo "  make sim-regfile      banco de registros vs modelo, 200k ciclos"
	@echo "  make sim-mem          memorias de programa y datos"
	@echo "  make sim-dbus         fabric del espacio de datos, 65 536 direcciones"
	@echo "  make sim-gpio         puertos de E/S: sincronizador y toggle por PINx"
	@echo "  make sim-timer0       Timer0 y prescaler compartido vs hoja de datos"
	@echo "  make sim-irq          controlador de interrupciones, exhaustivo"
	@echo "  make sim-soc          mapa de I/O del SoC: 224 direcciones, sin colisiones"
	@echo "  make sim-simavr       contraste contra simavr (tercer oráculo)"
	@echo "  make sim-decode       decodificador contra avr-objdump (65 536 opcodes)"
	@echo "  make sim-diff         co-simulación diferencial contra simavr"
	@echo "  make cycles-table     regenera la tabla de ciclos del contrato L3"
	@echo "  make sim-core         todas las anteriores"
	@echo "  make sim-random       10^6 instrucciones aleatorias vs simavr"
	@echo "  make mutation         prueba de mutación de TODO el RTL (~5 min)"
	@echo "  make sim-isa          suite dirigida de las 131 instrucciones"

	@echo ""
	@echo -e "$(BOLD)Fase 2$(NC)  $(DIM)FPGA$(NC)"
	@echo "  make bitstream-ulx3s  síntesis, P&R y empaquetado"
	@echo "  make prog-ulx3s       carga volátil en la SRAM de la FPGA"
	@echo "  make flash-ulx3s      escritura permanente en la flash SPI"
	@echo ""
	@echo -e "$(BOLD)Fase 6$(NC)  $(DIM)silicio$(NC)"
	@echo "  make asic             flujo LibreLane sobre Sky130"
	@echo ""
	@echo -e "$(DIM)Estado del proyecto y hoja de ruta: docs/00-PLAN.md$(NC)"

# ------------------------------------------------------------------ entorno
.PHONY: env
env:
	@if [ ! -d "$(OSS_CAD)" ]; then \
	  echo -e "$(RED)No se encuentra OSS CAD Suite en $(OSS_CAD)$(NC)"; \
	  echo "Instálala siguiendo docs/04-herramientas.md"; exit 1; fi

.PHONY: check-tools
check-tools:
	@echo -e "$(BOLD)Cadena de herramientas$(NC)"
	@ok=0; ko=0; \
	for t in yosys nextpnr-ecp5 ecppack verilator iverilog openFPGALoader sby gtkwave; do \
	  if command -v $$t >/dev/null 2>&1; then \
	    printf "  $(GREEN)ok$(NC)   %-18s %s\n" "$$t" "$$($$t --version 2>&1 | head -1 | cut -c1-46)"; ok=$$((ok+1)); \
	  else printf "  $(RED)--$(NC)   %-18s $(DIM)source $(OSS_CAD)/environment$(NC)\n" "$$t"; ko=$$((ko+1)); fi; \
	done; \
	for t in avr-gcc avr-objcopy avrdude simavr; do \
	  if command -v $$t >/dev/null 2>&1; then \
	    printf "  $(GREEN)ok$(NC)   %-18s %s\n" "$$t" "$$($$t --version 2>&1 | head -1 | cut -c1-46)"; ok=$$((ok+1)); \
	  else printf "  $(RED)--$(NC)   %-18s $(DIM)sudo apt install gcc-avr avr-libc avrdude simavr$(NC)\n" "$$t"; ko=$$((ko+1)); fi; \
	done; \
	python3 -c "import cocotb" 2>/dev/null \
	  && printf "  $(GREEN)ok$(NC)   %-18s\n" "cocotb" \
	  || printf "  $(RED)--$(NC)   %-18s $(DIM)pip install cocotb$(NC)\n" "cocotb"; \
	echo ""; echo -e "  $(BOLD)$$ok disponibles, $$ko pendientes$(NC)"

# ------------------------------------------------------- ficheros generados
.PHONY: regmap regmap-check lpf
regmap:
	@$(PYTHON) tools/gen_regmap.py

regmap-check:
	@$(PYTHON) tools/gen_regmap.py --check

lpf:
	@$(PYTHON) tools/gen_ulx3s_lpf.py

# Las figuras del README se generan, como el mapa de registros: una figura
# dibujada a mano se desincroniza del diseño y nadie se entera. Usa el python
# del sistema porque necesita pycairo (paquete python3-cairo), que no está en
# el venv del proyecto.
DIAG_PYTHON ?= python3

.PHONY: diagrams
diagrams:
	@$(DIAG_PYTHON) tools/gen_diagrams.py images

# ------------------------------------------------------------------- lint
.PHONY: lint
lint:
	@if [ -z "$(RTL_SRCS)" ]; then \
	  echo -e "$(DIM)Todavía no hay RTL en $(RTL_DIR)/ — nada que analizar. Ver docs/00-PLAN.md, fase 1.$(NC)"; \
	else \
	  verilator --lint-only -Wall -Wno-DECLFILENAME $(LINT_TOP) $(INCDIRS) $(RTL_SRCS) && \
	  echo -e "$(GREEN)lint limpio$(NC)"; \
	  $(if $(RTL_WIP),echo -e "$(DIM)  excluidos por estar en desarrollo: $(RTL_WIP)$(NC)";) \
	fi

# --- síntesis: latches y área ---
# El lint de verilator NO es un sintetizador: no infiere latches ni mide área.
# Este objetivo pasa yosys por todo el RTL y falla si aparece un solo latch.
.PHONY: synth-check
synth-check:
	@$(DIAG_PYTHON) tools/synth_check.py

# ------------------------------------------------------------- fase 1: sim
VEC_DIR := $(BUILD)/alu_vec

.PHONY: alu-vectors
alu-vectors: $(VEC_DIR)/spec.txt
$(VEC_DIR)/spec.txt: sim/alu/alu_ref.py
	@$(PYTHON) sim/alu/alu_ref.py --gen $(VEC_DIR)

.PHONY: sim-alu
sim-alu: alu-vectors
	@verilator --cc --exe --build -Wall -Wno-DECLFILENAME \
	  $(INCDIRS) -Mdir $(BUILD)/valu -o tb_alu \
	  --top-module axioma_alu rtl/core/axioma_alu.v sim/alu/tb_alu.cpp >/dev/null
	@echo -e "$(BOLD)Verificación exhaustiva de la ALU$(NC)"
	@./$(BUILD)/valu/tb_alu $(VEC_DIR)

.PHONY: sim-sreg
sim-sreg:
	@verilator --cc --exe --build -Wall -Wno-DECLFILENAME \
	  $(INCDIRS) -Mdir $(BUILD)/vsreg -o tb_sreg \
	  --top-module axioma_sreg rtl/core/axioma_sreg.v sim/alu/tb_sreg.cpp >/dev/null
	@./$(BUILD)/vsreg/tb_sreg

# --- tercer oráculo: simavr ---
SIMAVR_LIB     ?= $(HOME)/eda/simavr-src/simavr/obj-x86_64-linux-gnu
SIMAVR_INCLUDE ?= $(HOME)/eda/simavr-src/simavr/sim
SIM_VEC        := $(BUILD)/simavr_vec

$(BUILD)/simavr_oracle: sim/alu/simavr_oracle.c | $(BUILD)
	@test -d "$(SIMAVR_INCLUDE)" || { \
	  echo -e "$(RED)No se encuentra simavr en $(SIMAVR_INCLUDE)$(NC)"; \
	  echo "Ver docs/04-herramientas.md"; exit 1; }
	@gcc -O2 -o $@ $< -I$(SIMAVR_INCLUDE) -I$(SIMAVR_INCLUDE)/avr \
	     -L$(SIMAVR_LIB) -lsimavr -lelf

.PHONY: simavr-oracle
simavr-oracle: $(BUILD)/simavr_oracle
	@mkdir -p $(SIM_VEC)
	@LD_LIBRARY_PATH=$(SIMAVR_LIB):$$LD_LIBRARY_PATH ./$(BUILD)/simavr_oracle $(SIM_VEC) 1 >/dev/null

.PHONY: sim-simavr
sim-simavr: simavr-oracle
	@echo -e "$(BOLD)Contraste contra simavr$(NC)"
	@$(PYTHON) sim/alu/compare_simavr.py $(SIM_VEC)

# --- decodificador: oráculo avr-objdump ---
DEC_DIR := $(BUILD)/decode

$(DEC_DIR)/objdump.npz: sim/decode/objdump_oracle.py
	@mkdir -p $(DEC_DIR)
	@$(PYTHON) sim/decode/objdump_oracle.py $@

$(DEC_DIR)/rtl.bin: rtl/core/axioma_decode.v rtl/core/axioma_decode_ops.vh sim/decode/tb_decode.cpp
	@mkdir -p $(DEC_DIR)
	@verilator --cc --exe --build -Wall -Wno-DECLFILENAME \
	  $(INCDIRS) -Mdir $(BUILD)/vdec -o tb_decode \
	  --top-module axioma_decode rtl/core/axioma_decode.v sim/decode/tb_decode.cpp >/dev/null
	@./$(BUILD)/vdec/tb_decode $@ >/dev/null

.PHONY: sim-decode
sim-decode: $(DEC_DIR)/objdump.npz $(DEC_DIR)/rtl.bin
	@echo -e "$(BOLD)Decodificador contra avr-objdump$(NC)"
	@$(PYTHON) sim/decode/compare_decode.py $(DEC_DIR)

.PHONY: sim-regfile
sim-regfile:
	@verilator --cc --exe --build -Wall -Wno-DECLFILENAME \
	  $(INCDIRS) -Mdir $(BUILD)/vrf -o tb_regfile \
	  --top-module axioma_regfile rtl/core/axioma_regfile.v sim/alu/tb_regfile.cpp >/dev/null
	@./$(BUILD)/vrf/tb_regfile

# --- puerto de entrada/salida ---
.PHONY: sim-gpio
sim-gpio:
	@verilator --cc --exe --build -Wall -Wno-DECLFILENAME \
	  $(INCDIRS) -Mdir $(BUILD)/vgpio -o tb_gpio \
	  --top-module axioma_gpio -GBITS="8'hFF" \
	  rtl/periph/axioma_gpio.v sim/periph/tb_gpio.cpp >/dev/null
	@./$(BUILD)/vgpio/tb_gpio 255
	@verilator --cc --exe --build -Wall -Wno-DECLFILENAME \
	  $(INCDIRS) -Mdir $(BUILD)/vgpio7 -o tb_gpio7 \
	  --top-module axioma_gpio -GBITS="8'h7F" \
	  rtl/periph/axioma_gpio.v sim/periph/tb_gpio.cpp >/dev/null
	@./$(BUILD)/vgpio7/tb_gpio7 127

# --- Timer0 y su prescaler compartido ---
# Van juntos porque la trampa nº 12 —el prescaler es libre y no se reinicia al
# arrancar el temporizador— sólo se puede comprobar con los dos a la vez.
.PHONY: sim-timer0
sim-timer0:
	@verilator --cc --exe --build -Wall -Wno-DECLFILENAME \
	  $(INCDIRS) -Mdir $(BUILD)/vtimer0 -o tb_timer0 \
	  --top-module tb_timer0_top \
	  sim/periph/tb_timer0_top.v rtl/periph/axioma_timer0.v \
	  rtl/periph/axioma_prescaler.v sim/periph/tb_timer0.cpp >/dev/null
	@echo -e "$(BOLD)Timer0 contra la hoja de datos$(NC)"
	@./$(BUILD)/vtimer0/tb_timer0

# --- controlador de interrupciones ---
.PHONY: sim-irq
sim-irq:
	@verilator --cc --exe --build -Wall -Wno-DECLFILENAME \
	  $(INCDIRS) -Mdir $(BUILD)/virq -o tb_irq \
	  --top-module axioma_irq rtl/periph/axioma_irq.v sim/periph/tb_irq.cpp >/dev/null
	@echo -e "$(BOLD)Controlador de interrupciones, exhaustivo$(NC)"
	@./$(BUILD)/virq/tb_irq

# --- integracion: el mapa de I/O del SoC ---
# Cada periferico esta verificado por su cuenta; que esten bien COLOCADOS no lo
# comprobaba nadie, y ahi ya habia aparecido un fallo. Se barren las 224
# direcciones del espacio de I/O por el camino real, con el nucleo ejecutando
# un LDS por cada una.
SOC_SRCS := rtl/soc/axioma328_soc.v \
            rtl/core/axioma_core.v rtl/core/axioma_seq.v rtl/core/axioma_decode.v \
            rtl/core/axioma_alu.v rtl/core/axioma_sreg.v rtl/core/axioma_regfile.v \
            rtl/mem/axioma_progmem.v rtl/mem/axioma_dmem.v rtl/bus/axioma_dbus.v \
            rtl/periph/axioma_gpio.v rtl/periph/axioma_gpior.v \
            rtl/periph/axioma_prescaler.v rtl/periph/axioma_timer0.v \
            rtl/periph/axioma_irq.v

.PHONY: sim-soc
sim-soc:
	@verilator --cc --exe --build -Wall -Wno-DECLFILENAME \
	  $(INCDIRS) -Mdir $(BUILD)/vsoc -o tb_soc_map --top-module tb_soc_top \
	  sim/soc/tb_soc_top.v $(SOC_SRCS) sim/soc/tb_soc_map.cpp >/dev/null
	@echo -e "$(BOLD)Mapa de I/O del SoC, barrido entero$(NC)"
	@./$(BUILD)/vsoc/tb_soc_map

# --- fabric del espacio de datos ---
.PHONY: sim-dbus
sim-dbus:
	@verilator --cc --exe --build -Wall -Wno-DECLFILENAME \
	  $(INCDIRS) -Mdir $(BUILD)/vdbus -o tb_dbus \
	  --top-module axioma_dbus rtl/bus/axioma_dbus.v sim/bus/tb_dbus.cpp >/dev/null
	@./$(BUILD)/vdbus/tb_dbus

.PHONY: sim-mem
sim-mem:
	@verilator --cc --exe --build -Wall -Wno-DECLFILENAME $(INCDIRS) \
	  -Mdir $(BUILD)/vmem -o tb_mem \
	  --top-module tb_mem_top \
	  sim/mem/tb_mem_top.v rtl/mem/axioma_progmem.v rtl/mem/axioma_dmem.v \
	  sim/mem/tb_mem.cpp >/dev/null
	@./$(BUILD)/vmem/tb_mem

# --- co-simulación diferencial contra simavr ---
DIFF_DIR  := $(BUILD)/diff
DIFF_SRCS := rtl/soc/axioma328_soc.v \
             rtl/core/axioma_core.v rtl/core/axioma_seq.v rtl/core/axioma_decode.v \
             rtl/core/axioma_alu.v rtl/core/axioma_sreg.v rtl/core/axioma_regfile.v \
             rtl/mem/axioma_progmem.v rtl/mem/axioma_dmem.v \
             rtl/bus/axioma_dbus.v rtl/periph/axioma_gpio.v \
             rtl/periph/axioma_gpior.v rtl/periph/axioma_prescaler.v \
             rtl/periph/axioma_timer0.v rtl/periph/axioma_irq.v
AVR_AS    := avr-gcc -mmcu=atmega328p -nostdlib -nostartfiles -Wl,-Ttext=0

$(DIFF_DIR)/%.bin: sim/diff/tests/%.S
	@mkdir -p $(DIFF_DIR)
	@$(AVR_AS) -o $(DIFF_DIR)/$*.elf $<
	@avr-objcopy -O binary $(DIFF_DIR)/$*.elf $@

$(BUILD)/vdiff/Vaxioma_sim_top: sim/diff/axioma_sim_top.v sim/diff/diff.cpp $(DIFF_SRCS)
	@test -d "$(SIMAVR_INCLUDE)" || { echo -e "$(RED)falta simavr en $(SIMAVR_INCLUDE)$(NC)"; exit 1; }
	@verilator --cc --exe --build -Wall -Wno-DECLFILENAME $(INCDIRS) \
	  -Mdir $(BUILD)/vdiff -o diff --top-module axioma_sim_top \
	  -CFLAGS "-I$(SIMAVR_INCLUDE) -I$(SIMAVR_INCLUDE)/avr" \
	  -LDFLAGS "-L$(SIMAVR_LIB) -lsimavr -lelf" \
	  sim/diff/axioma_sim_top.v $(DIFF_SRCS) sim/diff/diff.cpp >/dev/null

DIFF_TESTS := $(patsubst sim/diff/tests/%.S,$(DIFF_DIR)/%.bin,$(wildcard sim/diff/tests/*.S))

# --- capa 3: tabla de ciclos del contrato L3 ---
# Se proyecta sobre los 65 536 opcodes usando el mnemónico de avr-objdump, así
# que depende del oráculo del decodificador: la identidad de cada codificación
# la fija binutils, no nuestro RTL.
PERF_DIR := $(BUILD)/perf

$(PERF_DIR)/cycles.bin: sim/perf/cycles_ref.py $(DEC_DIR)/objdump.npz
	@mkdir -p $(PERF_DIR)
	@$(PYTHON) sim/perf/cycles_ref.py $(DEC_DIR)/objdump.npz $@ >/dev/null

.PHONY: cycles-table
cycles-table: $(PERF_DIR)/cycles.bin
	@$(PYTHON) sim/perf/cycles_ref.py $(DEC_DIR)/objdump.npz $(PERF_DIR)/cycles.bin

.PHONY: sim-diff
sim-diff: $(BUILD)/vdiff/Vaxioma_sim_top $(DIFF_TESTS) $(PERF_DIR)/cycles.bin
	@echo -e "$(BOLD)Co-simulación diferencial contra simavr$(NC)"
	@ok=0; ko=0; \
	for t in $(DIFF_TESTS); do \
	  n=$$(basename $$t .bin); printf "  %-8s " "$$n"; \
	  if out=$$(LD_LIBRARY_PATH=$(SIMAVR_LIB):$$LD_LIBRARY_PATH ./$(BUILD)/vdiff/diff $$t 20000 $(PERF_DIR)/cycles.bin $(DIFF_DIR)/$$n.cov 2>&1); then \
	    echo "$$out" | tail -3; ok=$$((ok+1)); \
	  else echo -e "$(RED)FALLA$(NC)"; echo "$$out" | tail -14; ko=$$((ko+1)); fi; \
	done; \
	echo ""; echo -e "  $$ok programas sin divergencias, $$ko con divergencias"; \
	$(PYTHON) sim/perf/cycle_coverage.py $(DEC_DIR)/objdump.npz $(DIFF_DIR)/*.cov; \
	test $$ko -eq 0

.PHONY: sim-core
sim-core: sim-alu sim-sreg sim-regfile sim-mem sim-dbus sim-gpio sim-timer0 sim-irq \
          sim-soc sim-simavr sim-decode sim-diff

# ------------------------------------------- regresión de instrucciones aleatorias
# Último requisito del criterio de aceptación de la fase 1: 10^6 instrucciones
# aleatorias sin divergencia. Los programas se GENERAN con semilla fija, así que
# un fallo se reproduce exactamente.
RAND_DIR  := $(BUILD)/random
RAND_N    ?= 10
RAND_LEN  ?= 4000
RAND_RUN  ?= 100000
RAND_SEED ?= 20260909

.PHONY: sim-random
sim-random: $(BUILD)/vdiff/Vaxioma_sim_top $(PERF_DIR)/cycles.bin
	@echo -e "$(BOLD)Regresión de instrucciones aleatorias$(NC)"
	@$(PYTHON) sim/random/gen_random.py --out $(RAND_DIR) --n $(RAND_N) 	   --len $(RAND_LEN) --seed $(RAND_SEED)
	@ok=0; ko=0; tot=0; 	for f in $(RAND_DIR)/rnd*.S; do 	  n=$$(basename $$f .S); 	  $(AVR_AS) -o $(RAND_DIR)/$$n.elf $$f || { echo "no ensambla: $$f"; exit 1; }; 	  avr-objcopy -O binary $(RAND_DIR)/$$n.elf $(RAND_DIR)/$$n.bin; 	  printf "  %-8s " "$$n"; 	  if out=$$(LD_LIBRARY_PATH=$(SIMAVR_LIB):$$LD_LIBRARY_PATH 	            ./$(BUILD)/vdiff/diff $(RAND_DIR)/$$n.bin $(RAND_RUN) 	            $(PERF_DIR)/cycles.bin $(RAND_DIR)/$$n.cov 2>&1); then 	    echo "$$out" | tail -3 | head -1; ok=$$((ok+1)); 	    tot=$$((tot+$(RAND_RUN))); 	  else echo -e "$(RED)FALLA$(NC)"; echo "$$out" | tail -16; ko=$$((ko+1)); fi; 	done; 	echo ""; 	echo -e "  $$ok programas, $$ko con divergencias, $$tot instrucciones ejecutadas"; 	$(PYTHON) sim/perf/cycle_coverage.py $(DEC_DIR)/objdump.npz $(RAND_DIR)/*.cov; 	test $$ko -eq 0

.PHONY: mutation
mutation:
	@$(PYTHON) sim/mutation.py

.PHONY: sim-isa
sim-isa:
	@echo -e "$(DIM)Pendiente. Ver docs/00-PLAN.md y docs/03-verificacion.md.$(NC)"; exit 1

# ------------------------------------------------------------ fase 2: FPGA
$(BUILD):
	@mkdir -p $(BUILD)

.PHONY: bitstream-ulx3s
bitstream-ulx3s: env | $(BUILD)
	@if [ ! -f "$(RTL_DIR)/fpga/ecp5/$(ECP5_TOP).v" ]; then \
	  echo -e "$(DIM)Falta $(RTL_DIR)/fpga/ecp5/$(ECP5_TOP).v — fase 2. Ver docs/00-PLAN.md.$(NC)"; exit 1; fi
	yosys -p "read_verilog -I$(RTL_DIR) $(RTL_SRCS); synth_ecp5 -top $(ECP5_TOP) -json $(BUILD)/axioma.json"
	nextpnr-ecp5 --$(ECP5_DEV) --package $(ECP5_PKG) \
	             --json $(BUILD)/axioma.json --lpf $(ECP5_LPF) \
	             --textcfg $(BUILD)/axioma.config --report $(BUILD)/timing.json
	ecppack $(BUILD)/axioma.config $(BUILD)/axioma.bit
	@echo -e "$(GREEN)bitstream listo: $(BUILD)/axioma.bit$(NC)"

.PHONY: prog-ulx3s flash-ulx3s
prog-ulx3s: $(BUILD)/axioma.bit
	openFPGALoader -b ulx3s $(BUILD)/axioma.bit

flash-ulx3s: $(BUILD)/axioma.bit
	openFPGALoader -b ulx3s -f $(BUILD)/axioma.bit

# ---------------------------------------------------------- fase 6: silicio
.PHONY: asic
asic:
	@echo -e "$(DIM)Fase 6 pendiente. Ver docs/00-PLAN.md, sección 11.$(NC)"; exit 1

# ------------------------------------------------------------------ limpieza
.PHONY: clean
clean:
	rm -rf $(BUILD) obj_dir sim_build
	find . -name '*.vcd' -o -name '*.vvp' -o -name '__pycache__' | xargs rm -rf 2>/dev/null || true
	@echo "limpio"
