 <!-- Este es el requerimiento oficial del proyecyo no modificar ni borrar -->
# Requerimiento para Desarrollo del Microcontrolador AxiomaCore-328 con Herramientas Libres

## 1. Objetivo General

Desarrollar **AxiomaCore-328**, un microcontrolador de arquitectura abierta con características funcionalmente equivalentes al ATmega 328P utilizando exclusivamente herramientas de diseño libre y tecnología de proceso madura, implementando un flujo completo desde RTL hasta layout físico.

## 2. Especificaciones Técnicas Base (AxiomaCore-328)

### 2.1 Núcleo de Procesamiento
- **Arquitectura**: AVR de 8 bits compatible a nivel de instrucciones
- **Nombre del core**: AxiomaCore-AVR8
- **Frecuencia**: Hasta 20 MHz con cristal externo, 8 MHz con oscilador interno
- **Pipeline**: Arquitectura Harvard modificada con pipeline de 2 etapas
- **Conjunto de instrucciones**: 131 instrucciones, mayoría ejecutadas en 1 ciclo de reloj
- **Registros**: 32 registros de propósito general de 8 bits

### 2.2 Memoria
- **Flash Program Memory**: 32 KB (16K x 16 bits)
- **SRAM**: 2 KB para datos
- **EEPROM**: 1 KB no volátil para parámetros
- **Bootloader**: Sección programable vía UART (AxiomaBoot)

### 2.3 Periféricos Requeridos
- **GPIO**: 23 pines digitales configurables (AxiomaGPIO)
- **PWM**: 6 canales PWM de 8 bits (AxiomaPWM)
- **ADC**: 8 canales de 10 bits, referencia interna/externa (AxiomaADC)
- **UART**: Comunicación serie full-duplex (AxiomaUART)
- **SPI**: Interfaz serie síncrona maestro/esclavo (AxiomaSPI)
- **I2C (TWI)**: Bus de comunicación de 2 hilos (AxiomaI2C)
- **Timers**: 2 timers de 8 bits + 1 timer de 16 bits (AxiomaTimer)
- **Interrupciones**: Sistema vectorizado con 26 fuentes (AxiomaIRQ)

### 2.4 Características de Alimentación
- **Voltaje de operación**: 1.8V - 5.5V
- **Consumo activo**: < 1.5 mA @ 3V, 4MHz
- **Modo sleep**: < 1 µA @ 3V
- **Modos de bajo consumo**: Idle, ADC Noise Reduction, Power-down, Power-save

## 3. Herramientas y Tecnologías

### 3.1 Herramientas de Diseño Digital
- **HDL**: Verilog/SystemVerilog para descripción RTL
- **Simulación**: Icarus Verilog + GTKWave para verificación funcional
- **Síntesis**: Yosys para síntesis lógica
- **Place & Route**: OpenLane (integra OpenROAD, Magic, Netgen)
- **Layout**: KLayout para visualización y edición de layout
- **Verificación**: Magic DRC/LVS, Netgen para LVS

### 3.2 Tecnología de Proceso
- **PDK**: SkyWater Sky130 (130nm, tecnología madura y abierta)
- **Librerías estándar**: sky130_fd_sc_hd (high density standard cells)
- **Memoria**: Compiladores de memoria Sky130 SRAM/ROM
- **I/O**: Librerías de pads Sky130

### 3.3 Herramientas Auxiliares
- **Control de versiones**: Git para gestión de código
- **Automatización**: Makefiles y scripts Python/Bash
- **Documentación**: Markdown/LaTeX para especificaciones
- **Gestión**: Metodología ágil con sprints de 2 semanas

## 4. Arquitectura de Implementación

### 4.1 Jerarquía de Módulos
```
axioma_core_328/
├── core/                    # Núcleo AxiomaCore-AVR8
│   ├── axioma_cpu/         # Unidad de procesamiento
│   ├── axioma_alu/         # Unidad aritmético-lógica
│   ├── axioma_registers/   # Banco de registros
│   └── axioma_decoder/     # Decodificador de instrucciones
├── memory/                 # Subsistema de memoria
│   ├── axioma_flash_ctrl/  # Controlador Flash
│   ├── axioma_sram_ctrl/   # Controlador SRAM
│   └── axioma_eeprom_ctrl/ # Controlador EEPROM
├── peripherals/            # Periféricos AxiomaCores
│   ├── axioma_gpio/        # Puertos de E/S
│   ├── axioma_uart/        # UART
│   ├── axioma_spi/         # SPI
│   ├── axioma_i2c/         # I2C/TWI
│   ├── axioma_adc/         # Conversor A/D
│   ├── axioma_timers/      # Timers/Contadores
│   └── axioma_pwm/         # Generadores PWM
├── clock_reset/            # Gestión de reloj y reset
├── axioma_interrupt/       # Controlador de interrupciones
└── axioma_boot/           # Bootloader integrado
```

### 4.2 Flujo de Diseño AxiomaFlow
1. **Especificación RTL** → Verilog modular y sintetizable
2. **Verificación funcional** → Testbenches con Icarus + GTKWave
3. **Síntesis** → Yosys con optimización para área/potencia
4. **Place & Route** → OpenLane con Sky130 PDK
5. **Verificación física** → DRC/LVS con Magic/Netgen
6. **Post-layout** → Simulación con delays extraídos

## 5. Plan de Desarrollo

### 5.1 Fase 1: Infraestructura AxiomaFlow (4 semanas)
- Configuración del entorno OpenLane + Sky130
- Framework de verificación AxiomaVerify
- Scripts de automatización AxiomaBuild
- Diseño de la unidad de procesamiento básica AxiomaCore-CPU
- Banco de registros y ALU básica

### 5.2 Fase 2: Núcleo AxiomaCore-AVR8 (8 semanas)
- Implementación completa del set de instrucciones AVR
- Controlador de memoria Flash/SRAM
- Sistema de interrupciones AxiomaIRQ
- Verificación del núcleo con programas de prueba

### 5.3 Fase 3: Periféricos Básicos (6 semanas)
- AxiomaGPIO con configuración digital
- AxiomaUART para comunicación serie
- AxiomaTimer básico de 8 bits
- Sistema de clock y reset

### 5.4 Fase 4: Periféricos Avanzados (8 semanas)
- AxiomaSPI e AxiomaI2C
- AxiomaADC de 10 bits
- AxiomaTimers avanzados y AxiomaPWM
- EEPROM y AxiomaBoot bootloader

### 5.5 Fase 5: Integración y Optimización (6 semanas)
- Integración completa del sistema AxiomaCore-328
- Optimización de área y potencia
- Verificación completa del sistema
- Modos de bajo consumo AxiomaSleep

### 5.6 Fase 6: Tape-out (4 semanas)
- Place & Route final con OpenLane
- Verificación DRC/LVS completa
- Generación de archivos GDSII
- Documentación final y AxiomaSDK

## 6. Criterios de Verificación

### 6.1 Verificación Funcional
- **Compatibilidad de instrucciones**: 100% del set AVR implementado
- **AxiomaBench**: Suite de programas de benchmark específicos
- **Periféricos**: Verificación individual de cada AxiomaPeriférico
- **Interrupciones**: Latencia y anidamiento correcto de AxiomaIRQ

### 6.2 Verificación Física
- **DRC**: 0 violaciones de reglas de diseño
- **LVS**: Correspondencia exacta netlist vs layout
- **Timing**: Cumplimiento de constraints a 20 MHz
- **Power**: Estimación dentro de rango objetivo

### 6.3 Verificación de Sistema
- **AxiomaBoot**: Programación vía UART funcional
- **Compatibilidad**: Ejecutar código Arduino con AxiomaCore
- **Consumo**: Modos AxiomaSleep verificados
- **Robustez**: Operación en rango completo de voltaje/temperatura

## 7. Entregables

### 7.1 Código RTL
- Código Verilog AxiomaCore-328 completo y documentado
- AxiomaTestbench: Suite comprensiva de testbenches
- AxiomaBuild: Scripts de síntesis y P&R
- Constraints de timing y área

### 7.2 Documentación
- **AxiomaCore-328 Technical Reference Manual**
- **AxiomaCore Programming Guide** (instruction set)
- **AxiomaFlow Verification Manual**
- **AxiomaTools User Guide**

### 7.3 Layout Físico
- Archivos GDSII AxiomaCore-328 listos para fabricación
- Reportes de DRC/LVS
- Análisis de timing post-layout
- Estimaciones de área y potencia

### 7.4 AxiomaSDK
- AxiomaFlow: Flow automatizado completo
- AxiomaVerify: Scripts de verificación
- AxiomaDev: Ambiente de desarrollo reproducible
- Documentación de setup completa

## 8. Consideraciones Técnicas

### 8.1 Limitaciones de Sky130
- Tecnología de 130nm (mayor área vs procesos avanzados)
- Voltaje mínimo ~1.8V (vs 1.8V-5.5V original)
- Limitaciones en bloques analógicos complejos para AxiomaADC
- Adaptación de especificaciones de timing

### 8.2 Estrategias de Mitigación
- Optimización agresiva de área en síntesis AxiomaCore
- Uso eficiente de celdas estándar disponibles
- Implementación cuidadosa del AxiomaADC con limitaciones del proceso
- Verificación extensiva con AxiomaVerify

### 8.3 Innovaciones AxiomaCore
- Arquitectura más modular que el original ATmega328P
- AxiomaDebug: Capacidades de debug integradas mejoradas
- Interfaces opcionales futuras (AxiomaUSB, AxiomaCAN)
- Mejor eficiencia energética con AxiomaPower management

## 9. Métricas de Éxito

### 9.1 Funcionales
- ✅ Ejecución correcta del 100% del instruction set AVR en AxiomaCore
- ✅ Compatibilidad con toolchain Arduino/avr-gcc
- ✅ Funcionamiento de todos los AxiomaPeriféricos especificados
- ✅ Velocidad mínima 16 MHz garantizada

### 9.2 Físicas
- ✅ Área total < 4 mm² en Sky130
- ✅ 0 violaciones DRC/LVS
- ✅ Consumo comparable al original (escalado por proceso)
- ✅ Yield estimado > 90%

### 9.3 Metodológicas
- ✅ 100% herramientas open source con AxiomaFlow
- ✅ Proceso reproducible y documentado
- ✅ Código RTL sintetizable y portable
- ✅ Verificación completa y automatizada con AxiomaVerify

## 10. Roadmap AxiomaCore

### 10.1 AxiomaCore-328 (Actual)
- Compatible ATmega328P con herramientas libres
- Sky130 PDK, funcionalidad completa base

### 10.2 AxiomaCore-328+ (Futuro)
- Funcionalidades adicionales (USB, CAN, Ethernet)
- Mejor performance y menor consumo
- Proceso más avanzado (Sky90 cuando esté disponible)

### 10.3 AxiomaCore-32 (Visión)
- Arquitectura RISC-V de 32 bits
- Compatibilidad con ecosistema ARM Cortex-M
- Mantener filosofía de herramientas 100% libres

---

**AxiomaCore-328** representa un hito significativo para la comunidad de hardware abierto: el primer microcontrolador completamente desarrollado con herramientas libres, compatible con el ecosistema Arduino/AVR, estableciendo las bases para una nueva generación de microcontroladores abiertos y accesibles.