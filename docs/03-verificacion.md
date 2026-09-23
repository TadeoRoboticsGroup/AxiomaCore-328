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
| Aleatorio | `sim/random/gen_random.py`. **10⁶ instrucciones, 0 divergencias** (`make sim-random`). 10⁷ en la regresión nocturna |

### El generador aleatorio: lo difícil no es la aleatoriedad

Un generador de instrucciones aleatorias es fácil de escribir mal. Lo costoso es garantizar que el
programa **nunca** hace algo cuyo resultado no esté definido, o que los dos lados no puedan modelar
igual. Cada restricción del generador tiene su motivo, y están documentadas en su cabecera:

- **Los punteros no son destinos aleatorios.** Si cualquier instrucción pudiera escribir R26..R31,
  el siguiente `LD` o `ST` iría a parar a un periférico o fuera de la SRAM.
- **Amarre periódico.** Cada 48 instrucciones se rehacen X, Y, Z y el SP. Así la deriva máxima está
  acotada y todos los accesos caen dentro de la SRAM, incluidos `ldd Y+63` y el pre-decremento.
- **`LPM` sólo dentro del programa.** simavr inicializa la flash a `0xFF` y `axioma_progmem` a
  `0x0000`. Leer flash sin programar hace divergir el contraste sin que haya nada roto.
- **Sin transferencias de control arbitrarias**, porque un destino aleatorio caería en mitad de una
  instrucción de 32 bits.

**Sensibilidad comprobada.** Con el post-incremento de puntero sumando 2 en vez de 1, la regresión
aleatoria diverge en la instrucción 560 y señala el registro exacto. Un banco que no puede fallar
no verifica nada, y éste puede.

---

## Capa 2 — ALU exhaustiva

La ALU es de 8 bits: el espacio de entrada es enumerable **por completo**. Implementado en
`sim/alu/`, ejecutable con `make sim-alu`.

| Clase | Espacio barrido | Vectores por operación |
|-------|-----------------|------------------------|
| Dos operandos (ADD, ADC, SUB, SBC, AND, OR, EOR, MOV) | a × b × 8 valores de SREG | 524 288 |
| Un operando (COM, NEG, INC, DEC, LSR, ROR, ASR, SWAP) | a × **SREG completo (256)** | 65 536 |
| 16 bits (ADIW, SBIW) | a16 × k6, ambos completos, × 2 SREG | 8 388 608 |
| Multiplicación (MUL, MULS, MULSU, FMUL, FMULS, FMULSU) | a × b × 2 SREG | 131 072 |

**Total: 22 282 240 vectores sobre 24 operaciones. 0 fallos. 6 segundos.**

### El barrido de SREG no es cosmético

No basta con recorrer C y Z en la entrada. Hay que entrar con **H, T e I puestos** para verificar
que las operaciones que no deben tocarlos los conservan. Con H = 0 de entrada, una máscara que
escribiera H por error daría 0 en ambos lados y la comparación pasaría igualmente.

Esto era un hueco real del banco: la afirmación «INC y DEC no tocan H» no estaba verificada.
Se detectó auditando la cobertura, no ejecutando los tests. Cerrado y comprobado: inyectando esa
máscara errónea, el barrido pasa de 0 fallos a 65 536.

### Por qué hacen falta TRES oráculos, no dos

El oráculo es doble y se contrasta consigo mismo antes de emitir nada:

- `alu_scalar()` — transcripción escalar y legible del manual del ISA. Es la especificación
  ejecutable.
- `gen_*()` — versiones vectorizadas con numpy, que generan los 10,9 millones de vectores en medio
  segundo.

Antes de generar, las dos se comparan sobre todos los casos borde conocidos (0x00, 0x01, 0x0F,
0x10, 0x7E, 0x7F, 0x80, 0x81, 0xFE, 0xFF y sus combinaciones) más una muestra aleatoria. Si
divergen, el generador aborta: **una versión rápida que no coincide con la especificación legible
no sirve de oráculo.**

Pero eso **no basta**. El modelo de referencia y el RTL los escribe la misma persona leyendo el
mismo manual: que coincidan demuestra que no hay erratas de transcripción, no que la
interpretación sea correcta. Un error conceptual cometido dos veces pasa desapercibido.

Por eso hay un **tercer oráculo independiente**: `sim/alu/simavr_oracle.c` ejecuta las
instrucciones AVR reales sobre **simavr**, una implementación de terceros del núcleo, y
`compare_simavr.py` contrasta los 10 887 168 casos. El SREG esperado se calcula aplicando la
máscara —`(sreg_in & ~mask) | (sreg_out & mask)`— con lo que se verifica también su semántica.

**Esto no es teórico.** El contraste contra simavr encontró un fallo real que la verificación
exhaustiva contra nuestro propio modelo no podía encontrar: el flag H de `NEG` estaba
implementado como `R3 | ¬Rd3` cuando el manual dice `R3 | Rd3`. El mismo error estaba en el RTL y
en el modelo de referencia, así que coincidían en los 65 536 vectores de `NEG` y ninguno de los dos
podía delatar al otro; sólo un tercero podía verlo.

**Medido:** corregir uno solo de los dos lados produce **32 768 discrepancias** de 65 536 — el flag
difiere exactamente en los 128 valores de `Rd` cuyo resultado tiene el bit 3 a cero, por los 256
valores de SREG de entrada del barrido.

### Prueba de mutación: ¿puede fallar el banco?

Un banco de pruebas que no puede fallar no verifica nada. `sim/mutation.py` inyecta fallos
deliberados y plausibles en **todos** los módulos —un término de menos en una expresión de flags,
una polaridad invertida, una máscara que escribe un bit de más, un puntero intercambiado, un
operando con el signo equivocado— y comprueba que la regresión los detecta.

Los mutantes están curados para que ninguno sea *equivalente*. Por ejemplo, en `LSR` no vale usar
`n = r_lsr[7]`: como `r_lsr = {1'b0, a[7:1]}`, su bit 7 es siempre 0 y la mutación sería idéntica
al original. Sobreviviría sin que eso indicara agujero alguno.

**Y la curación no se acaba nunca**, porque el RTL se mueve. Al cerrar D12 sobrevivió un mutante
que apagaba la paridad y la parada en MSPIM: no era un agujero del banco —que corre con `UPM=11`,
`USBS=1` y `MPCM=1` puestos a propósito— sino un **equivalente sobrevenido**, porque en ese modo la
trama la delimita el reloj y esas ramas ya no se alcanzan. Un superviviente **no es** un fallo del
RTL por defecto: es una pregunta, y hay tres respuestas posibles —falta banco, falta observar el
pin, o la línea no hace nada—. En este caso la respuesta fue quitar tres líneas.

Se ejecuta con `make mutation` (~9 min), en un trabajo propio de la CI.

**Un patrón que ya no se encuentra NO es «detectado»**, y ésa es la forma más silenciosa de perder
un mutante: el catálogo busca un trozo de texto literal del RTL para sustituirlo, así que mover una
línea deja el mutante sin inyectar y la cuenta final no baja, porque ese mutante simplemente no
corre. Ha pasado **cinco veces** al mover el RTL. Por eso `make mutation-check` comprueba los 327
patrones **en un segundo** y corre en el trabajo rápido de la CI, en cada push; y `make mutation`
lo hace también antes de inyectar nada, en vez de descubrirlo nueve minutos después.

**El catálogo se reapunta EN EL MISMO COMMIT que mueve el RTL.** No es una recomendación: es la
única forma de que la cifra de mutantes signifique algo.

#### Y hay un segundo motivo para ejecutarlo, que se descubrió a base de sufrirlo

`make mutation` **modifica el RTL en sitio** y lo restaura al terminar. Si la ejecución se corta de
mala manera —la máquina se apaga, el proceso muere sin poder atender la señal—, **el árbol se queda
con el último mutante puesto**. El cerrojo de `build/.mutation.lock` sobrevive y avisa de que algo
quedó a medias, pero no dice *qué*.

Pasó el 22-sep: el árbol quedó con `total = primera ? 50 : 24` en el ADC, o sea **una conversión de
12 ciclos donde la tabla 23-1 dice 13**. Y lo importante es lo que NO lo detectó: `make lint` pasó
limpio, la síntesis habría pasado, y el fallo es de los que sólo se ven midiendo. Lo cazó
`mutation-check` en un segundo, porque un mutante puesto significa que **el texto original del
catálogo ya no está en el fichero**.

O sea que la misma puerta sirve para dos preguntas opuestas: *¿el catálogo sigue apuntando al
RTL?* y *¿el RTL sigue siendo el RTL?*. **Después de una mutación interrumpida, `mutation-check`
antes que nada.**

#### Y sirve para preguntar «¿esto lo comprueba alguien?»

La mutación no es sólo una nota al banco: es la forma barata de **medir un hueco antes de
escribirlo**. Al cerrar el modo SPI maestro se inyectaron a propósito cuatro fallos de
**encaminamiento de pines** —`XCK` fuera de PD4, el maestro mirando el `DDR` de otro pin, `SDA` y
`SCL` intercambiados, y el TWI adueñándose de dos pines del puerto C que no son suyos— y **los
cuatro sobrevivían a la regresión entera**.

No era un fallo del RTL: era que **nadie miraba esos pines**. El banco de un periférico cuelga de
su propio bus y no ve el SoC, así que no puede decir por dónde sale una señal; y el arnés
diferencial realimenta el pad sobre sí mismo, de modo que un lazo cerrado **se cree cualquier
cosa** —intercambiar `SDA` y `SCL` es simétrico y pasa sin más—. Lo que mata a los cuatro es
`make sim-hello`, que ejecuta firmware de verdad y **decodifica la línea**: un START es `SDA`
bajando con `SCL` alta, y eso sólo ocurre si `SDA` es PC4 y `SCL` es PC5.

**La regla, que ya va por su tercera repetición** —el SPI, `MSPIM` y ahora el TWI—: *si nadie mira
el pin, el mapa de pines no está verificado*. Al añadir un periférico con pines, el banco propio
prueba lo que hace; `sim-hello` prueba **por dónde sale**.

**Al terminar reconstruye el árbol.** Los ficheros se restauran, pero `build/` se quedaba con
los binarios del último mutante: quien después ejecutara `./build/vdiff/diff` a mano —que es
justo lo que recomienda esta guía para depurar— estaría corriendo un mutante sin saberlo. Ya
pasó. Ahora se reconstruye y se exige verde, lo que de paso demuestra que la restauración
fue buena.

#### No es un adorno: ha encontrado cinco fallos reales

Todos en los **bancos de pruebas**, no en el RTL. Es exactamente su función: comprobar al que
comprueba.

| Fallo | Cómo se manifestaba |
|-------|---------------------|
| El arnés de memoria presentaba la dirección **antes** del flanco de subida | Una memoria en flanco de subida pasaba el test igual que una en bajada. No comprobaba la decisión de temporización del [ADR 0001](adr/0001-memorias-en-flanco-de-bajada.md), que es de lo que depende que `LD` y `LDS` conserven sus ciclos. |
| El arnés del banco de registros dejaba el reloj **en alto** tras el reset | La escritura del primer ciclo se perdía en el DUT pero no en el modelo. Latente: solo apareció al cambiar la secuencia aleatoria. |
| El comparador del decodificador **no miraba `alu_op`** | ADD y ADC comparten clase de operación, así que confundir suma con suma-con-acarreo pasaba el test sin más. |
| Tampoco miraba **puntero, modo ni desplazamiento** | Intercambiar los punteros Y y Z en `LDD` no se detectaba. |
| Tampoco miraba la **dirección de I/O** | Perder los bits altos de la dirección en `IN` y `OUT` no se detectaba. |

Los tres últimos convirtieron el «0 discrepancias» del decodificador en una afirmación mucho más
débil de lo que parecía: solo se comparaban clase, tamaño y registros. El comparador pasó de 5 a
**11 comprobaciones**, y el decodificador resultó estar correcto — el flojo era el test.

Ésta es la razón por la que la fase 1 empieza por la ALU: es el bloque con el mejor retorno
inmediato y establece el patrón para todo el proyecto.

---

## Capa 2bis — El decodificador contra avr-objdump

El decodificador tiene un espacio de entrada de 65 536 palabras: es enumerable por completo.
`sim/decode/objdump_oracle.py` genera un binario con los 65 536 opcodes, cada uno seguido de una
palabra de relleno, lo desensambla con **`avr-objdump`** de binutils y extrae de la salida el
tamaño real de cada instrucción, su mnemónico y sus operandos.

binutils no comparte una línea de código ni de criterio con nuestro RTL. Se comprueban cuatro
cosas, de más a menos crítica:

| # | Qué | Por qué importa |
|---|-----|-----------------|
| 1 | **`is_32bit`** | Es la salida más delicada del decodificador. De ella dependen que el secuenciador traiga la segunda palabra de LDS/STS/JMP/CALL y que CPSE/SBRC/SBRS/SBIC/SBIS salten una o **dos** palabras — la trampa nº 1. objdump da el tamaño real: oráculo exacto. |
| 2 | `illegal` | Codificaciones que no son instrucciones. |
| 3 | `op_class` | Clasificación, vía el mnemónico. |
| 4 | `rd` / `rr` | Operandos de registro. |
| 5 | `alu_op` | Qué operación pide a la ALU. Sin esto, ADD y ADC son indistinguibles. |
| 6 | puntero | Selección X/Y/Z, modo (ninguno, post-inc, pre-dec, desplazamiento) y valor de `q`. |
| 7 | `io_addr` | Dirección de I/O en IN, OUT, SBI, CBI, SBIC y SBIS. |
| 8 | `bit_num` | Número de bit en las instrucciones de bit. |
| 9 | `imm` | Inmediato en LDI, CPI, SUBI, SBCI, ORI, ANDI, ADIW y SBIW. |
| 10 | `rel_addr` | Desplazamiento relativo de RJMP, RCALL y las ramas. |

**Resultado: 0 discrepancias. 192 instrucciones de 32 bits detectadas, 192 en objdump.**

La diferencia en el recuento de ilegales (1765 en el RTL frente a 1554 en objdump) son exactamente
las 211 instrucciones que objdump decodifica pero que **no existen en el ATmega328P**: `elpm` (65),
`xch`/`las`/`lac`/`lat` (32 cada una), `des` (16), `eijmp` y `eicall` (1 cada una). El comparador
las contabiliza aparte y verifica que el RTL las rechaza.

Sensibilidad comprobada: al forzar `is_32bit = 0` en JMP, el contraste pasa de 0 a **64
discrepancias** — exactamente las 64 codificaciones de JMP.

## Capa 3 — Exactitud de ciclos

La tabla de ciclos de [`01-arquitectura.md`](01-arquitectura.md#tabla-de-ciclos-contrato-l3) se
codifica como fichero de datos: `sim/perf/cycles_ref.py` la transcribe y la proyecta sobre los
65 536 opcodes. **La identidad de cada codificación la fija `avr-objdump`, no nuestro
decodificador**, de modo que un fallo de clasificación del RTL no puede heredarse a la tabla de
ciclos y darse la razón a sí mismo.

La comprobación vive dentro del arnés diferencial: `rtl_step()` ya devolvía los ciclos de cada
instrucción retirada, y ahora se contrastan contra la tabla tras **cada instrucción**, en todos los
programas del corpus. No hace falta un banco aparte.

**El ciclo de calentamiento tras el reset no se ignora, se comprueba.** La memoria de programa está
registrada, así que la primera instrucción consume un ciclo de más. El arnés exige que sea
exactamente uno: si costara dos, sería un fallo.

### simavr como contraste, no como oráculo

Se lee también `avr->cycle` y se compara. Pero **no es el oráculo**: el comentario de
`avr_run_one` en `sim_core.c` avisa de que su cuenta de ciclos «might not be entirely accurate».
Las discrepancias se informan aparte, con el mnemónico y el número de veces, para adjudicarlas a
mano contra el manual. A día de hoy no hay ninguna: sobre las 380 048 instrucciones dirigidas y
el millón de instrucciones aleatorias, simavr y el manual coinciden en todo lo ejecutado.

### Encontró un fallo real: MOVW

`MOVW` tardaba **2 ciclos** y el manual dice **1**. El estado quedaba correcto —los registros y el
SREG eran los que tocaba—, así que la comparación de estado lo daba por bueno. Sólo lo podía ver
una comprobación de ciclos.

La causa estaba en la **interfaz** del banco de registros, no en el secuenciador: lectura y
escritura de 16 bits compartían un único índice de par, así que copiar de un par a otro exigía dos
ciclos. [`01-arquitectura.md`](01-arquitectura.md) §4 ya decía que `MOVW` debe copiar par a par en
un ciclo; el que contradecía al documento normativo era el RTL. Se separaron los dos índices.

En el catálogo de mutación queda como mutante permanente —«MOVW vuelve a costar dos ciclos»—:
deja el estado correcto, así que **sólo la capa 3 puede cazarlo**. Si algún día sobrevive, es que
la comprobación de ciclos se ha apagado.

### La cobertura es un número, no una impresión

«0 desviaciones» no dice nada de lo que ningún programa ejecutó. `sim/perf/cycle_coverage.py` une
lo que el arnés ha comprobado de verdad y lo contrasta con la tabla.

Estado actual: **97 de 97 mnemónicos**, sobre 380 048 instrucciones y 0 desviaciones. Lo cerró la
suite dirigida (`sim/diff/tests/isa_*.S`). `SPM` es la única exclusión, y es deliberada.

### El arnés tampoco comparaba la memoria

`rtl_mem()` estaba definido y no se usaba: la comparación miraba PC, registros, SREG y SP, pero
ningún byte del espacio de datos. `ST`, `STS`, `PUSH`, `OUT`, `SBI` y `CBI` escriben sin leer, así
que una escritura a la dirección equivocada sólo se notaba si el programa volvía a leerla. Ahora,
al terminar cada programa, se barre la SRAM entera y los tres GPIOR.

Del resto del espacio de I/O no se puede decir nada en la fase 1: simavr modela los periféricos y
arranca varios registros con valores distintos de cero, mientras que aquí la I/O es memoria plana.
Los GPIOR son almacenamiento puro en ambos lados, y por eso son las direcciones que usan los
programas de prueba.

Lo que depende de esto: `_delay_ms()`, `_delay_us()`, `micros()`, `SoftwareSerial`, `Servo` y
cualquier protocolo bit-bangeado como el de las tiras NeoPixel.

---

## Capa 4 — Periféricos y mapa de registros

**Lo que hay hoy: `make sim-soc`**, que barre las **224 direcciones** del espacio de I/O por el bus
real del SoC y comprueba que el mapa coincide con la tabla `MAPA[]` de `sim/soc/tb_soc_map.cpp`
—escrita desde la hoja de datos—, que no hay dos periféricos respondiendo a la misma dirección, y
que los huecos se leen como `0x00`, porque **el espacio de I/O no es RAM**.

**Lo que falta, y está en la fase 3 del plan:** el barrido *semántico* del mapa, que no es el mismo
test. Comprobaría, dirección a dirección:

- bits reservados que deben leerse como 0;
- máscaras de sólo lectura;
- efectos laterales de lectura: leer `UDR0` limpia `RXC`, leer `ADCL` bloquea `ADCH`;
- la semántica *write-1-to-clear* de los `TIFRx`;
- el registro TEMP de 16 bits del Timer1.

Hoy cada una de esas propiedades la comprueba el banco propio de su periférico —que es donde vive
el modelo de la hoja de datos—, pero no hay un barrido único que las recorra todas. Mientras no lo
haya, la casilla de la Capa 4 se queda sin marcar.

**Modelos de bus en el banco de pruebas.** Un maestro y un esclavo I2C, un maestro y un esclavo SPI
y un extremo de USART —asíncrono y síncrono— que verifican la **forma de onda real** sobre los
pines, no sólo el contenido de los registros. Un periférico puede tener los registros correctos y
generar una trama incorrecta: los tres fallos del SPI y los seis del TWI son exactamente eso.

### El oráculo de cada periférico, y por qué no puede ser uno solo

El núcleo tiene a `simavr`, que es una implementación independiente y buena. Sus **periféricos**
no están al mismo nivel, así que cada uno se verifica por capas:

| Qué | Con qué |
|-----|---------|
| Semántica de los registros | Diferencial contra simavr, con la tabla `COMPARABLE[]` de `sim/diff/diff.cpp`, que crece con cada periférico |
| Lo que simavr no modela, o modela distinto | Banco propio contra un modelo escrito desde la hoja de datos |
| Forma de onda en los pines | Modelos de bus en el banco |

Y una regla: **donde discrepen simavr y la hoja de datos, manda la hoja de datos**, y la
discrepancia se anota en [`01-arquitectura.md`](01-arquitectura.md) §8bis. No es hipotético. Con
tres registros de E/S aparecieron tres discrepancias; con el Timer0, cinco más.

**El Timer0 es el caso extremo, porque simavr no cuenta ciclo a ciclo:** programa eventos e
INTERPOLA `TCNT0` desde `avr->cycle` cuando alguien lo lee. Compararlo en paralelo sería comparar
dos relojes distintos. El reparto que sí funciona:

- **cuándo** salta la interrupción lo decide el RTL, y lo verifica `sim/periph/tb_timer0.cpp`
  contra un modelo de la hoja de datos: 4 480 668 comprobaciones en 224 032 ciclos, con los ocho
  modos de onda, el doble búfer de `OCR0x`, las banderas y los pines de comparación;
- **qué hace el núcleo** al saltar lo verifica simavr: cuando el RTL entra en una ISR, el arnés le
  levanta ese mismo vector y le deja ejecutar su propia secuencia de entrada. Después se comparan
  el PC —la dirección del vector—, la pila, el `SP` y el `SREG`.

Esa segunda mitad es la que encontró los dos fallos de la entrada a interrupción: el vector se
calculaba multiplicado por cuatro en vez de por dos, y la máquina de estados se caía al `case` de
instrucciones en sus ciclos 1 a 3. Estuvieron escritos y sin ejercer desde la fase 1, que es
exactamente por lo que estaban declarados como no verificados.

**El controlador de interrupciones sí admite verificación exhaustiva**, porque su espacio de
entrada es enumerable: las 67 108 864 combinaciones de las 26 peticiones, comprobando prioridad y
reconocimiento (`make sim-irq`).

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

### La integración también se verifica

Cada periférico tiene su banco, pero que estén bien **colocados** es otra propiedad, y durante toda
la fase 1 y media fase 2 no la comprobaba nadie: el mapa de direcciones y el de vectores vivían en
el banco de pruebas. Ahí apareció un fallo real —un bit de más en una concatenación convertía
`TIMER0_COMPA` en `TIMER1_OVF`—.

`make sim-soc` barre **las 224 direcciones del espacio de I/O**, y lo hace por el camino real: carga
un programa con un `LDS` por dirección y deja que el núcleo lo ejecute. No fuerza ninguna señal
interna. Comprueba tres cosas:

1. **que no haya colisiones** — dos periféricos en la misma dirección es un fallo mudo, porque las
   lecturas se combinan con un OR y devolvería los dos valores mezclados;
2. **que el mapa sea el de la hoja de datos** — una dirección de menos es un registro que no
   existe; una de más, un registro que responde donde no debe;
3. **que los huecos se lean como `0x00`** — una dirección reservada del 328P no es RAM.

### El agujero que abre una conversión segura

Pasar el chip entero a habilitación de reloj (ADR 0003) es seguro **porque con
`CLKPS`=0 la habilitación vale uno siempre y el dispositivo queda bit a bit como estaba**: los
treinta y seis objetivos de la regresión siguen pasando sin tocar una línea, y si un módulo se
convierte mal lo dice su propio banco.

Y eso mismo significa que **nadie comprueba la habilitación**. Un módulo al que se le olvide —o un
`.ce()` que el SoC no cablee— pasa su banco, pasa lint, pasa síntesis y pasa el diferencial, porque
todos corren a reloj entero. El fallo sólo aparece el día que un programa baja el reloj para
ahorrar corriente, y aparece como un baudio que no cuadra.

`make sim-clk` lo cierra **midiendo por fuera, con programas de verdad**, y con cuatro patas
porque cada una recorre un camino distinto:

1. **un bucle que mueve un pin** — el núcleo, el bus y el puerto de E/S;
2. **`OC0A` en modo CTC, con dos tomas del prescaler** — la base de tiempo de un periférico. Las dos
   tomas no son redundancia: con `CS`=001 el reloj del temporizador sale directo de `clk_I/O` y **no
   pasa por el contador de diez bits compartido**, así que esa medida sola deja el contador sin
   comprobar. Se quitó su habilitación a mano y la medida seguía pasando;
3. **el ancho del bit de arranque de la USART** — que es el ejemplo que motiva el ADR. Al convertir
   el chip, el generador de baudios se quedó sin gatear y **ningún otro banco lo notó**;
4. **el intervalo entre dos mordiscos del perro guardián** — que tiene que salir **igual** con
   cualquier `CLKPS`, porque su cuenta corre con otro reloj.

Y `make sim-sleep` comprueba lo que hace `SLEEP`, que es **dejar de hacer**. Lo único que se puede
medir de eso es desde fuera y con el tiempo en la mano, y los cuatro casos están elegidos para que
entre los dos primeros y los dos últimos quede demostrado que `clk_CPU` y `clk_I/O` son **dos
relojes y no uno**:

| caso | qué pasa |
|---|---|
| `Idle` + desbordamiento del Timer0 | el núcleo se para y **el temporizador sigue**, así que lo despierta: el pin sale una vez cada 256 ciclos, clavado |
| sin `SE` | `SLEEP` es un `NOP` y el bucle corre suelto — 10 ciclos |
| `Power-down` + el mismo temporizador | **no despierta nunca**: es el mismo programa cambiando tres bits, y hace lo contrario |
| `Power-down` + perro guardián | **sí despierta**, a los ~200 700 ciclos, porque su cuenta no se gatea |

Ninguno necesita una ISR: el bit `I` global se deja a cero, y la hoja de datos dice que despierta
cualquier interrupción **habilitada en su máscara**. Con `I` a cero el chip despierta y sigue por la
instrucción de después del `SLEEP`. Es el idioma de «esperar a que pase algo» sin gastar un vector,
y comprobarlo así deja el banco sin tabla de vectores de por medio.

La cuarta pata nació de un mutante superviviente, y la lección es la de siempre: la primera versión
contaba los tics del oscilador **por fuera del chip**, y eso no prueba nada —los tics están ahí
igual; la pregunta es si el perro los usa—. Medir el mordisco sí lo prueba.

### `SPM`: cuando el oráculo no puede existir

De casi todo este chip hay un tercero que dice qué debería pasar. De `SPM` **no puede haberlo**, y
el motivo es bonito: el arnés diferencial contrasta el RTL contra simavr ejecutando **el mismo
programa** en los dos. Un programa que se reescribe la Flash **cambia ese programa mientras corre**,
así que a partir de la primera página escrita los dos lados ya no están ejecutando lo mismo y el
contraste no significa nada. No es que simavr no lo modele —lo modela—: es que la técnica no aplica.

Así que aquí el oráculo es el capítulo 26 de la hoja de datos, en dos niveles:

- **`make sim-spm`** (28 comprobaciones) contra el módulo: la secuencia temporizada, el búfer, el
  borrado, el volcado y `SPM_READY`;
- **`make sim-robust`** corre **la secuencia entera de un gestor de arranque** sobre el SoC —llenar
  el búfer con `SPM Z+`, borrar, esperar a `SPMEN` con `LDS`/`SBRC`/`RJMP`, volcar, esperar otra vez
  y releer con `LPM`—. Incluida una tercera palabra que tiene que salir **borrada**: eso comprueba
  de una vez que el búfer se limpió tras volcarlo y que el borrado llegó a las 64 palabras y no sólo
  a las dos escritas.

Y dos mutantes supervivientes dejaron su marca, como es costumbre aquí: uno quitó una guarda que
resultó ser **código muerto** —el `SPM` que arranca la operación ya cierra la ventana— y el otro
destapó que **ningún caso escribía `SPMEN` sin ejecutar `SPM` detrás**, que es justo cuando la hoja
de datos dice que se cae a los cuatro ciclos.

### Y una puerta que sólo se ve desde fuera: clonar y ejecutar

Todas las puertas de arriba corren en **este** árbol, que lleva meses de `build/` acumulado,
variables de entorno puestas y ficheros generados de una ejecución anterior. Eso las hace ciegas a
una clase entera de fallo: **lo que le pasa a quien clona el repositorio y ejecuta el comando**.

No es hipotético. Al verificar el estado publicado desde un clon limpio, `make check-all` falló
**los cuarenta y dos objetivos a la vez** con «No such file or directory»: la regresión escribe el
registro de cada objetivo en `build/` **antes** de que ningún objetivo haya corrido, y en un árbol
recién clonado ese directorio todavía no existe. Los objetivos lo crean al compilar; la regresión lo
necesitaba antes.

No rompía nada del chip, y por eso ninguna puerta lo veía. Pero es el primer comando que ejecuta un
tercero, y fallaba entero.

### El barrido de direcciones I2C, con un esclavo de verdad

La tercera cláusula del criterio de aceptación, y está bien elegida porque es la prueba que más
cosas tiene que atravesar a la vez: el núcleo ejecutando un bucle con saltos condicionales y espera
por bandera; el TWI generando START, dirección, ACK/NACK y STOP **ciento veintisiete veces
seguidas** sin colgarse ni una; los códigos de estado de `TWSR` siendo los de la tabla **porque el
programa decide con ellos**; y los pines como colector abierto de verdad, con el esclavo
contestando al tirar de la línea que el maestro acaba de soltar.

`make sim-i2c` usa **el mismo `EsclavoI2C`** que el banco del periférico —escrito desde la hoja de
datos, sin una línea en común con el RTL—, y que sea el mismo importa: si el barrido usara otro,
estaría probando el esclavo nuevo. Por eso el modelo vive ahora en `sim/periph/esclavo_i2c.h`.

**Y la prueba no es «encuentra el esclavo».** Es **encuentra el esclavo y no encuentra nada más**:
un TWI que contestara ACK a todo pasaría la primera mitad con nota. Las 126 direcciones vacías valen
tanto como la que responde. Y hay una tercera pasada con el esclavo **mudo**, donde no puede
aparecer ninguna: sin ella, un barrido que devolviera siempre `0x50` también pasaría.

Medido: **127 direcciones en 48 533 ciclos, una sola contesta; con el esclavo mudo, ninguna.**

### `micros()` no deriva, y qué significa eso en un chip

Es una de las tres cláusulas del criterio de aceptación de la fase 3, y conviene decir qué se
demuestra, porque `micros()` es una función de una biblioteca y aquí no se compila ninguna.

`micros()` y `millis()` se apoyan en **una sola cosa del hardware**: que el Timer0 desborde cada 256
cuentas y que **ninguno de esos desbordamientos se pierda**. Si se pierde uno, el reloj del programa
se retrasa 1 024 µs **de golpe y no se recupera nunca**. No es un redondeo que se promedie: es un
escalón permanente.

`make sim-micros` lo mide con el chip incómodo —otra interrupción compitiendo y secciones con las
interrupciones apagadas, que es lo que hace cualquier biblioteca al tocar una variable compartida—
y separa dos cosas que no son lo mismo:

| | qué es | se acumula |
|---|---|---|
| **jitter de latencia** | que una ISR entre unos ciclos más tarde que otra | **no** — y un AVR de verdad también lo tiene |
| **deriva** | que el periodo medio no sea el del temporizador | **sí**, y eso rompe `micros()` |

Se distinguen **midiendo dos ventanas de longitud muy distinta**. Con deriva, el desvío crecería con
la ventana. Medido: **200 periodos → +13 ciclos; 800 periodos → +13 ciclos**. No crece, así que es
latencia. Un solo ciclo de deriva por periodo habría dado 800.

Y hay un segundo escenario, el que de verdad pierde desbordamientos: **una ISR casi tan larga como
el periodo**, barriendo su longitud para caer en el ciclo exacto en vez de confiar en que toque.
Aquí la afirmación hay que medirla bien, y la primera versión no lo hizo: con la ISR en 248 ciclos
el servicio ya no cabe en los 256 del periodo y **un AVR de verdad también pierde el
desbordamiento**. Exigir que no se pierda ahí es exigirle al chip algo que el original no cumple. Lo
que se exige, y es lo que importa, es que **mientras la ISR quepa no se pierda ni uno**, por poco
que sobre.

### El barrido semántico: 656 bits, y ninguno sin decir qué es

`make sim-soc` comprueba el mapa de **direcciones**. Eso deja entera la pregunta que de verdad
decide si un sketch funciona: **dentro de un registro que sí existe, ¿qué hace cada bit?** Un
registro puede estar en su dirección, leerse y escribirse, y tener un bit reservado que devuelve
basura, o uno de sólo lectura que se deja escribir, o una bandera de las que se limpian escribiendo
un uno que se comporta como almacenamiento. Nada de eso lo ve el barrido de direcciones.

`make sim-bits` lo cierra, y su valor está en **de dónde sale cada mitad**:

- **qué bits existen** lo genera `tools/gen_regmap.py` preguntándole al preprocesador de avr-gcc con
  avr-libc. O sea que la lista de reservados no es una lectura mía de un PDF: es el mismo tercero
  independiente que ya decide las direcciones. Y de los reservados la hoja de datos dice algo
  comprobable: **se leen como cero**;
- **qué hace cada bit que existe** se escribe a mano, porque no hay tercero que lo sepa, y la tabla
  obliga: los bits que no son almacenamiento llano **tienen que llevar un motivo escrito**, y el
  banco falla si falta. Un bit sin clasificar no puede esconderse.

Son **tres pasadas**. Las dos primeras prueban cada registro **desde un reinicio limpio**, con su
propio programa —escribir `0xFF` en `WDTCSR` arma el perro guardián y en `EECR` lanza una
grabación—, con unos y con ceros. La tercera **satura el espacio entero** y después lee: sin ella,
los bits reservados de un registro alimentados desde otro se escapan, y eso no es teórico —un
mutante que hacía `EEARH` devolver bits de `EEARL` sobrevivía a las dos primeras—.

Hoy: **656 bits en 82 registros — 393 de almacenamiento, 134 con comportamiento propio y 129
reservados. Ninguno sin clasificar.**

#### Lo que encontró, y una vez perdió el oráculo

**Un fallo nuestro:** `PRR` guardaba y devolvía su bit 4, que no existe. No rompe nada hoy; rompe el
día que un programa lee el registro, le cambia un bit y lo vuelve a escribir, que es el idioma
normal en C.

**Dos clasificaciones mías equivocadas**, que el banco corrigió: `MSTR` de `SPCR` no es
almacenamiento —el hardware lo **limpia** si `SS` es entrada y está a cero, que es la detección de
colisión de maestros—, y `TWDR` tampoco —sólo se deja cargar con `TWINT` puesto, y fuera de tiempo
levanta `TWWC`—. Las dos son la hoja de datos funcionando, y ahora están escritas.

**Y una vez el oráculo se equivocó**, que es el caso para el que existe la segunda mitad de la regla
del proyecto. avr-libc define los bits de `TWAMR` como `TWAM0`=0 … `TWAM6`=6. La hoja de datos los
pone en los bits 7:1. No hace falta creer a ninguno de los dos: **en el mismo fichero**, avr-libc
define `TWAR` como `TWGCE`=0 y `TWA0`…`TWA6` en los bits 1:7, y `TWAMR` es la máscara que se aplica
a esa dirección:

```
((recibida ^ TWAR) & ~TWAMR) == 0
```

Una máscara colocada en los bits 6:0 **no puede enmascarar una dirección que vive en los 7:1**. La
definición de avr-libc es incoherente consigo misma, y por tanto es la equivocada. El RTL ya estaba
bien. La corrección vive en `tools/gen_regmap.py`, con el razonamiento escrito, **y no en el banco**:
quien habla por avr-libc en este proyecto es ese generador, y una excepción escondida en un banco
sería una excepción que nadie encuentra.

### Siete cables a la vez: `PRR`

`PRR` apaga siete periféricos uno a uno, y con la habilitación de reloj repartida implementarlo es
**una `and` por módulo**. Eso lo hace barato y también fácil de cablear mal: un bit cambiado de
sitio apaga el periférico de al lado.

`make sim-prr` pone **los siete a moverse a la vez** y apaga uno cada vez. La comprobación tiene dos
mitades y las dos hacen falta: que **el que se apaga se pare**, y que **los otros seis sigan**. La
segunda es la que distingue siete cables de uno — sin ella, atar todas las habilitaciones a
`~|prr` pasaría entero.

Cada uno se mira por un pin distinto a propósito, porque dos que compartieran harían que apagar uno
pareciera apagar al otro: `OC0A` en PD6, `OC1A` en PB1, `OC2B` en PD3 —PB3 no vale, ahí manda
`MOSI`—, `TXD` en PD1, `SCK` en PB5, y del TWI **su habilitación de salida** y no su valor, porque
es colector abierto y no «saca» un uno. El ADC va en modo libre y se mira el pulso del S/H.

**Y escribir ese programa encontró un fallo real en el ADC**, de los que no dan error: la guarda que
limpia `ADSC` con el convertidor apagado miraba el `ADEN` **guardado**, así que escribir
`ADCSRA = (1<<ADEN)|(1<<ADSC)` —el idioma de medio Arduino— borraba el `ADSC` recién puesto y el ADC
no convertía nunca. La hoja de datos nombra ese caso con todas las letras al explicar los 25 ciclos:
*«or if ADSC is written at the same time as the ADC is enabled»*. Ningún caso del banco del ADC lo
escribía así; ahora hay uno.

### Y una tercera vez: `PUD`

`PUD` vive en `MCUCR`, que es del control de reloj, y lo que apaga son los pull-up de los **tres**
puertos de E/S. Otro cable entre periféricos, y por tanto otra cosa que ningún banco de módulo
puede decir: en `axioma_gpio` el `pud` es un puerto de entrada y da igual quién lo mueva. Tres
cables son tres oportunidades de olvidarse de uno.

`make sim-pud` lo cierra con un programa que deja los tres puertos como entrada con el pull-up
pedido y escribe `MCUCR`. Se mira por fuera que los tres se caigan — y con `PUD` a cero, que estén
**puestos**, porque un SoC que atara `pud` a uno apagaría los tres y sin el caso contrario eso
parece «apaga bien». Hay un mutante por cable y uno más para ese caso.

### El mismo agujero, otra vez: los cables entre periféricos

El mapa de direcciones no es lo único que vive en el SoC y no en ningún módulo. **Las fuentes del
disparo automático del ADC son ocho cables**, y en `axioma_adc` son un puerto: da igual qué haya al
otro lado. Una permutación —que `OCF0A` y `OCF1B` se crucen— pasa el banco de módulo, pasa lint,
pasa síntesis y sale en el chip.

`make sim-trig` lo cierra provocando **cada fuente por su camino real**. Un programa de verdad
configura el periférico de verdad: se pone `PD2` como salida y la sube para fabricarse su propio
`INT0`, precarga el Timer1 cerca del final para fabricarse su `TOV1`, mueve `ICP1` para fabricarse
su captura. Desde fuera se mira el pulso del S/H, que es la prueba observable de que una conversión
empezó.

**Y la prueba positiva no basta.** Un multiplexor roto de forma que TODO dispare pasaría las siete
pruebas. Por eso cada fuente se comprueba tres veces: con `ADTS` apuntando a ella —tiene que
arrancar—, con `ADTS` apuntando a otra que nadie provoca —no tiene que arrancar— y sin `ADATE`
—tampoco—. **Eso es lo que distingue un cable de un cortocircuito**, y es el mismo razonamiento que
la prueba negativa del mapa de I/O: comprobar que algo responde donde debe no dice nada hasta que
se comprueba que no responde donde no debe.

Que el banco sirve está comprobado por construcción: se cruzaron dos entradas de la tabla a mano y
cayó con dos fallos.

---

## La cobertura: la única que dice lo que NO se ha probado

Un «0 divergencias» no dice nada sobre lo que no se ejecutó. La prueba de mutación cubre parte de
ese hueco, pero su catálogo lo escribe una persona: **sólo prueba lo que a alguien se le ocurrió
romper**. La cobertura de código dice, sin opinión, qué líneas y qué señales no ha tocado nadie.

`make coverage` instrumenta el RTL y **fusiona todas las fuentes**: 53 ejecuciones instrumentadas
—el arnés diferencial con sus veinte programas y los diez aleatorios, el banco propio de cada
periférico, el del disparo del ADC, el de robustez y el de extremo a extremo—. La fusión es lo que importa: medir sólo el
diferencial da un 80 % y una conclusión falsa, porque cada periférico sale bajo cuando su
funcionalidad la cubre **su** banco.

**Y el banco de un periférico nuevo tiene que ESCRIBIR su fichero de cobertura**
(`VerilatedCov::write` con `AXIOMA_COV`). Sin eso corre entero, pasa entero, y el módulo aparece al
65 % porque lo único que lo pisa son los programas del diferencial. Es el séptimo sitio que hay que
tocar al añadir un periférico, y lo destapó esta puerta al bajar de 99,6 % a 95,2 %.

**Qué encontró la primera medida.** Cuatro caminos que ningún banco pisaba jamás:

| Camino | Qué había dentro |
|--------|------------------|
| `SPM` | **Tres fallos.** Escribía `{Rd, Rd}` en vez de la palabra `R1:R0`; `SPM Z+` decodificaba el post-incremento sin escribir `Z` de vuelta; y cuando se arregló eso, avanzaba **un byte** donde una palabra son dos |
| Ejecución de un opcode ilegal | Sin comprobar que el núcleo no se cuelga. En un chip que va a fabricarse, un opcode corrupto no puede parar la máquina |
| Las tres interrupciones de la USART | Los vectores 18, 19 y 20 nunca dispararon. El cableado de vectores es justo donde apareció el primer fallo del Timer0 |
| `sreg_wr_en` / `sreg_wr_data` | **Lógica muerta**: dos puertos y una puerta OR que no podían activarse nunca. Eliminados |

Hoy está en **99,8 %** —3 258 de 3 266 puntos—, con **22 de 28 módulos al 100 %**. Los catorce
puntos que faltan **no son alcanzables** y están adjudicados uno a uno:

| Módulo | Puntos | Qué son |
|--------|-------:|---------|
| `axioma328_soc` | 8 | líneas de declaración cuyos bits van atados a constante: el TWI no conduce nunca un uno, el esclavo de SPI sólo fuerza dirección, y el frente analógico del comparador no mueve las suyas en simulación |
| `axioma_alu` | 3 | el `default:` de un `case` completo. El decodificador sólo emite operaciones válidas; es la rama defensiva que la síntesis elimina |
| `axioma_seq` | 1 | `next_warmup`, el ciclo de calentamiento que sólo pone el reset |
| `axioma_progmem` | 1 | el `$readmemh`, que sólo corre cuando el programa va DENTRO del bitstream; en simulación se carga por la puerta de atrás |
| `axioma_twi` | 1 | el `default:` de la máquina de estados, con sus casos enumerados |

El umbral está en el 99 %: si baja, hay un camino nuevo que nadie ejercita.

---

## La comprobación que no es una capa: que el RTL siga sintetizando

`verilator --lint-only` **no es un sintetizador**. No infiere latches, no resuelve la jerarquía
como lo hará la herramienta que fabrica el bitstream, y no dice cuánta área ocupa nada. Durante la
fase 1 el README citó números de LUT del ECP5 que ningún comando volvía a medir: eran una foto de
un día, no una propiedad comprobada.

`make synth-check` pasa yosys por todo el RTL y:

- **falla si se infiere un solo latch.** Un latch es una rama de un `always @(*)` que no asigna una
  señal, y es el fallo clásico del RTL escrito a mano. **La simulación no lo distingue de la lógica
  correcta**, porque el simulador conserva el valor anterior igual que el latch: aparece en
  silicio. Ningún banco de los de arriba lo puede cazar;
- **mide el área de cada módulo por separado** y la publica. El área no es criterio de fallo: es un
  número que se enseña, para que un cambio que duplique un módulo se vea en el diff de la CI en vez
  de descubrirse al cerrar el timing en la fase 5.

Se sintetiza módulo a módulo a propósito: así el área es atribuible y uno que crece no se esconde
dentro del total.

---

## Capa 6 — Verificación formal

SymbiYosys sobre propiedades acotadas, donde el coste es bajo y el valor alto:

- El stack pointer nunca sale del rango de la SRAM
- El decodificador nunca emite dos escrituras simultáneas al banco de registros
- La máquina de estados del TWI no tiene estados inalcanzables ni bloqueos
- `I` del SREG sólo cambia con `SEI`, `CLI`, `RETI`, la entrada a interrupción o `BSET`/`BCLR`

---

## Integración continua

**Lo que hay hoy: `.github/workflows/ci.yml`, en cada push a `main` y en cada pull request**, y en
TRES trabajos separados a propósito:

| Trabajo | Qué ejecuta | Por qué va aparte |
|---------|-------------|-------------------|
| **Lint y ficheros generados** | `lint` · `regmap-check` · `lpf` · `check-docs` · `mutation-check` | Falla en un minuto, y casi todos los fallos tontos caen aquí. `check-docs` son **tres** comprobaciones: las rutas que citan los `.md`, la cuenta de vectores contra `irq_src`, y que **toda deuda citada en el código exista en el registro** |
| **Verificación del núcleo** | las **26 simulaciones**, `coverage` y `synth-check` | Es la señal que importa: si esto está verde, el dispositivo hace lo que dice. En local, `make check-all` corre los **33 objetivos** de una vez |
| **Mutación** | `make mutation`, los 327 mutantes | Tarda ~9 minutos y **modifica el RTL en sitio**. En un trabajo aparte no retrasa la señal del resto, y un catálogo desincronizado no se confunde con un fallo del RTL |

**Lo que NO hay, y conviene no creérselo:** no hay ejecución nocturna, ni matriz de compatibilidad
generada, ni síntesis para las otras dos familias de FPGA. Las tres estaban escritas aquí como si
existieran, en presente. Lo que sí es cierto es que **ninguna cifra de este repositorio se inventa:
todas las imprime un comando**. Pero copiarlas al README es un acto manual, y por eso se quedan
atrás — el 14-sep-2026 había nueve desactualizadas a la vez, y las nueve se descubrieron
comparando el README contra la salida de `make`, no por un fallo de la CI. Generar esa tabla desde
los resultados es trabajo pendiente; hasta que exista, **el `make` que cambie una cifra obliga a
revisar el README en el mismo commit**.

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
