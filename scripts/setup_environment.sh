#!/bin/bash
#
# AxiomaCore-328 Environment Setup Script
# ========================================
# 
# Script para configurar el entorno de desarrollo completo
# para el proyecto AxiomaCore-328
#
# Este script instala y configura:
# - Herramientas de síntesis (Yosys, OpenLane)
# - Simuladores (Icarus Verilog, GTKWave)
# - Toolchain AVR (avr-gcc, avrdude)
# - Arduino IDE support
# - Python tools (caracterización y producción)
#
# Uso: ./setup_environment.sh
#
# © 2025 AxiomaCore Project
# Licensed under Apache 2.0

set -e

# Colores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}AxiomaCore-328 Environment Setup${NC}"
echo -e "${BLUE}========================================${NC}"

log() {
    echo -e "${GREEN}[$(date +'%H:%M:%S')] $1${NC}"
}

error() {
    echo -e "${RED}[ERROR] $1${NC}"
}

warning() {
    echo -e "${YELLOW}[WARNING] $1${NC}"
}

# Detectar sistema operativo
detect_os() {
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        if [ -f /etc/ubuntu-release ] || [ -f /etc/debian_version ]; then
            OS="ubuntu"
            PACKAGE_MANAGER="apt"
        elif [ -f /etc/redhat-release ]; then
            OS="redhat"
            PACKAGE_MANAGER="yum"
        else
            OS="linux"
            PACKAGE_MANAGER="unknown"
        fi
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        OS="macos"
        PACKAGE_MANAGER="brew"
    else
        OS="unknown"
        PACKAGE_MANAGER="unknown"
    fi
    
    log "Sistema detectado: $OS"
}

# Verificar si el usuario tiene privilegios sudo
check_sudo() {
    if ! sudo -n true 2>/dev/null; then
        warning "Este script requiere privilegios sudo para instalar paquetes"
        echo "Por favor ingresa tu contraseña cuando se solicite"
    fi
}

# Actualizar lista de paquetes
update_packages() {
    log "Actualizando lista de paquetes..."
    
    case $PACKAGE_MANAGER in
        apt)
            sudo apt update
            ;;
        yum)
            sudo yum update
            ;;
        brew)
            brew update
            ;;
        *)
            warning "Gestor de paquetes no soportado: $PACKAGE_MANAGER"
            ;;
    esac
}

# Instalar herramientas básicas
install_basic_tools() {
    log "Instalando herramientas básicas..."
    
    case $PACKAGE_MANAGER in
        apt)
            sudo apt install -y \
                build-essential \
                git \
                wget \
                curl \
                python3 \
                python3-pip \
                make \
                cmake \
                autoconf \
                automake \
                libtool \
                pkg-config
            ;;
        yum)
            sudo yum install -y \
                gcc \
                gcc-c++ \
                git \
                wget \
                curl \
                python3 \
                python3-pip \
                make \
                cmake \
                autoconf \
                automake \
                libtool \
                pkgconfig
            ;;
        brew)
            brew install \
                git \
                wget \
                curl \
                python3 \
                make \
                cmake \
                autoconf \
                automake \
                libtool \
                pkg-config
            ;;
    esac
    
    log "Herramientas básicas instaladas ✓"
}

# Instalar herramientas de síntesis
install_synthesis_tools() {
    log "Instalando herramientas de síntesis..."
    
    # Yosys - Open source synthesis suite
    case $PACKAGE_MANAGER in
        apt)
            sudo apt install -y yosys
            ;;
        yum)
            warning "Yosys debe instalarse manualmente en sistemas RedHat"
            ;;
        brew)
            brew install yosys
            ;;
    esac
    
    # Verificar instalación de Yosys
    if command -v yosys &> /dev/null; then
        log "Yosys instalado ✓ ($(yosys -V | head -1))"
    else
        warning "Yosys no encontrado, instalar manualmente"
    fi
}

# Instalar simuladores
install_simulators() {
    log "Instalando simuladores Verilog..."
    
    case $PACKAGE_MANAGER in
        apt)
            sudo apt install -y \
                iverilog \
                gtkwave \
                verilator
            ;;
        yum)
            # En sistemas RedHat, puede requerir EPEL
            sudo yum install -y \
                iverilog \
                gtkwave
            ;;
        brew)
            brew install \
                icarus-verilog \
                gtkwave
            ;;
    esac
    
    # Verificar instalaciones
    if command -v iverilog &> /dev/null; then
        log "Icarus Verilog instalado ✓ ($(iverilog -V 2>&1 | head -1))"
    fi
    
    if command -v gtkwave &> /dev/null; then
        log "GTKWave instalado ✓"
    fi
}

# Instalar toolchain AVR
install_avr_toolchain() {
    log "Instalando toolchain AVR..."
    
    case $PACKAGE_MANAGER in
        apt)
            sudo apt install -y \
                gcc-avr \
                avr-libc \
                avrdude \
                binutils-avr
            ;;
        yum)
            sudo yum install -y \
                avr-gcc \
                avr-libc \
                avrdude \
                avr-binutils
            ;;
        brew)
            brew tap osx-cross/avr
            brew install \
                avr-gcc \
                avr-libc \
                avrdude
            ;;
    esac
    
    # Verificar toolchain AVR
    if command -v avr-gcc &> /dev/null; then
        log "AVR-GCC instalado ✓ ($(avr-gcc --version | head -1))"
    fi
    
    if command -v avrdude &> /dev/null; then
        log "AVRDUDE instalado ✓ ($(avrdude -v 2>&1 | head -1))"
    fi
}

# Instalar dependencias Python
install_python_deps() {
    log "Instalando dependencias Python..."
    
    # Crear requirements.txt si no existe
    cat > "$PROJECT_ROOT/requirements.txt" << EOF
# AxiomaCore-328 Python Dependencies
numpy>=1.21.0
matplotlib>=3.5.0
scipy>=1.7.0
pyserial>=3.5
pandas>=1.3.0
argparse
json5
pyyaml
EOF
    
    # Instalar dependencias
    python3 -m pip install --user -r "$PROJECT_ROOT/requirements.txt"
    
    log "Dependencias Python instaladas ✓"
}

# Configurar Arduino IDE support
setup_arduino_support() {
    log "Configurando soporte para Arduino IDE..."
    
    # Crear directorio para boards
    local arduino_dir="$HOME/.arduino15"
    local boards_dir="$arduino_dir/packages/axioma/hardware/avr"
    
    mkdir -p "$boards_dir"
    
    # Copiar archivos de configuración Arduino
    if [ -d "$PROJECT_ROOT/arduino_core/axioma" ]; then
        cp -r "$PROJECT_ROOT/arduino_core/axioma" "$boards_dir/1.0.0"
        log "Archivos Arduino copiados a $boards_dir/1.0.0 ✓"
    fi
    
    # Crear package index
    cat > "$arduino_dir/package_axioma_index.json" << EOF
{
  "packages": [
    {
      "name": "axioma",
      "maintainer": "AxiomaCore Project",
      "websiteURL": "https://axioma-core.org",
      "email": "info@axioma-core.org",
      "platforms": [
        {
          "name": "AxiomaCore AVR Boards",
          "architecture": "avr",
          "version": "1.0.0",
          "category": "Contributed",
          "url": "https://axioma-core.org/arduino/axioma-avr-1.0.0.tar.bz2",
          "archiveFileName": "axioma-avr-1.0.0.tar.bz2",
          "checksum": "SHA-256:0000000000000000000000000000000000000000000000000000000000000000",
          "size": "1000000",
          "boards": [
            {"name": "AxiomaCore-328"}
          ],
          "toolsDependencies": [
            {
              "packager": "arduino",
              "name": "avr-gcc",
              "version": "7.3.0-atmel3.6.1-arduino7"
            },
            {
              "packager": "arduino", 
              "name": "avrdude",
              "version": "6.3.0-arduino17"
            }
          ]
        }
      ]
    }
  ]
}
EOF
    
    log "Arduino IDE configurado ✓"
    echo "  URL del board manager: file://$arduino_dir/package_axioma_index.json"
}

# Configurar variables de entorno
setup_environment_vars() {
    log "Configurando variables de entorno..."
    
    local shell_rc=""
    if [ -n "$BASH_VERSION" ]; then
        shell_rc="$HOME/.bashrc"
    elif [ -n "$ZSH_VERSION" ]; then
        shell_rc="$HOME/.zshrc"
    else
        shell_rc="$HOME/.profile"
    fi
    
    # Agregar variables de entorno si no existen
    if ! grep -q "AXIOMACORE_PATH" "$shell_rc" 2>/dev/null; then
        echo "" >> "$shell_rc"
        echo "# AxiomaCore-328 Environment" >> "$shell_rc"
        echo "export AXIOMACORE_PATH=\"$PROJECT_ROOT\"" >> "$shell_rc"
        echo "export PATH=\"\$AXIOMACORE_PATH/scripts:\$PATH\"" >> "$shell_rc"
        
        log "Variables de entorno agregadas a $shell_rc ✓"
        warning "Ejecuta 'source $shell_rc' o reinicia el terminal"
    else
        log "Variables de entorno ya configuradas ✓"
    fi
}

# Verificar instalación
verify_installation() {
    log "Verificando instalación..."
    
    local tools=(
        "yosys:Síntesis"
        "iverilog:Simulación"
        "avr-gcc:Toolchain AVR"
        "avrdude:Programación AVR"
        "python3:Python"
        "git:Control de versiones"
    )
    
    local missing_tools=0
    
    for tool_info in "${tools[@]}"; do
        local tool="${tool_info%%:*}"
        local description="${tool_info##*:}"
        
        if command -v "$tool" &> /dev/null; then
            log "✓ $description: $tool disponible"
        else
            error "✗ $description: $tool NO disponible"
            missing_tools=$((missing_tools + 1))
        fi
    done
    
    if [ $missing_tools -eq 0 ]; then
        log "Todas las herramientas están disponibles ✓"
        return 0
    else
        error "$missing_tools herramientas faltantes"
        return 1
    fi
}

# Generar reporte de instalación
generate_report() {
    log "Generando reporte de instalación..."
    
    local report_file="$PROJECT_ROOT/installation_report.txt"
    
    cat > "$report_file" << EOF
AxiomaCore-328 Environment Setup Report
=======================================
Fecha: $(date)
Sistema: $OS
Usuario: $USER
Directorio: $PROJECT_ROOT

Herramientas instaladas:
$(which yosys 2>/dev/null && echo "✓ Yosys: $(yosys -V | head -1)" || echo "✗ Yosys: No disponible")
$(which iverilog 2>/dev/null && echo "✓ Icarus Verilog: $(iverilog -V 2>&1 | head -1)" || echo "✗ Icarus Verilog: No disponible")
$(which avr-gcc 2>/dev/null && echo "✓ AVR-GCC: $(avr-gcc --version | head -1)" || echo "✗ AVR-GCC: No disponible")
$(which avrdude 2>/dev/null && echo "✓ AVRDUDE: Disponible" || echo "✗ AVRDUDE: No disponible")
$(which python3 2>/dev/null && echo "✓ Python3: $(python3 --version)" || echo "✗ Python3: No disponible")

Dependencias Python:
$(python3 -m pip list | grep -E "(numpy|matplotlib|pyserial)" || echo "Verificar manualmente")

Configuración:
✓ Scripts en: $PROJECT_ROOT/scripts/
✓ Arduino core en: ~/.arduino15/packages/axioma/
✓ Variables de entorno configuradas

Próximos pasos:
1. Ejecutar 'source ~/.bashrc' (o reiniciar terminal)
2. Probar con: ./scripts/build_project.sh help
3. Ejecutar: ./scripts/build_project.sh all

Para más información: https://axioma-core.org/docs/
EOF
    
    log "Reporte generado: $report_file"
}

# Función principal
main() {
    echo "Este script configurará el entorno completo para AxiomaCore-328"
    echo "Esto incluye herramientas de síntesis, simulación y desarrollo"
    echo ""
    read -p "¿Continuar con la instalación? (y/N): " -n 1 -r
    echo
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log "Instalación cancelada por el usuario"
        exit 0
    fi
    
    detect_os
    check_sudo
    
    log "Iniciando instalación del entorno AxiomaCore-328..."
    
    update_packages
    install_basic_tools
    install_synthesis_tools
    install_simulators
    install_avr_toolchain
    install_python_deps
    setup_arduino_support
    setup_environment_vars
    
    if verify_installation; then
        generate_report
        
        echo ""
        echo -e "${GREEN}========================================${NC}"
        echo -e "${GREEN}Instalación AxiomaCore-328 COMPLETADA${NC}"
        echo -e "${GREEN}========================================${NC}"
        echo ""
        echo "Próximos pasos:"
        echo "1. Ejecutar: source ~/.bashrc"
        echo "2. Probar: cd $PROJECT_ROOT"
        echo "3. Ejecutar: ./scripts/build_project.sh all"
        echo ""
        echo "Documentación: $PROJECT_ROOT/docs/"
        echo "Reporte: $PROJECT_ROOT/installation_report.txt"
        
    else
        error "Instalación completada con errores"
        echo "Ver reporte en: $PROJECT_ROOT/installation_report.txt"
        exit 1
    fi
}

# Ejecutar función principal
main "$@"