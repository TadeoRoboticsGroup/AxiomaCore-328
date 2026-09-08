# Código heredado — sólo referencia

Aquí está congelado el proyecto anterior a la reconstrucción de septiembre de 2026.

> **No se compila, no se sintetiza y no forma parte de la construcción.** Existe por dos motivos:
> servir de checklist mientras se reescribe el RTL, y no perder el trabajo que sí tiene valor.

## Qué hay de valor

| Ruta | Por qué se conserva |
|------|---------------------|
| `core/axioma_decoder/axioma_decoder.v` | Cubre ~108 mnemónicos AVR con decodificación combinacional limpia. Su tabla de opcodes es un buen punto de partida como checklist. |
| `core/axioma_alu/axioma_alu.v` | Los flags de ADIW y SBIW están bien resueltos. Ojo: `flag_s_out` genera un **cerrojo inferido** (confirmado por yosys); S es simplemente `N ⊕ V`. |
| `peripherals/axioma_uart.v`, `axioma_spi.v`, `axioma_i2c.v` | Máquinas de estado con estructura razonable. Sus mapas de registros no están verificados contra `iom328p.h`. |
| `peripherals/axioma_timers/` | Base de los timers. `timer1` **no** implementa el registro TEMP de 16 bits, que es obligatorio para el nivel L2. |
| `arduino_core/axioma/` | `boards.txt` y `pins_arduino.h` reutilizables tras corregir `build.core` y los nombres de placa que usan marcas de Arduino. |
| `tools/` | Ideas de caracterización y programación. |

## Qué NO se conserva y por qué

| Eliminado | Motivo |
|-----------|--------|
| `bootloader/optiboot/` | Derivado de Optiboot, **GPL-2.0**, incompatible con la licencia Apache-2.0 del proyecto. Se reescribe desde la especificación pública de STK500v1. |
| `layout/` | `axioma_minimal.gds` eran 172 bytes con un rectángulo de 100×100 µm y `axioma_cpu_layout.gds` pesaba 0 bytes. Los scripts que los fabricaban inducían a error. |
| `openlane/axioma_core_328/src/` | Copia byte a byte de `core/` y `peripherals/`. La duplicación garantiza deriva. |
| `*.tar.gz` | Backups binarios versionados en git. Purgados también del historial. |

## Problemas estructurales que motivaron la reconstrucción

1. `core/axioma_cpu/axioma_cpu.v:795` — `assign io_data_in_cpu = 8'h00;` deja el bus de escritura
   hacia periféricos atado a cero. Ningún `OUT` ni `STS` puede escribir un registro de periférico.
2. `axioma_sram_ctrl.v` existe pero **no está instanciado**: no hay memoria de datos.
3. Timers 0/1/2, watchdog y comparador analógico **no están en la jerarquía**, aunque sus señales
   estén declaradas y conectadas al controlador de interrupciones.
4. Las memorias son arrays conductuales de `reg`, sin abstracción de backend: 512 Kbit de
   biestables sólo para la Flash.
5. Ningún testbench compara contra un oráculo.

Análisis completo en [`../docs/00-PLAN.md`](../docs/00-PLAN.md), sección 4.
