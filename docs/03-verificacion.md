# Estrategia de verificación

**Versión 1.0** · 8 de septiembre de 2026

> **La regla del proyecto: nada entra sin oráculo.** Un bloque que no se compara contra una
> referencia independiente no está verificado, está *ejecutado*. El intento anterior tenía
> testbenches que no comparaban contra nada: por eso era imposible distinguir «funciona» de «no se
> cuelga».

---

## Capa 1 — Diferencial contra simavr

La columna vertebral de todo. Se ejecuta el mismo `.elf` en el RTL y en `simavr`, y se comparan los
estados observables tras **cada instrucción retirada**.

```
   programa .elf (avr-gcc)
        │
        ├────────────► simavr ─────────► PC · R0-R31 · SREG · SP · escrituras a memoria
        │                                        │
        └────────────► RTL (Verilator) ─────────► traza equivalente
                                                 │
                                        comparador ──► primera divergencia + VCD acotado
```

Cuando diverge, el comparador imprime la instrucción, el estado esperado y el obtenido, y vuelca
una ventana de ondas alrededor del fallo. Este único mecanismo reduce la depuración de un core de
días a minutos.

**Corpus de programas:**

| Tipo | Contenido |
|------|-----------|
| Suite dirigida | Un programa por instrucción, con casos borde de flags: `0x00`, `0x7F`, `0x80`, `0xFF`, acarreos, medio acarreo, desbordamiento con signo |
| Programas reales | `printf` de avr-libc, aritmética de 32 bits, `qsort`, manipulación de cadenas, recursión profunda |
| Aleatorio | Generador de secuencias válidas con operandos aleatorios. 10⁷ instrucciones en la regresión nocturna |

---

## Capa 2 — ALU exhaustiva

La ALU es de 8 bits: el espacio de entrada es enumerable **por completo**. Implementado en
`sim/alu/`, ejecutable con `make sim-alu`.

| Clase | Espacio barrido | Vectores por operación |
|-------|-----------------|------------------------|
| Dos operandos (ADD, ADC, SUB, SBC, AND, OR, EOR, MOV) | a × b × (C,Z) | 262 144 |
| Un operando (COM, NEG, INC, DEC, LSR, ROR, ASR, SWAP) | a × (C,Z) | 1 024 |
| 16 bits (ADIW, SBIW) | a16 × k6, ambos completos | 4 194 304 |
| Multiplicación (MUL, MULS, MULSU, FMUL, FMULS, FMULSU) | a × b | 65 536 |

**Total: 10 887 168 vectores sobre 24 operaciones. 0 fallos. 5,3 segundos.**

El oráculo es doble y se contrasta consigo mismo antes de emitir nada:

- `alu_scalar()` — transcripción escalar y legible del manual del ISA. Es la especificación
  ejecutable.
- `gen_*()` — versiones vectorizadas con numpy, que generan los 10,9 millones de vectores en medio
  segundo.

Antes de generar, las dos se comparan sobre todos los casos borde conocidos (0x00, 0x01, 0x0F,
0x10, 0x7E, 0x7F, 0x80, 0x81, 0xFE, 0xFF y sus combinaciones) más una muestra aleatoria. Si
divergen, el generador aborta: **una versión rápida que no coincide con la especificación legible
no sirve de oráculo.**

Ésta es la razón por la que la fase 1 empieza por la ALU: es el bloque con el mejor retorno
inmediato y establece el patrón para todo el proyecto.

---

## Capa 3 — Exactitud de ciclos

La tabla de ciclos de [`01-arquitectura.md`](01-arquitectura.md#tabla-de-ciclos-contrato-l3) se
codifica como fichero de datos. Un test ejecuta cada instrucción aislada con un contador de ciclos
y falla ante cualquier desviación.

Además se compara la **cuenta total de ciclos** contra simavr en programas completos, lo que
detecta errores de temporización que un test por instrucción no ve —típicamente en la entrada a
interrupciones y en los saltos tomados.

Lo que depende de esto: `_delay_ms()`, `_delay_us()`, `micros()`, `SoftwareSerial`, `Servo` y
cualquier protocolo bit-bangeado como el de las tiras NeoPixel.

---

## Capa 4 — Periféricos y mapa de registros

**Barrido del mapa de registros.** Test generado que escribe y lee **cada dirección de I/O**
comprobando:

- Bits reservados que deben leerse como 0
- Máscaras de sólo lectura
- Efectos laterales de lectura: leer `UDR0` limpia `RXC`, leer `ADCL` bloquea `ADCH`
- Semántica *write-1-to-clear* de los registros `TIFRx`
- El registro TEMP de 16 bits de Timer1

**Modelos de bus en el testbench.** Un esclavo I2C, un esclavo SPI y un receptor UART que verifican
la **forma de onda real** sobre los pines, no sólo el contenido de los registros. Un periférico
puede tener los registros correctos y generar una trama incorrecta.

---

## Capa 5 — Compatibilidad Arduino de extremo a extremo

Sketches compilados con avr-gcc y ejecutados en RTL y en FPGA:

| Sketch | Qué ejercita |
|--------|--------------|
| Blink | GPIO, Timer0, `delay()` |
| Serial (varios baudios) | USART, generador de baudios |
| AnalogRead | ADC, multiplexor de canal |
| analogWrite (6 canales) | PWM en Timer0/1/2 |
| Wire — scanner I2C | TWI maestro, arbitraje |
| SPI | SPI maestro, los cuatro modos |
| Servo | Timer1 de 16 bits, registro TEMP |
| SoftwareSerial | Exactitud de ciclos en bucles cerrados |
| LiquidCrystal | Temporización de GPIO |
| **Adafruit_NeoPixel** | **El más exigente: temporización a nivel de ciclo con interrupciones desactivadas** |
| SD | SPI a alta velocidad, bloques grandes |
| EEPROM | Máquina de estados de `EECR` |
| millis / micros | Deriva de temporización a largo plazo |

---

## Capa 6 — Verificación formal

SymbiYosys sobre propiedades acotadas, donde el coste es bajo y el valor alto:

- El stack pointer nunca sale del rango de la SRAM
- El decodificador nunca emite dos escrituras simultáneas al banco de registros
- La máquina de estados del TWI no tiene estados inalcanzables ni bloqueos
- `I` del SREG sólo cambia con `SEI`, `CLI`, `RETI`, la entrada a interrupción o `BSET`/`BCLR`

---

## Integración continua

| Cuándo | Qué se ejecuta |
|--------|----------------|
| **Cada push** | Lint (`verilator -Wall`) · ALU exhaustiva · suite ISA dirigida · tabla de ciclos · diff del mapa de registros · síntesis ECP5 con reporte de área y Fmax |
| **Cada noche** | 10⁷ instrucciones aleatorias · suite Arduino completa · síntesis para las tres familias de FPGA |
| **Cada release** | Todo lo anterior + regeneración de la matriz de compatibilidad del README |

**La matriz de compatibilidad del README se genera a partir de los resultados.** Nunca se escribe a
mano. Ésa es la diferencia entre una afirmación y una medida.

---

## Criterios de aceptación de la v1.0

| # | Métrica | Umbral |
|---|---------|--------|
| 1 | Instrucciones que pasan el diferencial | 131 / 131 |
| 2 | Divergencias en regresión aleatoria | 0 en 10⁷ |
| 3 | Cobertura de la ALU | 100 % |
| 4 | Desviaciones de ciclos | 0 |
| 5 | Diferencias del mapa de registros | 0 |
| 6 | Vectores de interrupción verificados | 26 / 26 |
| 7 | Sketches sin modificar | ≥ 10, NeoPixel incluido |
| 8 | Fmax en ECP5 | ≥ 32 MHz |
