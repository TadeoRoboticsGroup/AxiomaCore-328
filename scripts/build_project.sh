#!/bin/bash
#
# AxiomaCore-328 Build Script
# ============================
# 
# Script de construcción automatizado para el proyecto AxiomaCore-328
# Incluye síntesis, simulación, verificación y generación de reportes
#
# Uso:
#   ./build_project.sh [target]
#
# Targets disponibles:
#   - synthesis: Solo síntesis con Yosys
#   - simulation: Solo simulación con testbenches
#   - all: Síntesis y simulación completa
#   - clean: Limpieza de archivos temporales
#   - test: Ejecutar suite de pruebas
#
# © 2025 AxiomaCore Project
# Licensed under Apache 2.0

set -e  # Exit on any error

# Colores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuración del proyecto
PROJECT_NAME="AxiomaCore-328"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$PROJECT_ROOT/build"
LOG_DIR="$BUILD_DIR/logs"

# Herramientas requeridas
YOSYS_BIN="yosys"
IVERILOG_BIN="iverilog"
VVP_BIN="vvp"
GTKWAVE_BIN="gtkwave"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}AxiomaCore-328 Build System${NC}"
echo -e "${BLUE}========================================${NC}"

# Función para logging
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

error() {
    echo -e "${RED}[ERROR] $1${NC}"
}

warning() {
    echo -e "${YELLOW}[WARNING] $1${NC}"
}

# Verificar herramientas
check_tools() {
    log "Verificando herramientas requeridas..."
    
    if ! command -v $YOSYS_BIN &> /dev/null; then
        error "Yosys no encontrado. Instalar con: sudo apt install yosys"
        exit 1
    fi
    
    if ! command -v $IVERILOG_BIN &> /dev/null; then
        error "Icarus Verilog no encontrado. Instalar con: sudo apt install iverilog"
        exit 1
    fi
    
    log "Todas las herramientas están disponibles ✓"
}

# Crear directorios de build
setup_build_dirs() {
    log "Configurando directorios de build..."
    mkdir -p "$BUILD_DIR"
    mkdir -p "$LOG_DIR"
    mkdir -p "$BUILD_DIR/synthesis"
    mkdir -p "$BUILD_DIR/simulation"
    mkdir -p "$BUILD_DIR/reports"
}

# Síntesis con Yosys
run_synthesis() {
    log "Iniciando síntesis con Yosys..."
    
    cd "$PROJECT_ROOT"
    
    # Ejecutar síntesis
    $YOSYS_BIN synthesis/axioma_syn.ys > "$LOG_DIR/synthesis.log" 2>&1
    
    if [ $? -eq 0 ]; then
        log "Síntesis completada exitosamente ✓"
        
        # Mover resultados
        if [ -f "axioma_core_328.v" ]; then
            mv axioma_core_328.v "$BUILD_DIR/synthesis/"
        fi
        
        if [ -f "axioma_core_328.json" ]; then
            mv axioma_core_328.json "$BUILD_DIR/synthesis/"
        fi
        
        # Generar estadísticas
        generate_synthesis_report
    else
        error "Síntesis falló. Ver log: $LOG_DIR/synthesis.log"
        return 1
    fi
}

# Generar reporte de síntesis
generate_synthesis_report() {
    log "Generando reporte de síntesis..."
    
    cat > "$BUILD_DIR/reports/synthesis_report.txt" << EOF
AxiomaCore-328 Synthesis Report
===============================
Fecha: $(date)
Herramienta: Yosys
Target: Sky130 PDK

Archivos procesados:
$(grep -c "\.v" synthesis/axioma_syn.ys) archivos Verilog

Estadísticas:
$(tail -20 "$LOG_DIR/synthesis.log" | grep -E "(cells|wires|processes)")

Estado: EXITOSO
EOF

    log "Reporte de síntesis generado ✓"
}

# Ejecutar simulaciones
run_simulation() {
    log "Iniciando simulaciones..."
    
    cd "$PROJECT_ROOT/testbench"
    
    # Lista de testbenches
    testbenches=(
        "axioma_cpu_tb"
        "axioma_cpu_v2_tb" 
        "axioma_cpu_v3_tb"
        "axioma_cpu_v4_tb"
    )
    
    local failed_tests=0
    
    for tb in "${testbenches[@]}"; do
        log "Ejecutando testbench: $tb"
        
        # Compilar testbench
        $IVERILOG_BIN -o "$BUILD_DIR/simulation/${tb}" \
            -I../core/axioma_cpu/ \
            -I../core/axioma_alu/ \
            -I../core/axioma_decoder/ \
            -I../core/axioma_registers/ \
            "${tb}.v" \
            ../core/**/*.v > "$LOG_DIR/${tb}_compile.log" 2>&1
        
        if [ $? -eq 0 ]; then
            # Ejecutar simulación
            cd "$BUILD_DIR/simulation"
            $VVP_BIN "${tb}" > "$LOG_DIR/${tb}_sim.log" 2>&1
            
            if [ $? -eq 0 ]; then
                log "✓ $tb: PASS"
                
                # Mover archivos VCD si existen
                if [ -f "${tb}.vcd" ]; then
                    mv "${tb}.vcd" "$BUILD_DIR/simulation/"
                fi
            else
                error "✗ $tb: FAIL"
                failed_tests=$((failed_tests + 1))
            fi
            cd "$PROJECT_ROOT/testbench"
        else
            error "✗ $tb: COMPILATION FAILED"
            failed_tests=$((failed_tests + 1))
        fi
    done
    
    if [ $failed_tests -eq 0 ]; then
        log "Todas las simulaciones pasaron ✓"
        generate_simulation_report $failed_tests ${#testbenches[@]}
        return 0
    else
        error "$failed_tests de ${#testbenches[@]} simulaciones fallaron"
        generate_simulation_report $failed_tests ${#testbenches[@]}
        return 1
    fi
}

# Generar reporte de simulación
generate_simulation_report() {
    local failed=$1
    local total=$2
    local passed=$((total - failed))
    
    log "Generando reporte de simulación..."
    
    cat > "$BUILD_DIR/reports/simulation_report.txt" << EOF
AxiomaCore-328 Simulation Report
================================
Fecha: $(date)
Herramienta: Icarus Verilog

Resultados:
- Total testbenches: $total
- Pasaron: $passed
- Fallaron: $failed
- Tasa de éxito: $(( (passed * 100) / total ))%

Testbenches ejecutados:
- axioma_cpu_tb: $([ -f "$LOG_DIR/axioma_cpu_tb_sim.log" ] && echo "EJECUTADO" || echo "NO EJECUTADO")
- axioma_cpu_v2_tb: $([ -f "$LOG_DIR/axioma_cpu_v2_tb_sim.log" ] && echo "EJECUTADO" || echo "NO EJECUTADO")
- axioma_cpu_v3_tb: $([ -f "$LOG_DIR/axioma_cpu_v3_tb_sim.log" ] && echo "EJECUTADO" || echo "NO EJECUTADO")
- axioma_cpu_v4_tb: $([ -f "$LOG_DIR/axioma_cpu_v4_tb_sim.log" ] && echo "EJECUTADO" || echo "NO EJECUTADO")

Archivos VCD generados en: $BUILD_DIR/simulation/
Logs disponibles en: $LOG_DIR/

Estado: $([ $failed -eq 0 ] && echo "EXITOSO" || echo "CON ERRORES")
EOF

    log "Reporte de simulación generado ✓"
}

# Ejecutar suite de pruebas Arduino
run_arduino_tests() {
    log "Ejecutando pruebas de compatibilidad Arduino..."
    
    if [ -d "$PROJECT_ROOT/test_programs/arduino_compatibility" ]; then
        # Verificar sintaxis de archivos .ino
        local ino_files=(
            "test_basic_functions.ino"
            "test_communication_protocols.ino"
        )
        
        local test_passed=0
        
        for ino in "${ino_files[@]}"; do
            if [ -f "$PROJECT_ROOT/test_programs/arduino_compatibility/$ino" ]; then
                # Verificación básica de sintaxis Arduino
                if grep -q "void setup()" "$PROJECT_ROOT/test_programs/arduino_compatibility/$ino" && \
                   grep -q "void loop()" "$PROJECT_ROOT/test_programs/arduino_compatibility/$ino"; then
                    log "✓ $ino: Sintaxis Arduino válida"
                    test_passed=$((test_passed + 1))
                else
                    error "✗ $ino: Sintaxis Arduino inválida"
                fi
            else
                warning "$ino no encontrado"
            fi
        done
        
        log "Pruebas Arduino: $test_passed de ${#ino_files[@]} pasaron"
    else
        warning "Directorio de pruebas Arduino no encontrado"
    fi
}

# Limpiar archivos temporales
clean_build() {
    log "Limpiando archivos temporales..."
    
    # Remover directorio de build
    if [ -d "$BUILD_DIR" ]; then
        rm -rf "$BUILD_DIR"
        log "Directorio build removido ✓"
    fi
    
    # Remover archivos temporales en el proyecto
    find "$PROJECT_ROOT" -name "*.vcd" -delete
    find "$PROJECT_ROOT" -name "*.out" -delete
    find "$PROJECT_ROOT" -name "*.log" -delete
    
    log "Limpieza completada ✓"
}

# Mostrar ayuda
show_help() {
    echo "Uso: $0 [target]"
    echo ""
    echo "Targets disponibles:"
    echo "  synthesis   - Ejecutar síntesis con Yosys"
    echo "  simulation  - Ejecutar simulaciones con testbenches"
    echo "  arduino     - Verificar compatibilidad Arduino"
    echo "  all         - Ejecutar síntesis, simulación y pruebas"
    echo "  clean       - Limpiar archivos temporales"
    echo "  help        - Mostrar esta ayuda"
    echo ""
    echo "Ejemplos:"
    echo "  $0 all           # Build completo"
    echo "  $0 synthesis     # Solo síntesis"
    echo "  $0 simulation    # Solo simulación"
    echo "  $0 clean         # Limpiar"
}

# Función principal
main() {
    local target="${1:-all}"
    
    case $target in
        synthesis)
            check_tools
            setup_build_dirs
            run_synthesis
            ;;
        simulation)
            check_tools
            setup_build_dirs
            run_simulation
            ;;
        arduino)
            setup_build_dirs
            run_arduino_tests
            ;;
        all)
            check_tools
            setup_build_dirs
            log "Ejecutando build completo..."
            
            if run_synthesis; then
                if run_simulation; then
                    run_arduino_tests
                    log "Build completo exitoso ✓"
                    
                    # Resumen final
                    echo ""
                    echo -e "${GREEN}========================================${NC}"
                    echo -e "${GREEN}Build AxiomaCore-328 COMPLETADO${NC}"
                    echo -e "${GREEN}========================================${NC}"
                    echo -e "Resultados en: $BUILD_DIR"
                    echo -e "Logs en: $LOG_DIR"
                    echo -e "Reportes en: $BUILD_DIR/reports"
                else
                    error "Simulación falló"
                    exit 1
                fi
            else
                error "Síntesis falló"
                exit 1
            fi
            ;;
        clean)
            clean_build
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            error "Target desconocido: $target"
            show_help
            exit 1
            ;;
    esac
}

# Ejecutar función principal
main "$@"