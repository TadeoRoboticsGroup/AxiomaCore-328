# AxiomaCore-328: Open Source AVR-Compatible Microcontroller

## Visión General

**AxiomaCore-328** es un microcontrolador de arquitectura abierta funcionalmente equivalente al ATmega328P, desarrollado completamente con herramientas libres y tecnología Sky130 PDK.

## Características Principales

- 🚀 **Núcleo AVR de 8 bits** - Compatible con instruction set AVR
- 💾 **32KB Flash + 2KB SRAM + 1KB EEPROM** - Memoria completa
- 🔌 **23 GPIO + PWM + ADC + UART + SPI + I2C** - Periféricos completos  
- ⚡ **Hasta 20 MHz** - Rendimiento comparable
- 🔋 **Modos de bajo consumo** - Eficiencia energética
- 🛠️ **100% herramientas libres** - Yosys + OpenLane + Sky130

## Arquitectura del Proyecto

```
axioma_core_328/
├── core/                    # Núcleo AxiomaCore-AVR8
│   ├── axioma_cpu/         # Unidad de procesamiento principal
│   ├── axioma_alu/         # Unidad aritmético-lógica
│   ├── axioma_registers/   # Banco de 32 registros
│   └── axioma_decoder/     # Decodificador de instrucciones
├── memory/                 # Subsistema de memoria
├── peripherals/            # Periféricos AxiomaCores
├── testbench/             # Verificación y testbenches
├── synthesis/             # Configuraciones de síntesis
└── docs/                  # Documentación técnica
```

## Estado de Desarrollo

### ✅ Fase 1: Infraestructura (Actual)
- [x] Estructura de proyecto
- [ ] AxiomaCore-CPU básico
- [ ] AxiomaALU
- [ ] AxiomaRegisters
- [ ] Framework de verificación

### 🔄 Próximas Fases
- **Fase 2**: Núcleo AVR completo
- **Fase 3**: Periféricos básicos  
- **Fase 4**: Periféricos avanzados
- **Fase 5**: Integración y optimización
- **Fase 6**: Tape-out final

## Quick Start

```bash
# Clonar repositorio
cd axioma_core_328/

# Compilar CPU básico
make cpu_basic

# Ejecutar testbench
make test_cpu

# Síntesis con OpenLane
make synthesize
```

## Herramientas Requeridas

- **Icarus Verilog** - Simulación RTL
- **GTKWave** - Visualización de ondas
- **Yosys** - Síntesis lógica
- **OpenLane** - Place & Route
- **Sky130 PDK** - Tecnología 130nm

## Compatibilidad

✅ **Arduino IDE** - Programación compatible  
✅ **avr-gcc** - Toolchain estándar AVR  
✅ **ATmega328P** - Pin-to-pin compatible  
✅ **Shields Arduino** - Hardware compatible  

## Licencia

**Apache 2.0** - Hardware abierto y libre

---

**AxiomaCore-328** - *El primer microcontrolador AVR completamente open source*