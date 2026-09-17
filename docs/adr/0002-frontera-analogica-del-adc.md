# ADR 0002 — Dónde termina el RTL del ADC y empieza lo analógico

**Fecha:** 17 de septiembre de 2026 · **Estado:** aceptada

## Contexto

El ADC del ATmega328P es un **convertidor de aproximaciones sucesivas de 10 bits**. La hoja de
datos lo describe como un bloque con tres piezas: un multiplexor de entrada, un **comparador** con
su **DAC** de realimentación y un **registro de aproximaciones sucesivas** que va probando bits.
Las dos primeras son analógicas. La tercera es lógica digital y se sintetiza como cualquier otra.

Todo lo que este proyecto ha escrito hasta ahora es digital de punta a punta, y el oráculo de cada
periférico ha sido siempre *el otro extremo del cable*: un receptor de USART, un esclavo de SPI,
un bus de colector abierto. Con el ADC no hay cable que modelar — hay una **tensión**, que en
Verilog no existe.

Hay además un precedente que conviene no repetir. De `simavr` se ha escrito tres veces en este
repositorio que **no serializa**: su USART transporta bytes por IRQs internas, su SPI devuelve lo
que se le escribió, su TWI mueve direcciones enteras. Su ADC hace lo mismo y un poco peor:
`avr_adc.c` programa la interrupción a `prescale * 11` ciclos —la hoja de datos dice **13 ciclos de
reloj de ADC**, y **25** la primera conversión— y entrega el valor de golpe desde una IRQ en
milivoltios. **No hay ninguna aproximación sucesiva en ninguna parte.**

Si el RTL hiciera lo mismo, el `analogRead()` devolvería el número correcto y el módulo sería,
literalmente, un registro con un retardo. Compilaría, pasaría cualquier banco que mirase el
resultado, y no habría forma de distinguirlo de un ADC de verdad hasta la oblea.

## Opciones consideradas

| Opción | Efecto | Descartada porque |
|--------|--------|-------------------|
| El módulo recibe el valor ya convertido y lo publica tras N ciclos | Trivial de escribir; `analogRead()` funciona | **No es un ADC**: no hay SAR, no hay DAC y no hay nada que llevar a una foundry. Es el modelo de simavr con otro nombre |
| Modelar la tensión como un número real y comparar en Verilog | Se parece a lo analógico | `real` no se sintetiza. Lo que se verifica deja de ser lo que se fabrica, que es el error que este proyecto persigue desde la fase 1 |
| Escribir el comparador como lógica digital dentro del módulo | Todo en un sitio | Un comparador de tensiones **no es lógica**: en silicio es un par diferencial, y en la FPGA no existe. Meterlo dentro obliga a sacarlo después, justo en el paso más caro |
| **Cortar en el comparador: el RTL es el SAR, el DAC y el comparador son macro** | **Sintetizable entero, y el corte cae donde lo pone la hoja de datos** | — |

## Decisión

**El RTL implementa el registro de aproximaciones sucesivas y su secuenciador. El DAC y el
comparador quedan fuera, detrás de una interfaz de cuatro señales.**

```
        ┌──────────────── axioma_adc (digital, sintetizable) ─────────────┐
        │  prescaler · secuenciador de 13/25 ciclos · SAR de 10 bits      │
        │  ADMUX · ADCSRA · ADCSRB · ADCL/ADCH con su cerrojo · DIDR0     │
        └───┬──────────────┬─────────────────┬───────────────────┬────────┘
   adc_canal│   adc_ref    │   adc_muestrea  │   adc_dac[9:0]    │ adc_cmp
            ▼              ▼                 ▼                   ▲
        ┌──────────────── macro analógico (fuera del RTL) ────────────────┐
        │  multiplexor de entrada · referencia · S/H · DAC · comparador   │
        └─────────────────────────────────────────────────────────────────┘
```

| Señal | Sentido | Qué es |
|-------|---------|--------|
| `adc_canal[3:0]` | salida | `MUX3:0`: qué entrada mira el multiplexor. 0–7 son `ADC0..ADC7`; 8 el sensor de temperatura; 14 la referencia interna de 1,1 V; 15 masa |
| `adc_ref[1:0]` | salida | `REFS1:0`: qué referencia alimenta el DAC —`AREF`, `AVCC` o la interna de 1,1 V— |
| `adc_muestrea` | salida | pulso de un ciclo: el S/H **cierra y retiene**. Es el instante exacto en que la tensión queda congelada |
| `adc_dac[9:0]` | salida | el código que el SAR está probando |
| `adc_cmp` | entrada | 1 si la tensión retenida es **mayor o igual** que la del DAC |

### Por qué este corte y no otro

**Es el que dibuja la propia hoja de datos.** La figura 23-1 separa el «*Sample & Hold Comparator*»
y el «*10-bit DAC*» del resto, y el resto es exactamente lo que queda dentro.

**Hace que el banco pueda mentirle al RTL.** Con el comparador fuera, el banco escribe su modelo
desde la hoja de datos —`cmp = (v_retenida >= v_dac)`— y comprueba que el SAR **converge**, bit a
bit, en el orden correcto y en el número exacto de ciclos. Un ADC que devuelve el valor bueno por
casualidad y uno que aproxima de verdad dejan de ser indistinguibles: se ven las diez decisiones.

**Y hace que el módulo siga siendo el que se fabrica.** En el flujo ASIC, `adc_dac` y `adc_cmp` se
conectan al macro del PDK. En la FPGA no hay comparador, así que el **top de la placa** —no el
SoC— lleva un modelo digital del frente analógico: es honesto, porque una FPGA no convierte
tensiones, y deja el dispositivo idéntico en los dos destinos.

## Consecuencias

- **`axioma328_soc` gana cinco puertos** hacia el macro analógico, igual que ya exporta los pines.
  El SoC **no** contiene el modelo: lo contiene quien lo instancia.
- **El oráculo del ADC es el banco propio**, con un comparador escrito desde la hoja de datos. En
  la tabla `COMPARABLE[]` del diferencial entran `ADMUX`, `ADCSRA`, `ADCSRB` y `DIDR0`, que son
  almacenamiento en los dos lados; **quedan fuera `ADCL`, `ADCH` y `ADIF`**, porque la temporización
  de simavr es otra —`prescale * 11` frente a los 13 ciclos del manual— y compararlos sería
  comparar dos relojes distintos. Es el mismo reparto que con el Timer0.
- **La linealidad del convertidor no se verifica aquí, y no puede.** Con un DAC ideal el código de
  salida es exacto por construcción. El error de no linealidad, el *offset* y el ruido son del
  macro analógico y se miden con otras herramientas, en otra fase. Lo que este RTL promete es la
  **lógica** de la aproximación: el orden de los bits, el número de ciclos y el instante del
  muestreo.
- **El sensor de temperatura y la referencia de 1,1 V son entradas del multiplexor**, no casos
  especiales del RTL: para el SAR son un canal más. Su tensión la pone el macro.

## Cómo se comprueba que el corte está bien hecho

1. `make sim-adc` barre **los 1024 códigos** contra el modelo de comparador y exige que el SAR
   converja al código exacto, con las **diez** comparaciones en orden de peso.
2. El banco cuenta los **ciclos de reloj de ADC** de cada conversión: 13 las normales y **25 la
   primera tras `ADEN`**, que es la fila de la tabla 23-1 que casi nadie implementa.
3. El banco comprueba **cuándo** se cierra el S/H —1,5 ciclos en una conversión normal, 13,5 en la
   primera—, que es lo que hace que dos conversiones seguidas de una señal que cambia den valores
   distintos y correctos.
4. La mutación inyecta el ADC «de simavr»: un mutante que salta las aproximaciones y publica el
   valor de golpe. Si sobrevive, es que el banco mira el resultado y no el proceso.
