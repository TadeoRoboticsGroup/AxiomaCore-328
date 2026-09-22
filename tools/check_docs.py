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
from pathlib import Path

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
    return deudas_citadas()


# --------------------------------------------------------------------------
#  LAS DEUDAS QUE CITA EL CODIGO TIENEN QUE EXISTIR EN EL REGISTRO
#
#  POR QUE ESTA PUERTA. El 17-sep-2026 se cerro D13, cuya leccion era que una
#  deuda escrita SOLO en un comentario del RTL no la ve nadie: «lo peor de ella
#  es donde estaba escrita». Cuatro dias despues, un comentario de
#  axioma_eeprom.v decia «es la deuda D15, declarada en el registro» — y el
#  registro no la tenia. La leccion estaba escrita y se repitio igual.
#
#  Asi que ahora se comprueba. Un comentario que diga «deuda Dn» obliga a que
#  exista la fila `| Dn |` en docs/06-deuda-tecnica.md. Cuesta un segundo, y es
#  la diferencia entre una deuda declarada —que es una decision— y una deuda
#  olvidada, que es una sorpresa en la oblea.
#
#  Se busca la CITA y no el numero: `D0` y `D13` son tambien los nombres de dos
#  pines de Arduino en el top de la placa y en el generador de constraints, y
#  buscar `\bD[0-9]+\b` a secas los daria por deudas.
#
#  Y SE BUSCA EN LOS DOS SENTIDOS, porque el castellano admite los dos ordenes:
#  «la deuda D14» y «D1 de la deuda tecnica». La primera version de esta puerta
#  solo miraba el primero y se dejaba una cita de tb_gpio.cpp — una puerta con
#  un punto ciego da una respuesta tranquilizadora, que es peor que ninguna.
FUENTES = ("rtl", "sim", "fw", "sw")
EXT = (".v", ".vh", ".cpp", ".c", ".h", ".S", ".py")
CITA = re.compile(r"deuda[^\n]{0,30}?\bD(\d+)\b"
                  r"|\bD(\d+)\b[^\n]{0,30}?deuda", re.IGNORECASE)


def deudas_citadas():
    registro = Path("docs/06-deuda-tecnica.md")
    if not registro.exists():
        print(f"  {ROJO}falta docs/06-deuda-tecnica.md{FIN}")
        return 1
    texto = registro.read_text(encoding="utf-8")
    declaradas = set(re.findall(r"^\|\s*D(\d+)\s*\|", texto, re.M))

    citas = {}
    for raiz in FUENTES:
        for f in Path(raiz).rglob("*"):
            if f.suffix not in EXT or not f.is_file() or "legacy" in f.parts:
                continue
            try:
                src = f.read_text(encoding="utf-8", errors="ignore")
            except OSError:
                continue
            for n, linea in enumerate(src.splitlines(), 1):
                for par in CITA.findall(linea):
                    d = par[0] or par[1]
                    citas.setdefault(d, (str(f), n))

    huerfanas = {d: donde for d, donde in citas.items() if d not in declaradas}
    print(f"\n{NEGRITA}Las deudas que cita el codigo{FIN}")
    print(f"  {len(citas)} citadas en el RTL y los bancos, "
          f"{len(declaradas)} declaradas en el registro")
    if huerfanas:
        print(f"\n  {ROJO}{len(huerfanas)} citadas y SIN declarar:{FIN}")
        for d, (f, n) in sorted(huerfanas.items(), key=lambda x: int(x[0])):
            print(f"    D{d}  citada en {f}:{n}")
        print(f"\n  {GRIS}Una deuda que solo vive en un comentario no la ve nadie:")
        print(f"  es la leccion de D13. Declarala en docs/06-deuda-tecnica.md,")
        print(f"  con que la desbloquea, EN ESTE MISMO COMMIT.{FIN}")
        return 1
    print(f"  {VERDE}todas las citadas estan declaradas{FIN}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
