# AxiomaCore-328 — Plan maestro de reconstrucción

**Versión:** 1.0 · **Fecha:** 8 de septiembre de 2026
**Estado del proyecto:** reinicio controlado sobre la base existente
**Objetivo:** microcontrolador de 8 bits, libre y abierto, compatible a nivel binario con el
ATmega328P, validado en FPGA con toolchain 100 % libre y preparado para tape-out en un PDK abierto.

---

## 1. Resumen ejecutivo

### 1.1 Las cinco decisiones que definen el proyecto

| # | Decisión | Elección | Por qué |
|---|----------|----------|---------|
| 1 | **Qué significa "copia exacta"** | Compatibilidad **binaria + mapa de registros + ciclos** (L1/L2/L3). NO compatibilidad eléctrica ni de pinout a nivel de die. | El PDK abierto no da 5 V ni Flash embebida. La compatibilidad de pinout se resuelve en el **módulo/PCB**, no en el silicio. |
| 2 | **Cómo evitar problemas legales** | Reimplementación *clean-room* desde la documentación pública del ISA + licencia **Apache-2.0**. Firmware propio. Signature bytes propios. Sin marcas de terceros en el nombre. | Los ISA no son copiables como tales; el HDL y el texto del datasheet sí. Precedente comercial: LGT8F328P. |
| 3 | **Cómo saber que funciona** | **Co-simulación diferencial contra `simavr`** instrucción a instrucción + verificación exhaustiva de la ALU + regresión en CI. | Es la única forma de afirmar "131 instrucciones correctas" con evidencia y no con un README. |
| 4 | **Plataforma de validación** | **Lattice ECP5** (yosys + nextpnr-ecp5 + prjtrellis) como primaria; iCE40 UP5K y Gowin GW1NR-9 como secundarias. | Toolchain libre y madura, BRAM de sobra para 32 KB + 2 KB + 1 KB, placas desde 20 USD. |
| 5 | **Camino a silicio** | Abstracción de memorias con backend intercambiable desde el día 1. Tiny Tapeout como prueba barata, chipIgnite (~15 000 USD) como objetivo real. | Si la jerarquía de memoria no se abstrae desde el principio, el port a ASIC es una reescritura. |

### 1.2 Qué cambia respecto al proyecto actual

El repositorio actual tiene trabajo real y aprovechable (un decodificador con ~108 mnemónicos,
periféricos con estructura razonable), pero tres problemas estructurales impiden avanzar sobre él:

1. **El SoC no está conectado.** `core/axioma_cpu/axioma_cpu.v:795` fija `io_data_in_cpu = 8'h00`;
   ningún `OUT`/`STS` puede escribir un periférico. No hay memoria de datos instanciada. Los timers
   no existen en la jerarquía.
2. **No hay oráculo de verificación.** Los testbenches no comparan contra nada. Es imposible
   distinguir "funciona" de "no crashea".
3. **No hay abstracción de memoria.** Flash, SRAM y EEPROM son arrays conductuales de `reg`. Eso
   sintetiza a biestables en ASIC (512 Kbit de flip-flops para la Flash: inviable) y hace que el
   camino a silicio sea una reescritura completa.

El plan **no borra** el trabajo previo: lo mueve a `legacy/` y lo usa como referencia y checklist.

---

## 2. Contrato de compatibilidad

Definimos cuatro niveles. Es importante fijarlos por escrito porque "copia exacta" significa
cosas distintas y sólo tres de las cuatro son alcanzables con herramientas libres.

| Nivel | Definición | ¿Objetivo? | Cómo se verifica |
|-------|-----------|-----------|------------------|
| **L1 — Binaria / ISA** | Ejecuta correctamente código máquina AVR de 8 bits: 131 instrucciones, semántica exacta del SREG, PC de 14 bits, stack, interrupciones. | **Sí, obligatorio** | Diferencial contra `simavr` sobre programas reales y aleatorios |
| **L2 — Mapa de registros** | Mismas direcciones, mismos nombres y misma semántica de bits que el ATmega328P. `avr/io.h` con `-mmcu=atmega328p` funciona sin tocar nada. | **Sí, obligatorio** | Generación automática del mapa desde `iom328p.h` (avr-libc, BSD-3) + diff en CI |
| **L3 — Ciclos** | Mismo número de ciclos por instrucción y misma temporización de periféricos (prescalers, generador de baudios, modos de timer). | **Sí** — lo necesitan `_delay_ms()`, `micros()`, SoftwareSerial, NeoPixel | Tabla de ciclos del manual del ISA codificada como test + contador de ciclos en RTL |
| **L4 — Eléctrica / pinout** | 5 V, 20 MHz, DIP-28 con el mismo orden de patillas. | **No a nivel de die.** Sí a nivel de **módulo**. | Sky130 es 1,8 V de core / 3,3 V de I/O. Se resuelve con un módulo DIP-28 con level shifters. |

> **Consecuencia práctica:** el chip no será *drop-in* en una placa de 5 V sin adaptación, pero el
> **módulo** sí puede serlo. Un programa compilado para Arduino Uno correrá sin recompilar.

### 2.1 Superset opcional (`AxiomaCore-328X`)

Una vez cerrada la compatibilidad, se puede añadir un perfil extendido **opt-in** que mantiene
L1/L2 (las extensiones viven en direcciones de I/O extendida no usadas por el 328P):

- Reloj de 40–60 MHz en ECP5 (2–3× el original).
- SRAM de 4–8 KB.
- Segunda USART, Timer3 de 16 bits, divisor hardware.

**No se empieza hasta que el perfil compatible pase toda la regresión.** Es la vía más rápida de
arruinar el proyecto.

---

## 3. Marco legal y de licencias

Esta sección es normativa: son reglas, no sugerencias.

### 3.1 Por qué esto es legal

- **Los conjuntos de instrucciones no son protegibles por copyright como tales.** Lo protegible es
  la *expresión*: el RTL de Microchip, el texto del datasheet, los layouts. Reimplementar la
  funcionalidad desde documentación pública es legal y tiene precedente industrial masivo
  (clones de 8051, de Z80, de x86, y en este mismo nicho el **LGT8F328P**, que se vende
  comercialmente y es compatible en instrucciones, registros y pinout).
- **Las patentes del núcleo AVR** datan de mediados de los 90; el plazo de 20 años está vencido.
  Las patentes específicas del ATmega328P (2006–2008) están venciendo en esta ventana. Riesgo bajo
  para un proyecto abierto; si algún día se comercializa a escala, hace falta una opinión de
  *freedom to operate* formal.
- **Nombres de registros y bits** (`PORTB`, `TCCR1A`, `WGM13`) son identificadores funcionales
  necesarios para la interoperabilidad. Además ya están disponibles bajo licencia libre: el fichero
  `iom328p.h` de **avr-libc es BSD-3-Clause**. Podemos usarlo directamente.

### 3.2 Reglas obligatorias

**Fuentes permitidas**
1. *AVR Instruction Set Manual* (Microchip, documento público) — para la semántica de instrucciones.
2. Hoja de datos del ATmega328P — para **conocer** el mapa de registros y el comportamiento.
   Nunca para copiar texto.
3. `avr-libc` (BSD-3-Clause) — headers de dispositivo. Uso directo permitido, con atribución.
4. `avr-gcc` — como compilador. La *GCC Runtime Library Exception* garantiza que el binario
   generado no queda afectado por la GPL.
5. `simavr` (LGPL) — **sólo como oráculo de test**, nunca enlazado ni derivado en el producto.

**Prohibiciones**
1. No copiar HDL de terceros sin auditar la licencia y registrarlo en `LICENSE-EXCEPTIONS.md`.
2. No copiar prosa del datasheet a nuestra documentación. Se escribe de cero.
3. No usar "AVR", "Atmel", "Microchip" ni "Arduino" en el nombre del producto, en el logo ni en
   nombres de placas. Uso **descriptivo** permitido: *"compatible con el conjunto de instrucciones
   AVR® de 8 bits"*, con nota de marcas registradas.
4. No reutilizar los signature bytes del ATmega328P (`0x1E 0x95 0x0F`). Usamos los nuestros y
   distribuimos nuestra entrada de `avrdude.conf`. Reutilizarlos haría el dispositivo
   indistinguible de una pieza genuina — ése es exactamente el escenario de falsificación.

### 3.3 Deuda legal detectada en el repositorio actual

| Hallazgo | Severidad | Acción |
|----------|-----------|--------|
| `bootloader/optiboot/optiboot.c` es un derivado de **Optiboot, GPLv2**, con líneas de copyright de Bill Westfield y Peter Knight. | **Alta** | Borrar. Escribir un bootloader STK500v1 propio desde la especificación pública del protocolo (AVR061). |
| **No existe fichero LICENSE.** El README dice "MIT License" en el texto y el badge dice "Apache-2.0". El bootloader es GPLv2. Tres licencias incompatibles declaradas a la vez. | **Alta** | Añadir `LICENSE` (Apache-2.0) + `LICENSE-EXCEPTIONS.md` con inventario de terceros. |
| `boards.txt` define placas llamadas "Uno R4" y "Nano Plus". "Uno" y "Nano" son nombres de producto de Arduino. | Media | Renombrar a `AxiomaCore-328 DEV` / `AxiomaCore-328 MINI`. |
| `README.md` afirma "timing closure achieved", "3.2 mm² die area", "production ready" sin ninguna corrida que lo respalde; `layout/axioma_minimal.gds` es un rectángulo de 172 bytes. | Media (reputacional) | Reescribir el README con el estado real y una matriz de compatibilidad medida. |

### 3.4 Licencias elegidas

| Artefacto | Licencia | Motivo |
|-----------|----------|--------|
| RTL, testbenches, scripts, firmware | **Apache-2.0** | Concesión explícita de patentes (crítico en hardware). Es lo que usa OpenTitan. |
| PCB / diseño físico | **CERN-OHL-P v2** | Licencia de hardware permisiva y reconocida. |
| Documentación | **CC-BY-4.0** | |

---

## 4. Inventario: qué se rescata del repositorio actual

Verdicto por artefacto. `Referencia` significa: no se copia, se usa como checklist mientras se
reescribe con la interfaz nueva.

| Ruta | Veredicto | Razón |
|------|-----------|-------|
| `core/axioma_decoder/axioma_decoder.v` (1259 L) | **Referencia — alto valor** | Cubre ~108 mnemónicos, decodificación combinacional limpia. Su interfaz de 60+ señales planas no encaja con un secuenciador multiciclo, pero su tabla de opcodes es un excelente punto de partida. |
| `core/axioma_alu/axioma_alu.v` (362 L) | **Referencia** | Flags mayormente correctos (ADIW/SBIW bien). Pero `flag_s_out` no tiene valor por defecto en el `always @(*)` → **latch inferido**. Y `S = N ⊕ V` debería ser un `assign` trivial, no un caso por instrucción. |
| `core/axioma_registers/axioma_registers.v` | Reescribir | Sin puerto de 16 bits real para X/Y/Z/MOVW/ADIW. |
| `core/axioma_cpu/axioma_cpu.v` | **Descartar** | Bus de I/O roto, sin SRAM, sin timers. Es el fichero que hay que rehacer. |
| `memory/*` | Descartar (conservar como referencia funcional) | Arrays conductuales sin abstracción de backend. |
| `peripherals/axioma_uart.v`, `axioma_spi.v`, `axioma_i2c.v` | **Referencia** | Máquinas de estado razonables. El mapa de registros no está verificado contra `iom328p.h`. |
| `peripherals/axioma_timers/*` | Referencia parcial | `timer1` no implementa el **registro TEMP** de acceso de 16 bits, que es obligatorio para L2. |
| `peripherals/axioma_gpio.v` | Referencia | Falta la escritura a `PINx` como *toggle* de `PORTx` (característica real del 328P, usada en la práctica). |
| `peripherals/axioma_adc.v` | Descartar | Es un modelo digital, no un ADC. |
| `openlane/axioma_core_328/src/*` | **Borrar** | Copia byte a byte de `core/` + `peripherals/`. Duplicación garantiza deriva. Se sustituye por listas de ficheros. |
| `openlane/.../config.json` | Descartar | Formato de OpenLane 1. Hoy el flujo es **LibreLane 3.x**. |
| `synthesis/*.ys`, `synthesis_report.txt` | Descartar | El script no hace `dfflibmap` ni `abc -liberty`: nunca mapeó a Sky130. El informe es de una jerarquía anterior. |
| `layout/*.gds`, `layout/physical/*` | **Borrar** | `axioma_minimal.gds` son 172 bytes con un rectángulo de 100×100 µm. `axioma_cpu_layout.gds` pesa 0 bytes. |
| `bootloader/optiboot/optiboot.c` | **Borrar** (motivo legal) | Ver §3.3. |
| `arduino_core/axioma/*` | **Rescatar y corregir** | `boards.txt` es reutilizable. `build.core=arduino` debe ser `arduino:arduino`. Renombrar placas. |
| `examples/*.ino`, `test_programs/arduino_compatibility/*.ino` | **Rescatar** | Base de la suite de compatibilidad. |
| `tools/*.py` | Referencia | Ideas útiles de caracterización y programación. |
| `testbench/*` | Descartar | No comparan contra ningún oráculo. |
| `*.tar.gz` (1,06 MB) | **Borrar del historial** | Backups binarios versionados. |
| `requerimiento.md` | **Conservar intacto** | Es el requisito oficial del proyecto. |
| `README.md` | Reescribir | Ver §3.3. |

---

## 5. Arquitectura objetivo

### 5.1 Diagrama de bloques

```
                    ┌──────────────────────────────────────────────┐
                    │            axioma328_soc  (el "chip")        │
                    │                                              │
   clk ─────────────┤ ┌────────────┐        ┌──────────────────┐   │
   reset_n ─────────┤ │ clk/reset  │        │  axioma_progmem  │   │
                    │ │  CLKPR     │        │  16K x 16 bits   │   │
                    │ └─────┬──────┘        │  ┌────────────┐  │   │
                    │       │               │  │  BACKEND   │  │   │
                    │  ┌────▼──────────┐    │  │ bram/sky130│  │   │
                    │  │  axioma_core  │◄───┤  └────────────┘  │   │
                    │  │               │ IF └──────────────────┘   │
                    │  │  ┌─────────┐  │                           │
                    │  │  │ decode  │  │    ┌──────────────────┐   │
                    │  │  ├─────────┤  │    │   axioma_dmem    │   │
                    │  │  │  seq    │  │◄──►│   2 KB SRAM      │   │
                    │  │  ├─────────┤  │    │  ┌────────────┐  │   │
                    │  │  │ regfile │  │    │  │  BACKEND   │  │   │
                    │  │  ├─────────┤  │    │  └────────────┘  │   │
                    │  │  │   ALU   │  │    └──────────────────┘   │
                    │  │  ├─────────┤  │                           │
                    │  │  │  SREG   │  │    ┌──────────────────┐   │
                    │  │  └─────────┘  │◄──►│  axioma_eeprom   │   │
                    │  └───────┬───────┘    │      1 KB        │   │
                    │          │            └──────────────────┘   │
                    │   ┌──────▼───────────────────────────────┐   │
                    │   │       axioma_dbus  (0x0000-0x08FF)   │   │
                    │   │  regs │ I/O │ ext I/O │ SRAM         │   │
                    │   └──┬────┬────┬────┬────┬────┬────┬─────┘   │
                    │      │    │    │    │    │    │    │         │
                    │   ┌──▼─┐┌─▼──┐┌▼───┐┌▼──┐┌▼──┐┌▼──┐┌▼───┐    │
                    │   │GPIO││TMR0││TMR1││TMR2││USART││SPI││TWI│   │
                    │   └──┬─┘└─┬──┘└─┬──┘└─┬─┘└──┬──┘└─┬─┘└─┬──┘   │
                    │   ┌──▼─┐┌─▼──┐┌─▼──┐┌─▼─┐ │    │   │        │
                    │   │ADC ││ AC ││WDT ││INT│ │    │   │        │
                    │   └────┘└────┘└────┘└─┬─┘ │    │   │        │
                    │              ┌────────▼───▼────▼───▼──┐     │
                    │              │      axioma_irq        │     │
                    │              │   26 vectores, prio    │     │
                    │              └────────────────────────┘     │
                    └──────────────────────────────────────────────┘
                          PB[7:0]  PC[6:0]  PD[7:0]  ADC[7:0]
```

### 5.2 Mapa del espacio de datos (contrato L2)

El AVR es Harvard pero tiene un **espacio de datos unificado**. Éste es el punto que el diseño
actual no modela y que hay que clavar:

```
0x0000 – 0x001F   32 registros de propósito general (R0–R31)
0x0020 – 0x005F   64 registros de I/O estándar     ← IN/OUT usan dir. = data_addr − 0x20
0x0060 – 0x00FF   160 registros de I/O extendida   ← sólo accesibles con LD/ST
0x0100 – 0x08FF   2048 bytes de SRAM interna
                  RAMEND = 0x08FF  (valor inicial del SP)
```

Implicaciones que hay que implementar explícitamente:

- `LD r16, X` con `X = 0x0005` **lee R5**. Programas reales hacen esto.
- `IN`/`OUT` sólo alcanzan `0x00–0x3F` del espacio de I/O.
- `CBI`/`SBI`/`SBIC`/`SBIS` sólo alcanzan `0x00–0x1F` del espacio de I/O.
- `PORTB` está en I/O `0x05` **y** en dato `0x25`. Son el mismo registro.

### 5.3 Mapa completo de registros (extracto normativo)

El mapa se **genera automáticamente** desde `iom328p.h` de avr-libc (BSD-3-Clause) hacia:
- `rtl/soc/axioma_regmap.vh` (constantes Verilog)
- `docs/03-register-map.md` (documentación)
- `sim/isa/regmap_check.py` (test de CI que falla si divergen)

Esto convierte L2 de "esperemos que esté bien" en una propiedad verificada mecánicamente.

| Dato | I/O | Registro | | Dato | Registro |
|------|-----|----------|-|------|----------|
| 0x23 | 0x03 | PINB | | 0x60 | WDTCSR |
| 0x24 | 0x04 | DDRB | | 0x61 | CLKPR |
| 0x25 | 0x05 | PORTB | | 0x64 | PRR |
| 0x26 | 0x06 | PINC | | 0x66 | OSCCAL |
| 0x27 | 0x07 | DDRC | | 0x68 | PCICR |
| 0x28 | 0x08 | PORTC | | 0x69 | EICRA |
| 0x29 | 0x09 | PIND | | 0x6B–0x6D | PCMSK0–2 |
| 0x2A | 0x0A | DDRD | | 0x6E–0x70 | TIMSK0–2 |
| 0x2B | 0x0B | PORTD | | 0x78–0x79 | ADCL / ADCH |
| 0x35 | 0x15 | TIFR0 | | 0x7A | ADCSRA |
| 0x36 | 0x16 | TIFR1 | | 0x7B | ADCSRB |
| 0x37 | 0x17 | TIFR2 | | 0x7C | ADMUX |
| 0x3B | 0x1B | PCIFR | | 0x7E–0x7F | DIDR0 / DIDR1 |
| 0x3C | 0x1C | EIFR | | 0x80–0x82 | TCCR1A/B/C |
| 0x3D | 0x1D | EIMSK | | 0x84–0x85 | TCNT1L / TCNT1H |
| 0x3F | 0x1F | EECR | | 0x86–0x87 | ICR1L / ICR1H |
| 0x40 | 0x20 | EEDR | | 0x88–0x8B | OCR1A/B L/H |
| 0x41–0x42 | | EEARL / EEARH | | 0xB0–0xB1 | TCCR2A/B |
| 0x44–0x45 | 0x24–0x25 | TCCR0A / TCCR0B | | 0xB2 | TCNT2 |
| 0x46 | 0x26 | TCNT0 | | 0xB3–0xB4 | OCR2A / OCR2B |
| 0x47–0x48 | 0x27–0x28 | OCR0A / OCR0B | | 0xB6 | ASSR |
| 0x4C–0x4E | 0x2C–0x2E | SPCR / SPSR / SPDR | | 0xB8–0xBD | TWBR…TWAMR |
| 0x50 | 0x30 | ACSR | | 0xC0–0xC2 | UCSR0A/B/C |
| 0x53–0x55 | 0x33–0x35 | SMCR / MCUSR / MCUCR | | 0xC4–0xC5 | UBRR0L / UBRR0H |
| 0x57 | 0x37 | SPMCSR | | 0xC6 | UDR0 |
| 0x5D–0x5F | 0x3D–0x3F | SPL / SPH / SREG | | | |

### 5.4 Tabla de vectores de interrupción (26)

Direcciones **de palabra**. Cada vector ocupa 2 palabras (un `JMP`) porque la Flash es de 32 KB.

```
0x0000 RESET          0x001A TIMER1_OVF
0x0002 INT0           0x001C TIMER0_COMPA
0x0004 INT1           0x001E TIMER0_COMPB
0x0006 PCINT0         0x0020 TIMER0_OVF
0x0008 PCINT1         0x0022 SPI_STC
0x000A PCINT2         0x0024 USART_RX
0x000C WDT            0x0026 USART_UDRE
0x000E TIMER2_COMPA   0x0028 USART_TX
0x0010 TIMER2_COMPB   0x002A ADC
0x0012 TIMER2_OVF     0x002C EE_READY
0x0014 TIMER1_CAPT    0x002E ANALOG_COMP
0x0016 TIMER1_COMPA   0x0030 TWI
0x0018 TIMER1_COMPB   0x0032 SPM_READY
```

Prioridad = orden numérico (vector más bajo, mayor prioridad). Sin anidamiento automático:
el `I` del SREG se limpia al entrar y se restaura con `RETI`.

### 5.5 Microarquitectura del núcleo

**Pipeline de 2 etapas**, igual que el AVR original:

```
  IF                          ID / EX / WB
┌──────────────┐            ┌───────────────────────────────┐
│ PC → progmem │  ──IR──►   │ decode → regfile → ALU → wb   │
│ PC += 1|2    │            │ dbus (LD/ST/PUSH/POP)         │
└──────────────┘            └───────────────────────────────┘
        ▲                                │
        └──────── stall / redirect ──────┘
```

Un **secuenciador** (`axioma_seq.v`) gestiona las instrucciones multiciclo congelando la etapa IF.

**Tabla de ciclos objetivo (contrato L3)**

| Clase | Ciclos | Notas |
|-------|--------|-------|
| ALU registro/inmediato (ADD, SUB, AND, LDI…) | 1 | |
| `MUL`, `MULS`, `MULSU`, `FMUL*` | 2 | resultado en R1:R0 |
| `ADIW` / `SBIW` | 2 | |
| `MOVW` | 1 | |
| `LD` / `ST` (X, Y, Z, con desplazamiento o inc/dec) | 2 | |
| `LDS` / `STS` (32 bits) | 2 | |
| `PUSH` / `POP` | 2 | |
| `LPM` | 3 | |
| `SPM` | — | depende del backend de progmem |
| `RJMP`, `IJMP` | 2 | |
| `JMP` | 3 | |
| `RCALL`, `ICALL` | 3 | |
| `CALL` | 4 | |
| `RET`, `RETI` | 4 | |
| Branch condicional (`BRxx`) | 1 no tomado / 2 tomado | |
| `CPSE`, `SBRC`, `SBRS`, `SBIC`, `SBIS` | 1 / 2 / **3** | 3 si la instrucción saltada es de 32 bits |
| `IN`, `OUT`, `SBI`, `CBI` | 1 / 2 | |
| Entrada a interrupción | 4 + 3 (`JMP` del vector) | |

### 5.6 Las doce trampas de compatibilidad

Éstas son las que hunden un core AVR "casi correcto". Cada una necesita un test dirigido.

1. **Skip de instrucciones de 32 bits.** `CPSE`/`SBRC`/`SBRS`/`SBIC`/`SBIS` deben saltar **1 o 2
   palabras** según si la siguiente instrucción es `LDS`/`STS`/`JMP`/`CALL`. Requiere un
   predecodificador de "¿la siguiente es de 2 palabras?".
2. **Retardo del `SEI`.** Tras `SEI`, la interrupción no se atiende hasta **después** de ejecutar
   la instrucción siguiente. El idioma `SEI; SLEEP` depende de ello.
3. **`CLI` es inmediato**, a diferencia de `SEI`.
4. **Registro TEMP de 16 bits.** Leer `TCNT1L` captura el byte alto en TEMP; leer `TCNT1H` devuelve
   TEMP. Escribir `TCNT1H` guarda en TEMP; escribir `TCNT1L` compromete los 16 bits. Aplica a
   TCNT1, ICR1, OCR1A, OCR1B. **Sin esto, `micros()` y Servo dan valores basura.**
5. **Escritura a `PINx` = toggle de `PORTx`.** Característica real del 328P.
6. **`LD`/`ST` sobre 0x0000–0x001F** accede al banco de registros.
7. **Punteros con post-incremento / pre-decremento** escriben de vuelta al regfile en el mismo
   ciclo; `ST X+, r26` tiene semántica de orden definida.
8. **`PUSH`**: guarda en `SP`, luego `SP--`. **`POP`**: `SP++`, luego lee. `CALL` apila la
   dirección de retorno con el byte **alto primero**.
9. **Flags de `NEG`**: `H = R3 | ¬Rd3`, `V = (R == 0x80)`, `C = (R != 0x00)`. Es la instrucción con
   los flags más peculiares.
10. **`ROR`/`ASR`/`LSR`**: `V = N ⊕ C` calculado **después** del desplazamiento.
11. **Efectos laterales de lectura.** Leer `UDR0` limpia `RXC`. Leer `ADCL` bloquea `ADCH` hasta que
    se lee `ADCH`. Leer `TIFRx` no limpia; se limpia escribiendo un 1.
12. **Prescaler compartido.** Timer0 y Timer1 comparten prescaler; `GTCCR` permite resetearlo. El
    generador de baudios de la USART deriva de `F_CPU`, no del prescaler de timers.

### 5.7 Abstracción de memorias (la decisión que hace posible el ASIC)

Interfaz única, backend intercambiable en tiempo de compilación:

```verilog
module axioma_progmem #(
    parameter WORDS    = 16384,   // 32 KB
    parameter INIT_HEX = ""       // sólo sim/FPGA
)(
    input  wire        clk,
    // Puerto de fetch: sólo lectura, 1 ciclo de latencia
    input  wire [13:0] if_addr,
    input  wire        if_en,
    output wire [15:0] if_data,
    // Puerto de datos: LPM (lectura) y SPM (escritura de página)
    input  wire [13:0] d_addr,
    input  wire        d_en,
    input  wire        d_we,
    input  wire [15:0] d_wdata,
    output wire [15:0] d_rdata
);
```

| Backend | Implementación | Uso |
|---------|---------------|-----|
| `sim` | array conductual + `$readmemh` | simulación rápida |
| `fpga_bram` | BRAM inferida, inicializada desde `.hex` | ECP5 / iCE40 / Gowin |
| `sky130_sram` | matriz de macros `sky130_sram_2kbyte_1rw1r_32x512_8` + ROM de arranque que copia desde QSPI externa | ASIC |

Lo mismo para `axioma_dmem` (2 KB) y `axioma_eeprom` (1 KB).

> **El problema de la Flash en silicio abierto.** Sky130 **no tiene memoria no volátil embebida**.
> No existe IP de Flash ni de EEPROM en el PDK abierto. Un ATmega328P literal, con 32 KB de Flash
> interna, no es reproducible. Las tres salidas reales:
>
> 1. **Shadow RAM (recomendada).** Memoria de programa en macros de SRAM; una ROM de arranque
>    pequeña copia desde una Flash QSPI externa al encender. **Preserva la exactitud de ciclos (L3).**
>    Coste: área.
> 2. **XIP con caché de instrucciones.** Ejecutar directamente desde QSPI externa con una caché
>    de 2–4 KB. Área mucho menor, pero **rompe L3**.
> 3. **ROM de máscara.** Programa fijo grabado en la máscara. Barato, no reprogramable.

---

## 6. Estructura del repositorio

```
axioma328/
├── LICENSE                        Apache-2.0
├── LICENSE-EXCEPTIONS.md          inventario de terceros y sus licencias
├── README.md                      estado real + matriz de compatibilidad medida
├── CONTRIBUTING.md
├── Makefile                       punto de entrada único
├── docs/
│   ├── 00-PLAN.md                 este documento
│   ├── 01-architecture.md
│   ├── 02-isa.md                  nuestra especificación del ISA (escrita de cero)
│   ├── 03-register-map.md         GENERADO desde iom328p.h
│   ├── 04-compat-matrix.md        GENERADO desde los resultados de la regresión
│   ├── 05-legal.md                política clean-room
│   └── adr/                       registros de decisiones de arquitectura
├── rtl/
│   ├── core/       axioma_core.v  decode.v  alu.v  regfile.v  sreg.v  seq.v
│   ├── bus/        dbus.v  iomux.v
│   ├── mem/        progmem.v  dmem.v  eeprom.v
│   │   └── backends/  sim/  fpga_bram/  sky130_sram/
│   ├── periph/     gpio.v  timer0.v  timer1.v  timer2.v  usart.v  spi.v
│   │               twi.v  adc.v  ac.v  wdt.v  extint.v  pcint.v
│   ├── soc/        axioma328_soc.v  irq.v  clkctrl.v  axioma_regmap.vh
│   └── fpga/       ecp5/  ice40/  gowin/     tops + constraints por placa
├── sim/
│   ├── tb/         testbenches Verilog
│   ├── cocotb/     tests en Python
│   ├── golden/     co-simulación diferencial contra simavr
│   ├── isa/        tests dirigidos, uno por instrucción
│   └── perf/       comprobación de la tabla de ciclos
├── fw/
│   ├── bootloader/ NUESTRO bootloader STK500v1
│   ├── selftest/   POST / BIST
│   └── examples/
├── sw/
│   ├── arduino/    paquete de placas para Arduino IDE 2.x
│   ├── platformio/
│   └── avrdude/    axioma.conf con nuestros signature bytes
├── asic/
│   ├── librelane/  config.yaml, constraints
│   ├── macros/     LEF/GDS/LIB de las SRAM
│   └── reports/
├── board/          KiCad: módulo DIP-28
├── tools/          generadores, scripts de build
├── legacy/         el repositorio actual, congelado, como referencia
└── .github/workflows/   CI
```

**Regla de oro:** cada fichero RTL existe **una sola vez**. Nada de copiar `rtl/` dentro de
`asic/`. Las herramientas reciben listas de ficheros (`*.f`), no copias.

---

## 7. Herramientas: qué instalar

### 7.1 Núcleo (sin sudo)

**OSS CAD Suite** — un solo tarball con casi todo lo necesario:

```bash
mkdir -p ~/eda && cd ~/eda
curl -LO https://github.com/YosysHQ/oss-cad-suite-build/releases/download/2026-09-08/oss-cad-suite-linux-x64-20260908.tgz
tar xzf oss-cad-suite-linux-x64-20260908.tgz
echo 'source ~/eda/oss-cad-suite/environment' >> ~/.bashrc
```

Incluye: `yosys`, `nextpnr-ice40/ecp5/nexus/himbaechel(gowin)`, `icestorm`, `prjtrellis`,
`apicula`, `iverilog`, `verilator`, `gtkwave`, `openFPGALoader`, `sby` (SymbiYosys), `ghdl`.

### 7.2 Toolchain AVR

```bash
sudo apt install gcc-avr avr-libc avrdude simavr srecord
```

Sin sudo, alternativa: el toolchain que empaqueta Arduino
(`downloads.arduino.cc/tools/avr-gcc-*.tar.bz2`), extraído en `~/eda/avr-gcc`.

### 7.3 Verificación

```bash
python3 -m venv ~/eda/venv && source ~/eda/venv/bin/activate
pip install cocotb cocotb-test pytest pyelftools intelhex
```

### 7.4 Flujo ASIC (fase 6, vía Docker — ya disponible)

- **LibreLane 3.x** (sucesor de OpenLane 2, bajo la FOSSi Foundation). Instalación por Nix o Docker.
- **ciel** (sustituye a `volare`) para gestionar el PDK Sky130A.
- `magic`, `netgen`, `klayout` vienen en la imagen de LibreLane.

### 7.5 Tabla resumen

| Herramienta | Para qué | Fase |
|-------------|----------|------|
| iverilog / verilator | simulación RTL | 1 |
| cocotb | testbenches en Python | 1 |
| simavr | **oráculo de referencia** | 1 |
| avr-gcc + avr-libc | compilar los programas de test | 1 |
| yosys | síntesis | 2 |
| nextpnr + prjtrellis | P&R en ECP5 | 2 |
| openFPGALoader | cargar el bitstream | 2 |
| gtkwave | depuración de ondas | todas |
| sby (SymbiYosys) | propiedades formales | 3 |
| avrdude | programar vía bootloader | 4 |
| LibreLane + ciel | RTL→GDSII en Sky130 | 6 |
| KiCad | PCB del módulo | 7 |

---

## 8. Estrategia de verificación

Esto es lo que separa este plan del intento anterior. **Sin oráculo no hay proyecto.**

### Capa 1 — Diferencial contra `simavr` (la columna vertebral)

```
   programa .elf (avr-gcc)
        │
        ├──────────────► simavr ──────► traza: PC, R0-R31, SREG, SP, escrituras a memoria
        │                                          │
        └──────────────► RTL (verilator) ──────►  traza equivalente
                                                   │
                                          comparador ──► primera divergencia + ondas
```

Se compara tras **cada instrucción retirada**. Cuando diverge, el comparador imprime la
instrucción, el estado esperado y el obtenido, y vuelca un VCD acotado. Este único mecanismo
convierte la depuración de un core de días a minutos.

Corpus de programas:
- Suite dirigida: un programa por instrucción, con casos borde de flags.
- Programas reales compilados: `printf` de avr-libc, aritmética de 32 bits, `qsort`, cadenas.
- **Generador de instrucciones aleatorias**: secuencias válidas con operandos aleatorios,
  millones de instrucciones en CI nocturno.

### Capa 2 — ALU exhaustiva

La ALU es de 8 bits: el espacio de entrada es enumerable por completo.
256 (A) × 256 (B) × 2 (carry in) × ~20 operaciones ≈ **2,6 millones de vectores**.
Se comparan resultado y los 6 flags contra un modelo de referencia en Python escrito directamente
desde el manual del ISA. Cobertura del 100 %, demostrable, en segundos.

### Capa 3 — Exactitud de ciclos (L3)

La tabla de §5.5 se codifica como fichero de datos. Un test ejecuta cada instrucción aislada con un
contador de ciclos y falla si difiere. Además: comparación de la cuenta total de ciclos contra
`simavr` en programas completos.

### Capa 4 — Periféricos contra el mapa de registros

- Test generado que escribe y lee **cada dirección de I/O** comprobando bits reservados,
  máscaras de sólo lectura y efectos laterales (`RXC`, bloqueo de `ADCH`, `TIFR` write-1-to-clear).
- Modelos de bus: un modelo de esclavo I2C, un modelo de esclavo SPI y un receptor UART en el
  testbench, que verifican la forma de onda real, no sólo los registros.

### Capa 5 — Compatibilidad Arduino de extremo a extremo

Suite de sketches compilados con avr-gcc y ejecutados en RTL y en FPGA:

`Blink` · `Serial` (varios baudios) · `AnalogRead` · `analogWrite` (PWM en los 6 canales) ·
`Wire` (scanner I2C) · `SPI` · `Servo` · `SoftwareSerial` · `LiquidCrystal` · `Adafruit_NeoPixel`
(el más exigente en ciclos) · `SD` · `EEPROM` · `millis()/micros()` con verificación de deriva.

### Capa 6 — Formal (selectiva)

SymbiYosys sobre propiedades acotadas: el SP nunca sale de la SRAM, el decodificador nunca emite
dos operaciones de escritura al regfile a la vez, la FSM del TWI no tiene estados inalcanzables.

### CI

Cada push: lint (verilator `-Wall`), ALU exhaustiva, suite ISA dirigida, tabla de ciclos, síntesis
ECP5 con reporte de área/Fmax. Cada noche: 10⁷ instrucciones aleatorias + suite Arduino completa.
El README publica la matriz de compatibilidad **generada**, no escrita a mano.

---

## 9. Plataforma FPGA

Requisito: **32 KB (256 Kbit) de memoria de programa + 2 KB de datos + 1 KB EEPROM = ~280 Kbit**
más ~3 000–5 000 LUT4 para el core y los periféricos.

| Placa | FPGA | Lógica | Memoria | Toolchain | Precio aprox. | Veredicto |
|-------|------|--------|---------|-----------|--------------|-----------|
| **ULX3S 25F** | ECP5 LFE5U-25F | 24 k LUT4 | 1008 Kbit EBR + 32 MB SDRAM | yosys + nextpnr-ecp5 + prjtrellis | ~120 USD | **Recomendada.** Recursos de sobra, muchísima E/S, ESP32, HDMI, microSD. |
| **Colorlight 5A-75B** | ECP5 LFE5U-25F | 24 k LUT4 | 1008 Kbit + SDRAM | ídem | ~15–25 USD | **Mejor relación precio/prestaciones.** Necesita una placa adaptadora para sacar E/S. |
| **Tang Nano 9K** | Gowin GW1NR-9 | 8,6 k LUT4 | 468 Kbit BSRAM + 64 Mbit PSRAM | yosys + apicula + nextpnr | ~15–20 USD | Muy barata, cabe. Toolchain abierta algo menos madura. |
| **iCEBreaker** | iCE40 UP5K | 5,3 k LUT4 | 128 KB SPRAM + 120 Kbit BRAM | yosys + nextpnr-ice40 + icestorm | ~70 USD | La cadena más madura y 100 % abierta. La SPRAM va perfecta para memoria de programa. Ajustado en LUTs. |
| OrangeCrab | ECP5 25F | 24 k LUT4 | 1008 Kbit + 128 MB DDR3 | ídem ECP5 | ~130 USD | Formato Feather, USB nativo. |

**Recomendación:** ECP5 como objetivo primario. Si el presupuesto es lo primero, **Colorlight
5A-75B**; si se quiere comodidad, **ULX3S 25F**. El RTL soportará las tres familias mediante
`rtl/fpga/<familia>/` con tops y constraints separados; el SoC no cambia.

**Objetivo de rendimiento:** cierre de timing a ≥ 32 MHz en ECP5 (2× un ATmega328P real). El
diseño de referencia expondrá F_CPU seleccionable (8/16/20/25/32 MHz) para poder correr binarios
Arduino sin recompilar.

---

## 10. Firmware propio e integración con IDE

### 10.1 Bootloader (escrito desde cero)

- Protocolo **STK500v1**, el mismo que usa `avrdude -c arduino`. La especificación del protocolo es
  pública (nota de aplicación AVR061); implementarla de cero es limpio legalmente.
- Objetivo de tamaño: ≤ 512 bytes (una sección de boot de 256 palabras), como referencia de calidad.
- Funciones: sincronización, lectura de signature, borrado de página, escritura de página vía `SPM`,
  lectura para verificación, salto a la aplicación con timeout.
- Licencia: Apache-2.0. Sin una línea de Optiboot.

### 10.2 Arduino IDE 2.x

Paquete de placas instalable por *Boards Manager* mediante una URL JSON:

```
sw/arduino/
├── package_axioma_index.json      (publicado en GitHub Pages)
└── axioma/avr/1.0.0/
    ├── boards.txt
    ├── platform.txt
    ├── programmers.txt
    ├── variants/axioma328/pins_arduino.h
    ├── bootloaders/axioma/axioma_boot.hex
    └── tools/avrdude/axioma.conf     (nuestros signature bytes)
```

Punto clave: **no forkeamos el core de Arduino**. En `boards.txt`:

```
axioma328.build.core=arduino:arduino     # referencia al core AVR de Arduino (LGPL), sin copiarlo
axioma328.build.mcu=atmega328p           # objetivo de compilación: 100 % legal y necesario
axioma328.build.variant=axioma328
```

Así se cumple con la LGPL sin distribuir código de terceros y se mantiene la compatibilidad
binaria total.

### 10.3 PlatformIO

`sw/platformio/boards/axioma328.json`, plataforma `atmelavr`, `mcu: atmega328p`,
protocolo de subida `arduino`. Diez líneas de configuración.

### 10.4 Bare metal

`Makefile` + `avr-gcc -mmcu=atmega328p` + `avrdude -C sw/avrdude/axioma.conf`. Documentado en
`docs/`.

---

## 11. Camino a silicio: opciones y costes reales (septiembre de 2026)

El ecosistema cambió en 2025: **Efabless cerró en marzo de 2025** y dejó cientos de diseños en el
aire. El hueco lo cubrieron varios actores. Estado actual:

| Vía | Proceso | Coste | Qué entregan | Cabida | Cuándo usarla |
|-----|---------|-------|--------------|--------|---------------|
| **Tiny Tapeout** | Sky130 (vía ChipFoundry), IHP SG13G2, GF180 | ~100–500 USD según *tiles* | Chip en placa de evaluación | 1 tile ≈ 160 × 100 µm ≈ 1 000 puertas. Multi-tile disponible. **No caben las memorias.** | **Primera prueba de silicio real, barata.** El núcleo con memoria externa QSPI. |
| **ChipFoundry chipIgnite** | Sky130 | **14 950 USD** por proyecto | 100 piezas encapsuladas QFN, ~5 meses, arnés Caravel (~10,3 mm² de área de usuario) | El MCU completo cabe (ver cálculo abajo) | **El objetivo real.** 3 lanzaderas previstas en 2026. |
| Lanzaderas Cadence + SkyWater | Sky130 | variable | — | — | Alternativa a vigilar |
| IHP / wafer.space | SG13G2 (130 nm BiCMOS), GF180 | variable | — | — | PDK abierto europeo, muy activo |

### 11.1 Presupuesto de área en Sky130

Macro de referencia: `sky130_sram_1kbyte_1rw1r_32x256_8` mide **479,78 × 397,5 µm = 0,191 mm²**.

| Bloque | Área estimada |
|--------|--------------|
| Memoria de programa, 32 KB | ~5,0–6,1 mm² (16 macros de 2 KB / 32 de 1 KB) |
| SRAM de datos, 2 KB | ~0,38 mm² |
| "EEPROM" (SRAM respaldada en Flash externa), 1 KB | ~0,19 mm² |
| Núcleo + periféricos (~8 k celdas estándar) | ~0,3–0,5 mm² |
| **Total** | **~6–7 mm²** |

Área de usuario de Caravel: **2,92 × 3,52 = 10,3 mm²**. **Cabe**, pero con poco margen para el
enrutado sobre macros. Recomendación para el primer tape-out: **16 KB de memoria de programa**
(~2,5–3 mm²), que deja holgura cómoda, o adoptar la variante XIP con caché.

### 11.2 Lo que no va en el primer chip

- **ADC**: es analógico. Se expone el controlador SAR digital con pines para un comparador externo.
  Un ADC integrado es un proyecto en sí mismo.
- **Oscilador RC interno, bandgap, POR, brown-out**: analógicos. Se usa reloj externo.
- **5 V**: Sky130 no lo da. Level shifters en el módulo.

---

## 12. Plan por fases

Estimaciones asumiendo ~15 h/semana. El camino crítico es la fase 1.

### Fase 0 — Fundación (1 semana)

- [ ] Instalar OSS CAD Suite, toolchain AVR, simavr, cocotb.
- [ ] `git mv` de todo lo actual a `legacy/`. Purgar los `.tar.gz` del historial.
- [ ] Crear la estructura de §6, `LICENSE` (Apache-2.0), `LICENSE-EXCEPTIONS.md`, `docs/05-legal.md`.
- [ ] Borrar `bootloader/optiboot/`, `layout/*.gds`, `openlane/src/`.
- [ ] Generador `tools/gen_regmap.py`: `iom328p.h` → `axioma_regmap.vh` + `docs/03-register-map.md`.
- [ ] CI mínima en GitHub Actions (lint + build).

**Criterio de aceptación:** `make check-tools` pasa; el mapa de registros se genera y su test de
diff está verde; `git clone` limpio pesa < 2 MB.

### Fase 1 — Núcleo ISA (4 semanas) ← *camino crítico*

- [ ] `regfile.v` (2R/1W + acceso de 16 bits), `sreg.v`, `alu.v`.
- [ ] Modelo de referencia de la ALU en Python + **verificación exhaustiva** (Capa 2).
- [ ] `decode.v` — decodificación combinacional completa + predecodificador de "siguiente de 32 bits".
- [ ] `seq.v` — secuenciador multiciclo.
- [ ] `progmem`/`dmem` con backend `sim`.
- [ ] Arnés de co-simulación diferencial contra simavr (Capa 1).
- [ ] Test dirigido por cada una de las 131 instrucciones.
- [ ] Tabla de ciclos verificada (Capa 3).

**Criterio de aceptación:** las 131 instrucciones pasan el diferencial contra simavr; 10⁶
instrucciones aleatorias sin divergencia; ALU 100 % exhaustiva verde; tabla de ciclos exacta.
**Aquí es donde el proyecto se gana el derecho a existir.**

### Fase 2 — SoC mínimo y primer bitstream (2 semanas)

- [ ] `dbus.v` con el mapa unificado de §5.2.
- [ ] `gpio.v` (incluido el toggle por `PINx`), `timer0.v`, `usart.v`, `irq.v`.
- [ ] Backend `fpga_bram`; top de ECP5 + constraints.
- [ ] Bootstrap: precargar el `.hex` en la BRAM del bitstream.

**Criterio de aceptación:** un `Blink.ino` compilado con avr-gcc parpadea un LED **en la FPGA**, y
`Serial.println("Hola")` sale por el UART a 115200 baudios y se lee en el PC.

### Fase 3 — Periféricos completos (5 semanas)

- [ ] `timer1.v` con el **registro TEMP** de 16 bits; `timer2.v`; los 6 canales PWM.
- [ ] `spi.v`, `twi.v` (con modelos de bus en el testbench).
- [ ] `adc.v` (controlador SAR; comparador externo o modelo), `ac.v`, `wdt.v`.
- [ ] `extint.v` (INT0/INT1) y `pcint.v` (PCINT0/1/2).
- [ ] `eeprom.v` + máquina de estados de `EECR`.
- [ ] `clkctrl.v`: CLKPR, PRR, modos de sueño, `SMCR`.
- [ ] Barrido completo del mapa de registros (Capa 4).

**Criterio de aceptación:** los 26 vectores de interrupción disparan y se atienden con la prioridad
correcta; `micros()` no deriva; el scanner I2C detecta un esclavo real.

### Fase 4 — Compatibilidad Arduino (3 semanas)

- [ ] Bootloader STK500v1 propio, ≤ 512 B.
- [ ] `SPM` funcional sobre el backend de BRAM.
- [ ] Paquete de placas para Arduino IDE + JSON en GitHub Pages.
- [ ] `axioma.conf` para avrdude con signature bytes propios.
- [ ] Suite de sketches (Capa 5).

**Criterio de aceptación:** desde el Arduino IDE, sin herramientas externas: seleccionar la placa,
pulsar *Upload* y que el sketch corra en la FPGA. Diez sketches de la suite pasando, **NeoPixel
incluido**.

### Fase 5 — Endurecimiento (2 semanas)

- [ ] Cierre de timing ≥ 32 MHz en ECP5; reporte de área y Fmax en CI.
- [ ] Portes a iCE40 UP5K y Gowin.
- [ ] Regresión nocturna de 10⁷ instrucciones.
- [ ] README reescrito con la matriz de compatibilidad **generada**.
- [ ] Release v1.0 con bitstreams precompilados.

**Criterio de aceptación:** un tercero clona el repo, ejecuta un comando y obtiene un bitstream
funcionando en su placa.

### Fase 6 — Silicio (6–10 semanas, opcional)

- [ ] Backend `sky130_sram` + integración de macros.
- [ ] ROM de arranque + cargador desde QSPI.
- [ ] LibreLane: floorplan, PDN, colocación de macros, CTS, enrutado.
- [ ] DRC y LVS limpios; simulación con retardos post-layout (SDF).
- [ ] Tiny Tapeout primero (núcleo, ~300 USD) como validación barata.
- [ ] Envío a chipIgnite (~15 000 USD).

**Criterio de aceptación:** GDSII real con DRC y LVS limpios; el netlist post-layout pasa el
diferencial contra simavr con retardos anotados.

### Fase 7 — Hardware (3 semanas)

- [ ] Módulo DIP-28 en KiCad: FPGA + Flash QSPI + level shifters a 5 V + regulador.
- [ ] Compatible pin a pin con el zócalo de un Arduino Uno.

---

## 13. Riesgos

| Riesgo | Prob. | Impacto | Mitigación |
|--------|-------|---------|-----------|
| La exactitud de ciclos (L3) resulta más costosa de lo previsto | Media | Alto — rompe librerías sensibles a temporización | Medirla desde la fase 1, no al final. Es barato corregir el secuenciador y caro rediseñarlo. |
| El registro TEMP de 16 bits y los efectos laterales de lectura se subestiman | Alta | Alto | Están en la lista de las doce trampas (§5.6) con test dedicado desde el principio. |
| El área en Sky130 no da para 32 KB | Media | Medio | Plan B ya definido: 16 KB, o XIP con caché. Decisión en fase 6, no antes. |
| La toolchain de Gowin/apicula falla en algún primitivo | Baja | Bajo | ECP5 es la primaria; Gowin es un extra. |
| Deriva del alcance hacia el perfil "X" | **Alta** | Alto | Regla explícita: nada de extensiones hasta que la regresión de compatibilidad esté verde. |
| Cierre de una lanzadera (como pasó con Efabless) | Media | Medio | Hay tres vías activas (ChipFoundry, IHP, wafer.space). El RTL es portable entre PDKs. |
| Agotamiento: es un proyecto de meses | **Alta** | Alto | Hitos con demo visible: fase 2 da un LED parpadeando en hardware real a las 7 semanas. |

---

## 14. Métricas de éxito

**v1.0 (FPGA)** — todas verificables automáticamente:

1. 131/131 instrucciones pasando el diferencial contra simavr.
2. 0 divergencias en 10⁷ instrucciones aleatorias.
3. ALU: 100 % de cobertura exhaustiva.
4. Ciclos: 0 desviaciones respecto a la tabla del manual del ISA.
5. Mapa de registros: 0 diferencias frente a `iom328p.h`.
6. 26/26 vectores de interrupción verificados.
7. ≥ 10 sketches de Arduino corriendo sin modificar, NeoPixel incluido.
8. Fmax ≥ 32 MHz en ECP5.
9. Subida desde el Arduino IDE funcionando de principio a fin.
10. 0 dependencias de herramientas propietarias.

**v2.0 (silicio)**: GDSII con DRC/LVS limpios, enviado a una lanzadera, chips recibidos y
caracterizados.

---

## 15. Qué hacer a continuación

1. Confirmar la placa FPGA (§9) — condiciona los constraints de la fase 2.
2. Ejecutar la fase 0.
3. Empezar la fase 1 por el par `alu.v` + verificación exhaustiva: es el bloque con el mejor
   retorno inmediato y establece el patrón de "nada entra sin oráculo" para todo el proyecto.

---

## Referencias

- [OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build) — distribución binaria de herramientas libres
- [LibreLane](https://github.com/librelane/librelane) — sucesor de OpenLane, bajo la FOSSi Foundation
- [Anuncio de LibreLane, FOSSi Foundation](https://fossi-foundation.org/blog/2025-08-17-librelane)
- [ChipFoundry — chipIgnite](https://chipfoundry.io/faqs) — lanzaderas Sky130
- [Tiny Tapeout](https://tinytapeout.com/) — silicio de bajo coste, Sky130 / IHP / GF180
- [efabless/sky130_sram_macros](https://github.com/efabless/sky130_sram_macros) — macros de SRAM para Sky130
- [Cierre de Efabless (Tom's Hardware)](https://www.tomshardware.com/tech-industry/semiconductors/efabless-shuts-down-fate-of-tiny-tapeout-chip-production-projects-unclear)
- [Diseño clean-room (Wikipedia)](https://en.wikipedia.org/wiki/Clean-room_design)
- [LGT8F328P](https://github.com/RalphBacon/LGT8F328P-Arduino-Clone-Chip-ATMega328P) — precedente comercial de un compatible ATmega328P

*AVR es una marca registrada de Microchip Technology Inc. Arduino es una marca registrada de
Arduino SA. Este proyecto es una implementación independiente, sin relación ni respaldo de dichas
compañías.*
