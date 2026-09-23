# Deuda técnica

**Última revisión:** 22 de septiembre de 2026 (cierre de D14)

Este documento existe porque «está en el plan» y «está a medias» **no son lo mismo**, y mezclarlos
es la forma más fácil de que algo a medias llegue a una foundry. Aquí sólo hay lo segundo.

**La regla:** nada de esta lista se queda sin cerrar o sin justificar antes de abrir un frente
nuevo. Si algo no se puede cerrar todavía, se dice **por qué** y **qué lo desbloquea**.

---

## 1. Deuda: cosas construidas a medias

Son las que cuentan. RTL que existe, que se sintetiza y que va a acabar en silicio, pero que no
hace todo lo que su nombre promete.

| # | Qué | Estado |
|---|-----|--------|
| D1 | **Los cuatro pines de comparación no llegan al pad.** `OC0A`, `OC0B`, `OC1A` y `OC1B` se generan y están verificados en sus bancos, pero en el SoC salen a `()`. Sin ellos no hay `analogWrite()`, que es de lo primero que usa cualquiera | **CERRADA** — ver abajo |
| D2 | **`SPM` no es el del 328P.** Sin `SPMCSR` y sin granularidad de página: lo que hay es la escritura de una palabra, y está verificada. Un bootloader real no funcionará | Abierta · **fase 4** |
| D3 | **USART: modo síncrono y `MPCM`.** Sus bits se almacenaban y se leían de vuelta, pero no cambiaban el comportamiento | **CERRADA** 14-sep — ver abajo |
| D4 | **Modos de onda reservados.** `WGM` 4 y 6 del Timer0 y 13 del Timer1 no los define nadie: aquí cuentan como el modo normal | **Justificada**: ningún programa puede depender de un modo reservado. Declarado en el RTL |
| D5 | **El pull-up no es dinámico en la FPGA.** El SoC lo declara por pin como el chip, pero en el ECP5 el modo de pull-up es un atributo estático del bloque de E/S | **Justificada** para FPGA · en silicio se conecta a la celda del PDK |
| D6 | **Sincronizador de una sola etapa en `PINx`.** Deliberado: es lo que exige la temporización documentada del `nop`. Pero es un riesgo de metaestabilidad sin cálculo de MTBF | Abierta · **fase 5** |
| D7 | **`make sim-isa` era un objetivo que salía con error.** Prometía una suite que ya cubre `sim-diff` | **CERRADA** — ver abajo |
| D9 | **La documentación citaba ficheros que no existen.** Tres referencias muertas, una de ellas a un «test de CI» inexistente | **CERRADA** — ver abajo |
| D10 | **El Timer2 asíncrono no tiene dominio de reloj propio.** Cuenta los flancos de `TOSC1` sincronizados, viviendo en el reloj del sistema. La cuenta y las banderas salen bien; lo que no existe son los cinco bits de ocupado de `ASSR` —`TCN2UB` y compañía—, que se leen siempre a cero | Abierta · **fase 5** |
| D12 | **La USART no tenía el modo SPI maestro (`UMSEL` = 11).** Sus bits se almacenaban y se leían de vuelta, y nada más | **CERRADA** 16-sep — ver abajo |
| D13 | **`TXD` y `RXD` no llegaban a `PD1` y `PD0`.** Salían del SoC por dos puertos aparte | **CERRADA** 14-sep — ver abajo |
| D15 | **Leer la EEPROM no para el núcleo cuatro ciclos.** La hoja de datos dice «the CPU is halted for four clock cycles before the next instruction is executed»; aquí `EERE` devuelve el byte y el programa sigue. Rompe el nivel **L3** en las instrucciones que siguen a una lectura de EEPROM | Abierta · **fase 5** |
| D14 | **El ADC no tenía disparo automático (`ADATE` con `ADTS`).** Sólo hacía conversiones sueltas. Sus bits se almacenaban y se leían de vuelta | **CERRADA** 22-sep — ver abajo |
| D16 | **`IVSEL` no mueve la tabla de vectores.** El registro y su secuencia temporizada (`IVCE`) están hechos y verificados, y `ivsel` sale de `axioma_clkctrl`, pero el SoC no lo conecta: no hay sección de arranque hasta la fase 4 | Abierta · **fase 4** |
| D11 | **Los pines del TWI no tienen el limitador de pendiente del chip.** La hoja de datos describe `SDA` y `SCL` como colector abierto **con limitación de pendiente y supresión de picos**. El colector abierto y la supresión de picos están hechos y probados; la limitación de pendiente es del transistor de salida y no se puede escribir en Verilog | **Justificada** — ver abajo |
| D8 | **Los directorios de backend de memoria están vacíos.** `rtl/mem/backends/{sim,fpga_bram,sky130_sram}` sólo tienen un `.gitkeep`; la implementación real está dentro de los módulos | **Justificada**: el README y la arquitectura ya dicen que hay **una** implementación. Los directorios son marcadores de la fase 6 |

### D16 — `IVSEL` sin sitio a donde apuntar  ·  nace el 23-sep-2026

**Qué hay:** el registro `MCUCR` con su bit `IVSEL` y **la cuarta secuencia temporizada del chip**,
la de `IVCE`: escribir `IVCE` a uno, y dentro de los cuatro ciclos siguientes escribir `IVSEL` con
`IVCE` a cero. Está implementada y verificada en `sim/periph/tb_clkctrl.cpp`, incluida la regla de
que escribir `IVSEL` cierra la ventana en el acto.

**Qué falta:** que sirva de algo. `IVSEL` mueve la tabla de vectores de interrupción al principio de
la **sección de arranque**, y este chip no tiene sección de arranque: la escritura por páginas de la
Flash y `SPMCSR` son la deuda **D2**, de la fase 4. Mover los vectores a una dirección donde no hay
gestor de arranque sería peor que no moverlos.

**Por qué se declara en vez de no escribirlo.** Porque el registro **sí** tiene que leerse de
vuelta: un gestor de arranque que compruebe si ya está en modo arranque lee `MCUCR`, y un programa
que ejecute la secuencia tiene que ver `IVCE` subir y caer. Lo que no puede es fingir el efecto.

**Qué la desbloquea:** D2. Las dos son la misma pieza vista por dos sitios, y se cierran juntas.

### D10 — por qué está abierta y qué la desbloquea

En el chip, con `AS2` puesto, **todo** el Timer2 pasa al dominio de los 32 768 Hz, y de ahí salen
los bits de ocupado: una escritura tarda hasta un ciclo del cristal en cruzar, y el programa tiene
que esperar a que el bit se limpie. Aquí el temporizador sigue en el reloj del sistema y cuenta los
flancos de `TOSC1` con un sincronizador de dos etapas.

Lo que se pierde, dicho sin adornos: un programa que haga `while (ASSR & (1<<TCN2UB));` sale del
bucle a la primera. Sale **con la escritura ya hecha**, porque aquí son inmediatas, así que lo que
el programa quería garantizar se cumple — no es de las diferencias que hacen funcionar aquí código
que en el chip falla. Pero es observable, y está declarada en la cabecera de `axioma_timer2.v` y en
[`01-arquitectura.md`](01-arquitectura.md) §8bis.

**Qué la desbloquea:** un segundo dominio de reloj de verdad, con la transferencia de cada registro
por petición y confirmación, y los bits de ocupado saliendo de ahí. Eso es lógica entre dominios, y
la regla del proyecto para lógica entre dominios es que no se cierra sin **verificación formal** —
que es de la fase 5 y hoy está a cero. Cerrarla antes sería cambiar un problema declarado por uno
escondido.

### D11 — por qué está justificada

De las tres cosas que la hoja de datos pide en esos dos pines, **la que es lógica está hecha y la
que es eléctrica no lo es**:

- **Colector abierto: hecho, y en el diseño, no en el pad.** El TWI no tiene ningún camino por el
  que conducir un uno. Se construye con las dos anulaciones de `axioma_gpio`: el valor atado a cero
  y la dirección modulada. Un mutante que lo rompa —`assign scl_pull = ~scl_drv_q`, sin `TWEN`—
  muere en `make sim-twi`.
- **Supresión de picos: hecha, y hubo que escribirla.** Al redactar esta misma entrada se
  comprobó que **el sincronizador de dos etapas NO filtra nada**: propaga un pulso de un ciclo
  tal cual, porque para eso sirve un sincronizador —resolver metaestabilidad—, no para filtrar.
  Y en un bus de dos hilos eso no produce un bit erróneo: un flanco falso de `SDA` con `SCL`
  alto es un **START o un STOP inventado**, y se lleva la trama entera por delante.
  Ahora hay un filtro de coincidencia detrás del sincronizador: el valor sólo cambia cuando dos
  muestras consecutivas coinciden, con lo que se descarta cualquier pulso más corto que un ciclo
  —a 12,5 MHz, 80 ns, con margen sobre los 50 ns que pide la hoja de datos—.
  **Y se prueba con ruido de verdad**, que es la lección que este proyecto ya pagó con la USART:
  `make sim-twi` barre un pico de un ciclo por **todas** las posiciones de una transferencia
  completa, en las dos líneas, y exige que ni el código de estado ni el byte entregado cambien.
  El pico se inyecta **en el pin del DUT y sólo ahí**, no en el bus: el maestro y el esclavo del
  banco son el oráculo, y un oráculo con el mismo filtro que el diseño deja de serlo.
  Un mutante quita el filtro y muere en esa fase; con ondas limpias no se notaría.
- **Limitación de pendiente: no está, y no puede estarlo aquí.** Es una propiedad del transistor de
  salida, no del RTL. En la FPGA la fija el bloque de E/S del ECP5 y en silicio la celda de pad del
  PDK, exactamente igual que el pull-up de D5.

**Qué la desbloquea:** nada que se pueda escribir en Verilog. Se cierra eligiendo la celda de pad
en la fase 6 y comprobando en su hoja de características que cumple los tiempos de la
especificación I2C. Está anotado ahí.

## 2. Alcance planificado — esto NO es deuda

Está en el plan, con su fase y su criterio de aceptación. Se lista aquí sólo para que nadie lo
confunda con lo de arriba.

- **Fase 3:** ADC, comparador analógico, watchdog, EEPROM, `clkctrl`.
  Hoy **1 de los 25 vectores de interrupción** no tienen fuente, y la cuenta ya no se puede
  quedar atrás en silencio: la comprueba `make check-docs` contra el cableado de `irq_src`
  del SoC. Llegó a haber tres cifras distintas —10, 7 y 9— para la misma cosa.
- **Fase 4:** bootloader STK500v1, `SPM` completo, paquete de Arduino.
- **Fase 5:** verificación formal (a cero), simulación post-P&R con retardos anotados, portes a
  iCE40 y Gowin, regresión de 10⁷ instrucciones.
- **Fase 6:** silicio — DFT (scan y BIST), backend de Sky130, los `initial` de las memorias.

## 3. Lo que bloquea un tape-out

Vive en [`00-PLAN.md`](00-PLAN.md), al final de la fase 2, y se mantiene ahí porque es una lista de
**criterios de salida**, no de deuda. El único con riesgo de rediseño —el doble flanco de reloj— se
acotó el 11-sep: sólo `LDS` y `STS` obligan a que el macro de SRAM sea de flanco de bajada, y hay
mitigación identificada. Ver la adenda 2 del [ADR 0001](adr/0001-memorias-en-flanco-de-bajada.md).

---

## 4. Cómo se cerró cada una

### D1 — los cuatro canales de comparación llegan al pad  ·  11-sep-2026

`axioma_gpio` recibe dos máscaras nuevas, `ovr_en` y `ovr_val`, y el pad sale de

```verilog
assign pad_out = (port_q & ~ovr_en) | (ovr_val & ovr_en);
```

**Se anula el valor, nunca la dirección.** La hoja de datos es explícita: «the Data Direction
Register bit for the OC0A pin must be set as output before the value is visible on the pin». Un
`analogWrite()` sin su `pinMode()` no saca nada, ni en el chip ni aquí; modelarlo al revés haría
funcionar código que en silicio no funciona, que es la peor clase de incompatibilidad.

El SoC conecta `OC0A`→PD6, `OC0B`→PD5, `OC1A`→PB1 y `OC1B`→PB2. Verificación: `make sim-gpio` añade
una fase dirigida de anulación (909 708 comprobaciones) y `make sim-hello` **mide el ciclo de
trabajo en el pin**, en **tres canales a la vez y con tres ciclos distintos a propósito**:

| Canal | Pin | Medido | La fórmula `(OCR+1)/(TOP+1)` |
|-------|-----|--------|------------------------------|
| `OC1A` | PB1 | 25,39 % | 25,39 % |
| `OC0A` | PD6 | 74,86 % | 75,00 % |
| `OC0B` | PD5 | 12,49 % | 12,50 % |

Que los tres ciclos sean distintos no es decoración: es lo que hace VISIBLE un mapa de pines
cruzado. Con los tres al mismo porcentaje, intercambiar dos canales no cambiaría ni una cifra.

Cuatro mutantes nuevos en el catálogo, los cuatro mueren: que el canal no llegue al pad, que la
anulación fuerce también la dirección, que los dos canales del Timer0 salgan por el pin del otro, y
que `OC1A` se lleve el pin de `OC1B`.

**Y lo destapó la cobertura, no el banco.** Con sólo `OC1A` encendido, las tres líneas del SoC que
llevan los canales del Timer0 al puerto D no las ejercitaba nadie: salían marcadas como no cubiertas
—que es exactamente la forma que tenía D1 antes de cerrarse—. La puerta de cobertura es lo que
convierte «lo he conectado» en «lo he conectado y algo lo usa».

### D1bis — la anulación de DIRECCIÓN, que llegó con el SPI  ·  12-sep-2026

Al cerrar D1, el puerto sólo sabía anular el **valor** de un pin, y eso era lo correcto para los
canales de comparación: el programa sigue teniendo que poner `DDRx`. El SPI obligó a añadir el otro
mecanismo, el que la hoja de datos dibuja como `DDOE` en el diagrama del pin, porque su tabla 18-1
**sí** fuerza la dirección:

|         | `MOSI`  | `MISO`  | `SCK`   | `SS`    |
|---------|---------|---------|---------|---------|
| maestro | usuario | ENTRADA | usuario | usuario |
| esclavo | ENTRADA | usuario | ENTRADA | ENTRADA |

Son dos mecanismos y tienen que estar separados. Con uno solo, o los canales PWM forzarían la
dirección —y funcionaría un `analogWrite()` sin `pinMode()`, que en el chip no saca nada— o el SPI
no la forzaría y un esclavo con `DDB4` mal puesto conduciría `MISO` contra el maestro. Dos mutantes
lo fijan: «la anulación de VALOR también fuerza la dirección» y «la anulación de DIRECCIÓN no hace
nada».

### D7 — `make sim-isa`  ·  11-sep-2026

Objetivo retirado del `Makefile` y de la ayuda. No había nada que construir: las 131 instrucciones
las cubre `make sim-diff` contra simavr, instrucción a instrucción y con el contrato de ciclos L3,
y `make sim-random` las ejercita con 10⁶ instrucciones aleatorias. Un objetivo que promete una suite
y sale con error es peor que no tenerlo.

### D9 — las rutas que cita la documentación  ·  11-sep-2026

Tres referencias apuntaban a ficheros inexistentes, y la peor citaba un test de CI que nunca se
escribió:

| Dónde | Decía | Es |
|-------|-------|-----|
| `docs/00-PLAN.md`, `docs/01-arquitectura.md` | `sim/isa/regmap_check.py` | `tools/gen_regmap.py --check` |
| `docs/00-PLAN.md` | `docs/05-legal.md` | `docs/02-legal.md` |
| `docs/02-legal.md` | `docs/02-isa.md` | no existe; la descripción del ISA está en `01-arquitectura.md` |

Arreglar las tres era el trabajo de un minuto; lo que faltaba era la puerta. La CI ya validaba los
los enlaces de Markdown, que son la mitad de las referencias; la otra mitad son los
`path/como/este` del texto corrido, y nadie los miraba. `make check-docs` los comprueba y la CI lo
ejecuta. Mira sólo lo que **parece** una ruta del repositorio —lleva barra y empieza por un
directorio de primer nivel conocido—, de modo que quedan fuera los nombres sueltos en prosa
(`timer2.v`) y las cabeceras de terceros (`avr/io.h`). Lo que se cita a propósito sin existir —la
estructura anterior del repositorio, las rutas de fases futuras— va en una lista de excepciones con
su motivo al lado.

---

### D3 — el modo síncrono y MPCM, cerrada  ·  14-sep-2026

**Salió más barato de lo que parecía, y por un motivo que conviene recordar: el motor de trama es
el mismo.** Arranque, datos, paridad y parada se cuentan igual en asíncrono y en síncrono; lo único
que cambia es quién dice «avanza un bit». En asíncrono lo dice el generador de baudios con su
sobremuestreo por dieciséis; en síncrono, los flancos de `XCK`. Poniendo el sobremuestreo a uno, el
contador se agota en el mismo pulso y **la máquina de estados no se tocó**.

Ése fue el orden, y es el mismo que salvó el refactor del Timer0: primero se metió la indirección
dejando el camino asíncrono idéntico, se corrieron sus **44 082 comprobaciones** como red —0
fallos, la misma cifra exacta— y sólo después se añadió lo nuevo.

**`UCPOL` es una inversión del pin.** Visto así ahorra media máquina de estados: dentro se trabaja
siempre con la misma convención —se muestrea en la subida y se cambia el dato en la bajada— y el
pin lleva ese reloj pasado por un XOR. Sale exactamente lo que dicen las dos filas de la hoja de
datos sin escribir dos caminos.

**`XCK` es `PD4`, y la dirección la pone el programa.** `DDR_XCK0` es lo que elige entre maestro y
esclavo, así que el periférico anula el **valor** del pin y nunca su dirección — el criterio
contrario al del SPI, y el mismo que el de los canales de comparación.

**Verificación:** `make sim-usart`, **45 313 comprobaciones**, contra un extremo síncrono escrito
desde la hoja de datos que cuelga de `XCK`. El periodo de `XCK` se **mide** contra
`f_CPU/(2·(UBRR+1))` en cuatro divisores; la forma de onda va en los dos sentidos, con las dos
polaridades, de maestro y de esclavo, en cinco tamaños de trama y tres paridades; y hay 150
transacciones aleatorias de semilla fija. Ocho mutantes nuevos, todos muertos.

**Dos cosas que el banco enseñó, y que no se habrían visto sin ellas:**

- **Que el dato llegue no prueba que `UCPOL` esté bien.** Con los dos extremos equivocados de la
  misma manera la trama sale perfecta — el fallo de siempre, el modelo y el diseño dándose la razón
  mutuamente. Un mutante que hacía al esclavo ignorar `UCPOL` sobrevivió a todo, incluido el
  tráfico aleatorio con las dos polaridades, hasta que se comprobó **en el flanco**: que `TXD` esté
  quieto alrededor del de muestreo, que es cuando el otro extremo lo lee.
- **`RXB8` se lee ANTES que `UDR0`**, porque leer `UDR0` saca el byte del búfer y con él se va su
  noveno bit. Lo destapó el barrido aleatorio: los casos dirigidos tenían el bit 8 a cero y pasaban
  sin probar nada. La hoja de datos lo dice con esas palabras, y el RTL ya lo hacía bien; era el
  banco el que leía al revés.

### D15 — leer la EEPROM no para el núcleo  ·  nace el 21-sep-2026

**Qué dice la hoja de datos:** «when the EEPROM is read, the CPU is halted for four clock cycles
before the next instruction is executed». Cuatro ciclos, cada vez que un programa hace `EERE`.

**Qué hace este RTL:** devolver el byte y seguir. El dato es correcto; lo que no es correcto es
**cuánto tarda el programa**.

**Por qué importa, y por qué no es cosmético.** Este proyecto tiene un contrato de nivel **L3** —la
misma cuenta de ciclos que el chip— y de él dependen `_delay_ms()`, `micros()`, `SoftwareSerial` y
cualquier protocolo bit-bangeado. Una rutina que lea varios bytes de EEPROM dentro de un bucle
temporizado va **cuatro ciclos por byte más rápida** que en el chip. No se nota leyendo una
calibración al arrancar; se nota en un bucle que además mueve un pin.

**Por qué se deja fuera ahora, por escrito.** Parar el núcleo **no es cosa de este periférico**:
hace falta una señal de espera que llegue a `axioma_seq` y congele la etapa de retiro, y hoy el
secuenciador no tiene ninguna. Es exactamente el mismo mecanismo que pedirá la **cola de
prebúsqueda** de la [adenda 2 del ADR 0001](adr/0001-memorias-en-flanco-de-bajada.md), que es de la
fase 5. Meter una espera ad-hoc para un solo periférico obligaría a rehacerla cuando llegue la
general.

**Qué la desbloquea:** esa señal de espera en el secuenciador. Cuando exista, esto son dos líneas:
`EERE` la levanta cuatro ciclos.

**Cómo se comprobará:** con un programa dirigido en el diferencial. simavr **sí** modela la parada,
así que el contraste de ciclos la cazaría sola — hoy no la caza porque ningún programa del
diferencial lee la EEPROM con `EERE`, y eso también queda dicho aquí para que no parezca que pasa
por estar bien.

### D14 — el disparo automático del ADC, cerrada  ·  nace el 17-sep-2026, cerrada el 22-sep-2026

**Lo que la tenía abierta era una dependencia, no una dificultad.** El texto de cuando nació lo
decía: *«dos de las ocho fuentes no existen todavía —el comparador analógico es de esta misma fase
y aún no está—, y cablear las otras seis sin poder probar las ocho dejaría media función sin
banco»*. Con el comparador dentro, la dependencia desapareció y la deuda se cerró entera.

**Lo que hay ahora.** `ADATE` rearma la conversión sola cuando se dispara la fuente que eligen los
tres bits `ADTS`, con las **ocho** entradas de la tabla 23-6 cableadas:

| `ADTS` | fuente | de dónde sale |
|---|---|---|
| 000 | modo libre | el fin de la conversión anterior |
| 001 | `ACI` | comparador analógico |
| 010 | `INTF0` | interrupción externa 0 |
| 011 | `OCF0A` | comparación A del Timer0 |
| 100 | `TOV0` | desbordamiento del Timer0 |
| 101 | `OCF1B` | comparación B del Timer1 |
| 110 | `TOV1` | desbordamiento del Timer1 |
| 111 | `ICF1` | captura del Timer1 |

**Tres cosas que no son obvias y que costaron sitio en el RTL:**

**1. El disparo va por el FLANCO de la bandera, no por su nivel.** Las banderas se quedan puestas
hasta que alguien las limpia, así que con nivel una sola comparación del Timer0 encadenaría
conversiones para siempre. Y hay un caso que sólo sale del flanco: la hoja de datos dice que
**cambiar `ADTS` a una fuente que YA está puesta genera un flanco positivo**, o sea que dispara.
Eso no es un efecto lateral, es el comportamiento documentado, y el banco lo comprueba.

**2. Son las banderas CRUDAS, no las peticiones de vector.** El ADC se dispara con `OCF0A` aunque
la interrupción de `OCF0A` esté apagada, que es justamente el uso típico: muestrear a una
frecuencia fija sin gastar una ISR por cada disparo. Por eso los cuatro módulos que aportan fuentes
—Timer0, Timer1, `extint` y el comparador— exportan un puerto nuevo con la bandera **sin la máscara
de habilitación**, y no se reutiliza la línea que ya va al controlador de interrupciones. Tres
mutantes del catálogo son exactamente ese error: exportar `bandera & habilitación`.

**3. `OCF0B` y `OCF1A` NO disparan.** Existen, están a un cable de distancia, y la tabla 23-6 no
las incluye: el ADC tiene siete fuentes, no nueve. En el SoC se declaran sin usar **a propósito y
por escrito**, para que lint no las tape y para que nadie las «arregle» más adelante.

**Cómo se verifica, y por qué el banco de módulo no bastaba.** En `axioma_adc` el bus de disparo es
un puerto: da igual qué haya al otro lado del cable. **Una permutación en la tabla del SoC —que
`OCF0A` y `OCF1B` se crucen— pasa entero el banco de módulo, pasa lint, pasa síntesis y sale en el
chip.** Es la misma lección del mapa de pines, y la respuesta es la misma: mirar el cable de
verdad. Así que hay dos capas:

- **`sim/periph/tb_adc.cpp`** (1 603 comprobaciones): las ocho entradas del multiplexor, el flanco,
  el cambio de fuente como flanco, el modo libre y que sin `ADATE` no dispara nada.
- **`sim/soc/tb_soc_trig.cpp`** (21 comprobaciones): cada fuente provocada **por su camino real**.
  Un programa de verdad configura el periférico de verdad —pone `PD2` como salida y la sube para
  fabricarse su propio `INT0`, arranca el Timer1 con la cuenta precargada cerca del final para
  fabricarse su `TOV1`, mueve `ICP1` para fabricarse su captura— y desde fuera se mira el pulso del
  S/H, que es la prueba observable de que una conversión empezó.

  **Y la prueba positiva no basta**, porque un multiplexor roto de forma que TODO dispare pasaría
  las siete. Por eso cada fuente se comprueba tres veces: se provoca con `ADTS` apuntando a ella
  —tiene que arrancar—, con `ADTS` apuntando a otra que nadie provoca —no tiene que arrancar— y sin
  `ADATE` —tampoco—. Eso es lo que distingue un cable de un cortocircuito.

**Que el banco sirve está comprobado por construcción**: se cruzaron `OCF0A` y `OCF1B` en el SoC a
mano y el banco cayó con dos fallos. Y en el catálogo de mutación hay **ocho mutantes nuevos** para
esta función —cuatro permutan la tabla, uno la cortocircuita y tres enmascaran las banderas en
origen—, los ocho detectados.

### D12 — la USART como maestro SPI, cerrada  ·  16-sep-2026

**El motor es el mismo por tercera vez** —asíncrono, síncrono y ahora MSPIM—, con la trama más
corta que se puede escribir: ocho bits de datos y nada más. Lo que no se pudo reutilizar son tres
cosas, y las tres son de fondo.

**1. Sin bit de arranque, la trama la delimita EL RELOJ.** De ahí sale todo lo demás: el receptor
no puede buscar un flanco de bajada, así que arranca con el transmisor; y la trama no puede
terminar «cuando toque el bit de parada», así que termina en el **octavo flanco de salida del
pulso**. Ése es el único instante que existe con las dos fases de `UCPHA` y el único que deja el
pin en su nivel de reposo — parar en la última muestra dejaría el reloj colgado a media altura.

**2. `XCK` sólo corre mientras hay trama.** Un maestro SPI no puede dejar el reloj suelto entre
bytes: el esclavo cuenta flancos, y un pulso de más lo descoloca para siempre. En el modo síncrono
es al revés —ahí el reloj corre libre—, y por eso son dos cosas distintas y no un parámetro.
Y **vuelve a su reposo entre tramas**: no basta con dejar de conmutarlo, porque el modo síncrono lo
deja donde le pilla y ese uno colgado es un flanco de bajada nada más arrancar. **La primera trama
salía corrida un bit** hasta que se escribió esa línea.

**3. El dato NO pasa por el sincronizador de tres etapas.** En asíncrono ese sincronizador es parte
de la recuperación de reloj. En síncrono se lo puede permitir por una razón que conviene no perder:
**el bit de arranque viaja por el mismo retardo, así que la trama se alinea sola**. En MSPIM no hay
arranque que alinee nada —el reloj lo pone este mismo módulo— y tres ciclos a `f_CPU/2` son **bit y
medio**. Se muestrea con una etapa, que es la guarda de metaestabilidad y nada más.

Lo que sí salió gratis: `UCPHA` **intercambia los dos flancos** en vez de duplicar la máquina, y
`UDORD` se resuelve **dando la vuelta al byte** al cargarlo y al guardarlo, con lo que el
desplazador sigue siendo uno solo. Los bits de `UCSR0C` son **los mismos biestables con otro
nombre**, que es lo que hace el chip, así que no hay un registro nuevo que almacenar.

**Verificación:** `make sim-usart`, **46 650 comprobaciones**, contra un **esclavo SPI escrito
desde la hoja de datos** —el mismo oráculo que usó el SPI: el otro extremo del cable—. Los cuatro
modos por los dos órdenes de bit, que una trama sean **ocho pulsos y ni uno más**, que `XCK` esté
quieto antes y después, el periodo contra `f_CPU/(2·(UBRR+1))`, el búfer de dos niveles con su
desbordamiento, tráfico aleatorio de semilla fija, y que con `UPM`, `USBS` y `MPCM` puestos la
trama salga **idéntica**. **Doce mutantes nuevos, los doce muertos.**

**Y tres cosas que dejó por el camino:**

- **Al modo síncrono le faltaba su velocidad máxima.** La suite empezaba en `UBRR=3`, así que de
  `UBRR=0` —que son `f_CPU/2`, lo que hace útil el modo— no se sabía nada. Ahora se barre 0..3.
- **Un mutante que sobrevive no siempre es un fallo.** Tres `wire` apagaban la paridad, la parada y
  `MPCM` en MSPIM; el mutante que los volvía a encender **sobrevivió a la regresión entera**, y no
  por falta de banco —corre con `UPM=11`, `USBS=1` y `MPCM=1` puestos a propósito— sino porque era
  **equivalente**: en MSPIM esas tres ramas quedan detrás del final de la trama y no se alcanzan
  nunca. Se quitaron los tres y se escribió el porqué en el módulo.
- **La cobertura destapó el segundo nivel del búfer.** El banco leía `UDR0` justo después de `RXC`,
  así que en MSPIM nunca había dos bytes a la vez y la rama salía sin cubrir. `axioma_usart.v`
  vuelve a estar al **100 %**.

**Y hay una segunda verificación que el banco del periférico NO puede dar: por qué pin sale `XCK`.**
`tb_usart.cpp` no ve el SoC, así que un `XCK` encaminado a otro bit del puerto D le parecería
correcto. Por eso `fw/hello/hello.c` hace ahora una **transacción MSPIM de tres bytes** —modo 3, el
más significativo primero, con `<avr/io.h>` sin tocar— y `make sim-hello` **la decodifica del pin**:
`XCK` en **PD4** con **48 flancos exactos** —tres tramas de ocho pulsos, ni uno más— y los bytes
`96 5A C3` por **PD1**. Dos mutantes nuevos, y son de los que **sólo** caza ese banco: quitarle a
`XCK` la anulación de PD4, y hacer que el modo maestro mire el `DDR` de otro pin.

De paso apareció algo que no es del chip sino **de quien lo observa**: al apagar MSPIM, el orden
importa. Si se borra `UCSR0C` antes que `UBRR0`, queda una ventana de dos instrucciones en la que
`UMSEL` ya dice «asíncrono» y el divisor sigue siendo el del SPI — y el banco midió ahí un periodo
de bit que no existe y no decodificó ni una trama del puerto serie. El chip no se entera; el
analizador lógico de al lado, sí.

**Coste medido:** el módulo pasa de **391 a 486 LUT4** en el ECP5, y el `Fmax` del dispositivo
entero de 20,23 a **19,77 MHz** tras el rutado —con la placa a 12,5, margen 1,58×—.

### D13 — el puerto serie vive en `PD1` y `PD0`, cerrada  ·  14-sep-2026

**No hacía falta nada que no estuviera ya escrito.** `axioma_gpio` tenía las dos anulaciones desde
el 11-sep —la de valor, del cierre de D1, y la de dirección, que llegó con el SPI—, así que el
trabajo era cablear:

- **`PD1`**: con `TXEN0` puesto es **salida pase lo que pase en `DDRD1`**, y la conduce el
  transmisor. Anulación de dirección **y** de valor.
- **`PD0`**: con `RXEN0` puesto es **entrada pase lo que pase en `DDRD0`**, y su pull-up sigue
  saliendo de `PORTD0`. Sólo anulación de dirección.

Son los dos únicos pines del puerto D que llevan anulación de dirección: los canales de comparación
y `XCK` no la llevan, porque ahí la hoja de datos exige que el programa ponga `DDRx` él mismo.

**Y se comprueba EN EL PIN, que es lo único que distingue un pin encaminado de un pin que resulta
que vale lo mismo.** `fw/hello/hello.c` deja `PD0` como **salida a propósito** antes de encender la
USART y no toca `DDRD1` en ningún momento; `make sim-hello` verifica que al encenderla los dos dan
la vuelta. Tres mutantes nuevos, los tres muertos, y ninguno se ve sin esa maniobra.

En el top de la placa, `PD0` y `PD1` se cablean como `D0` y `D1` en un Uno: el pad del conector y
la patilla del conversor USB-serie son el mismo pin.

### D13 — por qué estuvo sin registrar, que es lo peor de ella

La deuda está cerrada —arriba está cómo—, pero la lección de dónde vivía se queda escrita, porque
es la única parte que puede repetirse con la siguiente.

`TXD` y `RXD` salían del SoC por dos puertos propios y no por `PD1` y `PD0`. Las consecuencias no
eran teóricas: un programa no podía usar esos dos pines como E/S general con la USART apagada, la
USART no se adueñaba de ellos cuando estaba encendida, y el pinout del encapsulado no era el del
328P en esos dos pines.

**Lo que la hizo peor que una deuda normal es dónde estaba escrita: en un comentario del RTL y en
ningún otro sitio.** No estaba en este documento, ni en el plan, ni en el README. Y el comentario
decía que enchufarlos era «de la fase 3, igual que la de OC0A/OC0B» — trabajo que se cerró el
11-sep. O sea: la condición que la desbloqueaba llevaba tres días cumplida y nadie lo sabía, porque
la deuda no estaba en la lista que se revisa. Cuando por fin se registró, cerrarla costó un rato:
no faltaba nada: `axioma_gpio` ya tenía las dos anulaciones y el trabajo era cablear.

**La regla que sale de aquí:** un comentario del RTL no es un registro. Si algo se deja a medias a
propósito, la frase que lo dice va en este documento el mismo día, aunque el comentario del módulo
la repita.

## Cómo se usa este documento

1. Cuando algo se construye a medias **a propósito**, entra aquí en el mismo commit, con el motivo
   y con lo que lo desbloquea. No vale «ya lo pondré».

   **Y desde el 22-sep-2026 hay una puerta que lo comprueba.** `make check-docs` busca en el RTL y
   en los bancos cualquier comentario que cite una deuda —«la deuda D14», «D1 de la deuda
   técnica»— y **exige que exista su fila en esta tabla**. Si no está, falla y dice el fichero y la
   línea.

   No es una precaución teórica: la lección de D13 era precisamente que una deuda escrita **sólo**
   en un comentario del RTL no la ve nadie, y **cuatro días después de escribirla** un comentario
   de `axioma_eeprom.v` decía «es la deuda D15, declarada en el registro» con el registro sin D15.
   La lección estaba escrita y se repitió igual. Lo que no falla es lo que se comprueba.
2. Antes de abrir un frente nuevo se revisa esta lista y se cierra lo que se pueda cerrar.
3. Lo que no se pueda, se justifica. Una deuda justificada y escrita es una decisión; una deuda
   olvidada es una sorpresa en la oblea.
