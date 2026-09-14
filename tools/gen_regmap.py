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


def collect_orden():
    """Devuelve [(fichero, nombre), ...] en el ORDEN en que se definen.

    Hace falta porque avr-libc NO nombra los bits con el prefijo de su
    registro —`TWINT` es de `TWCR`, `ADEN` de `ADCSRA`, `DDB0` de `DDRB`— y
    asociarlos por prefijo dejaba sin bits a la mayoría de los registros de
    control del chip: SPCR, ADCSRA, ADMUX, UCSR0A, TIMSK0, WDTCSR, SPMCSR,
    EECR, MCUCR, PRR y los tres DDRx. Lo que sí es autoritativo es la
    PROXIMIDAD: la cabecera define cada registro y a continuación sus bits.

    `-dD` conserva las directivas en su sitio, con los marcadores de línea
    que dicen de qué fichero viene cada una."""
    r = _cc(["-E", "-dD", "-xc", "-"], stdin_text="#include <avr/io.h>\n")
    if r.returncode != 0:
        sys.exit("avr-gcc falló al preprocesar <avr/io.h> con -dD:\n" + r.stderr)
    orden, fichero = [], ""
    for line in r.stdout.splitlines():
        if line.startswith("# ") and '"' in line:
            fichero = line.split('"')[1]
            continue
        m = RE_DEFINE.match(line)
        if m:
            orden.append((fichero, m.group(1)))
    return orden


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

    # ------------------------------------------------------------------ bits
    # POR PROXIMIDAD, NO POR PREFIJO. avr-libc no nombra los bits con el
    # prefijo de su registro: `TWINT` es de `TWCR`, `ADEN` de `ADCSRA`, `DDB0`
    # de `DDRB`, `OCR2BUB` de `ASSR`. Con la regla de prefijo se quedaban sin un
    # solo bit SPCR, ADCSRA, ADMUX, UCSR0A, TIMSK0, WDTCSR, SPMCSR, EECR, MCUCR,
    # PRR, TWCR, TWSR y los tres DDRx —casi todos los registros de control del
    # chip—, y la tabla no daba ningún aviso: salía un guion, que se lee igual
    # que «este registro no tiene bits con nombre». El nivel L2 promete las
    # direcciones Y LOS BITS, así que media promesa estaba sin verificar.
    #
    # Lo autoritativo es el orden de la cabecera: un registro y, pegado detrás,
    # su bloque de bits. EL BLOQUE SE CIERRA EN LA PRIMERA MACRO QUE NO SEA UN
    # BIT, y eso es lo que impide que las constantes del final del fichero
    # —`XRAMSIZE`, `E2PAGESIZE`, `FUSE_MEMORY_SIZE`— se cuelen como bits del
    # último registro declarado. Sin esa regla se colaban las cuatro, y lo
    # delataba la comprobación de duplicados de abajo.
    regset = {r["name"] for r in regs}
    bits = {}
    actual, fichero_actual = None, None
    for fichero, name in collect_orden():
        if fichero != fichero_actual:
            actual, fichero_actual = None, fichero
        if name in regset:
            actual = name                 # abre bloque
            continue
        if actual is None:
            continue
        body = macros.get(name)
        m = RE_INT_BODY.match(body) if body is not None else None
        val = int(m.group(1)) if m else None
        # Un identificador reservado —los que empiezan por `_`— nunca es el
        # nombre de un bit de la hoja de datos.
        elegible = (val is not None and 0 <= val <= 7
                    and not name.endswith("_vect_num")
                    and not name.startswith("_"))
        if elegible:
            bits.setdefault(actual, []).append((name, val))
        else:
            actual = None                 # cierra bloque

    # DOS NOMBRES PARA EL MISMO BIT DELATAN UNA ASIGNACIÓN MAL HECHA, así que
    # se comprueba. Los tres casos en que avr-libc lo hace de verdad van aquí
    # con su motivo; cualquier otro para la generación, porque significa que
    # la cabecera no está ordenada como se supone.
    ALIAS = {
        ("SPMCSR", 0): {"SELFPRGEN", "SPMEN"},   # el mismo bit, dos nombres
        ("UCSR0C", 1): {"UCSZ00", "UCPHA0"},     # asíncrono / SPI maestro
        ("UCSR0C", 2): {"UCSZ01", "UDORD0"},     # ídem
    }
    for reg, lista in sorted(bits.items()):
        porbit = {}
        for bname, bval in lista:
            porbit.setdefault(bval, set()).add(bname)
        for bval, nombres in sorted(porbit.items()):
            if len(nombres) > 1 and ALIAS.get((reg, bval)) != nombres:
                sys.exit(f"gen_regmap: {reg} bit {bval} tiene varios nombres "
                         f"({', '.join(sorted(nombres))}) y no está en la lista "
                         f"de alias conocidos. Revisa la asociación de bits.")

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
        "//   Fuente:    preprocesador de avr-gcc con avr-libc (BSD-3-Clause)",
        "//",
        "// Direcciones del espacio de DATOS. Para IN/OUT, dir_io = dir_dato - 0x20.",
        "//",
        "// SIN GUARDA DE INCLUSION, a proposito. Esta cabecera se incluye DENTRO del",
        "// cuerpo de cada modulo y declara `localparam`, que tienen ambito de modulo.",
        "// Con una guarda `ifndef, el segundo modulo que la incluyera en la misma",
        "// compilacion se quedaria sin constantes: el lint y la sintesis procesan",
        "// todos los ficheros en una sola invocacion. Cada modulo necesita su copia.",
        "// Las guardas son para ficheros de `define, que si son globales.",
        "// Mismo criterio que axioma_alu_ops.vh y axioma_decode_ops.vh.",
        "",
        "/* verilator lint_off UNUSEDPARAM */",
        "",
        "// ---------------------------------------------------------- direcciones",
    ]
    for r in regs:
        if r["width"] == 16:
            continue  # los alias de 16 bits duplican el byte bajo
        io = f"  // I/O 0x{r['io']:02X}" if r["io"] is not None else ""
        L.append(f"localparam [7:0] ADDR_{r['name']:<10s} = 8'h{r['data']:02X};{io}")
    L += ["", "// ----------------------------------------------------------------- bits"]
    # UN NOMBRE, UNA CONSTANTE. avr-libc repite algunos nombres de bit en dos
    # registros —`OCR2_0..OCR2_7` van detrás de OCR2A Y de OCR2B—, y un
    # `localparam` repetido es un error de declaración duplicada en cuanto
    # alguien incluya esta cabecera. Se emite una sola vez, y si el mismo
    # nombre trajera dos valores distintos se para: eso ya no es una
    # repetición, es una contradicción.
    emitidos = {}
    for reg in sorted(bits):
        if not any(r["name"] == reg for r in regs):
            continue
        for bname, bnum in sorted(bits[reg], key=lambda t: t[1]):
            if bname in emitidos:
                if emitidos[bname] != bnum:
                    sys.exit(f"gen_regmap: el bit {bname} vale {emitidos[bname]} "
                             f"en un registro y {bnum} en otro.")
                continue
            emitidos[bname] = bnum
            L.append(f"localparam [2:0] BIT_{bname:<12s} = 3'd{bnum};")
    L += ["", "// ------------------------------------------------- vectores de interrupción",
          f"localparam integer NUM_VECTORS = {len(vectors) + 1};  // incluye RESET"]
    # Cada vector ocupa 2 palabras en una Flash de 32 KB.
    L.append(f"localparam [13:0] VEC_{'RESET':<14s} = 14'h0000;")
    for v in vectors:
        L.append(f"localparam [13:0] VEC_{v['name']:<14s} = 14'h{v['num'] * 2:04X};")
    L += ["", "/* verilator lint_on UNUSEDPARAM */", ""]
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
    # Nota: la salida NO incrusta la versión del compilador. Si lo hiciera,
    # `--check` fallaría en cualquier máquina con otro avr-gcc aunque el mapa
    # fuese idéntico.

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
