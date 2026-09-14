#!/usr/bin/env python3
"""
Comprueba que lo que la documentación dice sobre los vectores de interrupción
sea lo que el RTL hace.

POR QUÉ EXISTE. El 14-sep-2026 había TRES cifras distintas para la misma cosa
—cuántos de los 25 vectores no tienen todavía un periférico que los dispare—:
`docs/00-PLAN.md` decía 10 y listaba el Timer2 y el SPI, que llevaban dos días
dentro; `docs/06-deuda-tecnica.md` decía 7; y el fichero de contexto, 9. La
verdad, leída del RTL, era 6. Ninguna de las tres estaba mal cuando se escribió:
se quedaron atrás, que es peor, porque una cifra obsoleta se lee igual que una
cierta.

Es el mismo fallo que las rutas muertas que cerró `make check-docs` y que las
figuras del README que se quedaban atrás sin avisar. Y la respuesta es la misma
que en los dos casos: una puerta, no un repaso.

EL ORÁCULO ES `irq_src` DEL SoC. Esa concatenación es el cableado real de los 26
vectores: lo que va atado a una constante cero no tiene fuente, y lo que va a una
señal sí la tiene. No hay ninguna otra lista que mantener al día, que es
precisamente el punto.

Uso:
    python3 tools/check_vectores.py          comprueba
    python3 tools/check_vectores.py --lista  enseña la cuenta y se calla
"""
import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOC = ROOT / "rtl/soc/axioma328_soc.v"

# Dónde se buscan afirmaciones. El fichero de contexto NO entra: no se comitea
# y es un cuaderno de trabajo, no documentación publicada.
DOCS = sorted((ROOT / "docs").rglob("*.md")) + [ROOT / "README.md"]

# «N de los 25 vectores», «N de 25 vectores», con o sin negrita alrededor.
RE_SIN_FUENTE = re.compile(
    r"(\d+)\s+de\s+(?:los\s+)?25\s+vectores", re.IGNORECASE)
# «los 25 vectores ... hoy lo hacen N»
RE_CON_FUENTE = re.compile(r"hoy\s+lo\s+hacen\s+(\d+)", re.IGNORECASE)


def leer_irq_src():
    """Devuelve (con_fuente, sin_fuente) leyendo la concatenación del SoC."""
    txt = SOC.read_text()
    m = re.search(r"assign\s+irq_src\s*=\s*\{(.*?)\};", txt, re.S)
    if not m:
        sys.exit(f"check_vectores: no encuentro `assign irq_src` en {SOC}")

    # Cada elemento es `ancho'valor` (sin fuente) o un nombre de señal (con
    # fuente). Los comentarios de línea se quitan antes de partir por comas:
    # llevan números y nombres que confundirían el análisis.
    cuerpo = re.sub(r"//[^\n]*", "", m.group(1))
    con, sin = 0, 0
    for trozo in cuerpo.split(","):
        t = trozo.strip()
        if not t:
            continue
        lit = re.fullmatch(r"(\d+)'[bdh]?([0-9a-fA-FxXzZ_]+)", t)
        if lit:
            ancho = int(lit.group(1))
            # Un literal ocupa `ancho` vectores y ninguno tiene fuente.
            sin += ancho
        else:
            con += 1

    total = con + sin
    if total != 26:
        sys.exit(f"check_vectores: la concatenación suma {total} y no 26. "
                 f"Los anchos de `irq_src` SON el mapa de vectores: revísalos "
                 f"antes que esta comprobación.")
    # El vector 0 es RESET, que no es una interrupción y va atado a cero por
    # definición. No cuenta como «sin fuente»: nunca la va a tener.
    return con, sin - 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lista", action="store_true")
    args = ap.parse_args()

    con, sin = leer_irq_src()
    if args.lista:
        print(f"  vectores con fuente: {con} de 25 · sin fuente: {sin}")
        return 0

    fallos = []
    for doc in DOCS:
        if not doc.exists():
            continue
        for n, linea in enumerate(doc.read_text().splitlines(), 1):
            for mm in RE_SIN_FUENTE.finditer(linea):
                if int(mm.group(1)) != sin:
                    fallos.append((doc, n, mm.group(0),
                                   f"el RTL deja {sin} sin fuente"))
            for mm in RE_CON_FUENTE.finditer(linea):
                if int(mm.group(1)) != con:
                    fallos.append((doc, n, mm.group(0),
                                   f"el RTL dispara {con}"))

    if fallos:
        print("  la documentación no coincide con el cableado de `irq_src`:")
        for doc, n, dice, real in fallos:
            print(f"    {doc.relative_to(ROOT)}:{n}  dice «{dice}», y {real}")
        print("\n  El oráculo es rtl/soc/axioma328_soc.v. Actualiza el texto,")
        print("  no esta comprobación.")
        return 1

    print(f"  vectores: {con} de 25 con fuente, {sin} sin ella · "
          f"la documentación coincide")
    return 0


if __name__ == "__main__":
    sys.exit(main())
