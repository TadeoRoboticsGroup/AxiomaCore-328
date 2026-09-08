#!/usr/bin/env python3
"""
Genera el mapa de registros y la tabla de vectores de AxiomaCore-328 a partir
de `iom328p.h` de avr-libc (BSD-3-Clause).

Por qué generarlo en vez de escribirlo:
    El nivel L2 del contrato de compatibilidad exige que cada registro esté en
    su dirección exacta con sus bits exactos. Una tabla escrita a mano se
    desincroniza en el tercer commit y nadie se entera hasta que un sketch
    falla. Generándola desde la fuente autoritativa, L2 pasa de ser una
    aspiración a ser una propiedad verificada mecánicamente en cada push.

Salidas:
    rtl/soc/axioma_regmap.vh    constantes Verilog (direcciones y bits)
    docs/05-register-map.md     documentación

Uso:
    python3 tools/gen_regmap.py              genera
    python3 tools/gen_regmap.py --check      falla si lo generado difiere de
                                             lo que hay en el árbol (para CI)

Atribución: los nombres y direcciones proceden de avr-libc, BSD-3-Clause.
Ver LICENSE-EXCEPTIONS.md.
"""
import argparse
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VH_OUT = ROOT / "rtl/soc/axioma_regmap.vh"
MD_OUT = ROOT / "docs/05-register-map.md"

SFR_OFFSET = 0x20  # __SFR_OFFSET en AVR: I/O 0x00 == dato 0x20

# Los 26 vectores del ATmega328P, en orden. Sirve de comprobación cruzada
# frente a lo que declare la cabecera.
EXPECTED_VECTORS = 26


def find_header() -> Path:
    """Localiza iom328p.h preguntando a avr-gcc, o buscando en rutas típicas."""
    try:
        out = subprocess.run(
            ["avr-gcc", "-mmcu=atmega328p", "-E", "-Wp,-v", "-xc", "/dev/null"],
            capture_output=True, text=True, timeout=20,
        ).stderr
        for line in out.splitlines():
            line = line.strip()
            if line.startswith("/") and Path(line).is_dir():
                cand = Path(line) / "avr/iom328p.h"
                if cand.exists():
                    return cand
    except (FileNotFoundError, subprocess.SubprocessError):
        pass

    for pat in ("/usr/lib/avr/include/avr/iom328p.h",
                "/usr/avr/include/avr/iom328p.h",
                "/usr/local/avr/include/avr/iom328p.h"):
        p = Path(pat)
        if p.exists():
            return p
    for base in (Path.home() / "eda", Path("/opt"), Path("/usr")):
        if base.exists():
            for p in base.rglob("avr/iom328p.h"):
                return p
    sys.exit(
        "No se encontró iom328p.h.\n"
        "Instala el toolchain AVR:  sudo apt install gcc-avr avr-libc\n"
        "o extrae el de Arduino en ~/eda/avr-gcc."
    )


RE_SFR = re.compile(
    r'^\s*#\s*define\s+(\w+)\s+_SFR_(IO|MEM)(8|16)\s*\(\s*(0x[0-9A-Fa-f]+|\d+)\s*\)'
)
RE_BIT = re.compile(r'^\s*#\s*define\s+(\w+)\s+(\d+)\s*$')
RE_VECNUM = re.compile(r'^\s*#\s*define\s+(\w+)_vect_num\s+(\d+)')


def parse(path: Path):
    regs, bits, vectors = [], {}, []
    current = None
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        m = RE_SFR.match(raw)
        if m:
            name, space, width, addr = m.groups()
            a = int(addr, 0)
            data = a + SFR_OFFSET if space == "IO" else a
            io = a if space == "IO" else None
            regs.append({"name": name, "data": data, "io": io, "width": int(width)})
            current = name
            continue
        m = RE_VECNUM.match(raw)
        if m:
            vectors.append({"name": m.group(1), "num": int(m.group(2))})
            continue
        m = RE_BIT.match(raw)
        if m and current:
            bname, bnum = m.group(1), int(m.group(2))
            if 0 <= bnum <= 7 and not bname.endswith("_vect_num"):
                bits.setdefault(current, []).append((bname, bnum))

    regs.sort(key=lambda r: (r["data"], r["name"]))
    vectors.sort(key=lambda v: v["num"])
    return regs, bits, vectors


def emit_vh(regs, bits, vectors, src: Path) -> str:
    L = [
        "// AxiomaCore-328 - mapa de registros",
        "// FICHERO GENERADO. No editar a mano.",
        "//   Generador: tools/gen_regmap.py",
        f"//   Fuente:    {src}  (avr-libc, BSD-3-Clause)",
        "//",
        "// Direcciones del espacio de DATOS. Para IN/OUT, dir_io = dir_dato - 0x20.",
        "",
        "`ifndef AXIOMA_REGMAP_VH",
        "`define AXIOMA_REGMAP_VH",
        "",
        "// ---------------------------------------------------------- direcciones",
    ]
    for r in regs:
        if r["width"] == 16:
            continue  # los alias de 16 bits duplican el byte bajo
        io = f"  // I/O 0x{r['io']:02X}" if r["io"] is not None else ""
        L.append(f"localparam [7:0] ADDR_{r['name']:<10s} = 8'h{r['data']:02X};{io}")
    L += ["", "// ----------------------------------------------------------------- bits"]
    for reg in sorted(bits):
        if not any(r["name"] == reg for r in regs):
            continue
        for bname, bnum in sorted(bits[reg], key=lambda t: t[1]):
            L.append(f"localparam [2:0] BIT_{bname:<12s} = 3'd{bnum};")
    L += ["", "// ------------------------------------------------- vectores de interrupción",
          f"localparam integer NUM_VECTORS = {len(vectors)};"]
    for v in vectors:
        # Cada vector ocupa 2 palabras en una Flash de 32 KB.
        L.append(f"localparam [13:0] VEC_{v['name']:<14s} = 14'h{v['num'] * 2:04X};")
    L += ["", "`endif // AXIOMA_REGMAP_VH", ""]
    return "\n".join(L)


def emit_md(regs, bits, vectors, src: Path) -> str:
    L = [
        "# Mapa de registros",
        "",
        "> **Fichero generado.** No editar a mano.",
        "> Generador: `tools/gen_regmap.py` · Fuente: `iom328p.h` de avr-libc (BSD-3-Clause).",
        "> Regenerar con `make regmap`; la CI falla si este fichero diverge de la fuente.",
        "",
        "Direcciones del **espacio de datos**. Para `IN`/`OUT`, la dirección de I/O es",
        "`dirección de dato − 0x20`. `CBI`/`SBI`/`SBIC`/`SBIS` sólo alcanzan I/O `0x00–0x1F`.",
        "",
        "## Registros",
        "",
        "| Dato | I/O | Registro | Bits |",
        "|------|-----|----------|------|",
    ]
    for r in regs:
        if r["width"] == 16:
            continue
        io = f"`0x{r['io']:02X}`" if r["io"] is not None else "—"
        bl = bits.get(r["name"], [])
        bs = ", ".join(f"`{b}`={n}" for b, n in sorted(bl, key=lambda t: -t[1])) if bl else "—"
        L.append(f"| `0x{r['data']:02X}` | {io} | **{r['name']}** | {bs} |")

    L += ["", "## Vectores de interrupción", "",
          f"{len(vectors)} vectores. Direcciones **de palabra**; cada vector ocupa 2 palabras",
          "(un `JMP`) porque la Flash es de 32 KB. Prioridad = orden numérico.", "",
          "| Nº | Palabra | Vector |", "|----|---------|--------|"]
    L.append("| 0 | `0x0000` | RESET |")
    for v in vectors:
        L.append(f"| {v['num']} | `0x{v['num'] * 2:04X}` | {v['name']} |")
    L += ["", "---", "",
          "Los nombres y direcciones proceden de avr-libc, bajo licencia BSD-3-Clause.",
          "Ver [`../LICENSE-EXCEPTIONS.md`](../LICENSE-EXCEPTIONS.md).", ""]
    return "\n".join(L)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true",
                    help="no escribe: falla si lo generado difiere del árbol")
    args = ap.parse_args()

    hdr = find_header()
    regs, bits, vectors = parse(hdr)

    if not regs:
        sys.exit(f"no se extrajo ningún registro de {hdr}")
    # El vector 0 (RESET) no aparece como *_vect_num en la cabecera.
    total = len(vectors) + 1
    if total != EXPECTED_VECTORS:
        print(f"AVISO: se esperaban {EXPECTED_VECTORS} vectores y se hallaron {total}",
              file=sys.stderr)

    vh, md = emit_vh(regs, bits, vectors, hdr), emit_md(regs, bits, vectors, hdr)

    if args.check:
        bad = False
        for path, want in ((VH_OUT, vh), (MD_OUT, md)):
            if not path.exists():
                print(f"FALTA: {path.relative_to(ROOT)}", file=sys.stderr); bad = True
            elif path.read_text(encoding="utf-8") != want:
                print(f"DESACTUALIZADO: {path.relative_to(ROOT)} — ejecuta `make regmap`",
                      file=sys.stderr); bad = True
        if bad:
            sys.exit(1)
        print(f"mapa de registros al día: {len(regs)} registros, {total} vectores")
        return

    VH_OUT.parent.mkdir(parents=True, exist_ok=True)
    MD_OUT.parent.mkdir(parents=True, exist_ok=True)
    VH_OUT.write_text(vh, encoding="utf-8")
    MD_OUT.write_text(md, encoding="utf-8")
    print(f"fuente: {hdr}")
    print(f"  {VH_OUT.relative_to(ROOT)}  — {len(regs)} registros, {total} vectores")
    print(f"  {MD_OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
