# Deuda técnica

**Última revisión:** 14 de septiembre de 2026

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
| D3 | **USART: modo síncrono y `MPCM`.** Sus bits se almacenan y se leen de vuelta, pero no cambian el comportamiento | Abierta · **fase 3** — **justificada el 14-sep**, ver abajo |
| D4 | **Modos de onda reservados.** `WGM` 4 y 6 del Timer0 y 13 del Timer1 no los define nadie: aquí cuentan como el modo normal | **Justificada**: ningún programa puede depender de un modo reservado. Declarado en el RTL |
| D5 | **El pull-up no es dinámico en la FPGA.** El SoC lo declara por pin como el chip, pero en el ECP5 el modo de pull-up es un atributo estático del bloque de E/S | **Justificada** para FPGA · en silicio se conecta a la celda del PDK |
| D6 | **Sincronizador de una sola etapa en `PINx`.** Deliberado: es lo que exige la temporización documentada del `nop`. Pero es un riesgo de metaestabilidad sin cálculo de MTBF | Abierta · **fase 5** |
| D7 | **`make sim-isa` era un objetivo que salía con error.** Prometía una suite que ya cubre `sim-diff` | **CERRADA** — ver abajo |
| D9 | **La documentación citaba ficheros que no existen.** Tres referencias muertas, una de ellas a un «test de CI» inexistente | **CERRADA** — ver abajo |
| D10 | **El Timer2 asíncrono no tiene dominio de reloj propio.** Cuenta los flancos de `TOSC1` sincronizados, viviendo en el reloj del sistema. La cuenta y las banderas salen bien; lo que no existe son los cinco bits de ocupado de `ASSR` —`TCN2UB` y compañía—, que se leen siempre a cero | Abierta · **fase 5** |
| D11 | **Los pines del TWI no tienen el limitador de pendiente del chip.** La hoja de datos describe `SDA` y `SCL` como colector abierto **con limitación de pendiente y supresión de picos**. El colector abierto y la supresión de picos están hechos y probados; la limitación de pendiente es del transistor de salida y no se puede escribir en Verilog | **Justificada** — ver abajo |
| D8 | **Los directorios de backend de memoria están vacíos.** `rtl/mem/backends/{sim,fpga_bram,sky130_sram}` sólo tienen un `.gitkeep`; la implementación real está dentro de los módulos | **Justificada**: el README y la arquitectura ya dicen que hay **una** implementación. Los directorios son marcadores de la fase 6 |

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

### D3 — por qué sigue abierta tras abrir el frente del TWI  ·  14-sep-2026

La regla de este documento es que antes de abrir un frente nuevo se revisa la lista y se cierra lo
que se pueda; lo que no, **se justifica por escrito**. El 14-sep se abrió el TWI con D3 abierta, y
ésta es la justificación.

**Qué falta exactamente.** `UMSEL` y `MPCM0` se guardan y se leen de vuelta, pero no cambian nada:
no hay pin `XCK`, no hay reloj síncrono —ni generado ni recibido—, y `MPCM0` no filtra las tramas
de dirección. Un programa que los ponga se lleva una USART asíncrona sin enterarse.

**Por qué el TWI iba antes.** No es una cuestión de esfuerzo sino de alcance: el criterio de
aceptación de la fase 3 es que **el scanner I2C detecte un esclavo real**, y eso es el TWI. En
código de verdad, además, la distancia es enorme: `Wire` está en el primer ejemplo de media
estantería de sensores, mientras que la USART síncrona del 328P no la usa prácticamente nadie —no
hay API de Arduino que la exponga— y `MPCM` es de buses RS-485 multipunto. Cerrar D3 primero
habría retrasado lo que sí bloquea el criterio de la fase por lo que no lo bloquea.

**Qué la desbloquea, y por qué es barato ahora.** El registro de desplazamiento con muestreo y
cambio en flancos opuestos ya está escrito dos veces —en `axioma_spi` y en la capa de bit de
`axioma_twi`—, y `axioma_gpio` ya tiene la anulación de dirección que `XCK` necesita. Lo que falta
es el modo síncrono sobre esas piezas y el filtro de `MPCM`, con su banco propio contra la hoja de
datos: simavr tampoco sirve aquí, por lo mismo que no sirvió para la asíncrona.

**Lo que NO se puede decir mientras siga abierta:** que la USART esté completa. El README y la
tabla de estado dicen «modo asíncrono», y tienen que seguir diciéndolo.

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
  Hoy **5 de los 25 vectores de interrupción** no tienen fuente, y la cuenta ya no se puede
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
una fase dirigida de anulación (909 886 comprobaciones) y `make sim-hello` **mide el ciclo de
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

## Cómo se usa este documento

1. Cuando algo se construye a medias **a propósito**, entra aquí en el mismo commit, con el motivo
   y con lo que lo desbloquea. No vale «ya lo pondré».
2. Antes de abrir un frente nuevo se revisa esta lista y se cierra lo que se pueda cerrar.
3. Lo que no se pueda, se justifica. Una deuda justificada y escrita es una decisión; una deuda
   olvidada es una sorpresa en la oblea.
