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
corre. Ha pasado **cinco veces** al mover el RTL. Por eso `make mutation-check` comprueba los 259
patrones **en un segundo** y corre en el trabajo rápido de la CI, en cada push; y `make mutation`
lo hace también antes de inyectar nada, en vez de descubrirlo nueve minutos después.

**El catálogo se reapunta EN EL MISMO COMMIT que mueve el RTL.** No es una recomendación: es la
única forma de que la cifra de mutantes signifique algo.

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

---

## La cobertura: la única que dice lo que NO se ha probado

Un «0 divergencias» no dice nada sobre lo que no se ejecutó. La prueba de mutación cubre parte de
ese hueco, pero su catálogo lo escribe una persona: **sólo prueba lo que a alguien se le ocurrió
romper**. La cobertura de código dice, sin opinión, qué líneas y qué señales no ha tocado nadie.

`make coverage` instrumenta el RTL y **fusiona todas las fuentes**: 35 ejecuciones instrumentadas
—el arnés diferencial con sus veinte programas y los diez aleatorios, el banco propio de cada
periférico, el de robustez y el de extremo a extremo—. La fusión es lo que importa: medir sólo el
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

Hoy está en **99,5 %** —3 003 de 3 017 puntos—, con **21 de 26 módulos al 100 %**. Los catorce
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
| **Mutación** | `make mutation`, los 259 mutantes | Tarda ~9 minutos y **modifica el RTL en sitio**. En un trabajo aparte no retrasa la señal del resto, y un catálogo desincronizado no se confunde con un fallo del RTL |

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
