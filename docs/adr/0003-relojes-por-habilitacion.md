# ADR 0003 — `CLKPR` y `PRR` cortan relojes de verdad, en forma de habilitación

**Fecha:** 23 de septiembre de 2026 · **Estado:** aceptada

## Contexto

El décimo y último periférico de la fase 3 es el control de reloj, y trae dos registros que no se
parecen a nada de lo escrito hasta ahora porque **no actúan sobre sí mismos: actúan sobre todo lo
demás**.

- **`CLKPR`** divide el reloj del sistema entre 1 y 256. Afecta al núcleo, a la Flash y a todos los
  periféricos a la vez.
- **`PRR`** apaga el reloj de siete periféricos uno a uno, para ahorrar corriente.

Los dos son, en el chip, **puertas sobre el árbol de reloj**. Y el RTL de este proyecto está
escrito con un único `clk` que entra a diecinueve módulos y cuarenta y un bloques secuenciales.

Hay además un precedente incómodo que conviene mirar de frente: este documento ya declara cuatro
deudas cuya forma es exactamente *«los bits se almacenan y se leen de vuelta, y no pasa nada más»*
(D3, D12, D14 y el modo síncrono de la USART). Tres están cerradas. La cuarta manera de terminar
así sería declarar `CLKPR` como almacenamiento, y hay que decidirlo a conciencia y no por inercia.

## Decisión

**Se cortan relojes de verdad, y se hace con una señal de habilitación (`clock enable`) y no con
una puerta sobre el reloj.**

`axioma_clkctrl` genera dos habilitaciones —`ce_cpu` y `ce_io`— y el SoC las reparte. Cada bloque
secuencial del chip pasa de `always @(posedge clk)` a `always @(posedge clk) if (ce)`.

## Por qué, y por qué no de las otras dos formas

**Guardar los bits y no hacer nada** —la opción barata— no es aceptable aquí, y no por purismo. Un
programa que baja a `f/8` para ahorrar corriente **sigue viendo la USART a la velocidad de antes**:
el baudio sale mal por un factor de ocho. No es una incompatibilidad de detalle que se note en un
banco; es un dispositivo que no habla. Lo mismo con cualquier temporizador usado para medir tiempo
real. `clock_prescale_set()` es parte de avr-libc y se usa.

**Generar un reloj dividido y repartirlo** es lo que hace el chip, pero escrito a mano en Verilog es
una puerta combinacional sobre el reloj: genera picos en el cambio, y ninguna herramienta de
temporización lo analiza bien. La forma correcta —un pestillo en el flanco de bajada más una
puerta— **introduce un latch**, y este proyecto tiene una puerta de regresión que falla si aparece
uno (`make synth-check`). Saltársela para esto sería cambiar una regla que ha encontrado fallos por
una conveniencia.

**La habilitación es la forma que sintetiza bien en las dos tecnologías que este proyecto tiene
por delante**, y ésa es la razón de fondo:

- en la **FPGA** es la entrada `CE` del biestable, que ya está físicamente ahí y no cuesta área;
- en el **flujo ASIC** es exactamente de donde las herramientas *derivan* las celdas de puerta de
  reloj integradas (`ICG`). Escribir la habilitación es escribir la intención en la forma que la
  herramienta sabe traducir; escribir la puerta a mano es hacerle el trabajo mal.

## Las consecuencias, incluidas las que no gustan

**La buena, y es grande: con `CLKPS`=0 la habilitación vale 1 siempre.** El chip que hay hoy queda
**bit a bit idéntico**, así que las treinta y cuatro pruebas de la regresión anterior siguen
valiendo, y valen como red: si un módulo se equivoca al añadirle la habilitación, lo dice su propio
banco, que no ha cambiado. El contraste ciclo a ciclo contra simavr también sobrevive, que es lo
que decide el valor de reinicio (`CLKPS_RESET` = 0, el fusible `CKDIV8` sin programar, que es como
viene una placa Arduino).

**Los dos relojes no son uno.** `clk_CPU` y `clk_I/O` salen separados porque la figura 9-1 los
separa, y porque el sueño los necesita separados: en modo `Idle` el núcleo se para y los
temporizadores siguen contando. Ésa es la diferencia entre un `Idle` que sirve para algo y uno que
es un `Power-down` con otro nombre.

**Parar el reloj de verdad se hereda hacia abajo, y eso es bueno.** Sin `clk_I/O` no hay detección
de flancos, así que de un `Power-down` sólo despierta lo que no necesita reloj: una interrupción
externa de **nivel**, el perro guardián con su oscilador propio, la EEPROM. No hay que programar esa
restricción en ninguna parte — **sale sola de haber parado el reloj en vez de fingirlo**, y coincide
con lo que dice la hoja de datos. Fingirlo habría exigido escribir a mano una tabla de qué despierta
de qué modo, y esa tabla habría sido una fuente de fallos.

**`PRR` sale gratis, y ése es el argumento que cierra la decisión.** Con una habilitación por
periférico, apagar uno es `ce_periph = ce_io & ~prr[n]`: una `and`. Un periférico apagado se queda
congelado en el estado que tenía, sus escrituras no llegan y al encenderlo sigue donde estaba, que
es literalmente lo que promete la hoja de datos. Con la opción barata, `PRR` habría sido una segunda
deuda declarada.

**Lo que cuesta:** tocar diecinueve módulos y cuarenta y un bloques secuenciales, y añadir un pin a
cada envoltorio de banco. Es trabajo mecánico y con red, pero es trabajo, y se hace en un paso
aparte del que escribe el módulo — justo para que si algo se rompe se sepa qué commit lo rompió.

## Lo que esta decisión NO resuelve

`IVSEL` —mover la tabla de vectores al gestor de arranque— sale de este módulo con su secuencia
temporizada hecha y verificada, pero **el SoC no lo conecta**: no hay sección de arranque hasta la
fase 4. Queda declarado en el registro de deuda técnica en lugar de fingir que hace algo.

`BODS` y `BODSE` —apagar el detector de caída de tensión durante el sueño— se almacenan y se leen
de vuelta, y no pueden hacer nada más: **el detector de caída de tensión es analógico** y está
fuera por el mismo motivo que el comparador del ADC (ADR 0002). Aquí no hay deuda que declarar
porque no hay lógica que falte; hay una frontera, y es la misma de siempre.
