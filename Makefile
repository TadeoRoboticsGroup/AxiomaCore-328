# AxiomaCore-328 — punto de entrada único de la construcción
# Documentación: docs/00-PLAN.md

SHELL := /bin/bash
.DEFAULT_GOAL := help

OSS_CAD  ?= $(HOME)/eda/oss-cad-suite
RTL_DIR  := rtl
TOP_SOC  := axioma328_soc

# Objetivo FPGA por defecto: ULX3S 25F
ECP5_DEV   ?= 25k
ECP5_PKG   ?= CABGA381
ECP5_LPF   := $(RTL_DIR)/fpga/ecp5/axioma_ulx3s.lpf
ECP5_TOP   := axioma_ulx3s_top
BUILD      := build

RTL_SRCS := $(shell find $(RTL_DIR) -name '*.v' 2>/dev/null)

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
	@echo "  make lint             lint del RTL con verilator"
	@echo "  make clean            limpia los artefactos de construcción"
	@echo ""
	@echo -e "$(BOLD)Fase 1$(NC)  $(DIM)núcleo ISA$(NC)"
	@echo "  make sim-alu          verificación exhaustiva de la ALU"
	@echo "  make sim-isa          suite dirigida de las 131 instrucciones"
	@echo "  make sim-diff         diferencial contra simavr"
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
	@python3 tools/gen_regmap.py

regmap-check:
	@python3 tools/gen_regmap.py --check

lpf:
	@python3 tools/gen_ulx3s_lpf.py

# ------------------------------------------------------------------- lint
.PHONY: lint
lint:
	@if [ -z "$(RTL_SRCS)" ]; then \
	  echo -e "$(DIM)Todavía no hay RTL en $(RTL_DIR)/ — nada que analizar. Ver docs/00-PLAN.md, fase 1.$(NC)"; \
	else \
	  verilator --lint-only -Wall -Wno-fatal -I$(RTL_DIR) $(RTL_SRCS) && \
	  echo -e "$(GREEN)lint limpio$(NC)"; \
	fi

# ------------------------------------------------------------- fase 1: sim
.PHONY: sim-alu sim-isa sim-diff
sim-alu sim-isa sim-diff:
	@echo -e "$(DIM)Fase 1 pendiente. Ver docs/00-PLAN.md y docs/03-verificacion.md.$(NC)"; exit 1

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
