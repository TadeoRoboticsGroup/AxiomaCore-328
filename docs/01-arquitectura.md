# Arquitectura de AxiomaCore-328

**Versión 1.0** · 8 de septiembre de 2026 · Documento normativo de diseño

Este documento define la microarquitectura objetivo. Cualquier RTL que contradiga lo aquí escrito
es un error del RTL, no del documento. Si el documento está equivocado, se corrige el documento
primero.

---

## 1. Jerarquía

`axioma328_soc` **es un módulo de verdad** desde el 11-sep-2026, en
`rtl/soc/axioma328_soc.v`. Hasta entonces la integración —el mapa de direcciones de I/O y el
cableado de los 26 vectores— vivía dentro del banco de pruebas, de modo que lo que la regresión
verificaba no era el dispositivo. El desplazamiento de un bit que convertía `TIMER0_COMPA` en
`TIMER1_OVF` estaba justo ahí.

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
├── axioma_prescaler       contador de 10 bits COMPARTIDO por Timer0 y Timer1, y GTCCR
├── axioma_gpior           GPIOR0/1/2 · almacenamiento puro, tres bytes del chip
├── axioma_clkctrl         CLKPR, PRR, SMCR, MCUCR, MCUSR
├── axioma_extint          INT0, INT1 y PCINT0/1/2 · un solo módulo, dos mecanismos
├── axioma_timer8          motor de forma de onda de 8 bits, COMÚN al Timer0 y al Timer2
├── axioma_spi             maestro y esclavo · los cuatro modos · anula pines de PORTB
└── periféricos            gpio · timer0/1/2 · usart · twi · adc · ac · wdt
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

Una dirección que **ningún periférico reclama se lee como `0x00`** y su escritura se pierde, como
en el chip. No es RAM. Y como las lecturas se combinan con un OR, que dos periféricos reclamaran la
misma dirección sería un fallo mudo: devolvería los dos valores mezclados. El espacio es
enumerable, así que `make sim-soc` lo barre entero por el bus real —el núcleo ejecuta un `LDS` por
dirección— y comprueba que como mucho uno responde a cada una y que el mapa es el de la hoja de
datos.

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

Esta tabla **no es documentación decorativa: es un fichero de datos**.
`sim/perf/cycles_ref.py` la transcribe y la proyecta sobre los 65 536 opcodes usando el mnemónico
que da `avr-objdump`, y el arnés de co-simulación comprueba instrucción a instrucción que el RTL
tarda lo que aquí dice. Si el manual contradijera esta tabla, se corrige la tabla **antes** que el
RTL.

Dos filas dependen del resultado de la ejecución, y la condición se toma siempre del lado del
oráculo, nunca del RTL:

- **`BRxx`**: tomada o no según el SREG de simavr *antes* de ejecutar. No se deduce del avance del
  PC, porque `brne .+0` avanza una palabra tanto si salta como si no, y son 2 ciclos frente a 1.
- **Saltos de instrucción**: 1, 2 o 3 palabras de avance, que es exactamente el número de ciclos.

`SPM` queda fuera de la comprobación: el manual no le fija un número de ciclos porque depende del
backend de memoria de programa.

---

## 4. Banco de registros

32 registros de 8 bits con dos puertos de lectura y uno de escritura. Necesita además:

- **Acceso de 16 bits** a los pares R27:R26 (X), R29:R28 (Y), R31:R30 (Z) para el
  direccionamiento indirecto, y a R25:R24 para `ADIW`/`SBIW`.
- **`MOVW`**: copia de un par a otro en un solo ciclo. Esto obliga a que el par que se **lee** y el
  que se **escribe** se direccionen por separado: con un único índice compartido haría falta un
  ciclo para leer el origen y otro para escribir el destino, y `MOVW` costaría 2 ciclos donde el
  manual dice 1. Es un requisito del contrato L3, no una comodidad. `ADIW`, `SBIW` y los punteros
  con post-incremento o pre-decremento sí usan el mismo par en ambos lados.
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

- **`NEG`**: `H = R3 | Rd3` · `V = (R == 0x80)` · `C = (R != 0x00)`.
  Atención: es `Rd3`, **no** `¬Rd3`. Es un error fácil de cometer; en este proyecto se
  cometió y lo detectó el contraste contra simavr, no la verificación exhaustiva contra
  nuestro propio modelo.
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

**Cómo se verifica.** La prioridad y el reconocimiento, de forma **exhaustiva**: las 67 108 864
combinaciones posibles de las 26 peticiones (`make sim-irq`). La entrada en sí, contra simavr: el
arnés diferencial le levanta el mismo vector que acaba de tomar el RTL y compara después el PC —es
decir, la dirección del vector—, la pila, el `SP` y el `SREG`. El retardo de `SEI` lo comprueba el
propio arnés, porque es el RTL quien decide cuándo salta y simavr no le puede desmentir.

---

## 7. Memorias

Interfaz única, backend intercambiable en tiempo de compilación. Ésta es la decisión que hace
viable el port a ASIC sin reescribir.

> **Estado, a 11-sep-2026.** Lo que existe es **la interfaz y una sola implementación**: memoria
> inferida, que sirve para simulación y que la síntesis mapea a BRAM del ECP5 —comprobado con
> `make synth-check`—. El backend de Sky130 es de la fase 6 y los directorios de
> `rtl/mem/backends/` están **vacíos**: son marcadores de sitio, no código. Que la frontera esté
> puesta desde el principio es lo que hace barato el port; no es lo mismo que tenerlo portado.

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

> **Temporización.** Las memorias se registran en el **flanco de bajada** del reloj del núcleo.
> El AVR accede a memoria dentro del mismo ciclo y una BRAM en flanco de subida devolvería el dato
> un ciclo tarde, rompiendo las cuentas de `LD`, `LDS` y `ST` — y con ellas el nivel L3.
> Razonamiento y alternativas descartadas en
> [ADR 0001](adr/0001-memorias-en-flanco-de-bajada.md).

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
| 4 | **Registro TEMP de 16 bits.** Leer `TCNT1L` captura el byte alto en TEMP; leer `TCNT1H` devuelve TEMP. Al escribir el orden se invierte. Aplica a TCNT1, ICR1, OCR1A, OCR1B. **Implementado en `axioma_timer1.v`**, y es UNO SOLO para los cuatro: por eso una interrupción a mitad de un acceso de 16 bits corrompe el otro registro. | `micros()` y `Servo` devuelven basura. |
| 5 | **Escribir a `PINx` hace toggle de `PORTx`.** | Código optimizado de conmutación de pines deja de funcionar. |
| 6 | **`LD`/`ST` sobre `0x0000–0x001F`** accede al banco de registros. | Fallos sutiles en código con punteros. |
| 7 | **Punteros post-inc / pre-dec** escriben de vuelta al regfile en el mismo ciclo. | Corrupción de X/Y/Z. |
| 8 | **`PUSH`** guarda y luego decrementa; **`POP`** incrementa y luego lee. `CALL` apila el byte alto primero. | Todo retorno corrupto. |
| 9 | **Flags de `NEG`** (ver §5). `H = R3 \| Rd3` — con `Rd3`, no su negado. | Aritmética con signo incorrecta. |
| 10 | **`ROR`/`ASR`/`LSR`**: `V = N ⊕ C` tras el desplazamiento. | Comparaciones con signo erróneas. |
| 11 | **Efectos laterales de lectura.** Leer `UDR0` limpia `RXC`; leer `ADCL` bloquea `ADCH`; `TIFRx` se limpia escribiendo 1. | USART y ADC fallan de forma intermitente. |
| 12 | **Prescaler compartido** entre Timer0 y Timer1; `GTCCR` lo resetea. El baudrate deriva de F_CPU, no del prescaler. **Implementado en `axioma_prescaler.v`**, que es un módulo aparte justo por esto. | Deriva de temporización difícil de diagnosticar. |

---

## 8bis. Cuestiones abiertas

Diferencias deliberadas respecto al ATmega328P, con su razón. Cada una debe
resolverse contra la hoja de datos antes de la v1.0.

| Tema | Estado | Decisión provisional |
|------|--------|----------------------|
| Sincronizador de `PINx` | **Resuelto a favor de la hoja de datos.** El 328P pasa el valor del pad por un sincronizador, y por eso entre escribir `PORTx` y leer `PINx` hace falta una instrucción de por medio —el `nop` que aparece en todo el código AVR que relee un pin—. El modelo de ioport de simavr **no lo tiene** y devuelve `PORTx` al instante. | **Implementar el sincronizador.** Sin él el RTL sería más permisivo que el chip: código que funcionara en simulación fallaría en silicio. El mutante que lo elimina **sólo lo caza el banco propio**; el diferencial pasaría igual. |
| Bit 7 del puerto C | **Resuelto a favor de la hoja de datos.** `PC7` no existe en el ATmega328P y sus bits se leen como cero. simavr no enmascara. | **Enmascarar.** `sim/periph/tb_gpio.cpp` se ejecuta con las dos máscaras, `0xFF` y `0x7F`, porque el diferencial no puede ver esta diferencia. |
| Pin de entrada con el pull-up apagado | **Indefinido, y no lo define nadie.** simavr conserva el último valor leído; un pad real queda flotando. La hoja de datos no promete nada. | **Tratarlo como los casos de «resultado indefinido» del manual del ISA:** ningún programa de prueba puede depender de él, y `PINx` queda fuera del barrido de memoria del diferencial. |
| Fase del prescaler al arrancar un temporizador | **Resuelto a favor de la hoja de datos.** El prescaler es un contador libre de 10 bits COMPARTIDO entre Timer0 y Timer1: escribir los bits CS engancha el temporizador a una toma, pero no pone el contador a cero, así que la primera cuenta llega cuando a esa toma le toca. `avr_timer_write` de simavr llama a `avr_timer_reconfigure(p, 1)` y ancla su base en el ciclo de la escritura, es decir, reinicia el prescaler y le da uno propio a cada temporizador. | **Prescaler libre y compartido**, en su propio módulo. Es la trampa nº 12. El diferencial no lo puede ver: lo comprueba `sim/periph/tb_timer0.cpp`. |
| `GTCCR` | **Resuelto a favor de la hoja de datos.** simavr **no lo modela**: `grep GTCCR` no aparece en `avr_timer.c`, sólo en las cabeceras de registros, así que para él es un byte de almacenamiento. | **Implementar TSM, PSRSYNC y PSRASY.** `PSRSYNC` pone a cero el contador compartido y `PSRASY` el del Timer2, que es otro; los dos se autolimpian salvo con `TSM` puesto, que es lo que permite configurar los temporizadores y arrancarlos a la vez. |
| Los bits de ocupado de `ASSR` | **Diferencia declarada, a favor de lo simple.** En el chip, con `AS2` puesto, todo el Timer2 pasa al dominio del cristal de 32 768 Hz y por eso una escritura tarda hasta un ciclo en cruzar: eso son `TCN2UB`, `OCR2AUB`, `OCR2BUB`, `TCR2AUB` y `TCR2BUB`. Aquí el temporizador sigue en el reloj del sistema y cuenta los flancos de `TOSC1` sincronizados, así que las escrituras son inmediatas y los cinco bits se leen a cero. | **Aceptarlo y declararlo.** Un `while (ASSR & (1<<TCN2UB));` sale del bucle a la primera, y sale con la escritura ya hecha: lo que el programa quería garantizar se cumple. La cuenta y las banderas salen bien porque lo que manda es cuántos flancos de `TOSC1` han pasado. Cerrarlo de verdad es un segundo dominio de reloj con petición y confirmación por registro, y eso no se cierra sin formal: es la deuda D10, fase 5. |
| Escribir `TCNT0` con un valor ≥ TOP | **Resuelto a favor de la hoja de datos.** simavr lo convierte en cero (`if (tcnt >= p->tov_top) tcnt = 0;`). | **Guardar lo que se escribe.** |
| Leer `TCNT0` con el temporizador parado | **Resuelto a favor de la hoja de datos.** `_avr_timer_get_current_tcnt` devuelve 0 cuando no hay ciclos programados. | **Conservar la cuenta.** Un temporizador parado no pierde su valor. |
| Cuándo salta la interrupción del Timer0 | **No comparable con simavr, y no es fallo de ninguno.** simavr no cuenta ciclo a ciclo: INTERPOLA `TCNT0` desde `avr->cycle` cuando alguien lo lee, con su propia base de tiempo. Son dos relojes distintos. | **Repartir el oráculo.** *Cuándo* salta lo decide el RTL y lo verifica el banco propio contra la hoja de datos; *qué hace el núcleo* al saltar lo verifica simavr, al que el arnés le levanta el mismo vector para que ejecute su propia secuencia de entrada. `TCNT0`, `TIFR0` y `GTCCR` quedan fuera de la tabla `COMPARABLE[]`. |
| La toma de clk/1 bajo `TSM` | **Sin confirmar.** La figura «Prescaler for Timer/Counter0 and Timer/Counter1» saca `clk_I/O` directamente, sin pasar por el contador de 10 bits, de modo que el reset del prescaler no debería detener a un temporizador con `CS=001`. La hoja de datos no lo dice con palabras. | **Lectura literal de la figura:** `tick_1` no lo afecta ni `PSRSYNC` ni `TSM`. Pendiente de confirmar. |
| `UCSR0B` al resetear | **Resuelto a favor de la hoja de datos.** simavr arranca con `TXEN` puesto, y lo hace a propósito: `avr_uart_reset` lleva el comentario «DEBUG allow printf without fiddling with enabling the uart». El ATmega328P lo resetea a `0x00`. | **Resetear a cero.** `UCSR0B` queda fuera del barrido del espacio de datos; se contrasta por la comparación por instrucción, leyéndolo de vuelta tras escribirlo. |
| La forma de onda del SPI | **No comparable con simavr, y no es fallo de ninguno.** Su `avr_spi_write` guarda el byte en `SPDR`, programa un temporizador de `clkdiv*8` ciclos y levanta la interrupción; no hay bits, ni `SCK`, ni pines. Leer `SPDR` devuelve **lo que se escribió**, porque no hay nada al otro lado del cable, y ese mismo acceso limpia `SPIF` de golpe, sin la secuencia de dos accesos de la hoja de datos. `WCOL` no existe y el modo esclavo tampoco. | **Banco propio con el otro extremo del cable** (`sim/periph/tb_spi.cpp`): un maestro y un esclavo escritos desde la hoja de datos, enchufados al DUT. Del SPI, el diferencial sólo compara `SPCR`. A nivel de SoC, `make sim-hello` decodifica del PIN una transacción de tres bytes. |
| La forma de onda del TWI | **No comparable con simavr, y por el mismo motivo que el SPI.** Su `avr_twi.c` transporta la dirección y cada byte enteros por IRQs internas —`TWI_IRQ_INPUT` y `TWI_IRQ_OUTPUT`— y programa un temporizador para levantar el estado siguiente: no serializa `SDA` ni genera `SCL`, así que no hay bit, ni ACK, ni arbitraje, ni estiramiento de reloj que comparar. Tampoco implementa el valor de reset de `TWAR` (0xFE) ni el de `TWDR` (0xFF): su `avr_twi_reset` sólo toca `TWSR`. | **Banco propio con un BUS de colector abierto** (`sim/periph/tb_twi.cpp`): un maestro y un esclavo I2C escritos desde la hoja de datos, colgados del mismo par de líneas con resolución de Y cableado, más las tablas de los 26 códigos de estado. Del TWI, el diferencial sólo compara `TWBR` y `TWAMR` —los dos únicos que son almacenamiento con el mismo valor de reset en los dos lados—. El vector 24 sí se contrasta: `sim/diff/tests/twi.S` entra 185 veces en la ISR y simavr ejecuta su propia secuencia de entrada. |
| La forma de onda de la USART | **No comparable con simavr, y no es fallo de ninguno.** Su modelo NO SERIALIZA: transporta bytes enteros por IRQs internas y aproxima el tiempo con `cycles_per_byte`, que además suma siempre un bit de paridad esté o no activada. No hay bit de arranque, ni paridad, ni bits de parada, ni pin. | **Banco propio con un receptor de verdad** (`sim/periph/tb_usart.cpp`): decodifica el pin TXD y comprueba que el periodo de bit es exactamente el de la fórmula del manual. De la USART, el diferencial sólo compara `UCSR0C`, `UBRR0L` y `UBRR0H`. |
| El registro TEMP del Timer1 | **Resuelto a favor de la hoja de datos.** simavr **no lo modela**: escribe y lee los dos bytes por su cuenta (`avr->data[r_tcnth] = tcnt >> 8`), así que para él un acceso de 16 bits es atómico y el orden da igual. | **Implementarlo, y compartido entre los cuatro registros.** Es la trampa nº 4 y de ella dependen `micros()` y `Servo`. Lo certifica `sim/periph/tb_timer1.cpp`; del diferencial quedan fuera `TCNT1`, `ICR1` y los bytes altos. |
| `SPM Z+` (opcode `0x95F8`) | **Sin confirmar.** binutils lo decodifica en todas las arquitecturas AVR, incluso avr2, así que no es *device-aware* y no sirve como prueba de que el 328P lo tenga. `boot.h` de avr-libc no lo usa para este dispositivo. La emulación de SPM en simavr parece incompleta. | **Aceptarlo.** Un superset solo puede añadir compatibilidad: un programa que lo use funcionará, y uno que no, queda igual. Marcarlo ilegal sí podría romper código real. |

## 9. Mapa de registros

Se **genera** desde `iom328p.h` de avr-libc (BSD-3-Clause) con `tools/gen_regmap.py`, que produce:

- `rtl/soc/axioma_regmap.vh` — constantes Verilog
- `docs/05-register-map.md` — documentación
- la comprobación de CI `tools/gen_regmap.py --check`, que falla ante cualquier divergencia

Esto convierte el nivel L2 de compatibilidad en una propiedad verificada mecánicamente, no en una
tabla escrita a mano que se desincroniza en el tercer commit.
