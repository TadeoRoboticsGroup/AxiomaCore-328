# AxiomaCore-328 OpenLane Makefile
# RTL-to-GDSII flow for Sky130 130nm

DESIGN_NAME = axioma_cpu
CONFIG_FILE = config/config.json
SRC_DIR = src
RUNS_DIR = runs

# Source files from main project (absolute paths)
MAIN_PROJECT = ../..
CORE_DIR = $(MAIN_PROJECT)/core
MEMORY_DIR = $(MAIN_PROJECT)/memory
PERIPHERAL_DIR = $(MAIN_PROJECT)/peripherals
CLOCK_DIR = $(MAIN_PROJECT)/clock_reset
INT_DIR = $(MAIN_PROJECT)/axioma_interrupt

# Default target
.PHONY: all setup clean help drc lvs

all: setup flow

# Setup: copy RTL files to src directory
setup:
	@echo "Setting up AxiomaCore-328 source files..."
	@mkdir -p $(SRC_DIR)
	@echo "Copying core files..."
	@cp $(CORE_DIR)/axioma_cpu/axioma_cpu.v $(SRC_DIR)/
	@cp $(CORE_DIR)/axioma_alu/axioma_alu.v $(SRC_DIR)/
	@cp $(CORE_DIR)/axioma_decoder/axioma_decoder.v $(SRC_DIR)/
	@cp $(CORE_DIR)/axioma_registers/axioma_registers.v $(SRC_DIR)/
	@echo "Copying memory controllers..."
	@cp $(MEMORY_DIR)/axioma_flash_ctrl/axioma_flash_ctrl.v $(SRC_DIR)/
	@cp $(MEMORY_DIR)/axioma_sram_ctrl/axioma_sram_ctrl.v $(SRC_DIR)/
	@cp $(MEMORY_DIR)/axioma_eeprom_ctrl/axioma_eeprom_ctrl.v $(SRC_DIR)/
	@echo "Copying peripherals..."
	@cp $(PERIPHERAL_DIR)/axioma_gpio/axioma_gpio.v $(SRC_DIR)/
	@cp $(PERIPHERAL_DIR)/axioma_uart/axioma_uart.v $(SRC_DIR)/
	@cp $(PERIPHERAL_DIR)/axioma_spi/axioma_spi.v $(SRC_DIR)/
	@cp $(PERIPHERAL_DIR)/axioma_i2c/axioma_i2c.v $(SRC_DIR)/
	@cp $(PERIPHERAL_DIR)/axioma_adc/axioma_adc.v $(SRC_DIR)/
	@cp $(PERIPHERAL_DIR)/axioma_pwm/axioma_pwm.v $(SRC_DIR)/
	@cp $(PERIPHERAL_DIR)/axioma_timers/axioma_prescaler.v $(SRC_DIR)/
	@cp $(PERIPHERAL_DIR)/axioma_timers/axioma_pwm_generator.v $(SRC_DIR)/
	@cp $(PERIPHERAL_DIR)/axioma_timers/axioma_timer0.v $(SRC_DIR)/
	@cp $(PERIPHERAL_DIR)/axioma_timers/axioma_timer1.v $(SRC_DIR)/
	@cp $(PERIPHERAL_DIR)/axioma_timers/axioma_timer2.v $(SRC_DIR)/
	@cp $(PERIPHERAL_DIR)/axioma_analog_comp.v $(SRC_DIR)/
	@cp $(PERIPHERAL_DIR)/axioma_watchdog.v $(SRC_DIR)/
	@echo "Copying system files..."
	@cp $(CLOCK_DIR)/axioma_clock_system.v $(SRC_DIR)/
	@cp $(CLOCK_DIR)/axioma_system_tick.v $(SRC_DIR)/
	@cp $(INT_DIR)/axioma_interrupt.v $(SRC_DIR)/
	@echo "✅ Source files ready in $(SRC_DIR)/"
	@echo "Files copied: $$(ls $(SRC_DIR)/*.v | wc -l) Verilog modules"

# Run complete OpenLane flow
flow: setup
	@echo "Running OpenLane RTL-to-GDSII flow for AxiomaCore-328..."
	@if command -v openlane >/dev/null 2>&1; then \
		openlane -config $(CONFIG_FILE); \
	elif command -v docker >/dev/null 2>&1; then \
		echo "🐳 Using OpenLane via Docker..."; \
		docker run --rm -v $$(pwd):/work -v /tmp:/tmp efabless/openlane:2023.07.19-1 \
		openlane -config /work/$(CONFIG_FILE) -tag axioma_run; \
	else \
		echo "❌ OpenLane not found in PATH and Docker not available"; \
		echo "Please install OpenLane 2.0+ or Docker to run via container"; \
		exit 1; \
	fi

# Interactive OpenLane session
interactive: setup
	@echo "Starting OpenLane interactive session..."
	@if command -v openlane >/dev/null 2>&1; then \
		openlane -config $(CONFIG_FILE) -interactive; \
	elif command -v docker >/dev/null 2>&1; then \
		echo "🐳 Using OpenLane via Docker (interactive mode)..."; \
		docker run --rm -it -v $$(pwd):/work -v /tmp:/tmp efabless/openlane:2023.07.19-1 \
		openlane -config /work/$(CONFIG_FILE) -interactive -tag axioma_interactive; \
	else \
		echo "❌ OpenLane not found in PATH and Docker not available"; \
		echo "Please install OpenLane 2.0+ or Docker to run via container"; \
		exit 1; \
	fi

# Design Rule Check
drc:
	@echo "Running DRC check..."
	@if [ -d "$(RUNS_DIR)" ] && [ -n "$$(ls -A $(RUNS_DIR) 2>/dev/null)" ]; then \
		latest_run=$$(ls -t $(RUNS_DIR) | head -n1); \
		gds_file=$$(find $(RUNS_DIR)/$$latest_run -name "*.gds" | head -n1); \
		if [ -n "$$gds_file" ]; then \
			echo "DRC check on: $$gds_file"; \
			magic -drc -noconsole -dnull -batch $$gds_file; \
		else \
			echo "❌ No GDS file found. Run 'make flow' first."; \
		fi \
	else \
		echo "❌ No runs found. Run 'make flow' first."; \
	fi

# Layout vs Schematic check
lvs:
	@echo "Running LVS check..."
	@if [ -d "$(RUNS_DIR)" ] && [ -n "$$(ls -A $(RUNS_DIR) 2>/dev/null)" ]; then \
		latest_run=$$(ls -t $(RUNS_DIR) | head -n1); \
		echo "LVS check for run: $$latest_run"; \
		echo "⚠️ LVS requires netlist comparison - implementation needed"; \
	else \
		echo "❌ No runs found. Run 'make flow' first."; \
	fi

# Show status and results
status:
	@echo "=== AxiomaCore-328 OpenLane Status ==="
	@echo "Design: $(DESIGN_NAME)"
	@echo "Config: $(CONFIG_FILE)"
	@echo "Source files: $$(ls $(SRC_DIR)/*.v 2>/dev/null | wc -l) modules"
	@if [ -d "$(RUNS_DIR)" ]; then \
		echo "Runs: $$(ls $(RUNS_DIR) 2>/dev/null | wc -l)"; \
		if [ -n "$$(ls -A $(RUNS_DIR) 2>/dev/null)" ]; then \
			latest_run=$$(ls -t $(RUNS_DIR) | head -n1); \
			echo "Latest run: $$latest_run"; \
			if [ -f "$(RUNS_DIR)/$$latest_run/config.tcl" ]; then \
				echo "✅ Run completed"; \
			else \
				echo "⚠️ Run in progress or failed"; \
			fi \
		fi \
	else \
		echo "Runs: 0"; \
	fi

# Clean generated files
clean:
	@echo "Cleaning OpenLane files..."
	@rm -rf $(RUNS_DIR)
	@rm -rf $(SRC_DIR)
	@echo "✅ Cleaned runs and source files"

# Show results
results:
	@echo "=== AxiomaCore-328 Results ==="
	@if [ -d "$(RUNS_DIR)" ] && [ -n "$$(ls -A $(RUNS_DIR) 2>/dev/null)" ]; then \
		latest_run=$$(ls -t $(RUNS_DIR) | head -n1); \
		echo "Latest run: $$latest_run"; \
		echo ""; \
		gds_files=$$(find $(RUNS_DIR)/$$latest_run -name "*.gds" 2>/dev/null); \
		if [ -n "$$gds_files" ]; then \
			echo "📄 GDSII files:"; \
			echo "$$gds_files" | sed 's/^/  /'; \
		fi; \
		lef_files=$$(find $(RUNS_DIR)/$$latest_run -name "*.lef" 2>/dev/null); \
		if [ -n "$$lef_files" ]; then \
			echo "📄 LEF files:"; \
			echo "$$lef_files" | sed 's/^/  /'; \
		fi; \
		report_dirs=$$(find $(RUNS_DIR)/$$latest_run -name "reports" -type d 2>/dev/null); \
		if [ -n "$$report_dirs" ]; then \
			echo "📊 Reports:"; \
			echo "$$report_dirs" | sed 's/^/  /'; \
		fi; \
	else \
		echo "❌ No results found. Run 'make flow' first."; \
	fi

# Help
help:
	@echo "AxiomaCore-328 OpenLane Makefile"
	@echo "================================="
	@echo ""
	@echo "Targets:"
	@echo "  setup       - Copy RTL files to src/ directory"
	@echo "  flow        - Run complete RTL-to-GDSII flow"
	@echo "  interactive - Start interactive OpenLane session"
	@echo "  drc         - Run Design Rule Check on results"
	@echo "  lvs         - Run Layout vs Schematic check"
	@echo "  status      - Show current status"
	@echo "  results     - Show results from latest run"
	@echo "  clean       - Clean all generated files"
	@echo "  help        - Show this help message"
	@echo ""
	@echo "Requirements:"
	@echo "  - OpenLane 2.0+ installed and in PATH"
	@echo "  - Sky130 PDK installed"
	@echo "  - Magic and KLayout for verification"