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

- Cierre de timing real en ECP5 a la frecuencia objetivo (fase 5).
- Que el dato leído llega antes del flanco de subida en simulación post-P&R con retardos anotados.
