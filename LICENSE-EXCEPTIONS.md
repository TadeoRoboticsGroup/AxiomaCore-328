# Inventario de componentes de terceros

El proyecto se distribuye bajo **Apache-2.0** (ver [`LICENSE`](LICENSE)). Este fichero registra
todo componente de terceros que se use, se distribuya o del que se dependa, junto con su licencia
y el modo de uso. **Toda contribución que introduzca un componente nuevo debe añadirlo aquí.**

## Componentes distribuidos con el proyecto

| Componente | Licencia | Uso | Estado |
|------------|----------|-----|--------|
| `iom328p.h` de avr-libc | BSD-3-Clause | Fuente para generar el mapa de registros (`tools/gen_regmap.py`). Se cita la atribución en el fichero generado. | Pendiente de integrar |

## Dependencias de herramientas (no se distribuyen)

Se usan como herramientas de construcción o verificación. No se enlazan ni se derivan en el
producto, por lo que no afectan a la licencia de éste.

| Herramienta | Licencia | Uso |
|-------------|----------|-----|
| avr-gcc | GPL-3.0 + GCC Runtime Library Exception | Compilador. La excepción de la biblioteca de tiempo de ejecución garantiza que el binario generado no queda afectado por la GPL. |
| avr-libc | BSD-3-Clause | Biblioteca C estándar para los programas de test. |
| **simavr** | **LGPL-2.1** | **Oráculo de referencia en la co-simulación diferencial. Se ejecuta como proceso separado; no se enlaza ni se deriva.** |
| Yosys, nextpnr, prjtrellis, icestorm, apicula | ISC / MIT | Síntesis y place & route. |
| Verilator | LGPL-3.0 / Artistic-2.0 | Simulación. El modelo generado se usa sólo en verificación, no se distribuye. |
| Icarus Verilog | GPL-2.0 | Simulación. |
| LibreLane, Magic, Netgen, KLayout | Apache-2.0 / diversas libres | Flujo RTL a GDSII. |
| Sky130A PDK | Apache-2.0 | Tecnología de proceso. |
| `sky130_sram_*` macros | Apache-2.0 | Macros de memoria para el flujo ASIC. |
| Arduino AVR Core | LGPL-2.1 | **Referenciado, no redistribuido.** `boards.txt` usa `build.core=arduino:arduino`, de modo que el IDE emplea el core ya instalado del usuario. |

## Componentes retirados

| Componente | Licencia | Motivo de la retirada |
|------------|----------|----------------------|
| `bootloader/optiboot/optiboot.c` | GPL-2.0 | Derivado de Optiboot (© Bill Westfield, © Peter Knight). Incompatible con la licencia declarada del proyecto y contrario al requisito de firmware propio. **Sustituido por una implementación propia del protocolo STK500v1 escrita desde la especificación pública.** |

## Reglas

1. Ningún fichero HDL entra en `rtl/` sin que su procedencia esté documentada aquí.
2. La documentación se escribe de cero. No se copia prosa de hojas de datos de terceros.
3. Las herramientas GPL/LGPL se usan como herramientas, nunca como componentes enlazados.
4. Ante la duda sobre la licencia de un componente: no se integra.
