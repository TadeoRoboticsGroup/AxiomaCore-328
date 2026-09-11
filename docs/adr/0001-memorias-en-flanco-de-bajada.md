# ADR 0001 — Memoria de datos en flanco de bajada

**Fecha:** 8 de septiembre de 2026 · **Estado:** aceptada

## Contexto

El AVR accede a la memoria de datos **dentro del mismo ciclo**: presenta la dirección y consume el
dato antes del siguiente flanco. Por eso `LD Rd, X` tarda 2 ciclos y `LDS Rd, k` —que es de 32
bits y necesita traer la segunda palabra— también tarda 2.

Una BRAM de FPGA, en cambio, tiene **lectura registrada**: la dirección se captura en un flanco y
el dato aparece en el siguiente. Con memorias en flanco de subida, la secuencia de `LDS` sería:

```
ciclo 0   se está trayendo la segunda palabra (la dirección de datos)
ciclo 1   llega la segunda palabra; recién ahora se puede presentar a la SRAM
ciclo 2   llega el dato de la SRAM
```

Tres ciclos donde el ATmega328P tarda dos. Eso **rompe el nivel L3** del contrato de
compatibilidad, del que dependen `_delay_ms()`, `micros()`, `SoftwareSerial`, `Servo` y cualquier
protocolo bit-bangeado como el de las tiras NeoPixel.

## Opciones consideradas

| Opción | Efecto | Descartada porque |
|--------|--------|-------------------|
| Aceptar +1 ciclo en accesos a datos | Simple | Rompe L3, que es un objetivo obligatorio del proyecto |
| Escribir la SRAM con LUTRAM de lectura asíncrona | Respeta L3 | 2 KB en LUTRAM consume una cantidad desproporcionada de recursos, y no tiene equivalente en el flujo ASIC |
| Reloj de memoria al doble de frecuencia | Respeta L3 | Añade un dominio de reloj y un PLL al camino crítico; complica el cierre de timing y la verificación |
| **Memorias en flanco de bajada** | **Respeta L3** | — |

## Decisión

**`axioma_dmem` se registra en el flanco de bajada.** La dirección se presenta en la primera mitad
del ciclo, la memoria la captura a mitad y el dato queda disponible en la segunda mitad, a tiempo
para que el núcleo lo consuma en el flanco de subida siguiente. El acceso cabe dentro del ciclo,
como en el AVR real.

**`axioma_progmem` se queda en flanco de subida.** No sufre el problema y ponerla en bajada sería
contraproducente: la búsqueda de instrucción va adelantada un ciclo —mientras se ejecuta la
instrucción de la dirección A ya se está trayendo la de A+1— de modo que un puerto registrado en
subida da una palabra de instrucción **estable durante todo el ciclo**. Con flanco de bajada
cambiaría a mitad de ciclo y habría que meter decodificación, lectura de registros, ALU y escritura
en media década de reloj. Su puerto de datos (LPM y SPM) tampoco lo necesita: LPM dura 3 ciclos.

## Consecuencias

**A favor**

- Se conservan las cuentas de ciclos del manual del ISA sin casos especiales.
- Un solo dominio de reloj. Nada de PLL ni de cruces de dominio.
- Se traslada limpio al flujo ASIC: los macros `sky130_sram` también admiten el flanco invertido.

**En contra**

- El camino de la **memoria de datos** dispone de media década de reloj, no de una entera. A 32 MHz
  son 15,6 ns frente a 31,2 ns. Una BRAM del ECP5 accede en unos 3–5 ns, así que hay margen
  sobrado, pero es un presupuesto que hay que vigilar al subir la frecuencia.
- El diseño tiene dos flancos activos. Es una complicación real y hay que declararla en las
  constraints; a cambio evita el PLL y el cruce de dominios de la alternativa del reloj doble.
- Las herramientas de análisis estático de tiempos deben ver ambos flancos. Las constraints tendrán
  que declararlo explícitamente.

**A verificar**

- ~~Cierre de timing real en ECP5 a la frecuencia objetivo (fase 5).~~ **HECHO, y la suposición de
  arriba estaba incompleta. Ver la adenda.**
- Que el dato leído llega antes del flanco de subida en simulación post-P&R con retardos anotados.

---

## Adenda — 11 de septiembre de 2026

**La decisión se mantiene. El razonamiento tenía un agujero.**

Arriba se dice que la media década «tiene margen sobrado» porque «una BRAM del ECP5 accede en unos
3–5 ns». Eso contabiliza el tiempo de acceso de la memoria, pero **no la lógica que le da de
comer**. Y en el diseño real esa lógica era casi todo el presupuesto.

Medido con `nextpnr` sobre la ULX3S, el camino crítico resultó ser:

```
memoria de programa (5,8 ns de clk a dato, más su árbol de multiplexores)
  -> decodificador -> banco de registros -> sumador del desplazamiento
  -> dirección de la memoria de datos (flanco de BAJADA)
```

**35,3 ns en media década**, con el 61 % en rutado. El diseño se quedaba en unos 15 MHz cuando el
objetivo de la fase 5 son 32.

**La causa no era la decisión, era la implementación.** El ADR supone que la dirección llega lista;
el secuenciador la calculaba de forma combinacional desde la palabra de instrucción, en el mismo
ciclo del acceso. Registrándola —se calcula en un ciclo y se presenta en el siguiente— la media
década vuelve a cubrir sólo lo que el documento suponía.

**Y no cuesta ciclos.** Toda instrucción que toca la SRAM dura dos ciclos o más, así que el acceso
cabe en el segundo: lo que antes se hacía en el ciclo 0 ahora se hace en el 1, y la cuenta del
manual no cambia. Verificado: las 10⁶ instrucciones aleatorias dan **exactamente los mismos ciclos**
que antes del cambio.

**Dos excepciones, y las dos son estructurales:**

- `IN`, `OUT`, `SBI`, `CBI`, `SBIC` y `SBIS` son de uno o dos ciclos y su dirección sale de la
  propia instrucción: no hay ciclo anterior donde registrarla. No hace falta: su camino es corto, y
  se le quitó además el sumador del desplazamiento de I/O, que no hacía falta.
- `LDS` y `STS` toman la dirección de la **segunda palabra** de la instrucción, que no llega hasta
  el ciclo 1. Registrarla pediría un tercer ciclo y eso rompería el nivel L3, que es justo lo que
  este ADR existe para proteger.

**Resultado medido:** de 15,55 a **20,28 MHz** con la misma restricción exigente, y el margen sobre
los 12,5 MHz a los que corre la placa pasa de 1,13× a 1,62×. El camino que manda ahora son 24,7 ns
con **sólo 4 ns de lógica y 14,6 de rutado**: ya no es profundidad lógica, es distancia. El
siguiente paso, cuando haga falta, es sacar el dato de escritura de la SRAM del camino
combinacional, lo que obliga a separar los buses de datos de SRAM y de I/O.
