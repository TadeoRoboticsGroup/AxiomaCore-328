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
- `docs/05-register-map.md` (documentación)
- `tools/gen_regmap.py --check` (test de CI que falla si divergen)

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
9. **Flags de `NEG`**: `H = R3 | Rd3`, `V = (R == 0x80)`, `C = (R != 0x00)`. Es la instrucción con
   los flags más peculiares. Ojo: `Rd3`, no `¬Rd3`.
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

**Esto es lo que hay, no lo que se pensaba tener.** La versión de este árbol que vivió aquí hasta
el 23-sep-2026 era la proyección original y nombraba ficheros que nunca llegaron a existir
—`pcint.v`, `iomux.v`, una `eeprom.v` en `mem/`, tests de cocotb—. Es exactamente el fallo que
cerró la deuda **D9**, repetido en un diagrama en vez de en una cita, que es donde `check-docs` no
mira: su comprobación de rutas lee las que van entre acentos graves, no las de un bloque de código.

```
AxiomaCore-328/
├── README.md                      estado real + matriz de compatibilidad medida
├── Makefile                       punto de entrada unico · `make check-all` es la regresion
├── docs/
│   ├── 00-PLAN.md                 este documento
│   ├── 01-arquitectura.md         el chip por dentro, y las diferencias declaradas
│   ├── 02-legal.md                politica clean-room
│   ├── 03-verificacion.md         los oraculos, las puertas y por que cada una
│   ├── 04-herramientas.md         el entorno reproducible
│   ├── 05-register-map.md         el mapa de I/O
│   ├── 06-deuda-tecnica.md        lo construido a medias, con su fecha y su cierre
│   └── adr/                       0001 memorias · 0002 frontera analogica · 0003 relojes
├── rtl/
│   ├── core/       axioma_core.v  axioma_seq.v  axioma_decode.v  axioma_alu.v
│   │               axioma_regfile.v  axioma_sreg.v  + los dos .vh de opcodes
│   ├── bus/        axioma_dbus.v
│   ├── mem/        axioma_progmem.v  axioma_dmem.v  backends/
│   ├── periph/     gpio  gpior  prescaler  timer0  timer1  timer2  timer8  usart
│   │               spi  twi  extint  adc  ac  wdt  eeprom  clkctrl  irq
│   ├── soc/        axioma328_soc.v  axioma_regmap.vh
│   └── fpga/       axioma_adc_frente.v  ecp5/  ice40/  gowin/
├── sim/
│   ├── diff/       el arnes de co-simulacion contra simavr, y sus 20 programas
│   ├── alu/        exhaustivos de ALU, SREG y banco de registros
│   ├── periph/     un banco por periferico, escrito desde la hoja de datos
│   ├── soc/        mapa de I/O, robustez, extremo a extremo, disparo del ADC,
│   │               prescaler del reloj y sueño
│   ├── mem/  bus/  random/  perf/
│   └── mutation.py el catalogo de mutantes
├── fw/                            el C que se compila con avr-gcc sin tocar
├── tools/                         synth_check.py  coverage.py  check_docs.py
├── sw/                            arduino/  avrdude/  platformio/   — fase 4
├── asic/                          librelane/  macros/  reports/     — fase 6
├── board/  images/  legacy/       la placa, las figuras, y el codigo de partida
└── (la sintesis no tiene directorio: la gobiernan el Makefile y tools/)
```

Y la propia correccion de arriba estuvo a punto de repetir el fallo: la primera version de este
arbol nuevo nombraba un `synth/` que tampoco existe. Se comprobo fichero a fichero antes de
publicarlo, que es lo unico que funciona con un diagrama.


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

- [x] Instalar OSS CAD Suite, toolchain AVR, simavr, cocotb. `make check-tools`: **12 disponibles,
      0 pendientes**.
- [x] `git mv` de todo lo actual a `legacy/`. Purgar los `.tar.gz` del historial.
- [x] Crear la estructura de §6, `LICENSE` (Apache-2.0), `LICENSE-EXCEPTIONS.md`, `docs/02-legal.md`.
- [x] Borrar `bootloader/optiboot/`, `layout/*.gds`, `openlane/src/`.
- [x] Generador `tools/gen_regmap.py`: `iom328p.h` → `axioma_regmap.vh` + `docs/05-register-map.md`.
      Hoy genera además `sim/soc/regbits.h`, que es el que dice qué bits existen.
- [x] CI mínima en GitHub Actions (lint + build). Hoy son 43 objetivos.

**Criterio de aceptación:** `make check-tools` pasa; el mapa de registros se genera y su test de
diff está verde; `git clone` limpio pesa < 2 MB.

> **Dos de tres. El tamaño NO se cumple, y conviene decirlo con el número delante.** Un clon
> empaquetado pesa hoy **16 MB**: 4,6 MB de árbol de trabajo y **11 MB de historial**.
>
> La causa no son los `.tar.gz` que este punto mandó purgar —ésos no están—, sino **las cuatro
> figuras PNG del README**: entre todas sus versiones suman **~16 MiB de objetos**, porque cada
> `make diagrams` añade un binario nuevo de ~700 KB y se han regenerado muchas veces. El resto del
> repositorio, con meses de trabajo, cabe en poco más de 2 MB de objetos.
>
> Se deja anotado y no se arregla de tapadillo: limpiarlo es **reescribir el historial**, que es una
> decisión del proyecto y no de un commit de documentación. Lo que sí cambia desde hoy es el
> criterio para el futuro: **regenerar las figuras sólo cuando cambien de verdad**, no por costumbre
> al tocar el README.

### Fase 1 — Núcleo ISA (4 semanas) ← *camino crítico*

- [x] `alu.v` — combinacional pura, sin latches, multiplicador compartido.
- [x] `sreg.v` — actualización enmascarada, 29 comprobaciones dirigidas.
- [x] Modelo de referencia de la ALU en Python + **verificación exhaustiva** (Capa 2):
      **22 282 240 vectores, 24 operaciones, 0 fallos.**
- [x] **Tercer oráculo independiente**: contraste de los mismos 22 282 240 casos contra `simavr`
      ejecutando instrucciones AVR reales. Encontró un fallo que la verificación contra nuestro
      propio modelo no podía encontrar (flag H de `NEG`).
- [x] **Prueba de mutación** de todo el RTL: **317 fallos inyectados, 317 detectados** —eran 92 al cerrar la fase 1 y 160 al cerrar la 2; el catálogo crece con cada periférico y con cada puerta nueva—. El banco puede fallar, y se comprueba que puede.
- [x] `regfile.v` — 2R/1W más un puerto de 16 bits direccionado por índice de par, de modo que la
      interfaz no puede expresar una dirección impar. 800 064 comprobaciones contra un modelo
      sombra en 200 000 ciclos aleatorios, 0 fallos; **7 mutantes** y los 7 detectados.
- [x] `decode.v` — decodificación combinacional completa, sin cerrojos, 579 LUT en ECP5.
      **Contrastado contra `avr-objdump` sobre los 65 536 opcodes posibles: 0 discrepancias**
      en tamaño de instrucción, clasificación y operandos de registro. Las 192 instrucciones
      de 32 bits coinciden exactamente.
- [x] `seq.v` — secuenciador multiciclo completo, y `core.v` que une todo. **Verificado en parte:**
      la co-simulación diferencial pasa sobre tres programas, no sobre las 131 instrucciones.
- [x] `progmem` / `dmem` con la interfaz que fija §5.7. Ambas se mapean a bloques DP16KD del
      ECP5. **Registradas en flanco de bajada** para que el acceso quepa dentro del ciclo y no se
      rompan las cuentas de ciclos de LD, LDS y ST: ver
      [ADR 0001](adr/0001-memorias-en-flanco-de-bajada.md). Falta su test funcional.
- [x] Arnés de co-simulación diferencial contra simavr (Capa 1). Encontró dos fallos reales del
      secuenciador: un desfase de un ciclo en la búsqueda y `RET` leyendo el byte equivocado.
- [x] Suite dirigida del conjunto de instrucciones: cuatro programas que, con los tres
      anteriores, ejercitan los **97 mnemónicos** ejecutables del ATmega328P. `SPM` queda
      fuera a propósito (sin ciclos fijados en el manual y sin emulación comparable).
- [x] Tabla de ciclos (Capa 3) **comprobada mecánicamente, cobertura parcial.** La tabla del
      manual es un fichero de datos proyectado sobre los 65 536 opcodes con el mnemónico de
      `avr-objdump`, y el arnés diferencial contrasta los ciclos de cada instrucción retirada.
      Encontró un fallo real: `MOVW` costaba 2 ciclos donde el manual dice 1, con el estado
      correcto —invisible para la comparación de estado—. Cobertura: **97/97 mnemónicos**,
      120 048 instrucciones comprobadas y 0 desviaciones.

- [x] **Regresión aleatoria de 10⁶ instrucciones.** `sim/random/gen_random.py` genera programas
      válidos con operandos aleatorios y semilla fija; `make sim-random` los contrasta contra
      simavr. 10 programas × 100 000 instrucciones, **0 divergencias**.

**Criterio de aceptación: CUMPLIDO.**

| Requisito | Estado |
|-----------|--------|
| El conjunto de instrucciones pasa el diferencial contra simavr | 97/97 mnemónicos, 7 programas dirigidos |
| 10⁶ instrucciones aleatorias sin divergencia | 10⁶, 0 divergencias |
| ALU 100 % exhaustiva verde | 22 282 240 vectores, 0 fallos |
| Tabla de ciclos exacta | 97/97 mnemónicos, 0 desviaciones |

**Deuda conocida que la fase 1 no puede saldar: SALDADA en la fase 2.** La máquina de estados de
entrada a interrupción estaba escrita en `axioma_seq.v` pero `irq_req` estaba atado a 0 en el top
de simulación, así que no había forma de ejercitarla. Con el Timer0 y el controlador de
interrupciones ya se dispara, y al hacerlo aparecieron **dos fallos reales** en esa ruta:

- la dirección del vector se calculaba como `vector × 4` en palabras, cuando cada vector ocupa
  **dos** palabras y le corresponde `vector × 2`. El núcleo saltaba al doble de lejos;
- la máquina de estados se sostenía con una condición que incluía `cyc == 0`, y esa condición
  dejaba de cumplirse en cuanto el primer ciclo limpiaba el bit `I`: los ciclos 1 a 3 de la
  entrada se caían al `case` de instrucciones y ejecutaban lo que hubiera en el registro de
  instrucción.

Los dos están en el catálogo de mutación para que no puedan volver.

### Fase 2 — SoC mínimo y primer bitstream (2 semanas)

- [x] `dbus.v` con el mapa unificado de §5.2. **790 976 comprobaciones sobre las 65 536
      direcciones**, más seis mutantes detectados. El espacio de direcciones es enumerable por
      completo, así que se barre entero en vez de muestrear.
- [x] `gpio.v`, con el toggle por `PINx` —la trampa nº 5— y el sincronizador que obliga al `nop`
      entre escribir `PORTx` y leer `PINx`. Verificado por dos vías: diferencial contra simavr
      sobre los tres puertos, y banco propio contra la hoja de datos con las dos máscaras.
- [x] `timer0.v` **y `prescaler.v`**, que va aparte porque el prescaler es un contador libre de 10
      bits **compartido** con el Timer1: es la trampa nº 12, y arrancar un temporizador no lo pone
      a cero. Los ocho modos de onda, el doble búfer de `OCR0x`, las banderas `TIFR0` con su
      *write-1-to-clear*, `GTCCR` con `TSM`/`PSRSYNC`, el reloj externo por T0 y los pines de
      comparación. **4 480 668 comprobaciones** contra un modelo de la hoja de datos, 0 fallos, y
      **12 mutantes** y los 12 detectados. El encaminamiento de OC0A/OC0B al pad es de la fase 3, con el resto
      de los canales PWM.
- [x] `irq.v` — 26 vectores con prioridad fija. Verificado de forma **exhaustiva**: las
      67 108 864 combinaciones posibles de peticiones, 201 326 592 comprobaciones. Con él se
      salda la deuda de la fase 1: la entrada a ISR se ejercita por primera vez, y encontró dos
      fallos reales en el secuenciador.
- [x] **`rtl/soc/axioma328_soc.v`: la integración pasa a ser diseño.** Hasta ahora el mapa de
      direcciones de I/O y el cableado de los 26 vectores vivían en `sim/diff/axioma_sim_top.v`, un
      fichero que empieza diciendo «NO forma parte del diseño»: lo que la regresión verificaba era
      un banco de pruebas, y la integración era la única parte del chip sin verificación propia.
      No era teórico —el bit desplazado que convertía `TIMER0_COMPA` en `TIMER1_OVF` estaba ahí—.
      De paso desaparece el array que fingía que todo el espacio de I/O era RAM: los tres `GPIOR`
      son registros del 328P y ahora son un periférico (`axioma_gpior.v`), y una dirección sin
      implementar se lee como cero, como en el chip. `make sim-soc` barre las **221 direcciones** alcanzables por
      el bus real y comprueba que no hay colisiones y que el mapa es el de la hoja de datos.
- [x] `make synth-check`: yosys sobre todo el RTL, falla ante un latch y mide el área de cada
      módulo. Cierra un hueco que venía de la fase 1 —el lint de verilator no es un sintetizador—
      y entra en la CI junto con los dos bancos nuevos, que tampoco estaban.
- [x] **`usart.v`.** Modo asíncrono completo: 5 a 9 bits de datos, paridad par, impar o ninguna,
      uno o dos bits de parada, U2X, búfer de recepción de **dos niveles**, `FE`/`DOR`/`UPE` viajando
      con su trama, y los tres vectores de interrupción. El modo SPI maestro queda
      declarado fuera de alcance: sus bits se almacenan y se leen, pero no hacen nada.
      **El modo síncrono y `MPCM` se cerraron el 14-sep** — ver la fase 3.

      Es el primer periférico con **efecto lateral de lectura** —leer `UDR0` saca un byte del
      búfer, la trampa nº 11—, y aquel para el que **simavr sirve de menos**: su modelo no
      serializa nada. Así que la forma de onda la certifica un receptor escrito desde la hoja de
      datos que decodifica el pin y mide el periodo de bit. 44 082 comprobaciones, y el receptor
      aguanta un pulso de ruido de una muestra en cualquier posición de cualquier bit — que es
      para lo que existe el voto por mayoría.
- [x] **Top de ECP5 y bitstream.** `rtl/fpga/ecp5/axioma_ulx3s_top.v`: PLL, secuencia de reset,
      celdas de pad con triestado y PORTB espejado en los LED. `make bitstream-ulx3s` produce
      276 KB para la ULX3S 25F, con el **29 % de las LUT y el 58 % de la BRAM** — la medida es de
      después del Timer2 y del SPI, que es lo que ha subido las LUT.
- [x] **Bootstrap: el programa va dentro del bitstream.** `tools/bin2mem.py` convierte el binario
      de avr-gcc en el fichero que `$readmemh` precarga en la memoria de programa.
- [x] **Subir el reloj, primera vuelta.** De **15,55 a 20,28 MHz** con la misma restricción
      exigente, +30 %, y sin tocar una sola cuenta de ciclos. La causa estaba en la implementación,
      no en el [ADR 0001](adr/0001-memorias-en-flanco-de-bajada.md): la dirección de la memoria de
      datos se calculaba de forma combinacional desde la palabra de instrucción, así que la media
      década de reloj que el ADR reserva para el acceso tenía que cubrir además el decodificador,
      el banco de registros y el sumador del desplazamiento. Ahora va registrada. Detalle y
      medidas en la adenda del ADR.
- [ ] **Subir el reloj, lo que queda.** El camino que manda son 24,7 ns con **sólo 4 ns de lógica y
      14,6 de rutado**: ya no es profundidad, es distancia. El siguiente paso es sacar el dato de
      escritura de la SRAM del camino combinacional, lo que obliga a separar los buses de datos de
      SRAM y de I/O. Objetivo de la fase 5: 32 MHz.

- [x] **Cobertura de código como puerta** (`make coverage`), fusionando todas las fuentes. La
      primera medida encontró **cuatro caminos que ningún banco ejecutaba jamás**, y dentro de uno
      —`SPM`— había **tres fallos**. Hoy: **99,8 %**, con los siete puntos restantes adjudicados como
      inalcanzables. Detalle en [`03-verificacion.md`](03-verificacion.md).
- [ ] Backend `fpga_bram` como módulo aparte (hoy la memoria inferida ya se mapea a BRAM).

#### Qué placa hace falta, y cuál es el recurso que aprieta

**No hace falta tener la placa para seguir.** El flujo completo —síntesis, emplazamiento, rutado y
análisis de tiempos— corre en el PC: `nextpnr` da Fmax y utilización sin hardware delante. Lo único
que exige placa es ejecutarlo de verdad. Y la co-simulación diferencial contra `simavr` es una
verificación **más fuerte** que ver parpadear un LED: el LED prueba que integra, el diferencial
prueba que ejecuta bien instrucción a instrucción y con los ciclos exactos.

El recurso que decide no es la lógica, es la **memoria**. Medido sobre el diseño de hoy:

| Flash | BRAM (DP16KD) | LUT |
|-------|---------------|-----|
| 32 KB — la del ATmega328P | 33 | 4 628 (19 % de la 25F) |
| 16 KB | 17 | ídem |
| 8 KB | 9 | ídem |

`axioma_progmem` ya tiene el parámetro `WORDS`, así que recortar la Flash es cambiar un número —a
costa, claro, de dejar de ser una réplica en ese punto.

Consecuencia práctica: cualquier placa con un **ECP5 25F** sirve sin tocar nada del flujo, sólo el
fichero de constraints. Las hay desde 15-25 $ —las controladoras de paneles LED llevan justo ese
chip— frente a los 145 $ de una ULX3S, que lo que añade es comodidad (USB-JTAG, SDRAM, HDMI) y no
capacidad que este diseño necesite. Con un FPGA más pequeño de otra familia hay que decidir entre
recortar la Flash o cambiar de flujo, y los portes a iCE40 y Gowin ya están en la fase 5.

#### El oráculo de los periféricos, decidido y estrenado

El núcleo tenía a `simavr`, que ejecuta AVR de verdad. Los periféricos **no tienen un oráculo tan
bueno**: los modelos de periférico de simavr son bastante menos fiables que su núcleo. Era el mayor
riesgo metodológico de las fases 2 y 3, y se resuelve por capas:

| Qué se verifica | Con qué |
|-----------------|---------|
| Semántica de los registros | Diferencial contra simavr, con la tabla `COMPARABLE[]` de `sim/diff/diff.cpp`, que **crece con cada periférico** |
| Lo que simavr no modela | Banco propio contra la hoja de datos |
| Forma de onda en los pines | Modelos de bus en el banco (capa 4) |
| Donde discrepen simavr y la hoja de datos | **Manda la hoja de datos**, y se anota como cuestión abierta |

Con un periférico de tres registros ya aparecieron **tres diferencias** entre simavr y el chip (ver
[`01-arquitectura.md`](01-arquitectura.md) §8bis). La consecuencia práctica es una regla: **leer el
modelo de simavr antes de escribir el RTL de cada periférico**, no después.

**Camino crítico hasta el criterio de aceptación:** el `delay()` de un `Blink.ino` compilado con el
core de Arduino llama a `millis()`, que depende de la interrupción de desbordamiento de Timer0. Así
que `timer0` e `irq` no son opcionales para llegar al LED. **Ya está recorrido:** los dos están
hechos y verificados, y `sim/diff/tests/irq_timer0.S` enciende los tres vectores del Timer0 a la
vez para que se ejercite también la prioridad.

Con el Timer0 hubo que decidir además **quién es el oráculo de qué**, porque simavr no cuenta ciclo
a ciclo: interpola `TCNT0` desde `avr->cycle` y ancla su base en el ciclo en que se escribe
`TCCR0B`. *Cuándo* salta la interrupción lo decide el RTL y lo verifica su banco propio contra la
hoja de datos; *qué hace el núcleo* al saltar lo verifica simavr, al que el arnés le levanta el
mismo vector. Detalle en [`03-verificacion.md`](03-verificacion.md), capa 4.

**Criterio de aceptación:** un `Blink.ino` compilado con avr-gcc parpadea un LED **en la FPGA**, y
`Serial.println("Hola")` sale por el UART y se lee en el PC.

**CUMPLIDO EN SIMULACIÓN** (`make sim-hello`), que es todo menos el cable: `fw/hello/hello.c` se
compila con avr-gcc y avr-libc **sin modificar** —incluido `<util/setbaud.h>`, que calcula el
divisor él solo—, corre sobre el SoC completo, y el banco **decodifica el pin** como lo haría un
conversor USB-serie. 27 tramas leídas, 0 mal formadas, el texto correcto, PB5 parpadeando y la
velocidad medida a −0,76 % del nominal. No se mira ningún registro para sacar los caracteres.

**La velocidad no son 115200, y el motivo no es la USART sino el reloj.** A 12,5 MHz el divisor más
cercano a 115200 deja un error del −3,1 %, y una trama 8N1 aguanta como mucho un ±2,5 % sumando los
dos extremos; a 19200 el error es del −0,76 %. Subir el reloj —la tarea de optimización de timing
que ya está anotada— arregla las dos cosas a la vez. Conviene saber que un ATmega328P real a 16 MHz
tampoco llega limpio a 115200: se queda en +2,1 % usando U2X, que es justo por lo que el core de
Arduino activa U2X siempre.

Lo único que queda del criterio es **enchufar la placa**.

#### Lo que BLOQUEA un tape-out, hoy

Auditado el 11-sep-2026 contra lo que exige una foundry, no contra lo que exige una FPGA. El núcleo
y los periféricos que existen están verificados; **el conjunto no está listo para fabricar**, y
estas son las razones concretas:

| # | Bloqueo | Dónde se resuelve |
|---|---------|-------------------|
| 1 | **`SPM` no es el del 328P.** No hay `SPMCSR` ni granularidad de página: lo que hay es la escritura de una palabra. Un bootloader real corrompería la Flash | Fase 4 |
| 2 | **Doble flanco de reloj.** ACOTADO el 11-sep: lo único que obliga a que el **macro de SRAM** sea de flanco de bajada son `LDS` y `STS`; todo lo demás presenta la dirección ya registrada y funcionaría con un macro normal. Los flancos de bajada que quedan son celdas estándar de `axioma_dbus`, donde invertir el reloj es rutina. Mitigación identificada: una cola de prebúsqueda de dos palabras. Ver la adenda 2 del [ADR 0001](adr/0001-memorias-en-flanco-de-bajada.md) | Fase 6, y **ya no bloquea la fase 3** |
| 3 | **Sincronizador de una sola etapa en `PINx`.** Es deliberado —lo exige la temporización documentada del `nop`— pero es un riesgo de metaestabilidad que hay que firmar con un cálculo de MTBF, no dar por bueno | Fase 5 |
| 4 | **Sin verificación formal.** `sby` está instalado y no hay ni una propiedad escrita | Fase 5 |
| 5 | **Sin simulación post-P&R con retardos anotados.** Es el segundo punto de «a verificar» del propio ADR 0001 | Fase 5 |
| 6 | **Sin DFT.** Ni cadenas de scan ni BIST para la SRAM. Un chip sin DFT no se puede clasificar en oblea | Fase 6 |
| 7 | **CERRADO el 24-sep.** Aquí decía que a `SPM_READY` le faltaba fuente; la tiene desde que existe `axioma_spm`, y **los 25 vectores disparan desde un programa** | **Cerrado** |
| 8 | **Los `initial` de las memorias** no existen en silicio; los sustituye el backend del PDK | Fase 6 |

Nada de esto es una sorpresa: todo estaba en el plan. Lo que cambia es que ahora está **medido y
enumerado** en vez de implícito.

### Fase 3 — Periféricos completos (5 semanas)

- [x] **`timer1.v` con el registro TEMP de 16 bits.** Los 16 modos de onda, la captura de entrada
      con su cancelador de ruido de cuatro muestras, y el **TEMP compartido** entre `TCNT1`, `ICR1`,
      `OCR1A` y `OCR1B` —la trampa nº 4—, que es lo que hace que una interrupción a mitad de un
      acceso de 16 bits corrompa el otro registro. simavr **no lo modela**: escribe los dos bytes
      por su cuenta, así que esto sólo lo certifica el banco propio. 4 475 970 comprobaciones, y
      **usa el mismo prescaler que el Timer0**, con lo que la trampa nº 12 deja de ser teoría.

      De paso cerró un agujero de verificación que valía para todos los periféricos: con las cuatro
      interrupciones habilitadas a la vez, **intercambiar dos vectores es invisible** —el arnés le
      dice a simavr cuál tomó el RTL, así que no puede desmentirlo—. Se comprobó inyectando ese
      fallo exacto y sobrevivía. El programa de prueba habilita ahora **una sola cada vez**.
- [x] **`timer2.v`, y con él los SEIS canales PWM.** No es el Timer0 con otro nombre: tiene
      **prescaler propio** con dos tomas que los otros no tienen —`/32` y `/128`, que existen para
      dividir 32 768 Hz y dar un segundo exacto—, sus bits `CS` están corridos —`CS=4` es `clk/64`
      y no `clk/256`—, no tiene entrada de reloj externo, y lleva el **modo asíncrono** con `ASSR`.

      La máquina de forma de onda SÍ es la misma, palabra por palabra en la hoja de datos, así que
      vive una sola vez: `axioma_timer8.v`, con `axioma_timer0.v` y `axioma_timer2.v` aportando su
      decodificación de direcciones y su selector de reloj. Copiarla habría garantizado que dentro
      de un año uno tuviera un arreglo que el otro no. El refactor se hizo con el banco del Timer0
      SIN TOCAR: sus 4 480 668 comprobaciones son la red que dice que el motor extraído se comporta
      igual que el que estaba dentro.

      4 666 627 comprobaciones contra un modelo de la hoja de datos —el mismo `timer8_ref.h` que
      usa el banco del Timer0, por lo mismo— y un programa de co-simulación contra simavr con 30
      entradas a ISR. El modo asíncrono cuenta los flancos de `TOSC1` sincronizados; **sin cristal
      no cuenta**, que es lo que hace el chip en una placa que no lo lleva.

      Los seis canales llegan al pad y `make sim-hello` **los mide todos en el pin a la vez**, con
      seis ciclos de trabajo distintos a propósito: un mapa de pines cruzado cambia las cifras.
- [x] **`spi.v`, maestro y esclavo.** Los cuatro modos de `CPOL`/`CPHA`, `DORD`, las ocho
      divisiones de reloj con `SPI2X`, el doble búfer de recepción, `WCOL`, la secuencia de dos
      accesos que limpia `SPIF` —la trampa nº 11 otra vez— y la detección de colisión de maestros.

      **El oráculo es el otro extremo del cable.** simavr no serializa nada: su `avr_spi_write`
      guarda el byte, programa un temporizador de `clkdiv*8` ciclos y levanta la interrupción, de
      modo que leer `SPDR` devuelve **lo que se escribió**. Así que el banco implementa un maestro
      y un esclavo desde la hoja de datos y los enchufa al DUT; si los dos extremos no coinciden
      bit a bit, uno de los dos está mal.

      **Encontró tres fallos reales en el RTL, y los tres son de los que no dan ningún error:**
      el maestro muestreaba `MISO` a través del sincronizador de dos etapas —a `fosc/4` eso es un
      bit entero y todo llega desplazado—; el reloj se cortaba medio periodo antes de volver al
      reposo; y `SPIF` se levantaba con ese medio periodo todavía por delante, con lo que el
      modismo `while(!(SPSR&(1<<SPIF))); SPDR = siguiente;` se llevaba un `WCOL` y perdía el byte
      en silencio.

      **Y un cuarto de compatibilidad:** la colisión de maestros sólo aplica si `SS` es ENTRADA. Sin
      eso, un `digitalWrite(SS, LOW)` —como selecciona a su esclavo cualquier sketch de Arduino—
      borraba `MSTR` en la primera transferencia.

      El SPI comparte pines con los temporizadores —PB3 es `MOSI` y `OC2A`; PB2 es `SS` y `OC1B`—
      y con `SPE` puesto manda el SPI, que es lo que dice la tabla de anulaciones. Para forzar la
      dirección hizo falta darle a `axioma_gpio` una anulación **de dirección** separada de la de
      valor: la tabla 18-1 sí fuerza a entrada `MISO` en el maestro y `SS`, `MOSI` y `SCK` en el
      esclavo, mientras que los canales de comparación no fuerzan la dirección nunca.

      `make sim-hello` cierra el lazo a nivel de SoC: el firmware hace una transacción de arranque
      de tres bytes y el banco **la decodifica del pin** con el reloj de `SCK`, como un analizador
      lógico. Es lo único que ve si el SoC encamina el pin a quien manda en cada momento.
- [x] **`twi.v`: maestro, esclavo y arbitraje.** Los 26 códigos de estado de las tablas 21-2 a
      21-6, `TWAMR`, la llamada general, el estiramiento de reloj y el error de bus.

      **No es un cable, es un BUS**, y ahí está toda la diferencia con el SPI. Nadie conduce
      nunca una línea hacia arriba: se tira hacia abajo o se suelta, y el pull-up es el que
      sube el nivel. De ahí salen tres propiedades que ningún periférico anterior tenía, y las
      tres se verifican: **arbitraje** —dos maestros a la vez, y quien suelta la línea y la lee
      baja se calla en ese mismo bit, sin STOP y sin perder el dato—, **sincronización de
      reloj** —el alto no empieza cuando soltamos SCL sino cuando el pin sube de verdad— y
      **estiramiento**, que es lo que hace que una ISR lenta ralentice el bus en vez de
      corromperlo.

      El colector abierto se construye con las DOS anulaciones que `axioma_gpio` ya tenía: el
      valor se ata a cero permanentemente y lo que se modula es la dirección. No hay ningún
      camino por el que el TWI pueda conducir un uno. Y el pull-up sigue saliendo de `PORTC`,
      que es lo que hace funcionar el `digitalWrite(SDA, HIGH)` que `Wire.begin()` lleva dentro.

      **El oráculo es un bus de colector abierto con los dos extremos escritos desde la hoja de
      datos**, más las tablas de estado. simavr no sirve: su `avr_twi.c` transporta direcciones
      y bytes enteros por IRQs internas y no serializa `SDA`. 5 957 comprobaciones.

      **Y por qué pines sale, lo dice `make sim-hello`**, no ese banco: `hello.c` hace un START,
      una dirección y un STOP —lo mismo que `Wire.beginTransmission()` por dentro— y el banco
      **decodifica la línea**: `SDA` en PC4 y `SCL` en PC5. Hasta que se escribió, intercambiar los
      dos pines o moverlos a otros dos **sobrevivía a la regresión entera**: el arnés diferencial
      realimenta el pad sobre sí mismo y un lazo cerrado se cree cualquier cosa.

      **Encontró cinco fallos reales, y ninguno da error con ondas perfectas y un solo maestro:**
      el arbitraje miraba también el noveno bit mientras transmitíamos, con lo que el ACK
      legítimo del esclavo se leía como pérdida y el maestro se rendía justo cuando le acababan
      de decir que sí; tras perder el arbitraje el TWI seguía conduciendo `SDA` y corrompía la
      trama del ganador —por eso no reconocía que el ganador le llamaba a él, y el 0x68 de la
      hoja de datos salía como 0x38—; el START pedido era de flanco y no de nivel, así que una
      petición que llegara en el mismo ciclo que un STOP se perdía y el TWI se quedaba parado
      con `TWSTA` puesto para siempre; el semiperiodo se contaba desde que el pin cambia y no
      desde que se conduce, sumándole los dos ciclos del sincronizador en cada flanco —28
      ciclos de periodo donde la fórmula da 20, o sea 71 kHz donde el programa pidió 100—; y el
      estado de retención forzaba `SCL` abajo siempre, con lo que tras un STOP recibido el chip
      habría bloqueado el bus entero hasta que su ISR contestara.
> **Las cifras de esta lista —área, comprobaciones y mutantes— son las de HOY, no las del día en
> que cada módulo entró.** Se
> mueven cuando se mueve una decisión de todo el chip: al pasar el dispositivo a habilitación de
> reloj (ADR 0003) el ADC bajó de 269 a 217 LUT4 y el perro guardián subió de 100 a 107, porque la
> habilitación entra en el biestable pero añade una entrada a su lógica. Se comprueban con
> `make synth-check`, que es lo que las produce. Los mutantes suben cuando una puerta nueva hace
> observable algo que antes no lo era: el ADC pasó de 15 a 30 al llegar el disparo automático, el
> barrido semántico y el banco de `PRR`.

- [x] **`adc.v`: el controlador SAR, y dentro del SoC.** **Verificado y enchufado**, con su vector
      21 disparando —hoy los 25 tienen fuente—. **1 606 comprobaciones** contra un comparador escrito desde la hoja de datos, **30 mutantes** y
      los 30 muertos, 100 % de cobertura, **217 LUT4** en el ECP5 y sin latches. Hace conversiones
      sueltas —lo que usa `analogRead()`—; el disparo automático era la deuda **D14**, declarada el
      mismo día y **cerrada el 22-sep** en cuanto el comparador analógico, que era la fuente que
      faltaba, entró en el chip.

      **El banco encontró un fallo real, y de los que no dan error:** la conversión duraba **12,5
      ciclos de ADC** en vez de 13, porque arrancaba en cuanto se escribía `ADSC` y no en el
      siguiente flanco del reloj de ADC. Con la cuenta empezada a media fase, medio ciclo se perdía.
      La hoja de datos lo dice con estas palabras —«the conversion starts at the following rising
      edge of the ADC clock cycle after ADSC is written»— y el resultado de la conversión salía
      bien igualmente: sólo se ve midiendo.

      **Y se comprueba de extremo a extremo**, que es lo único que ve el cableado: `hello.c`
      convierte el canal 3 y **escribe el resultado por el puerto serie**, así que el número cruza
      el chip entero —bus, SAR, frente analógico, registros con su cerrojo, USART y PD1— y el banco
      lo lee del pin. Y `DIDR0`, cuyo registro vive en el ADC pero cuyo efecto es del **puerto**,
      enciende un testigo en PB0 sólo si `PINC0` leía uno antes de ponerlo y cero después: ese cable
      entre dos periféricos no lo ve ningún banco de periférico.

      **El modelo del frente analógico vive en `rtl/fpga/`, no en el SoC**, y eso es el ADR: una
      FPGA no convierte tensiones. El comparador y el S/H que usa son los de verdad —el SAR aproxima
      igual que con silicio—; lo sintético es de dónde sale la tensión.

      La frontera con lo analógico está decidida y escrita en el
      [ADR 0002](adr/0002-frontera-analogica-del-adc.md): **el RTL es el registro de aproximaciones
      sucesivas y su secuenciador; el DAC y el comparador quedan fuera**, detrás de cinco señales.
      Es el corte que dibuja la propia hoja de datos, y es lo que permite que el banco compruebe que
      el SAR **converge** —las diez decisiones, en orden de peso— en vez de mirar si el número final
      salió bien.

      **simavr no sirve de oráculo, y aquí menos que nunca:** `avr_adc.c` programa la interrupción a
      `prescale * 11` ciclos donde el manual dice **13** —y **25** la primera conversión— y entrega
      el valor de golpe desde una IRQ en milivoltios. No hay aproximación sucesiva en ninguna parte.
- [x] **`ac.v`: el comparador analógico.** Se corta por el mismo sitio que el ADC —la comparación
      es analógica y llega hecha (ADR 0002)—, y lo que queda dentro es lo que un comparador de
      tensión no sabe hacer solo: **elegir sus entradas**, sincronizar su salida, decidir qué flanco
      interrumpe y llevarla a la captura del Timer1.

      **Las dos entradas no son dos pines fijos**, y ahí está toda la lógica: la positiva es `AIN0`
      o la referencia interna de 1,1 V según `ACBG`; la negativa es `AIN1` o **el canal que elija
      `ADMUX`** si `ACME` está puesto **y el ADC apagado** —la tabla 22-1, literal—. Ese `ACME` vive
      en un registro del ADC, así que el SoC lo cablea entre los dos periféricos.

      2 045 comprobaciones, 8 mutantes, 47 LUT4. **Y la mutación encontró un fallo de
      compatibilidad**: el RTL suprimía la interrupción al apagar el comparador, y la hoja de datos
      avisa de lo contrario —«otherwise an interrupt can occur when the bit is changed»—. Apagarlo
      con la salida alta hace caer `ACO`, y esa caída es un flanco que el chip **sí** cuenta.
      `sim/diff/tests/ac_irq.S` dispara el vector 23 moviendo la entrada negativa por `ADMUX`, que
      es para lo que existe `ACME`.
- [x] **`wdt.v`: el perro guardián, y dentro del SoC.** Con su vector 6 disparando. 43 comprobaciones, 11 mutantes y los 11 muertos, 100 % de cobertura, **107 LUT4**.

      **Lo que de verdad hay que implementar bien es la secuencia temporizada**, no la cuenta: un
      perro guardián que se pueda apagar con una escritura suelta no sirve para nada, porque lo que
      vigila es justamente un programa desbocado. `WDCE` y `WDE` a uno **a la vez**, y el valor
      dentro de los **cuatro ciclos** siguientes; fuera de esa ventana, las escrituras a `WDE` y al
      prescaler se ignoran. `WDIE` **no** está protegido: lo protegido es lo que puede desactivar la
      vigilancia.

      **Su reloj no es el del sistema** —128 kHz propios—, y ésa es su razón de ser: si dependiera
      del principal, un fallo que parase ese reloj pararía también al vigilante. El oscilador entra
      como un pulso, por el mismo criterio del [ADR 0002](adr/0002-frontera-analogica-del-adc.md).

      La mutación cerró **dos huecos del banco**: el pulso de reinicio dura un ciclo y había que
      mirarlo **dentro** del avance —la misma lección que `dbg_irq_entry` en el arnés diferencial—,
      y el contador tiene que estar **quieto** con el perro apagado, no sólo callado: si sigue
      corriendo, al encenderlo el primer vencimiento llega antes de tiempo.
- [x] **`extint.v`: INT0, INT1 y los tres PCINT en un solo módulo.** Son dos mecanismos distintos
      —uno por pin y con dirección de flanco, otro por puerto y sólo «algo cambió»— pero comparten
      el sincronizador y la disciplina de banderas, así que separarlos duplicaría lo único
      delicado. 2 501 159 comprobaciones contra un modelo de la hoja de datos, y un programa de
      co-simulación contra simavr que entra 23 veces en ISR por las cinco fuentes.

      Lo que el banco propio verifica y el diferencial no alcanzaría: el **modo de nivel bajo**, que
      no deja bandera y sostiene la petición mientras el pin esté bajo —de ahí que una ISR que no
      quite la causa se vuelva a entrar para siempre, en el chip también—; que la bandera se ponga
      **con el vector deshabilitado**, que es el sondeo sin interrupciones; y que `PCMSKn` filtre
      también la bandera mientras `PCICR` sólo filtra el salto al vector.

      Para generar los flancos sin cables, el programa de co-simulación usa lo que dice la hoja de
      datos: la detección mira el PIN y no `PORTx`, así que un pin de salida que el programa
      conmute se interrumpe a sí mismo.
- [x] **El disparo automático del ADC (`ADATE` con `ADTS`)** — la deuda D14, cerrada. Las ocho
      fuentes de la tabla 23-6, cableadas y probadas: modo libre, el comparador, `INT0` y cinco
      banderas de los temporizadores.

      **Son las banderas CRUDAS, no las peticiones de vector.** El ADC se dispara con `OCF0A`
      aunque la interrupción de `OCF0A` esté apagada —muestrear a frecuencia fija sin gastar una
      ISR por disparo es justamente el uso—, así que los cuatro módulos que aportan fuentes
      exportan la bandera **sin la máscara de habilitación**. Y el disparo va por el **flanco**:
      con nivel, una sola comparación encadenaría conversiones para siempre, y además cambiar
      `ADTS` a una fuente ya puesta **es** un flanco, que es lo que dice la hoja de datos.

      **La tabla vive en el SoC, y el banco de módulo no puede decir nada sobre ella**: allí
      `adc_trig` es un puerto. Una permutación —que `OCF0A` y `OCF1B` se crucen— pasa el banco de
      módulo, pasa lint, pasa síntesis y sale en el chip. Por eso `sim/soc/tb_soc_trig.cpp` provoca
      cada fuente **por su camino real** —un programa se pone `PD2` como salida y la sube para
      fabricarse su `INT0`, precarga el Timer1 cerca del final para fabricarse su `TOV1`— y
      comprueba cada una tres veces: que dispara con su `ADTS`, que **no** dispara con otro, y que
      sin `ADATE` no dispara nadie. Se cruzaron dos entradas a mano para comprobar que el banco cae.
- [x] **USART: modo síncrono y `MPCM`** — la deuda D3, cerrada.

      **El motor de trama es el mismo**, y de ahí que saliera barato: arranque, datos, paridad y
      parada se cuentan igual, y lo único que cambia es quién dice «avanza un bit». En asíncrono lo
      dice el generador de baudios con su sobremuestreo por dieciséis; en síncrono, los flancos de
      `XCK`. Con el sobremuestreo puesto a uno el contador se agota en el mismo pulso y **la máquina
      de estados no se tocó**. Primero se metió la indirección dejando el camino asíncrono idéntico
      y se corrieron sus 44 082 comprobaciones como red —la misma cifra exacta, 0 fallos—, y sólo
      después se añadió lo nuevo. Es el orden que ya salvó el refactor del Timer0.

      `XCK` es `PD4` y **la dirección la pone el programa**: `DDR_XCK0` es lo que elige entre
      maestro —reloj interno, `f_XCK = f_CPU/(2·(UBRR+1))`— y esclavo. El periférico anula el valor
      del pin y nunca su dirección, al contrario que el SPI. Y `UCPOL`, visto desde dentro, es una
      inversión del pin: se trabaja siempre con la misma convención y el pin lleva el reloj pasado
      por un XOR, con lo que salen las dos filas de la hoja de datos sin duplicar nada.

      **45 313 comprobaciones**, y dos lecciones: que el dato llegue **no** prueba que `UCPOL` esté
      bien —con los dos extremos equivocados igual la trama sale perfecta, así que hay que mirar el
      flanco—, y que `RXB8` se lee **antes** que `UDR0`, porque leer `UDR0` saca el byte del búfer y
      con él su noveno bit. Lo segundo lo destapó el barrido aleatorio: los casos dirigidos tenían
      el bit 8 a cero y pasaban sin probar nada.
- [x] **`TXD` y `RXD` en `PD1` y `PD0`** — la deuda D13, cerrada. Salían del SoC por dos puertos
      aparte, así que el pinout no era el del 328P en esos dos pines y el programa no podía usarlos
      como E/S general con la USART apagada. No hizo falta nada nuevo: `axioma_gpio` ya tenía las
      dos anulaciones. Con `TXEN0` puesto `PD1` es salida pase lo que pase en `DDRD1`; con `RXEN0`
      puesto `PD0` es entrada pase lo que pase en `DDRD0`, y su pull-up sigue saliendo de `PORTD0`.
      **Se comprueba en el pin**: `hello.c` deja `PD0` como salida a propósito y no toca `DDRD1`, y
      `make sim-hello` verifica que al encender la USART los dos dan la vuelta. Es lo único que
      distingue un pin encaminado de un pin que resulta que vale lo mismo.
- [x] **La USART como MAESTRO SPI (`UMSEL` = 11)** — la deuda D12, cerrada. Es el mismo motor por
      tercera vez, con la trama más corta que se puede escribir: ocho bits y nada más.

      **Lo que no se pudo reutilizar, y por qué:** sin bit de arranque, la trama la delimita **el
      reloj**, así que el receptor arranca con el transmisor y la trama muere en el **octavo flanco
      de salida del pulso** —el único instante que existe con las dos fases de `UCPHA` y el único
      que deja el pin en su reposo—; `XCK` **sólo corre mientras hay trama** y vuelve a su nivel de
      reposo, porque un esclavo SPI cuenta flancos y un pulso de más lo descoloca para siempre; y
      **el dato no pasa por el sincronizador de tres etapas**, que en síncrono se podía permitir
      porque el bit de arranque viaja por el mismo retardo y alinea la trama sola, y aquí no hay
      arranque que alinee nada: tres ciclos a `f_CPU/2` son bit y medio.

      `UCPHA` intercambia los dos flancos en vez de duplicar la máquina, y `UDORD` se resuelve
      dando la vuelta al byte al cargarlo y al guardarlo, con lo que el desplazador sigue siendo
      uno. Los bits de `UCSR0C` son los mismos biestables con otro nombre, como en el chip.

      **46 650 comprobaciones** contra un esclavo SPI escrito desde la hoja de datos, doce mutantes
      nuevos y los doce muertos. **Y por qué pin sale `XCK` no lo puede decir ese banco**, que no ve
      el SoC: `hello.c` hace una transacción MSPIM de tres bytes y `make sim-hello` la decodifica
      **del pin** —`XCK` en PD4 con 48 flancos exactos y `96 5A C3` por PD1—, con dos mutantes que
      sólo caza ese banco. De paso: al modo síncrono le faltaba su velocidad máxima —la suite
      empezaba en `UBRR=3` y `UBRR=0` es `f_CPU/2`—, un mutante superviviente resultó **equivalente**
      y se quitaron tres líneas muertas, y la cobertura destapó que el segundo nivel del búfer no lo
      pisaba nadie en MSPIM.
- [x] **`eeprom.v`: 1 KB con su máquina de `EECR`, y dentro del SoC.** Con el **vector 22**
      disparando. Con la EEPROM dentro sólo quedaba `SPM_READY` sin fuente, y la tiene desde
      que existe `axioma_spm`. 49 comprobaciones, **12 mutantes** y los 12 muertos, 100 % de cobertura,
      **127 LUT4** y **una sola BRAM**.

      **Tres cosas, por orden de lo que duele si falla.** La **secuencia temporizada** —`EEMPE` y,
      dentro de cuatro ciclos, `EEPE`—, que existe porque una escritura perdida en la EEPROM no se
      nota hasta el siguiente arranque. **La física de la celda**: borrar la pone a `0xFF` y
      escribir sin borrar sólo puede **apagar** unos; tratarla como RAM haría funcionar aquí código
      que en silicio no funciona. Y **el tiempo**: 3,4 ms borrando y escribiendo, 1,8 ms haciendo
      sólo una de las dos, contados con el oscilador interno —que entra de fuera, por el criterio
      del [ADR 0002](adr/0002-frontera-analogica-del-adc.md)—.

      **`EE_READY` es de NIVEL, no de bandera** —«the interrupt is constantly triggered when EEPE is
      cleared»—, así que este módulo no tiene `ack`: la ISR tiene que quitar `EERIE` o lanzar otra
      escritura. Inventarle una bandera habría sido más cómodo y menos compatible.

      **Y la síntesis cazó un fallo antes del commit**: la lectura de la celda era combinacional, y
      con eso yosys no infiere memoria —«replacing memory with list of registers»: 1 024 bytes
      convertidos en **8 192 biestables**, más que todo el resto del chip—. Con la lectura
      registrada, la EEPROM entera cabe en **una BRAM**.
- [x] **`clkctrl.v`: `CLKPR`, `PRR`, `SMCR`, `MCUCR`, `MCUSR` y los modos de sueño.** El décimo y
      último periférico de la fase, y el único que no hace nada por sí solo: lo que hace es decidir
      quién se mueve y cuándo. La decisión de fondo está en el
      [ADR 0003](adr/0003-relojes-por-habilitacion.md) — **se cortan relojes de verdad**, en forma
      de habilitación y no de puerta sobre el reloj.

      **Guardar los bits y no hacer nada no valía**: un programa que baja a `f/8` para ahorrar
      corriente seguiría viendo la USART a la velocidad de antes, y eso no es incompatibilidad de
      detalle, es un dispositivo que no habla. Habría sido la cuarta deuda de la forma «los bits se
      almacenan y se leen de vuelta».

      **Con `CLKPS`=0 la habilitación vale uno siempre**, así que el chip quedó **bit a bit** igual
      y el diferencial dio 20/20 programas y 97/97 mnemónicos sin tocar una línea. Y esa misma red
      es el agujero: a un módulo se le puede olvidar la habilitación y pasar su banco, lint,
      síntesis y el diferencial. Por eso `make sim-clk` baja el reloj de verdad y mide **por el
      pin**, con cuatro patas. Encontró que el generador de baudios de la USART se había quedado
      sin gatear — literalmente el ejemplo que motiva el ADR.

      **El perro guardián y la EEPROM se gatean por partes**: las ventanas y las escrituras de
      registro sí, la cuenta y la temporización no, porque corren con el oscilador. Un perro
      guardián que se parase al pararse el reloj del sistema no serviría para nada.

      **`make sim-sleep`** comprueba lo que `SLEEP` hace, que es dejar de hacer: `Idle` despierta
      con el Timer0 cada 256 ciclos clavados; sin `SE` es un `NOP`; en `Power-down` el **mismo
      programa con tres bits distintos** no despierta nunca; y el perro guardián sí, a los ~200 700.
      Entre esos cuatro queda demostrado que `clk_CPU` y `clk_I/O` son dos relojes y no uno.

      Dos mutantes supervivientes quitaron código: el SoC cualificaba `io_we` con `ce_cpu` por si
      una escritura se quedaba congelada durante el sueño, y resulta que **no puede pasar** porque
      el secuenciador presenta la petición registrada (ADR 0001). Era defensa contra algo que la
      arquitectura ya impide.

      **`PUD` y `PRR` cierran el módulo.** `PUD` apaga los pull-up de los tres puertos y va en el
      RTL con una `and` aparte y al final, porque la hoja de datos lo pone **por encima** de `DDxn`
      y `PORTxn` —«even if the DDxn and PORTxn registers are configured to enable the pull-ups»—.
      `PRR` apaga siete periféricos uno a uno, y con la habilitación repartida es **una `and` por
      módulo**: `ce_io & ~prr[n]`. El bit 4 no existe —la tabla 10-2 tiene siete bits y el hueco
      está en medio—, y se declara sin usar a propósito.

      Los dos tienen banco de SoC propio, porque los dos son **cables entre periféricos** y ésos no
      los verifica ningún banco de módulo. `make sim-prr` pone los siete a moverse a la vez y apaga
      uno cada vez, comprobando las dos mitades: que el que se apaga se pare, y que **los otros seis
      sigan** — que es lo que distingue siete cables de uno.

      **Escribir ese programa encontró un fallo real en el ADC**, de los que no dan error: la guarda
      que limpia `ADSC` con el convertidor apagado miraba el `ADEN` guardado, así que
      `ADCSRA = (1<<ADEN)|(1<<ADSC)` —el idioma de medio Arduino— borraba el `ADSC` recién puesto y
      el ADC no convertía nunca. La hoja de datos nombra ese caso al explicar los 25 ciclos.

      Quedan declaradas dos deudas: **D16** (`IVSEL` sin sección de arranque, fase 4) y **D17** (el
      nivel bajo externo no despierta de `Power-down`, fase 5, va con D6).
- [x] **El barrido semántico del mapa de registros.** `make sim-bits`: **664 bits en 83 registros —
      399 de almacenamiento, 136 con comportamiento propio y 129 reservados. Ninguno sin
      clasificar.** Qué bits existen sale de avr-libc por el mismo generador que ya decide las
      direcciones; qué hace cada uno se escribe a mano y **el banco falla si un bit que no es
      almacenamiento llano no lleva motivo**.

      Encontró un fallo nuestro —`PRR` devolvía su bit 4, que no existe—, corrigió dos
      clasificaciones mías —`MSTR` lo limpia el hardware si `SS` está bajo; `TWDR` sólo se carga con
      `TWINT` puesto— y **pilló al oráculo**: avr-libc pone los bits de `TWAMR` en 6:0 cuando su
      propia definición de `TWAR` los exige en 7:1. La corrección vive en el generador, razonada.

**Criterio de aceptación:** los 25 vectores de interrupción disparan y se atienden con la prioridad
correcta; `micros()` no deriva; el scanner I2C detecta un esclavo real.

> **Dónde está la fase, con precisión: CERRADA el 24-sep-2026.** Las **tareas** de la lista están
> todas hechas —los diez periféricos, las deudas de la USART y del ADC, y el barrido semántico— y
> el **criterio de aceptación**, que son tres cláusulas, también:
>
> - **25 vectores** — **DEMOSTRADO**. El que faltaba era `SPM_READY`, y su fuente es el `SPM` por
>   páginas: al escribirlo para la fase 4 (deuda D2) llegó también el vector. `make check-docs`
>   compara la cuenta contra el cableado de `irq_src` y dice **25 de 25**.
> - **`micros()` no deriva** — **DEMOSTRADO** (`make sim-micros`). Se mide con otra interrupción
>   compitiendo y con las interrupciones apagadas a ratos, en dos ventanas de longitud muy distinta:
>   200 periodos dan +13 ciclos de desvío y 800 dan **los mismos +13**. No crece con la ventana, así
>   que es latencia acotada y no deriva; un solo ciclo de deriva por periodo habría dado 800. Y con
>   una ISR casi tan larga como el periodo, barriendo su longitud, no se pierde ninguno mientras
>   quepa —cuando ya no cabe, un AVR de verdad también lo pierde—.
> - **el scanner I2C detecta un esclavo real** — **DEMOSTRADO** (`make sim-i2c`). Un programa
>   barre las 127 direcciones con START, SLA+W, lectura de `TWSR` y STOP, sobre un bus de colector
>   abierto de verdad y con el mismo `EsclavoI2C` del banco del periférico. **127 direcciones en
>   48 533 ciclos, una sola contesta**; y con el esclavo mudo, ninguna — sin esa tercera pasada, un
>   barrido que devolviera siempre `0x50` también pasaría.
>
> **Las tres, con un comando cada una.** Y se deja escrito cómo se llegó aquí, porque la lección
> vale más que el resultado: durante un día esta nota decía que dos estaban demostradas y la
> tercera bloqueada, y era verdad. La lista de tareas y el criterio **no son lo mismo**, y este
> documento existe para que no se confundan — ni cuando falta, ni cuando sobra.

### Fase 4 — Compatibilidad Arduino (3 semanas)

- [x] **Gestor de arranque STK500v1 propio, ≤ 512 B.** `fw/bootloader/axioma_boot.c`: **500 bytes
      de los 512**, y el `Makefile` falla si se pasa. Habla el subconjunto que `avrdude` usa de
      verdad con `-c arduino`, y lo desconocido lo reconoce y lo ignora, como Optiboot.

      **No tiene código de Flash propio**: para borrar y escribir usa `<avr/boot.h>` de **avr-libc,
      sin tocar nada**. Eso lo convierte en una prueba del RTL — si `axioma_spm` no implementara la
      secuencia de cuatro ciclos, el búfer de página y la espera de `SPMEN` exactamente como manda
      la hoja de datos, la cabecera oficial no funcionaría. No hay capa de compatibilidad en medio.

      `make sim-boot` hace de `avrdude`: **pone y quita bits en `RXD` y lee `TXD`**, sin llamar a
      ninguna función ni mirar ninguna señal interna. Sincroniza, pide la firma, programa una página
      de 128 bytes y la relee con `LPM`. Y relee además **una página que nadie ha programado**, que
      tiene que salir borrada: sin eso, un `READ_PAGE` que devolviera lo último escrito pasaría con
      nota. El periodo de bit **no se supone**: se lee de `UBRR0` y `U2X0`, que es lo que el propio
      gestor acaba de calcular.

      **La firma que contesta es la del ATmega328P** (0x1E 0x95 0x0F), y es una decisión: con una
      firma propia el IDE no reconoce la placa hasta instalar un fichero de configuración, y el
      criterio de esta fase es «sin herramientas externas». Queda `-DFIRMA_PROPIA` para el otro
      camino.

      **Lo que costó encontrar**, y merece quedarse escrito: el gestor se colgaba en el bucle de
      limpieza de `.bss` que genera el enlazador. El bucle estaba bien —se llevó a la co-simulación
      contra simavr, `sim/diff/tests/bss_clear.S`, y salió idéntico—; lo que pasaba es que
      **terminaba y seguía hacia la nada**: con `-nostartfiles` no hay `crt0`, así que **nadie llama
      a `main`**, y la ejecución caía en la siguiente función de `.text`. Se arregla poniendo `main`
      en `.init9`, que es donde `crt0` pondría el salto — el mismo truco que Optiboot.
- [x] **`SPM` funcional sobre el backend de BRAM** — la deuda D2, cerrada. `rtl/periph/axioma_spm.v`
      con `SPMCSR`, el búfer temporal de 64 palabras y las tres operaciones: llenar, borrar la
      página y volcarla. **El núcleo ya no escribe la Flash**: `SPM` pasa de ser una escritura a ser
      una petición, y quien escribe es el periférico, que es quien sabe de páginas y de los 4,5 ms
      de la celda.

      Es la **quinta secuencia temporizada** del chip y la única cuyo segundo paso no es una
      escritura sino una **instrucción**: se escribe `SPMCSR` y se ejecuta `SPM` dentro de los
      cuatro ciclos.

      **Y con ella llegó el vector 25.** `SPM_READY` es de nivel, como `EE_READY`, y era el último
      de los 25 sin fuente: al cerrar esta deuda se cerró la última cláusula del criterio de
      aceptación de la **fase 3**.

      28 comprobaciones contra el capítulo 26 —el arnés diferencial no sirve aquí: un programa que
      se reescribe la Flash cambia el código que los dos lados ejecutan—, 13 mutantes, 179 LUT4, y
      `make sim-robust` corriendo **la secuencia entera de un gestor de arranque** sobre el SoC.
- [~] **Paquete de placas para Arduino IDE.** `sw/arduino/boards.txt` está y se usa hoy copiándolo
      al `boards.txt` del núcleo AVR del IDE. No hace falta un núcleo propio —`build.core=arduino`
      y `build.variant=standard` apuntan al mismo código que compila un Uno—, y **eso es en sí la
      prueba de que la compatibilidad es real**: si hiciera falta un núcleo propio, sería que el
      chip no lo es y lo estaríamos disimulando con software.

      `make check-arduino` comprueba las once claves que el IDE necesita y, sobre todo, **que las
      cifras cuadren con el resto del repositorio**: el tamaño máximo del sketch contra el gestor
      **compilado** —no contra una constante—, y `f_cpu` y `upload.speed` contra las banderas con
      las que el `Makefile` compila el gestor. Tres números que viven en dos sitios cada uno.

      **Falta el `package_axioma_index.json`** del Gestor de Tarjetas, y está sin hacer a propósito:
      ese fichero lleva la URL de un paquete comprimido y su SHA-256, y escribirlo antes de que el
      paquete exista sería poner un resumen criptográfico inventado junto a un enlace muerto. Es un
      paso de **publicación**, no de código: se hace cuando haya una versión etiquetada y subida.
- [x] **`axioma.conf` para avrdude con signature bytes propios.** `sw/avrdude/axioma.conf`
      define la pieza `axioma328` heredando del `m328p` y cambiando **sólo la firma**
      (0x1E 0xA0 0x01). Hereda a propósito: repetir los tamaños y tiempos es garantizar que un día
      se desincronicen, y son los mismos porque este chip **es** un 328P por dentro.

      **Lo valida el propio avrdude** (`make check-avrdude`), y con las dos mitades: que con el
      fichero liste `axioma328 = AxiomaCore-328`, **y que sin él no lo reconozca**. Sin la segunda,
      la primera pasaría igual el día que la pieza viniera de la configuración del sistema y este
      fichero hubiera dejado de hacer falta sin que nadie se enterara.

      **Son dos caminos y los dos están elegidos por escrito.** El gestor contesta por defecto la
      firma del 328P, y con eso el IDE funciona sin instalar nada — que es el criterio de esta fase.
      Este fichero es el camino B: compilar con `-DFIRMA_PROPIA` y que el chip no se haga pasar por
      otro. La decisión no es técnica sino de cómo se quiere presentar el chip.
- [~] **Suite de sketches (Capa 5).** Empezada por el que el criterio nombra: **NeoPixel**, que es
      el único que no se puede aprobar «a ojo» porque **el bit es la anchura del pulso**. Una tira
      WS2812B no tiene reloj: un cero son 350 ns de alto y un uno 700, con 150 de margen. A
      12,5 MHz un ciclo son 80 ns, así que todo se juega en cuatro instrucciones.

      Por eso es el que de verdad ejercita el nivel **L3**: el resto del repositorio comprueba que
      las instrucciones *hagan* lo correcto, y aquí se comprueba que *duren* lo que dice el manual.
      Un `SBI` que costara tres ciclos en vez de dos no rompería ningún otro banco — y en una tira
      se vería como colores equivocados.

      `make sim-neopixel` **cronometra el pin**, como un analizador lógico: no mira una sola señal
      interna. Medido: **T0H 320 ns, T1H 720 ns, periodo 1 315 ns y un reposo de 642 µs**, los tres
      dentro de la hoja de datos, y los 24 bits reconstruidos de las anchuras dan el color exacto
      que el programa dijo que iba a mandar.

      **La trama se busca por su FINAL y no por su principio**, que parece un rodeo y no lo es: en
      el WS2812B lo que delimita una trama es el reposo, no un bit de arranque, y el muestreo puede
      empezar a mitad de una. La primera versión buscaba el principio y contaba desplazada.

      **No se usa la biblioteca de Adafruit**, y no por preferencia: sus rutinas están escritas a
      mano para 8, 12 y 16 MHz, con un bloque de ensamblador por frecuencia, y 12,5 MHz no es
      ninguna. Eso le pasaría igual a un ATmega328P con ese cristal. Lo que aquí se comprueba es el
      chip, no la biblioteca.

      **Segundo y tercero: `Servo` y `tone()`**, en un solo programa porque los dos hacen su onda
      **con el hardware** y se dejan corriendo a la vez — que no es comodidad del banco, es la
      prueba de que dos temporizadores con prescaler distinto no se pisan.

      El servo usa el **modo 14** del Timer1: PWM rápido con el tope en `ICR1`, que es el que usa la
      biblioteca `Servo` de Arduino y el único que ejercita `ICR1` como TOP con su registro temporal
      de 16 bits de por medio. Medido: **trama de 20 000 µs exactos y pulso de 1 501 µs**, todas las
      tramas idénticas —un servo tiembla con la trama que varía, no con la que es larga, así que la
      media sola taparía un temblor simétrico—. `tone()` va por Timer2 en CTC conmutando `OC2A`:
      **996,49 Hz**.

      **Las cifras esperadas no son «20 ms» y «1 kHz», son las que salen de los registros**, y la
      distinción importa: a 12,5 MHz con prescaler 64 no existe un `OCR2A` que dé 1 000 Hz clavados,
      y un banco que redondeara aceptaría un prescaler equivocado.

      Dos cosas que el banco aprendió por el camino: **el pulso son `OCR1A`+1 tics y no `OCR1A`**
      —en PWM rápido el pin sube en BOTTOM y baja en la comparación, así que está alto durante las
      cuentas 0..`OCR1A`—, y **el primer pulso que pilla el muestreo puede estar empezado**, que
      corría la media 41 ciclos y parecía cosa del chip.

      Faltan siete sketches.

**Criterio de aceptación:** desde el Arduino IDE, sin herramientas externas: seleccionar la placa,
pulsar *Upload* y que el sketch corra en la FPGA. Diez sketches de la suite pasando, **NeoPixel
incluido**.

> **Dónde está la fase, al 24-sep-2026.** Las cuatro piezas de software están hechas y verificadas:
> el `SPM` por páginas, el gestor de arranque, `axioma.conf` y `boards.txt`. De los diez sketches
> hay **tres**, y son los tres que no se pueden aprobar a ojo. Lo que queda, por orden de lo que
> aporta:
>
> **1. Los siete sketches que faltan.** Los tres que hay son de temporización porque son los que
> sólo un cronómetro puede juzgar; de los siete, los que aportan algo nuevo son:
>
> - **`SoftwareSerial`** — una USART bit-bangeada. Es el único que mide el tiempo **desde el
>   programa** y no desde un temporizador, así que depende de la duración de las instrucciones y no
>   de un prescaler. Se decodifica del pin con el mismo receptor que ya tiene `tb_soc_boot.cpp`.
> - **`analogRead`** — el ADC llamado como lo llama un sketch, con el resultado saliendo por serie.
>   El banco del periférico ya cubre el SAR; lo que falta es el camino entero desde C.
> - **`Wire` como maestro con dos esclavos** — el barrido de `sim-i2c` usa uno. Con dos se
>   ejercita el direccionamiento de verdad, no sólo «responde / no responde».
> - **`EEPROM.read`/`write`** de avr-libc, que es el mismo caso que `<avr/boot.h>` con el `SPM`: si
>   el periférico no es exacto, la cabecera oficial no funciona.
>
> Los tres restantes —`Blink`, `Serial`, `analogWrite`— **ya están cubiertos** por `make sim-hello`,
> que decodifica del pin el LED, el texto y los seis canales de PWM. Contarlos otra vez como
> sketches nuevos sería inflar la cuenta.
>
> **2. Publicar el paquete.** El `package_axioma_index.json` del Gestor de Tarjetas **no se escribe
> antes de que exista el paquete**: lleva una URL y un SHA-256, y ponerlos inventados es exactamente
> lo que este repositorio no hace. Hace falta, por orden: etiquetar una versión, empaquetar
> `boards.txt` + el gestor en `.hex` + `platform.txt`, subirlo, y **entonces** escribir el JSON con
> el resumen real. Es un paso de *release*.
>
> **3. La cláusula que no se puede cerrar aquí.** «Que el sketch corra **en la FPGA**» necesita la
> placa enchufada. Todo lo demás del criterio se demuestra en simulación; eso no. Sigue siendo el
> mismo pendiente que la fase 2 dejó abierto —`make prog-ulx3s`—, y no hay forma honesta de darlo
> por cumplido sin hardware.

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
