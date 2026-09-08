<div align="center">

# AxiomaCore-328

**Microcontrolador de 8 bits libre y abierto, compatible a nivel binario con el ATmega328P.**
Diseñado íntegramente con herramientas libres, validado en FPGA y preparado para tape-out en un PDK abierto.

<img src="images/AxiomaCore.jpg" width="520"/>

[![Licencia](https://img.shields.io/badge/Licencia-Apache--2.0-blue)](LICENSE)
[![HDL](https://img.shields.io/badge/HDL-Verilog-ff6600)](#)
[![Síntesis](https://img.shields.io/badge/Síntesis-Yosys-yellowgreen)](#)
[![P%26R](https://img.shields.io/badge/P%26R-nextpnr-blueviolet)](#)
[![FPGA](https://img.shields.io/badge/FPGA-Lattice%20ECP5-6a1b9a)](#)
[![PDK](https://img.shields.io/badge/PDK-Sky130-7b1fa2)](#)
[![Estado](https://img.shields.io/badge/Estado-en%20reconstrucción-orange)](docs/00-PLAN.md)

</div>

---

## Estado actual

> **Este proyecto está en reconstrucción controlada.** El README anterior describía un diseño
> terminado y listo para producción. No lo estaba. Esta versión documenta el estado real, medido
> con herramientas, y el plan para llegar de verdad a donde el proyecto quiere llegar.

| Bloque | Estado real | Evidencia |
|--------|-------------|-----------|
| Decodificador de instrucciones | Borrador con ~108 mnemónicos cubiertos, sin verificar | 1259 líneas, decodificación combinacional |
| ALU | Borrador con un cerrojo inferido en `flag_s_out` | Confirmado por `yosys` |
| Banco de registros | Borrador, sin puerto real de 16 bits | — |
| Integración del SoC | **Rota** | `core/axioma_cpu/axioma_cpu.v:795` fija `io_data_in_cpu = 8'h00`: ningún `OUT`/`STS` puede escribir un periférico |
| Memoria de datos | **Ausente** | `axioma_sram_ctrl.v` existe pero no está instanciado |
| Timers 0/1/2, watchdog, comparador | **Ausentes de la jerarquía** | Sus señales están declaradas, nada las genera |
| Verificación | **Inexistente** | Los testbenches no comparan contra ningún oráculo |
| Síntesis Sky130 | **Nunca ejecutada** | El script no hace `dfflibmap` ni `abc -liberty`; el informe es de una jerarquía anterior |
| Layout / GDSII | **Inexistente** | `layout/axioma_minimal.gds` son 172 bytes con un rectángulo; el otro GDS pesa 0 bytes |

**Nada de esto es descartable.** El decodificador y los periféricos son un punto de partida real.
Lo que falta es la estructura que los convierte en un chip y la verificación que lo demuestra.

**➜ Lee el [plan maestro de reconstrucción](docs/00-PLAN.md) antes de tocar nada.**

---

## Qué es exactamente este proyecto

Un microcontrolador **compatible a nivel binario** con el ATmega328P: ejecuta el mismo código
máquina, expone el mismo mapa de registros y respeta la misma cuenta de ciclos. Un sketch
compilado para Arduino Uno corre sin recompilar.

No es, y no puede ser, una réplica eléctrica: el PDK abierto Sky130 no ofrece 5 V ni memoria Flash
embebida. Esa parte se resuelve en el módulo, no en el silicio.

### Contrato de compatibilidad

| Nivel | Qué garantiza | Objetivo |
|-------|---------------|----------|
| **L1 — Binaria** | 131 instrucciones, semántica exacta del SREG, PC de 14 bits, stack, interrupciones | Obligatorio |
| **L2 — Registros** | Mismas direcciones, nombres y bits. `avr/io.h` con `-mmcu=atmega328p` funciona sin tocar nada | Obligatorio |
| **L3 — Ciclos** | Misma cuenta de ciclos por instrucción y misma temporización de periféricos | Sí — lo necesitan `_delay_ms()`, `micros()`, NeoPixel |
| **L4 — Eléctrica** | 5 V, DIP-28, pinout idéntico | **No en el die.** Sí en el módulo, con level shifters |

---

## Especificación objetivo

| Componente | Especificación |
|------------|----------------|
| Núcleo | AVR de 8 bits, 131 instrucciones, pipeline de 2 etapas (Harvard) |
| Registros | 32 × 8 bits (R0–R31) + punteros X/Y/Z |
| Memoria de programa | 32 KB (16K × 16 bits) |
| SRAM | 2 KB · espacio de datos unificado `0x0000–0x08FF` |
| EEPROM | 1 KB |
| GPIO | 23 pines en 3 puertos (B/C/D), con toggle por escritura a `PINx` |
| Timers | Timer0 y Timer2 de 8 bits, Timer1 de 16 bits con registro TEMP |
| PWM | 6 canales |
| Comunicación | USART, SPI maestro/esclavo, TWI (I2C) |
| ADC | 10 bits, 8 canales (controlador SAR; comparador externo en la primera versión de silicio) |
| Interrupciones | 26 vectores con prioridad fija |
| Frecuencia | 8/16/20/25 MHz seleccionable · objetivo ≥ 32 MHz en ECP5 |

---

## Cadena de herramientas

100 % libre, de la especificación al GDSII. Sin una sola herramienta propietaria.

| Etapa | Herramienta |
|-------|-------------|
| Simulación RTL | Icarus Verilog · Verilator |
| Testbenches | cocotb (Python) |
| **Oráculo de referencia** | **simavr** |
| Compilación de tests | avr-gcc · avr-libc |
| Síntesis | Yosys |
| Place & route (FPGA) | nextpnr + prjtrellis / icestorm / apicula |
| Carga de bitstream | openFPGALoader |
| Verificación formal | SymbiYosys |
| RTL → GDSII | LibreLane 3.x + Sky130A (vía `ciel`) |
| DRC / LVS | Magic · Netgen · KLayout |

### Instalación

Casi todo llega en un único paquete:

```bash
mkdir -p ~/eda && cd ~/eda
curl -LO https://github.com/YosysHQ/oss-cad-suite-build/releases/download/2026-09-08/oss-cad-suite-linux-x64-20260908.tgz
tar xzf oss-cad-suite-linux-x64-20260908.tgz
echo 'source ~/eda/oss-cad-suite/environment' >> ~/.bashrc
```

El resto:

```bash
sudo apt install gcc-avr avr-libc avrdude simavr srecord
python3 -m venv ~/eda/venv && source ~/eda/venv/bin/activate
pip install cocotb cocotb-test pytest pyelftools intelhex
```

Detalles y alternativas sin `sudo` en [`docs/04-herramientas.md`](docs/04-herramientas.md).

---

## Plataforma de validación

| Placa | FPGA | Lógica | Memoria | Precio |
|-------|------|--------|---------|--------|
| **ULX3S 25F** *(recomendada)* | ECP5 LFE5U-25F | 24 k LUT4 | 1008 Kbit | ~120 USD |
| **Colorlight 5A-75B** *(mejor precio)* | ECP5 LFE5U-25F | 24 k LUT4 | 1008 Kbit | ~20 USD |
| Tang Nano 9K | Gowin GW1NR-9 | 8,6 k LUT4 | 468 Kbit | ~18 USD |
| iCEBreaker | iCE40 UP5K | 5,3 k LUT4 | 128 KB SPRAM | ~70 USD |

El SoC es el mismo para las tres familias; sólo cambian el top y los constraints en `rtl/fpga/`.

---

## Verificación

La regla del proyecto: **nada entra sin oráculo.**

1. **Diferencial contra `simavr`** — se ejecuta el mismo `.elf` en el RTL y en simavr, y se comparan
   PC, R0–R31, SREG y SP tras cada instrucción retirada. A la primera divergencia, el comparador
   señala la instrucción y vuelca las ondas.
2. **ALU exhaustiva** — 22 282 240 vectores contra un modelo de referencia transcrito del manual
   del ISA. Espacio de entrada barrido por completo, incluido el SREG de entrada.
3. **Tercer oráculo** — los mismos casos ejecutados sobre `simavr`, una implementación
   independiente del núcleo AVR. Que el modelo y el RTL coincidan descarta erratas, no un error
   conceptual cometido dos veces.
4. **Prueba de mutación** — 18 fallos deliberados inyectados en la ALU, 18 detectados. Un banco
   que no puede fallar no verifica nada.
5. **Exactitud de ciclos** — la tabla del manual del ISA codificada como test.
6. **Mapa de registros** — generado desde avr-libc; un test de CI falla si diverge.
7. **Sketches de Arduino reales**, NeoPixel incluido, que es el más exigente en temporización.
8. **Formal** (SymbiYosys) sobre propiedades acotadas.

La matriz de compatibilidad del README se **genera** a partir de los resultados. No se escribe a mano.

---

## Uso desde el IDE

Paquete de placas instalable desde el *Boards Manager* de Arduino IDE 2.x. No forkeamos el core de
Arduino: `boards.txt` lo referencia con `build.core=arduino:arduino`, de modo que se respeta la LGPL
sin redistribuir código de terceros y se mantiene la compatibilidad binaria total. También hay
soporte para PlatformIO y para compilación directa con `avr-gcc`.

El bootloader es **propio**, escrito desde cero contra la especificación pública del protocolo
STK500v1, de modo que `avrdude -c arduino` funciona sin modificaciones.

---

## Camino a silicio

| Vía | Proceso | Coste | Cuándo |
|-----|---------|-------|--------|
| Tiny Tapeout | Sky130 / IHP SG13G2 / GF180 | 100–500 USD | Primera prueba de silicio real; núcleo con memoria externa |
| **ChipFoundry chipIgnite** | Sky130 | 14 950 USD | Objetivo real: 100 piezas QFN, ~5 meses, área de usuario de 10,3 mm² |

Presupuesto de área estimado en Sky130: ~6–7 mm² con 32 KB de memoria de programa, ~3,5 mm² con
16 KB. Detalles en el [plan maestro](docs/00-PLAN.md).

---

## Documentación

| Documento | Contenido |
|-----------|-----------|
| [`docs/00-PLAN.md`](docs/00-PLAN.md) | **Plan maestro de reconstrucción.** Empieza aquí. |
| [`requerimiento.md`](requerimiento.md) | Requerimiento oficial del proyecto, v2.0 |
| [`docs/01-arquitectura.md`](docs/01-arquitectura.md) | Microarquitectura, mapa de memoria, vectores, tabla de ciclos |
| [`docs/02-legal.md`](docs/02-legal.md) | Política clean-room y análisis de licencias |
| [`docs/03-verificacion.md`](docs/03-verificacion.md) | Estrategia de verificación en seis capas |
| [`docs/04-herramientas.md`](docs/04-herramientas.md) | Instalación y uso de la cadena de herramientas |
| `docs/05-register-map.md` | Mapa de registros y vectores. **Generado** con `make regmap` |
| [`docs/requerimiento-v1-original.md`](docs/requerimiento-v1-original.md) | Requerimiento original, preservado sin cambios |
| [`legacy/README.md`](legacy/README.md) | Qué hay en el código heredado y por qué se conserva |

---

## Estructura del repositorio

```
rtl/      core · bus · mem (backends sim/fpga_bram/sky130_sram) · periph · soc · fpga
sim/      tb · cocotb · golden (diferencial vs simavr) · isa · perf
fw/       bootloader · selftest · examples
sw/       arduino · platformio · avrdude
asic/     librelane · macros · reports
board/    KiCad: módulo DIP-28
tools/    generadores: gen_regmap.py · gen_ulx3s_lpf.py
legacy/   proyecto anterior, congelado como referencia
```

Regla estructural: **cada fichero RTL existe una sola vez.** Las herramientas reciben listas de
ficheros, nunca copias del árbol de fuentes.

### Construcción

```bash
make help          # todos los objetivos
make check-tools   # verifica la cadena de herramientas
make regmap        # genera el mapa de registros desde iom328p.h
make lpf           # regenera las constraints de la ULX3S
make lint          # lint del RTL
```

Dos ficheros del proyecto se **generan** en vez de escribirse a mano, porque una transcripción
manual se desincroniza y nadie se entera hasta que algo falla:

| Generado | Desde | Garantiza |
|----------|-------|-----------|
| `rtl/soc/axioma_regmap.vh` y `docs/05-register-map.md` | `iom328p.h` de avr-libc | El nivel L2 de compatibilidad |
| `rtl/fpga/ecp5/axioma_ulx3s.lpf` | Constraints oficiales de la ULX3S | Que ningún pin esté mal transcrito |

La CI falla si cualquiera de los dos está desactualizado.

---

## Licencia

**Apache-2.0** para RTL, testbenches, scripts y firmware — elegida por su concesión explícita de
patentes, importante en hardware. El diseño físico y las PCB irán bajo **CERN-OHL-P v2**, y la
documentación bajo **CC-BY-4.0**. Ver [`LICENSE`](LICENSE), [`NOTICE`](NOTICE) y
[`LICENSE-EXCEPTIONS.md`](LICENSE-EXCEPTIONS.md).

Este es un proyecto **clean-room**: se implementa desde documentación pública del conjunto de
instrucciones. No contiene RTL, layouts ni texto de datasheet de terceros. Las reglas están en
[`docs/02-legal.md`](docs/02-legal.md) y son de obligado cumplimiento para cualquier contribución.

> AVR es una marca registrada de Microchip Technology Inc. Arduino es una marca registrada de
> Arduino SA. AxiomaCore-328 es una implementación independiente, sin relación ni respaldo de
> dichas compañías.

---

## Agradecimientos

SkyWater Technology y Google por el PDK Sky130 abierto · la FOSSi Foundation por LibreLane · el
equipo de YosysHQ por Yosys, nextpnr y la OSS CAD Suite · el proyecto OpenROAD · Icarus Verilog ·
Verilator · simavr · y la comunidad de hardware abierto que hizo que todo esto sea posible con un
portátil y sin licencias.
