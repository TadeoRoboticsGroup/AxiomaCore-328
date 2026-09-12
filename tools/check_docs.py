#!/usr/bin/env python3
"""
Comprueba que las RUTAS DEL REPOSITORIO citadas en la documentación existan.

La CI ya valida los enlaces de Markdown. Esto es lo otro: los `path/como/este`
entre comillas invertidas dentro del texto, que son la mitad de las referencias
y que nadie comprobaba. Una ruta muerta ahí manda al lector a buscar un fichero
que no está, y eso es exactamente lo que pasaba: el plan y la arquitectura
citaban `sim/isa/regmap_check.py` como «test de CI», y ese fichero no existe —
la comprobación real es `tools/gen_regmap.py --check`.

QUÉ SE MIRA Y QUÉ NO. Sólo lo que PARECE una ruta del repositorio: lleva
barra y empieza por un directorio de primer nivel conocido. Con eso quedan
fuera, y es intencionado:

  - los nombres sueltos en prosa —`timer2.v`, `spi.v`— que son elementos de una
    lista de tareas, no rutas;
  - las cabeceras de terceros —`avr/io.h`, `iom328p.h`, `avr_timer.c`—;
  - las rutas relativas entre documentos, que ya valida el paso de enlaces.

Y hay una lista de excepciones para lo que se cita a propósito sin existir:
la estructura del repositorio ANTERIOR, que el plan describe para decir qué se
borró, y las rutas de fases futuras.

Uso:  python3 tools/check_docs.py
"""
import glob
import os
import re
import sys

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOPES = ("rtl/", "sim/", "tools/", "fw/", "docs/", "board/", "asic/", "sw/",
         "images/", "legacy/", ".github/")

# Rutas que se citan SIN existir y con motivo. Cada una con el suyo.
PERMITIDAS = {
    # El plan describe la estructura ANTERIOR para decir qué se borró.
    "core/axioma_alu/axioma_alu.v", "core/axioma_cpu/axioma_cpu.v",
    "core/axioma_decoder/axioma_decoder.v", "core/axioma_registers/axioma_registers.v",
    "peripherals/axioma_gpio.v", "peripherals/axioma_uart.v",
    "peripherals/axioma_adc.v", "bootloader/optiboot/optiboot.c",
    "openlane/.../config.json",
    # Fases futuras, citadas en su casilla del plan.
    "sw/platformio/boards/axioma328.json",
    # La deuda D9 cita las tres rutas muertas que arregló, para decir qué eran.
    "sim/isa/regmap_check.py", "docs/05-legal.md", "docs/02-isa.md",
}

VERDE, ROJO, GRIS, NEGRITA, FIN = ("\033[0;32m", "\033[0;31m", "\033[2m",
                                   "\033[1m", "\033[0m")


def main():
    os.chdir(RAIZ)
    docs = sorted(glob.glob("*.md") + glob.glob("docs/**/*.md", recursive=True))
    malas, miradas = [], 0

    for md in docs:
        for n, linea in enumerate(open(md, errors="ignore"), 1):
            for ruta in re.findall(r"`([A-Za-z0-9_./-]+)`", linea):
                if "/" not in ruta or not ruta.startswith(TOPES):
                    continue
                if ruta in PERMITIDAS:
                    continue
                miradas += 1
                # Una ruta con comodín se da por buena si existe su directorio.
                objetivo = ruta.split("*")[0] if "*" in ruta else ruta
                if not os.path.exists(objetivo) and \
                   not os.path.isdir(os.path.dirname(objetivo) or "."):
                    malas.append((md, n, ruta))
                elif "*" not in ruta and not os.path.exists(ruta):
                    malas.append((md, n, ruta))

    print(f"{NEGRITA}Rutas del repositorio citadas en la documentación{FIN}")
    print(f"  {miradas} referencias en {len(docs)} documentos")
    if malas:
        print(f"\n  {ROJO}{len(malas)} apuntan a algo que no existe{FIN}")
        for md, n, ruta in malas:
            print(f"    {md}:{n}  ->  {ruta}")
        print(f"\n  {GRIS}Si es a propósito —estructura antigua, fase futura—,")
        print(f"  añádela a PERMITIDAS en tools/check_docs.py con su motivo.{FIN}")
        return 1
    print(f"  {VERDE}todas existen{FIN}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
