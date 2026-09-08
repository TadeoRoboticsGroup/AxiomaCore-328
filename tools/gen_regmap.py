#!/usr/bin/env python3
"""
Genera el mapa de registros y la tabla de vectores de AxiomaCore-328
preguntándole al preprocesador de avr-gcc, con avr-libc (BSD-3-Clause).

Se usa el preprocesador y no un parseo del texto de `iom328p.h` porque:
  - SREG, SPL, SPH y SP no viven en iom328p.h sino en avr/common.h;
  - common.h define cada uno varias veces bajo #ifdef distintos, y sólo el
    preprocesador, con -mmcu=atmega328p, sabe cuál aplica.
Un parseo de texto se saltaba los tres y era la clase de error silencioso que
este generador existe para eliminar.

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


def _cc(args, stdin_text=None):
    return subprocess.run(["avr-gcc", "-mmcu=atmega328p"] + args,
                          input=stdin_text, capture_output=True, text=True, timeout=60)


def check_toolchain():
    try:
        r = subprocess.run(["avr-gcc", "--version"], capture_output=True, text=True, timeout=20)
    except (FileNotFoundError, subprocess.SubprocessError):
        sys.exit(
            "No se encuentra avr-gcc.\n"
            "  source env.sh                              (si ya está en ~/eda)\n"
            "  sudo apt install gcc-avr avr-libc          (instalación del sistema)\n"
            "Ver docs/04-herramientas.md."
        )
    return r.stdout.splitlines()[0] if r.stdout else "avr-gcc"


RE_DEFINE = re.compile(r'^#define\s+(\w+)\s+(.*)$')
RE_SFR_BODY = re.compile(r'_SFR_(IO|MEM)(8|16)\s*\(')
RE_INT_BODY = re.compile(r'^\(?\s*(\d+)\s*\)?$')
RE_VECNUM = re.compile(r'^(\w+)_vect_num$')


def collect_macros():
    """Vuelca todas las macros que avr-gcc define para el atmega328p."""
    r = _cc(["-E", "-dM", "-xc", "-"], stdin_text="#include <avr/io.h>\n")
    if r.returncode != 0:
        sys.exit("avr-gcc falló al preprocesar <avr/io.h>:\n" + r.stderr)
    out = {}
    for line in r.stdout.splitlines():
        m = RE_DEFINE.match(line)
        if m:
            out[m.group(1)] = m.group(2).strip()
    return out


def resolve_addresses(names):
    """Expande cada registro con _SFR_ASM_COMPAT=1, que reduce las macros a
    aritmética pura, y evalúa el resultado."""
    # El nombre va entre comillas: el preprocesador no expande macros dentro
    # de un literal de cadena. Sin eso, el propio marcador se expandía también.
    marks = "\n".join(f'@@ "{n}" @@ {n} @@' for n in names)
    src = "#include <avr/io.h>\n" + marks + "\n"
    r = _cc(["-D_SFR_ASM_COMPAT=1", "-E", "-P", "-xc", "-"], stdin_text=src)
    if r.returncode != 0:
        sys.exit("avr-gcc falló al expandir las direcciones:\n" + r.stderr)
    addrs = {}
    for m in re.finditer(r'@@\s*"(\w+)"\s*@@(.*?)@@', r.stdout, re.S):
        name, expr = m.group(1), m.group(2).strip()
        try:
            addrs[name] = int(eval(expr, {"__builtins__": {}}, {}))
        except Exception:
            pass                      # macro no reducible a un número: se ignora
    return addrs


def collect():
    macros = collect_macros()

    sfr_names, widths, spaces = [], {}, {}
    for name, body in macros.items():
        m = RE_SFR_BODY.search(body)
        if m:
            sfr_names.append(name)
            spaces[name] = m.group(1)
            widths[name] = int(m.group(2))

    addrs = resolve_addresses(sorted(sfr_names))

    regs = []
    for name in sorted(sfr_names):
        if name not in addrs:
            continue
        data = addrs[name]
        io = data - SFR_OFFSET if spaces[name] == "IO" else None
        if io is not None and not (0 <= io <= 0x3F):
            io = None
        regs.append({"name": name, "data": data, "io": io, "width": widths[name]})
    regs.sort(key=lambda r: (r["data"], r["name"]))

    # Bits: macros con cuerpo entero 0..7 cuyo nombre empieza por el de un registro.
    regnames = sorted((r["name"] for r in regs), key=len, reverse=True)
    bits = {}
    for name, body in macros.items():
        m = RE_INT_BODY.match(body)
        if not m:
            continue
        val = int(m.group(1))
        if not 0 <= val <= 7 or name.endswith("_vect_num"):
            continue
        for rn in regnames:
            if name.startswith(rn) and name != rn:
                bits.setdefault(rn, []).append((name, val))
                break

    vectors = []
    for name, body in macros.items():
        m = RE_VECNUM.match(name)
        if m and body.strip().isdigit():
            vectors.append({"name": m.group(1), "num": int(body.strip())})
    vectors.sort(key=lambda v: v["num"])

    return regs, bits, vectors


def emit_vh(regs, bits, vectors, src: Path) -> str:
    L = [
        "// AxiomaCore-328 - mapa de registros",
        "// FICHERO GENERADO. No editar a mano.",
        "//   Generador: tools/gen_regmap.py",
        f"//   Fuente:    preprocesador de {src} con avr-libc (BSD-3-Clause)",
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
          f"localparam integer NUM_VECTORS = {len(vectors) + 1};  // incluye RESET"]
    # Cada vector ocupa 2 palabras en una Flash de 32 KB.
    L.append(f"localparam [13:0] VEC_{'RESET':<14s} = 14'h0000;")
    for v in vectors:
        L.append(f"localparam [13:0] VEC_{v['name']:<14s} = 14'h{v['num'] * 2:04X};")
    L += ["", "`endif // AXIOMA_REGMAP_VH", ""]
    return "\n".join(L)


def emit_md(regs, bits, vectors, src: Path) -> str:
    L = [
        "# Mapa de registros",
        "",
        "> **Fichero generado.** No editar a mano.",
        "> Generador: `tools/gen_regmap.py` · Fuente: preprocesador de avr-gcc con avr-libc (BSD-3-Clause).",
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

    hdr = check_toolchain()
    regs, bits, vectors = collect()

    if not regs:
        sys.exit("no se extrajo ningún registro del preprocesador")
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
