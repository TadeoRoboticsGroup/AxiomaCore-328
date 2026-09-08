# Arquitectura de AxiomaCore-328

**Versión 1.0** · 8 de septiembre de 2026 · Documento normativo de diseño

Este documento define la microarquitectura objetivo. Cualquier RTL que contradiga lo aquí escrito
es un error del RTL, no del documento. Si el documento está equivocado, se corrige el documento
primero.

---

## 1. Jerarquía

```
axioma328_soc
├── axioma_core
│   ├── axioma_decode      decodificación combinacional + predecodificador de 32 bits
│   ├── axioma_seq         secuenciador multiciclo (congela la etapa de fetch)
│   ├── axioma_regfile     32 × 8 bits, 2R/1W + acceso de 16 bits
│   ├── axioma_alu         combinacional pura
│   └── axioma_sreg        registro de estado
├── axioma_progmem         16K × 16 bits · backend parametrizable
├── axioma_dmem            2 KB · backend parametrizable
├── axioma_eeprom          1 KB · backend parametrizable
├── axioma_dbus            fabric del espacio de datos
├── axioma_irq             26 vectores con prioridad fija
├── axioma_clkctrl         CLKPR, PRR, SMCR, MCUCR, MCUSR
└── periféricos            gpio · timer0/1/2 · usart · spi · twi · adc · ac · wdt · extint · pcint
```

---

## 2. Espacio de datos

El AVR es Harvard —programa y datos en buses separados— pero el espacio de **datos** es unificado y
los registros forman parte de él. Modelarlo de otro modo produce un core que falla con programas
reales.

| Rango | Contenido | Acceso |
|-------|-----------|--------|
| `0x0000 – 0x001F` | 32 registros de propósito general | Directo, y también con `LD`/`ST` |
| `0x0020 – 0x005F` | 64 registros de I/O estándar | `LD`/`ST`, y `IN`/`OUT` con dirección `data − 0x20` |
| `0x0060 – 0x00FF` | 160 registros de I/O extendida | Sólo `LD`/`ST` |
| `0x0100 – 0x08FF` | 2048 bytes de SRAM | `LD`/`ST`, stack |

`RAMEND = 0x08FF`. El stack crece hacia abajo desde ahí.

### Reglas de acceso

- `LD r16, X` con `X = 0x0005` **lee R5**.
- `IN`/`OUT` alcanzan sólo `0x00–0x3F` del espacio de I/O.
- `CBI`/`SBI`/`SBIC`/`SBIS` alcanzan sólo `0x00–0x1F` del espacio de I/O.
- `PORTB` es I/O `0x05` y dato `0x25`: el mismo registro físico, dos direcciones.

### Interfaz de periférico

Todos los periféricos exponen la misma interfaz. El multiplexor central selecciona uno por
dirección y combina las lecturas.

```verilog
input  wire [7:0] io_addr,    // dirección baja dentro del espacio de datos
input  wire       io_re,
input  wire       io_we,
input  wire [7:0] io_wdata,
output wire [7:0] io_rdata,
output wire       io_sel      // este periférico responde a esta dirección
```

---

## 3. Pipeline

Dos etapas, como el AVR original:

| Etapa | Trabajo |
|-------|---------|
| **IF** | `PC → progmem`; captura del registro de instrucción |
| **ID/EX/WB** | Decodifica, lee registros, ALU, acceso a memoria, writeback |

Las instrucciones multiciclo las gestiona `axioma_seq`, que congela la etapa IF durante los ciclos
adicionales. No hay predicción de saltos: un salto tomado descarta la instrucción prefetchada, lo
que explica el ciclo extra de la tabla siguiente.

### Tabla de ciclos (contrato L3)

| Clase | Ciclos | Nota |
|-------|--------|------|
| ALU registro / inmediato | 1 | ADD, SUB, AND, OR, EOR, LDI, MOV… |
| MUL, MULS, MULSU, FMUL, FMULS, FMULSU | 2 | Resultado en R1:R0 |
| ADIW, SBIW | 2 | |
| MOVW | 1 | |
| LD / ST (X, Y, Z, desplazamiento, post-inc, pre-dec) | 2 | |
| LDS / STS | 2 | Instrucción de 32 bits |
| PUSH / POP | 2 | |
| LPM | 3 | |
| RJMP, IJMP | 2 | |
| JMP | 3 | |
| RCALL, ICALL | 3 | |
| CALL | 4 | |
| RET, RETI | 4 | |
| BRxx | 1 no tomado · 2 tomado | |
| CPSE, SBRC, SBRS, SBIC, SBIS | 1 · 2 · **3** | 3 cuando la instrucción saltada es de 32 bits |
| IN, OUT | 1 | |
| SBI, CBI | 2 | |
| Entrada a interrupción | 4 + 3 | Incluye el `JMP` del vector |

---

## 4. Banco de registros

32 registros de 8 bits con dos puertos de lectura y uno de escritura. Necesita además:

- **Acceso de 16 bits** a los pares R27:R26 (X), R29:R28 (Y), R31:R30 (Z) para el
  direccionamiento indirecto, y a R25:R24 para `ADIW`/`SBIW`.
- **`MOVW`**: copia de un par a otro en un solo ciclo.
- **Escritura de vuelta del puntero** en el mismo ciclo para post-incremento y pre-decremento.

En FPGA puede mapearse a LUTRAM; en ASIC son 256 biestables, lo cual es perfectamente razonable.

---

## 5. Registro de estado (SREG)

| Bit | Nombre | Significado |
|-----|--------|-------------|
| 7 | I | Habilitación global de interrupciones |
| 6 | T | Bit de copia (`BLD`/`BST`) |
| 5 | H | Acarreo de medio byte |
| 4 | S | Signo — **siempre `N ⊕ V`** |
| 3 | V | Desbordamiento en complemento a dos |
| 2 | N | Negativo |
| 1 | Z | Cero |
| 0 | C | Acarreo |

**S no es un flag independiente.** Se calcula como `assign flag_s = flag_n ^ flag_v;`. Tratarlo
como un caso por instrucción es la causa del cerrojo inferido en el RTL heredado.

### Casos de flags que hay que tratar aparte

- **`NEG`**: `H = R3 | ¬Rd3` · `V = (R == 0x80)` · `C = (R != 0x00)`.
- **`ROR`, `ASR`, `LSR`**: `V = N ⊕ C`, evaluado **después** del desplazamiento.
- **`ADIW`**: `V = ¬Rdh7_previo ∧ R15`. **`SBIW`**: `V = Rdh7_previo ∧ ¬R15`.
- **`CP`, `CPC`, `CPI`**: actualizan flags sin escribir el destino.
- **`CPC`, `SBC`, `SBCI`**: `Z` sólo se limpia, nunca se pone a 1 — permite comparaciones
  multibyte encadenadas.

---

## 6. Interrupciones

26 vectores, direcciones de palabra, 2 palabras cada uno (un `JMP`) porque la Flash es de 32 KB.

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

**Semántica:**
- Prioridad fija por orden numérico: vector más bajo, mayor prioridad.
- Las interrupciones sólo se atienden **entre instrucciones**, nunca en mitad de una.
- Al entrar: se apila el PC, se limpia `I`, se salta al vector. 4 ciclos + 3 del `JMP`.
- `RETI` desapila el PC y pone `I` a 1.
- Sin anidamiento automático. Una ISR que quiera ser interrumpible ejecuta `SEI` explícitamente.
- **`SEI` tiene un ciclo de retardo**: la primera interrupción se atiende después de ejecutar la
  instrucción siguiente. `CLI`, en cambio, es inmediato.

---

## 7. Memorias

Interfaz única, backend intercambiable en tiempo de compilación. Ésta es la decisión que hace
viable el port a ASIC sin reescribir.

```verilog
module axioma_progmem #(
    parameter WORDS    = 16384,
    parameter INIT_HEX = ""
)(
    input  wire        clk,
    input  wire [13:0] if_addr,   input wire if_en,   output wire [15:0] if_data,
    input  wire [13:0] d_addr,    input wire d_en,
    input  wire        d_we,      input wire [15:0] d_wdata,
    output wire [15:0] d_rdata
);
```

| Backend | Implementación | Uso |
|---------|---------------|-----|
| `sim` | Array conductual + `$readmemh` | Simulación |
| `fpga_bram` | BRAM inferida, inicializada desde `.hex` | ECP5 · iCE40 · Gowin |
| `sky130_sram` | Macros `sky130_sram_2kbyte_1rw1r_32x512_8` + ROM de arranque que copia desde QSPI externa | ASIC |

Análogo para `axioma_dmem` (2 KB, escritura por byte) y `axioma_eeprom` (1 KB).

### Por qué no hay Flash en el ASIC

Sky130 no incluye IP de memoria no volátil. La memoria de programa en silicio es SRAM cargada al
arranque desde una Flash QSPI externa (*shadow RAM*). Esto preserva la exactitud de ciclos a costa
de área. Las alternativas —XIP con caché, o ROM de máscara— están evaluadas en el
[plan](00-PLAN.md#57-abstracción-de-memorias-la-decisión-que-hace-posible-el-asic).

---

## 8. Las doce trampas de compatibilidad

Cada una necesita un test dirigido desde la fase 1.

| # | Trampa | Consecuencia si se ignora |
|---|--------|---------------------------|
| 1 | **Skip de instrucciones de 32 bits.** `CPSE`/`SBRC`/`SBRS`/`SBIC`/`SBIS` saltan 1 o 2 palabras según si la siguiente es `LDS`/`STS`/`JMP`/`CALL`. | El PC se descuadra en código compilado real. |
| 2 | **Retardo del `SEI`**: la interrupción se atiende tras la instrucción siguiente. | `SEI; SLEEP` pierde el despertar. |
| 3 | **`CLI` es inmediato.** | Secciones críticas que no lo son. |
| 4 | **Registro TEMP de 16 bits.** Leer `TCNT1L` captura el byte alto en TEMP; leer `TCNT1H` devuelve TEMP. Al escribir el orden se invierte. Aplica a TCNT1, ICR1, OCR1A, OCR1B. | `micros()` y `Servo` devuelven basura. |
| 5 | **Escribir a `PINx` hace toggle de `PORTx`.** | Código optimizado de conmutación de pines deja de funcionar. |
| 6 | **`LD`/`ST` sobre `0x0000–0x001F`** accede al banco de registros. | Fallos sutiles en código con punteros. |
| 7 | **Punteros post-inc / pre-dec** escriben de vuelta al regfile en el mismo ciclo. | Corrupción de X/Y/Z. |
| 8 | **`PUSH`** guarda y luego decrementa; **`POP`** incrementa y luego lee. `CALL` apila el byte alto primero. | Todo retorno corrupto. |
| 9 | **Flags de `NEG`** (ver §5). | Aritmética con signo incorrecta. |
| 10 | **`ROR`/`ASR`/`LSR`**: `V = N ⊕ C` tras el desplazamiento. | Comparaciones con signo erróneas. |
| 11 | **Efectos laterales de lectura.** Leer `UDR0` limpia `RXC`; leer `ADCL` bloquea `ADCH`; `TIFRx` se limpia escribiendo 1. | USART y ADC fallan de forma intermitente. |
| 12 | **Prescaler compartido** entre Timer0 y Timer1; `GTCCR` lo resetea. El baudrate deriva de F_CPU, no del prescaler. | Deriva de temporización difícil de diagnosticar. |

---

## 9. Mapa de registros

Se **genera** desde `iom328p.h` de avr-libc (BSD-3-Clause) con `tools/gen_regmap.py`, que produce:

- `rtl/soc/axioma_regmap.vh` — constantes Verilog
- `docs/05-register-map.md` — documentación
- `sim/isa/regmap_check.py` — test de CI que falla ante cualquier divergencia

Esto convierte el nivel L2 de compatibilidad en una propiedad verificada mecánicamente, no en una
tabla escrita a mano que se desincroniza en el tercer commit.
