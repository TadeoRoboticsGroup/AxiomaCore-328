<!-- Requerimiento oficial del proyecto AxiomaCore-328 · v2.0 · 8 de septiembre de 2026
     La v1.0 se conserva sin modificar en docs/requerimiento-v1-original.md
     Esta revisión NO cambia los objetivos del proyecto: los hace verificables y
     corrige las premisas que la investigación técnica demostró inalcanzables. -->

# Requerimiento oficial — AxiomaCore-328

**Versión 2.0** · 8 de septiembre de 2026
**Sustituye a:** v1.0 (preservada en [`docs/requerimiento-v1-original.md`](docs/requerimiento-v1-original.md))
**Plan de ejecución:** [`docs/00-PLAN.md`](docs/00-PLAN.md)

---

## 0. Qué cambia respecto a la v1.0 y por qué

La v1.0 fijó bien el destino. Esta revisión corrige cuatro premisas que la investigación técnica
demostró inviables tal como estaban escritas, y convierte los objetivos en criterios medibles.

| Punto de la v1.0 | Problema detectado | Cómo queda en la v2.0 |
|------------------|--------------------|-----------------------|
| «Flash Program Memory: 32 KB» sobre PDK Sky130 | **Sky130 no tiene memoria no volátil embebida.** No existe IP de Flash ni de EEPROM en el PDK abierto. | La memoria de programa es SRAM en silicio, cargada al arranque desde Flash QSPI externa (*shadow RAM*). En FPGA es BRAM. La abstracción de backend es obligatoria desde el día 1. |
| «Voltaje de operación 1,8 V – 5,5 V» | Sky130 es 1,8 V de núcleo y 3,3 V de I/O. Los 5 V no son alcanzables en el die. | La compatibilidad eléctrica se traslada al **módulo** (level shifters en la PCB). El die se especifica a 1,8 V / 3,3 V. |
| «Consumo activo < 1,5 mA @ 3V, 4 MHz» y «sleep < 1 µA» | Son cifras del ATmega328P en un proceso optimizado para bajo consumo. En Sky130 a 130 nm sin bibliotecas de baja fuga no son alcanzables ni verificables sin silicio. | Se retiran como requisito y se sustituyen por *medición y caracterización tras el tape-out*. |
| «ADC de 8 canales, 10 bits» | Un ADC es un bloque **analógico**. No se describe en Verilog ni lo sintetiza una cadena digital. | Se especifica el **controlador SAR digital** con interfaz a comparador. El comparador es externo en la primera versión de silicio; integrarlo es un proyecto propio. |

Todo lo demás de la v1.0 se mantiene.

---

## 1. Objetivo general

Desarrollar **AxiomaCore-328**, un microcontrolador de arquitectura abierta funcionalmente
equivalente al ATmega328P, utilizando **exclusivamente herramientas de diseño libre**, con un flujo
completo desde RTL hasta layout físico y validación en FPGA comercial de toolchain abierta.

El proyecto se publica bajo licencia libre y se desarrolla en régimen **clean-room**: la
implementación parte de documentación pública del conjunto de instrucciones, sin copiar RTL,
layouts ni texto de datasheet de terceros.

---

## 2. Contrato de compatibilidad

El requisito «compatible con el ATmega328P» se descompone en cuatro niveles, tres de los cuales son
obligatorios.

| Nivel | Requisito | Obligatorio | Verificación |
|-------|-----------|-------------|--------------|
| **L1 — Binaria / ISA** | Ejecuta código máquina AVR de 8 bits: 131 instrucciones, semántica exacta del SREG, PC de 14 bits, stack e interrupciones. | **Sí** | Co-simulación diferencial contra `simavr`, instrucción a instrucción |
| **L2 — Mapa de registros** | Mismas direcciones, nombres y semántica de bits que el ATmega328P. `avr/io.h` con `-mmcu=atmega328p` funciona sin modificación. | **Sí** | Mapa generado desde `iom328p.h` de avr-libc + test de diferencias en CI |
| **L3 — Ciclos** | Misma cuenta de ciclos por instrucción y misma temporización de periféricos. | **Sí** | Tabla de ciclos del manual del ISA codificada como test |
| **L4 — Eléctrica y pinout** | 5 V, DIP-28 con el mismo orden de patillas. | **No a nivel de die** | Se satisface a nivel de **módulo** (fase 7) |

---

## 3. Especificaciones técnicas

### 3.1 Núcleo de procesamiento

- Arquitectura AVR de 8 bits, compatible a nivel de instrucciones. Nombre del core: **AxiomaCore-AVR8**.
- Harvard con pipeline de **2 etapas** (IF · ID/EX/WB) y secuenciador para instrucciones multiciclo.
- Conjunto de **131 instrucciones**; la mayoría en 1 ciclo.
- **32 registros** de propósito general de 8 bits (R0–R31) más los punteros X/Y/Z.
- Frecuencia: 8/16/20/25 MHz seleccionable. **Objetivo de cierre de timing en FPGA: ≥ 32 MHz** en
  Lattice ECP5.

### 3.2 Memoria

- **Programa:** 32 KB (16K × 16 bits). PC de 14 bits.
- **SRAM de datos:** 2 KB. Espacio de datos **unificado** `0x0000–0x08FF`:
  registros `0x0000–0x001F` · I/O estándar `0x0020–0x005F` · I/O extendida `0x0060–0x00FF` ·
  SRAM `0x0100–0x08FF`. RAMEND = `0x08FF`.
- **EEPROM:** 1 KB, con la máquina de estados de `EECR`.
- **Bootloader:** sección programable vía UART (**AxiomaBoot**), con soporte de `SPM`.

**Requisito de implementación (nuevo y obligatorio):** las tres memorias se describen tras una
interfaz única con **backend intercambiable en tiempo de compilación** — `sim`, `fpga_bram` y
`sky130_sram`. Ninguna memoria se describe como array conductual en el RTL de producción.

### 3.3 Periféricos

| Periférico | Requisito |
|------------|-----------|
| **AxiomaGPIO** | 23 pines en 3 puertos (B/C/D). Incluye escritura a `PINx` como *toggle* de `PORTx`. |
| **AxiomaTimer** | Timer0 y Timer2 de 8 bits, Timer1 de 16 bits. Timer1 **debe** implementar el registro TEMP de acceso de 16 bits. |
| **AxiomaPWM** | 6 canales, modos Fast PWM y Phase-Correct. |
| **AxiomaUART** | USART full-duplex con generador de baudios derivado de F_CPU. |
| **AxiomaSPI** | Maestro/esclavo, los 4 modos de reloj. |
| **AxiomaI2C** | TWI multi-maestro con arbitraje. |
| **AxiomaADC** | Controlador SAR de 10 bits, 8 canales, con interfaz a comparador. El comparador es externo en la primera versión de silicio. |
| **AxiomaIRQ** | 26 vectores con prioridad fija por orden numérico. |
| Comparador analógico, watchdog, INT0/INT1, PCINT0/1/2 | Según el mapa de registros del ATmega328P. |

### 3.4 Alimentación y consumo

- **Die:** 1,8 V de núcleo, 3,3 V de I/O (impuesto por Sky130).
- **Módulo:** 5 V mediante level shifters, para compatibilidad con placas Arduino.
- Modos de bajo consumo: Idle, ADC Noise Reduction, Power-down, Power-save (vía `SMCR`), más `PRR`
  y `CLKPR`.
- Las cifras de consumo se **miden tras el tape-out**; no se especifican a priori.

---

## 4. Herramientas y tecnologías

Todas libres. Ninguna herramienta propietaria en ninguna etapa.

| Etapa | Herramienta |
|-------|-------------|
| HDL | Verilog-2005 |
| Simulación | Icarus Verilog · Verilator |
| Testbenches | cocotb (Python) |
| **Oráculo de verificación** | **simavr** |
| Compilación de programas de test | avr-gcc · avr-libc |
| Síntesis | Yosys |
| Place & route (FPGA) | nextpnr + prjtrellis (ECP5), icestorm (iCE40), apicula (Gowin) |
| Carga de bitstream | openFPGALoader |
| Verificación formal | SymbiYosys |
| RTL → GDSII | **LibreLane 3.x** (sucesor de OpenLane, bajo la FOSSi Foundation) |
| PDK | SkyWater **Sky130A**, biblioteca `sky130_fd_sc_hd`, gestionado con `ciel` |
| Memorias ASIC | Macros `sky130_sram_*` |
| DRC / LVS | Magic · Netgen · KLayout |
| PCB | KiCad |

---

## 5. Plataforma de validación en FPGA

Objetivo primario: **Lattice ECP5** (ULX3S 25F o Colorlight 5A-75B). Objetivos secundarios:
iCE40 UP5K y Gowin GW1NR-9. El SoC es idéntico en las tres; sólo cambian el top y los constraints.

---

## 6. Requisitos de verificación

Regla del proyecto: **ningún bloque se da por bueno sin un oráculo independiente.**

1. **Diferencial contra simavr** tras cada instrucción retirada (PC, R0–R31, SREG, SP).
2. **ALU exhaustiva:** ~2,6 millones de vectores contra un modelo de referencia independiente.
3. **Exactitud de ciclos** contra la tabla del manual del ISA.
4. **Mapa de registros** generado y comprobado contra `iom328p.h`.
5. **Suite de sketches de Arduino** reales, NeoPixel incluido.
6. **Formal** sobre propiedades acotadas.

---

## 7. Criterios de aceptación de la v1.0

Todos automáticamente verificables. Un requisito que no se puede medir no es un requisito.

| # | Criterio | Umbral |
|---|----------|--------|
| 1 | Instrucciones que pasan el diferencial contra simavr | 131 / 131 |
| 2 | Divergencias en la regresión aleatoria | 0 en 10⁷ instrucciones |
| 3 | Cobertura exhaustiva de la ALU | 100 % |
| 4 | Desviaciones respecto a la tabla de ciclos | 0 |
| 5 | Diferencias del mapa de registros contra `iom328p.h` | 0 |
| 6 | Vectores de interrupción verificados | 26 / 26 |
| 7 | Sketches de Arduino que corren sin modificar | ≥ 10, NeoPixel incluido |
| 8 | Frecuencia máxima en ECP5 | ≥ 32 MHz |
| 9 | Subida desde Arduino IDE de extremo a extremo | Funcional |
| 10 | Herramientas propietarias en la cadena | 0 |

**Criterio de aceptación de la v2.0 (silicio):** GDSII con DRC y LVS limpios, netlist post-layout
pasando el diferencial contra simavr con retardos anotados, y chips recibidos y caracterizados.

---

## 8. Requisitos legales y de licencia

De obligado cumplimiento. Desarrollo en régimen **clean-room** según [`docs/02-legal.md`](docs/02-legal.md).

1. **Fuentes permitidas:** *AVR Instruction Set Manual* (público), hoja de datos del ATmega328P
   sólo como referencia de comportamiento, `avr-libc` (BSD-3-Clause), `avr-gcc`, y `simavr` **sólo
   como oráculo de test**.
2. **Prohibido:** copiar HDL de terceros sin auditoría de licencia; copiar prosa del datasheet; usar
   «AVR», «Atmel», «Microchip» o «Arduino» en el nombre del producto, el logo o los nombres de placas.
3. **Signature bytes propios.** No se reutilizan los del ATmega328P.
4. **Firmware propio.** El bootloader se escribe desde cero contra la especificación pública del
   protocolo STK500v1. No se deriva de Optiboot ni de ningún otro bootloader existente.
5. **Licencias:** Apache-2.0 (RTL, software, firmware) · CERN-OHL-P v2 (diseño físico y PCB) ·
   CC-BY-4.0 (documentación). Todo componente de terceros se registra en `LICENSE-EXCEPTIONS.md`.

---

## 9. Camino a fabricación

| Vía | Proceso | Coste aproximado | Uso |
|-----|---------|------------------|-----|
| Tiny Tapeout | Sky130 · IHP SG13G2 · GF180 | 100–500 USD | Primera prueba de silicio real: núcleo con memoria externa |
| ChipFoundry chipIgnite | Sky130 | 14 950 USD | Objetivo: MCU completo, 100 piezas QFN, área de usuario de 10,3 mm² |

Presupuesto de área estimado en Sky130: ~6–7 mm² con 32 KB de memoria de programa; ~3,5 mm² con
16 KB. La decisión entre ambas configuraciones se toma en la fase 6, tras el floorplan.

---

## 10. Estructura y gestión

- Estructura de repositorio, fases y criterios de aceptación: [`docs/00-PLAN.md`](docs/00-PLAN.md).
- Regla estructural: **cada fichero RTL existe una sola vez.** Las herramientas reciben listas de
  ficheros, nunca copias del árbol de fuentes.
- Control de versiones con Git. Integración continua en cada push: lint, ALU exhaustiva, suite ISA,
  tabla de ciclos y síntesis con reporte de área y Fmax.
- Documentación en Markdown, generada automáticamente donde sea posible.

---

> AVR es una marca registrada de Microchip Technology Inc. Arduino es una marca registrada de
> Arduino SA. AxiomaCore-328 es una implementación independiente, sin relación ni respaldo de
> dichas compañías.
