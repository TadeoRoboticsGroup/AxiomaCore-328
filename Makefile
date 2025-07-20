# AxiomaCore-328 Makefile
# Automatización del flujo de desarrollo

# Directorios
CORE_DIR = core
TB_DIR = testbench
SYN_DIR = synthesis
DOCS_DIR = docs

# Archivos fuente
SOURCES = $(CORE_DIR)/axioma_registers/axioma_registers.v \
          $(CORE_DIR)/axioma_alu/axioma_alu.v \
          $(CORE_DIR)/axioma_decoder/axioma_decoder.v \
          $(CORE_DIR)/axioma_cpu/axioma_cpu.v

TESTBENCH = $(TB_DIR)/axioma_cpu_tb.v

# Herramientas
IVERILOG = iverilog
VVP = vvp
GTKWAVE = gtkwave
YOSYS = yosys

# Targets principales
.PHONY: all clean test cpu_basic synthesize view_waves help

all: cpu_basic test

help:
	@echo "AxiomaCore-328 Build System"
	@echo "=========================="
	@echo "make cpu_basic    - Compilar CPU básico"
	@echo "make test         - Ejecutar testbench"
	@echo "make test_view    - Ejecutar test y abrir GTKWave"
	@echo "make synthesize   - Síntesis con Yosys"
	@echo "make clean        - Limpiar archivos generados"
	@echo "make help         - Mostrar esta ayuda"

cpu_basic: axioma_cpu_sim
	@echo "✅ CPU básico compilado exitosamente"

axioma_cpu_sim: $(SOURCES) $(TESTBENCH)
	@echo "🔨 Compilando AxiomaCore-328..."
	$(IVERILOG) -o axioma_cpu_sim -I$(CORE_DIR) $(SOURCES) $(TESTBENCH)

test: axioma_cpu_sim
	@echo "🧪 Ejecutando testbench..."
	$(VVP) axioma_cpu_sim
	@echo "✅ Test completado"

test_view: test
	@echo "🔍 Abriendo GTKWave..."
	$(GTKWAVE) axioma_cpu_tb.vcd &

# Verificar módulos individuales
test_alu: $(CORE_DIR)/axioma_alu/axioma_alu.v
	@echo "🧪 Test individual ALU..."
	$(IVERILOG) -o test_alu -DTEST_ALU $(CORE_DIR)/axioma_alu/axioma_alu.v
	$(VVP) test_alu

test_registers: $(CORE_DIR)/axioma_registers/axioma_registers.v
	@echo "🧪 Test individual Registros..."
	$(IVERILOG) -o test_registers -DTEST_REGISTERS $(CORE_DIR)/axioma_registers/axioma_registers.v
	$(VVP) test_registers

test_decoder: $(CORE_DIR)/axioma_decoder/axioma_decoder.v
	@echo "🧪 Test individual Decodificador..."
	$(IVERILOG) -o test_decoder -DTEST_DECODER $(CORE_DIR)/axioma_decoder/axioma_decoder.v
	$(VVP) test_decoder

# Síntesis
synthesize: $(SOURCES)
	@echo "⚙️  Ejecutando síntesis con Yosys..."
	@mkdir -p $(SYN_DIR)
	$(YOSYS) -s synthesis/axioma_syn.ys

# Configuración de síntesis Yosys
$(SYN_DIR)/axioma_syn.ys:
	@mkdir -p $(SYN_DIR)
	@echo "# AxiomaCore-328 Synthesis Script" > $(SYN_DIR)/axioma_syn.ys
	@echo "read_verilog $(SOURCES)" >> $(SYN_DIR)/axioma_syn.ys
	@echo "hierarchy -top axioma_cpu" >> $(SYN_DIR)/axioma_syn.ys
	@echo "proc; opt; fsm; opt; memory; opt" >> $(SYN_DIR)/axioma_syn.ys
	@echo "techmap; opt" >> $(SYN_DIR)/axioma_syn.ys
	@echo "stat" >> $(SYN_DIR)/axioma_syn.ys
	@echo "write_verilog $(SYN_DIR)/axioma_cpu_syn.v" >> $(SYN_DIR)/axioma_syn.ys

# Documentación
docs:
	@echo "📚 Generando documentación..."
	@mkdir -p $(DOCS_DIR)
	@echo "# AxiomaCore-328 Documentation" > $(DOCS_DIR)/modules.md
	@echo "## CPU Modules" >> $(DOCS_DIR)/modules.md
	@echo "- axioma_cpu: Main CPU core" >> $(DOCS_DIR)/modules.md
	@echo "- axioma_alu: Arithmetic Logic Unit" >> $(DOCS_DIR)/modules.md
	@echo "- axioma_registers: Register bank" >> $(DOCS_DIR)/modules.md
	@echo "- axioma_decoder: Instruction decoder" >> $(DOCS_DIR)/modules.md

# Estadísticas del código
stats:
	@echo "📊 Estadísticas del proyecto:"
	@echo "Líneas de código Verilog:"
	@wc -l $(SOURCES) | tail -1
	@echo "Líneas de testbench:"
	@wc -l $(TESTBENCH)
	@echo "Archivos del proyecto:"
	@find . -name "*.v" | wc -l

# Limpieza
clean:
	@echo "🧹 Limpiando archivos generados..."
	rm -f axioma_cpu_sim
	rm -f test_alu test_registers test_decoder
	rm -f *.vcd
	rm -f *.out
	rm -rf $(SYN_DIR)/*.v $(SYN_DIR)/*.ys
	@echo "✅ Limpieza completada"

# Verificar herramientas requeridas
check_tools:
	@echo "🔧 Verificando herramientas..."
	@which $(IVERILOG) > /dev/null || echo "❌ Icarus Verilog no encontrado"
	@which $(GTKWAVE) > /dev/null || echo "❌ GTKWave no encontrado"
	@which $(YOSYS) > /dev/null || echo "⚠️  Yosys no encontrado (opcional)"
	@echo "✅ Verificación de herramientas completada"

# Install (para desarrollo)
install_tools:
	@echo "📦 Instalando herramientas de desarrollo..."
	sudo apt update
	sudo apt install -y iverilog gtkwave yosys
	@echo "✅ Herramientas instaladas"

# Información del proyecto
info:
	@echo "AxiomaCore-328: Open Source AVR-Compatible Microcontroller"
	@echo "==========================================================="
	@echo "Arquitectura: AVR de 8 bits"
	@echo "Tecnología: SkyWater Sky130 PDK"
	@echo "Herramientas: 100% Open Source"
	@echo "Estado: Fase 1 - Núcleo básico"
	@echo ""
	@echo "Módulos implementados:"
	@echo "  ✅ AxiomaRegisters - Banco de 32 registros"
	@echo "  ✅ AxiomaALU - Unidad aritmético-lógica"
	@echo "  ✅ AxiomaDecoder - Decodificador de instrucciones"
	@echo "  ✅ AxiomaCPU - Núcleo principal"
	@echo ""
	@echo "Instrucciones soportadas:"
	@echo "  ✅ LDI, ADD, ADC, SUB, AND, OR, EOR, MOV"
	@echo "  ✅ CPI, RJMP, BREQ, BRNE"
	@echo ""