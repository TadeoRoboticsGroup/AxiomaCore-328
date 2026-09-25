#!/usr/bin/env python3
"""Comprueba que `sw/arduino/boards.txt` es el que el IDE de Arduino espera.

No vale con que el fichero exista: al IDE le falta una clave y no enseña la
placa, o la enseña y falla al compilar con un mensaje que no dice cuál falta.
Aqui se comprueban las claves que el nucleo AVR usa de verdad, y ademas que
las cifras CUADREN CON EL RESTO DEL REPOSITORIO:

  - el tamaño maximo del sketch tiene que ser la Flash menos el gestor, y el
    tamaño del gestor lo dice el binario compilado, no una constante;
  - `f_cpu` tiene que ser el mismo reloj con el que se compila el firmware en
    el Makefile;
  - `upload.speed` tiene que ser el baudio con el que se compila el gestor.

Son tres numeros que viven en dos sitios cada uno, y esta comprobacion existe
porque tres copias de un numero son tres cifras que se desincronizan.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BOARDS = ROOT / "sw/arduino/boards.txt"
MAKEFILE = ROOT / "Makefile"
BOOT_BIN = ROOT / "build/fw/boot.bin"

OBLIGATORIAS = [
    "name", "upload.tool", "upload.protocol", "upload.maximum_size",
    "upload.maximum_data_size", "upload.speed",
    "build.mcu", "build.f_cpu", "build.board", "build.core", "build.variant",
]

FLASH_TOTAL = 32768


def main() -> int:
    if not BOARDS.exists():
        print(f"FALTA: {BOARDS.relative_to(ROOT)}", file=sys.stderr)
        return 1

    claves = {}
    for linea in BOARDS.read_text(encoding="utf-8").splitlines():
        linea = linea.strip()
        if not linea or linea.startswith("#"):
            continue
        if "=" not in linea:
            print(f"linea sin '=': {linea}", file=sys.stderr)
            return 1
        k, v = linea.split("=", 1)
        if not k.startswith("axioma328."):
            print(f"clave que no es de esta placa: {k}", file=sys.stderr)
            return 1
        claves[k[len("axioma328."):]] = v

    faltan = [k for k in OBLIGATORIAS if k not in claves]
    if faltan:
        print("faltan claves que el IDE necesita: " + ", ".join(faltan),
              file=sys.stderr)
        return 1

    malos = []

    # --- el tamaño del sketch, contra el gestor COMPILADO ---
    if BOOT_BIN.exists():
        boot = BOOT_BIN.stat().st_size
        # El gestor ocupa un numero entero de paginas de 128 bytes: el IDE
        # descuenta la seccion, no el binario.
        seccion = ((boot + 127) // 128) * 128
        esperado = FLASH_TOTAL - seccion
        if int(claves["upload.maximum_size"]) != esperado:
            malos.append(f"upload.maximum_size es {claves['upload.maximum_size']} "
                         f"y el gestor ocupa {boot} B -> {seccion} B de seccion, "
                         f"asi que deberia ser {esperado}")
    else:
        print("  (aviso: no hay build/fw/boot.bin; el tamaño no se contrasta)")

    # --- el reloj y el baudio, contra el Makefile ---
    mk = MAKEFILE.read_text(encoding="utf-8")
    m = re.search(r"BOOT_CC :=.*?-DF_CPU=(\d+)UL.*?-DBAUD=(\d+)", mk, re.S)
    if not m:
        malos.append("no se encontro BOOT_CC en el Makefile")
    else:
        f_cpu, baud = m.group(1), m.group(2)
        if claves["build.f_cpu"] != f_cpu + "L":
            malos.append(f"build.f_cpu es {claves['build.f_cpu']} y el gestor "
                         f"se compila con F_CPU={f_cpu}")
        if claves["upload.speed"] != baud:
            malos.append(f"upload.speed es {claves['upload.speed']} y el gestor "
                         f"se compila con BAUD={baud}")

    if malos:
        for x in malos:
            print("  " + x, file=sys.stderr)
        print("\n  Las cifras de boards.txt no son decorativas: el IDE compila\n"
              "  y sube con ellas.", file=sys.stderr)
        return 1

    print(f"  {len(claves)} claves, y las cifras cuadran con el gestor y el Makefile")
    return 0


if __name__ == "__main__":
    sys.exit(main())
