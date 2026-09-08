# Programas de ejemplo

Sketches de Arduino que sirven a la vez de **demostración** y de **suite de compatibilidad**. Cada
uno ejercita una parte concreta del contrato de compatibilidad definido en
[`../requerimiento.md`](../../requerimiento.md).

> **Estado:** estos sketches todavía no se pueden ejecutar. El paquete de placas para el Arduino
> IDE llega en la **fase 4** del [plan maestro](../../docs/00-PLAN.md). Hasta entonces sirven como
> especificación de lo que debe funcionar y como corpus para la
> [capa 5 de verificación](../../docs/03-verificacion.md).

---

## Sketches

### `basic_blink.ino`
LED parpadeante con salida por consola serie.

| Ejercita | Nivel |
|----------|-------|
| GPIO del puerto B, Timer0, `delay()`, `millis()` | L1 · L2 · L3 |
| USART a 115200 bps | L2 |

Es el primer hito de hardware del proyecto: cuando este sketch parpadea un LED en la FPGA, la
fase 2 está cerrada.

---

### `pwm_demo.ino`
Los 6 canales PWM simultáneos, con patrones de fundido, barrido y onda.

| Ejercita | Nivel |
|----------|-------|
| `analogWrite()` sobre Timer0, Timer1 y Timer2 | L2 · L3 |
| Modos Fast PWM y Phase-Correct | L2 |
| Prescaler compartido entre Timer0 y Timer1 | L3 |

**Montaje:** pines 3, 5, 6, 9, 10 y 11 → LED con resistencia de 220 Ω.

---

### `communication_test.ino`
Prueba conjunta de USART, SPI y TWI.

| Ejercita | Nivel |
|----------|-------|
| USART de 9600 a 115200 bps, generador de baudios | L2 · L3 |
| SPI maestro en bucle cerrado | L2 |
| Escaneo del bus I2C, arbitraje TWI | L2 |
| Operación simultánea de los tres protocolos | L1 · L2 |

**Montaje:** bucle SPI del pin 11 (MOSI) al 12 (MISO) con 1 kΩ. Pull-ups de 4,7 kΩ en A4 (SDA) y
A5 (SCL).

---

## Sketches pendientes de añadir

La suite de compatibilidad completa (fase 4) incorpora además:

| Sketch | Por qué está en la lista |
|--------|--------------------------|
| `Servo` | Timer1 de 16 bits y el registro TEMP — la trampa nº 4 |
| `SoftwareSerial` | Exactitud de ciclos en bucles cerrados |
| **`Adafruit_NeoPixel`** | **El caso más exigente: temporización a nivel de ciclo con interrupciones desactivadas.** Si NeoPixel funciona, el nivel L3 está cerrado. |
| `LiquidCrystal` | Temporización de GPIO |
| `SD` | SPI a alta velocidad con bloques grandes |
| `EEPROM` | Máquina de estados de `EECR` |
| `micros_drift` | Deriva de temporización a largo plazo |

---

## Cómo se usarán

Una vez disponible el paquete de placas:

1. Añadir la URL del índice JSON en *Preferencias → Gestor de tarjetas adicionales*.
2. Instalar **AxiomaCore-328** desde el Gestor de tarjetas.
3. Seleccionar *Herramientas → Placa → AxiomaCore-328*.
4. Compilar, subir y abrir el Monitor Serie a 115200 bps.

En la regresión automática estos mismos sketches se compilan con `avr-gcc` y se ejecutan tanto en
el RTL como en la FPGA, comparando la salida contra la referencia.

---

**Licencia:** Apache-2.0 · ver [`../LICENSE`](../../LICENSE)
