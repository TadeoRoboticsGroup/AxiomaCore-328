<div align="center">

# AxiomaCore-328

**Microcontrolador de 8 bits, libre y abierto, compatible a nivel binario con el ATmega328P.**

Diseñado íntegramente con herramientas libres, verificado contra oráculos independientes,
validado en FPGA y preparado para tape-out en un PDK abierto.

[![CI](https://github.com/TadeoRoboticsGroup/AxiomaCore-328/actions/workflows/ci.yml/badge.svg)](https://github.com/TadeoRoboticsGroup/AxiomaCore-328/actions/workflows/ci.yml)
[![Licencia](https://img.shields.io/badge/Licencia-Apache--2.0-blue)](LICENSE)
[![HDL](https://img.shields.io/badge/HDL-Verilog--2001-ff6600)](rtl/)
[![FPGA](https://img.shields.io/badge/FPGA-Lattice%20ECP5-6a1b9a)](rtl/fpga/ecp5/)
[![PDK](https://img.shields.io/badge/PDK-Sky130-7b1fa2)](docs/00-PLAN.md)
[![Fase](https://img.shields.io/badge/Fase%201-n%C3%BAcleo%20ISA-9a6700)](docs/00-PLAN.md)

</div>

---

## Arquitectura

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/arquitectura-dark.png">
  <img alt="Diagrama de bloques de AxiomaCore-328: núcleo, memorias, bus de datos y periféricos, con el estado de verificación de cada bloque" src="images/arquitectura-light.png">
</picture>

Un núcleo AVR de 8 bits con pipeline de dos etapas, un secuenciador multiciclo que congela la
etapa de búsqueda, y memorias tras una interfaz con backend intercambiable —simulación, BRAM de
FPGA o macros de SRAM en silicio— que es lo que evita que el port a ASIC sea una reescritura.

Los colores del diagrama no son decorativos: marcan qué está contrastado contra un oráculo
independiente y qué no. Ése es el criterio con el que se mide este proyecto.

---

## Estado actual

Todas las cifras de esta tabla se producen ejecutando `make`. Ninguna está escrita a mano.

| Bloque | Estado | Evidencia |
|--------|--------|-----------|
| `rtl/core/axioma_alu.v` | **Verificado** | 22 282 240 vectores sobre 24 operaciones, 0 fallos. Los mismos casos contrastados contra `simavr`: 0 discrepancias |
| `rtl/core/axioma_sreg.v` | **Verificado** | 200 029 comprobaciones contra un modelo sombra |
| `rtl/core/axioma_regfile.v` | **Verificado** | 800 064 comprobaciones en 200 000 ciclos aleatorios |
| `rtl/core/axioma_decode.v` | **Verificado** | Los 65 536 opcodes × 11 comprobaciones contra `avr-objdump`: 0 discrepancias |
| `rtl/mem/axioma_progmem.v` | **Verificado** | 34 049 comprobaciones, incluido el puerto de `LPM` |
| `rtl/mem/axioma_dmem.v` | **Verificado** | Barrido completo de las 2048 direcciones |
| `rtl/core/axioma_seq.v` | Verificado en parte | 7 programas dirigidos, 0 divergencias en estado, ciclos y espacio de datos. Falta la regresión aleatoria |
| `rtl/core/axioma_core.v` | Verificado en parte | Ídem. Es el módulo que une todo |
| Tabla de ciclos (nivel L3) | **Verificada** | 120 048 instrucciones con sus ciclos contrastados contra el manual, 0 desviaciones · **97 de 97 mnemónicos** |
| Bus de datos, periféricos, interrupciones | Pendientes | Fases 2 y 3 |
| Síntesis FPGA, GDSII | No ejecutadas | Fases 2 y 6 |

```
regresión   10/10 objetivos en verde
mutación    63/63 fallos inyectados, 63 detectados
```

**Estimación de avance:** fase 1 al ~90 %; hasta la v1.0 sobre FPGA, ~30 %; con silicio, ~18 %.

> Este README documenta el estado **medido**. Una versión anterior describía un diseño terminado
> y listo para producción que no existía. La regla desde entonces es simple: si no hay un comando
> que lo demuestre, no se afirma.

**➜ El plan completo está en [`docs/00-PLAN.md`](docs/00-PLAN.md).**

---

## Qué significa «compatible»

«Copia exacta» significa cosas distintas según a quién se pregunte. Aquí está fijado por escrito
en cuatro niveles, y sólo tres son alcanzables con herramientas libres.

| Nivel | Qué garantiza | ¿Objetivo? | Cómo se verifica |
|-------|---------------|-----------|------------------|
| **L1 — Binaria** | 131 instrucciones, semántica exacta del SREG, PC de 14 bits, pila, interrupciones | Obligatorio | Diferencial contra `simavr`, instrucción a instrucción |
| **L2 — Registros** | Mismas direcciones, nombres y bits. `avr/io.h` con `-mmcu=atmega328p` funciona sin tocar nada | Obligatorio | Mapa generado desde `iom328p.h` de avr-libc, con test de CI |
| **L3 — Ciclos** | Misma cuenta de ciclos por instrucción y misma temporización de periféricos | Sí | Tabla del manual del ISA como fichero de datos, comprobada en cada instrucción retirada |
| **L4 — Eléctrica** | 5 V, DIP-28, pinout idéntico | **No en el die.** Sí en el módulo | Sky130 no da 5 V; se resuelve con level shifters en la PCB |

De L3 dependen `_delay_ms()`, `micros()`, `SoftwareSerial`, `Servo` y cualquier protocolo
bit-bangeado como el de las tiras NeoPixel. Por eso se mide desde la fase 1 y no al final.

---

## Espacio de datos

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/espacio-datos-dark.png">
  <img alt="Mapa del espacio de datos unificado del AVR, de 0x0000 a 0x08FF, con las reglas de acceso de cada región" src="images/espacio-datos-light.png">
</picture>

El AVR es Harvard, pero su espacio de **datos** es uno solo y los registros forman parte de él.
Modelarlo de otro modo produce un núcleo que pasa los tests sintéticos y falla con código
compilado real.

---

## Verificación

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/verificacion-dark.png">
  <img alt="Esquema de la co-simulación diferencial contra simavr y resumen de los cuatro oráculos del proyecto" src="images/verificacion-light.png">
</picture>

### La regla

> **Nada entra sin oráculo. Y el oráculo también se comprueba.**

Un módulo que compila y sintetiza no cuenta como hecho. Cuenta cuando lo contrasta algo
independiente. Y como el modelo de referencia y el RTL los escribe la misma persona, hacen falta
terceros de verdad: `simavr` para la ALU y para el núcleo completo, `avr-objdump` de binutils para
el decodificador, el preprocesador de avr-gcc para el mapa de registros.

### No es teoría: fallos que sólo aparecieron así

| Fallo | Quién lo encontró | Por qué se escapaba |
|-------|-------------------|---------------------|
| Flag `H` de `NEG` implementado como `R3 \| ¬Rd3` en vez de `R3 \| Rd3` | Contraste contra `simavr` | El mismo error estaba en el RTL **y** en el modelo de referencia, así que se daban la razón mutuamente en las 1024 combinaciones |
| Desfase de un ciclo en la búsqueda: cada instrucción se ejecutaba dos veces | Co-simulación diferencial | Apareció en la segunda instrucción del primer programa |
| `RET` devolvía el byte bajo duplicado | Co-simulación diferencial | Consumía la lectura de memoria del ciclo equivocado |
| `MOVW` costaba 2 ciclos donde el manual dice 1 | Comprobación de ciclos | El **estado** quedaba correcto, así que la comparación de estado lo daba por bueno |
| Cinco fallos en los propios bancos de pruebas | Prueba de mutación | El arnés de memoria no distinguía flanco de subida de bajada; el comparador del decodificador no miraba `alu_op`, con lo que confundir `ADD` con `ADC` pasaba el test |
| El arnés no comparaba la memoria | Auditoría de cobertura | `ST`, `STS`, `PUSH`, `OUT`, `SBI` y `CBI` escriben sin leer: una escritura a la dirección equivocada sólo se notaba si el programa la releía |

El caso de `MOVW` es el que mejor explica por qué hay tantas capas: la causa no estaba en el
secuenciador sino en la **interfaz** del banco de registros, que direccionaba lectura y escritura
de 16 bits con el mismo índice de par. Copiar de un par a otro exigía dos ciclos. El documento de
arquitectura ya decía que debía costar uno; el que contradecía al documento era el RTL.

### Reproducirlo

```bash
source env.sh
make check-tools
make lint regmap-check lpf sim-alu sim-sreg sim-regfile sim-mem sim-simavr sim-decode sim-diff
```

Los diez objetivos deben pasar. Tarda menos de un minuto en un portátil.

La co-simulación diferencial recoge sola cualquier `.S` que aparezca en `sim/diff/tests/`. Hoy son
siete programas: tres de aritmética, control de flujo y memoria, y cuatro dirigidos que completan
el conjunto de instrucciones —bits y espacio de I/O, las 16 ramas condicionales, `LPM` en sus tres
formas, y el control del sistema—. Entre todos ejercitan **los 97 mnemónicos** que el ATmega328P
puede ejecutar. Tras cada instrucción se comparan PC, los 32 registros, SREG, SP y los ciclos; al
terminar, la SRAM entera byte a byte.

```bash
make mutation      # ~4 min · inyecta 63 fallos y comprueba que la regresión los caza
```

Además, `SPM` queda fuera de la suite a propósito: el manual no le fija un número de ciclos
—dependen del backend de memoria de programa— y su emulación en simavr no es comparable.

`make mutation` **modifica el RTL en sitio** mientras corre. Tiene cerrojo y manejadores de señal,
pero no debe ejecutarse en paralelo con nada más.

Para depurar el núcleo, el arnés señala la instrucción exacta donde diverge, con el estado de los
dos lados:

```bash
./build/vdiff/diff build/diff/flow.bin
```

Estrategia completa, en seis capas: [`docs/03-verificacion.md`](docs/03-verificacion.md).

---

## Plataforma de validación

<div align="center">
  <img src="images/ulx3s-v316-top.jpg" width="620" alt="Placa ULX3S con una FPGA Lattice ECP5, memoria SDRAM, HDMI, ranura microSD y conectores de expansión">
</div>

<div align="center">
  <sub>
    ULX3S · fotografía del repositorio <a href="https://github.com/emard/ulx3s">emard/ulx3s</a>,
    © 2016-2018 EMARD, bajo licencia tipo MIT. La unidad fotografiada monta un LFE5U-12F;
    la variante objetivo de este proyecto es la de <strong>25F</strong>, misma placa.
  </sub>
</div>

La **ULX3S 25F** es la plataforma primaria: ECP5 `LFE5U-25F`, 24 k LUT4 y 1008 Kbit de EBR, con
toolchain completamente libre (yosys + nextpnr-ecp5 + prjtrellis). Sobra memoria para los 32 KB de
programa, los 2 KB de SRAM y el 1 KB de EEPROM, y sobran pines para sacar los tres puertos.

| Placa | FPGA | Lógica | Memoria | Precio aprox. | Papel |
|-------|------|--------|---------|---------------|-------|
| **ULX3S 25F** | ECP5 LFE5U-25F | 24 k LUT4 | 1008 Kbit EBR + 32 MB SDRAM | ~120 USD | **Primaria.** Recursos de sobra y mucha E/S |
| Colorlight 5A-75B | ECP5 LFE5U-25F | 24 k LUT4 | 1008 Kbit + SDRAM | ~20 USD | Mejor relación precio/prestaciones; necesita placa adaptadora |
| Tang Nano 9K | Gowin GW1NR-9 | 8,6 k LUT4 | 468 Kbit BSRAM | ~18 USD | Secundaria. Toolchain abierta algo menos madura |
| iCEBreaker | iCE40 UP5K | 5,3 k LUT4 | 128 KB SPRAM | ~70 USD | Secundaria. La cadena más madura; ajustado en LUTs |

El SoC es el mismo para las tres familias: sólo cambian el top y las constraints bajo
`rtl/fpga/`. Las constraints de la ULX3S **se generan** desde el fichero oficial de la placa
(`make lpf`, 36 pines), de modo que ningún pin puede quedar mal transcrito.

**Objetivo de rendimiento:** cierre de timing a ≥ 32 MHz en ECP5, el doble de un ATmega328P real,
con F_CPU seleccionable (8/16/20/25/32 MHz) para correr binarios de Arduino sin recompilar.

---

## Cadena de herramientas

100 % libre, de la especificación al GDSII. Sin una sola herramienta propietaria.

| Etapa | Herramienta |
|-------|-------------|
| Simulación RTL | Verilator · Icarus Verilog |
| **Oráculo del núcleo** | **simavr** |
| **Oráculo del decodificador** | **avr-objdump** (binutils) |
| Compilación de los tests | avr-gcc · avr-libc |
| Síntesis | Yosys |
| Place & route | nextpnr + prjtrellis / icestorm / apicula |
| Carga del bitstream | openFPGALoader |
| Verificación formal | SymbiYosys |
| RTL → GDSII | LibreLane 3.x + Sky130A (vía `ciel`) |
| DRC / LVS | Magic · Netgen · KLayout |

### Instalación

Casi todo llega en un único paquete:

```bash
mkdir -p ~/eda && cd ~/eda
curl -LO https://github.com/YosysHQ/oss-cad-suite-build/releases/download/2026-09-08/oss-cad-suite-linux-x64-20260908.tgz
tar xzf oss-cad-suite-linux-x64-20260908.tgz
```

El resto —toolchain AVR, `simavr` y el entorno de Python— está en
[`INSTALL.md`](INSTALL.md), incluida la vía **sin `sudo`**. Después:

```bash
source env.sh
make check-tools
```

---

## Hoja de ruta

| Fase | Contenido | Estado |
|------|-----------|--------|
| 0 | Fundación: estructura, licencias, generador del mapa de registros, CI | **Hecha** |
| **1** | **Núcleo ISA: ALU, SREG, banco, decodificador, secuenciador, memorias, oráculos** | **En curso (~80 %)** |
| 2 | SoC mínimo: bus de datos, GPIO, Timer0, USART, IRQ. Primer bitstream | Pendiente |
| 3 | Periféricos completos: Timer1 con registro TEMP, SPI, TWI, ADC, EEPROM | Pendiente |
| 4 | Compatibilidad Arduino: bootloader STK500v1 propio, paquete para el IDE | Pendiente |
| 5 | Endurecimiento: cierre de timing, portes a iCE40 y Gowin, regresión nocturna | Pendiente |
| 6 | Silicio: backend Sky130, LibreLane, Tiny Tapeout y chipIgnite | Pendiente |
| 7 | Módulo DIP-28 en KiCad, compatible con el zócalo de un Arduino Uno | Pendiente |

Lo siguiente, en orden concreto: la **regresión aleatoria de 10⁶ instrucciones**, que es lo único
que le falta a la fase 1 para cumplir su criterio de aceptación, y el **controlador de
interrupciones**, sin el cual la máquina de estados de entrada a ISR que ya existe en el
secuenciador no se puede probar: `irq_req` está atado a 0 en el top de simulación.

Criterio de aceptación de la fase 1, sin ambigüedad: el conjunto de instrucciones pasando el
diferencial *(hecho)*, ALU exhaustiva en verde *(hecho)*, tabla de ciclos exacta *(hecho)* y
10⁶ instrucciones aleatorias sin divergencia *(pendiente)*.

---

## Estructura del repositorio

```
rtl/      core · bus · mem (backends sim/fpga_bram/sky130_sram) · periph · soc · fpga
sim/      alu · decode · mem · diff (co-simulación) · perf (tabla de ciclos) · isa
tools/    generadores: gen_regmap.py · gen_ulx3s_lpf.py · gen_diagrams.py
docs/     plan, arquitectura, verificación, legal, ADR
fw/       bootloader · selftest · examples
sw/       arduino · platformio · avrdude
asic/     librelane · macros · reports
board/    KiCad: módulo DIP-28
legacy/   proyecto anterior, congelado como referencia
```

**Regla estructural:** cada fichero RTL existe **una sola vez**. Las herramientas reciben listas de
ficheros, nunca copias del árbol de fuentes.

### Ficheros generados, nunca escritos a mano

Una transcripción manual se desincroniza y nadie se entera hasta que algo falla.

| Generado | Desde | Garantiza |
|----------|-------|-----------|
| `rtl/soc/axioma_regmap.vh` · `docs/05-register-map.md` | `iom328p.h` de avr-libc | El nivel L2 de compatibilidad |
| `rtl/fpga/ecp5/axioma_ulx3s.lpf` | Fichero de constraints oficial de la ULX3S | Que ningún pin esté mal transcrito |
| `build/perf/cycles.bin` | La tabla del manual, vía el mnemónico de `avr-objdump` | El nivel L3 de compatibilidad |
| `images/*.png` | `tools/gen_diagrams.py` | Que las figuras no se desincronicen del diseño |

La CI falla si los dos primeros están desactualizados.

---

## Documentación

| Documento | Contenido |
|-----------|-----------|
| [`docs/00-PLAN.md`](docs/00-PLAN.md) | **Plan maestro.** Decisiones, fases, presupuesto de área, riesgos. Empieza aquí |
| [`docs/01-arquitectura.md`](docs/01-arquitectura.md) | Microarquitectura, mapa de datos, vectores, tabla de ciclos, las doce trampas |
| [`docs/03-verificacion.md`](docs/03-verificacion.md) | Estrategia de verificación en seis capas |
| [`docs/02-legal.md`](docs/02-legal.md) | Política clean-room y análisis de licencias |
| [`docs/04-herramientas.md`](docs/04-herramientas.md) | Cadena de herramientas |
| [`docs/05-register-map.md`](docs/05-register-map.md) | Mapa de registros y vectores. **Generado** |
| [`docs/adr/`](docs/adr/) | Registros de decisiones de arquitectura |
| [`INSTALL.md`](INSTALL.md) | Instalación desde cero, con y sin `sudo` |
| [`requerimiento.md`](requerimiento.md) | Requerimiento oficial del proyecto |

---

## Licencia y marco legal

**Apache-2.0** para RTL, bancos de pruebas, scripts y firmware, elegida por su concesión explícita
de patentes, que en hardware importa. El diseño físico irá bajo **CERN-OHL-P v2** y la
documentación bajo **CC-BY-4.0**. Ver [`LICENSE`](LICENSE), [`NOTICE`](NOTICE) y el inventario de
terceros en [`LICENSE-EXCEPTIONS.md`](LICENSE-EXCEPTIONS.md).

Este es un proyecto **clean-room**: se implementa desde documentación pública del conjunto de
instrucciones. No contiene RTL, layouts ni prosa de hoja de datos de terceros. Los signature bytes
son propios y no se reutilizan los del ATmega328P: hacerlo volvería el dispositivo indistinguible
de una pieza genuina, que es exactamente el escenario de falsificación. Las reglas están en
[`docs/02-legal.md`](docs/02-legal.md) y son de obligado cumplimiento para cualquier contribución.

> AVR es una marca registrada de Microchip Technology Inc. Arduino es una marca registrada de
> Arduino SA. AxiomaCore-328 es una implementación independiente, sin relación ni respaldo de
> dichas compañías.

---

## Agradecimientos

SkyWater Technology y Google por el PDK Sky130 abierto · la FOSSi Foundation por LibreLane · el
equipo de YosysHQ por Yosys, nextpnr y la OSS CAD Suite · el proyecto OpenROAD · Verilator ·
Icarus Verilog · `simavr`, sin el cual este núcleo no tendría cómo demostrar que funciona ·
EMARD y RADIONA por la ULX3S · y la comunidad de hardware abierto, que hizo posible que todo esto
se haga con un portátil y sin una sola licencia de pago.
