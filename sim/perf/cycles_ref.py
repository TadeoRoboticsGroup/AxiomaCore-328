#!/usr/bin/env python3
"""
Tabla de ciclos del contrato L3, como fichero de datos.

Transcribe la tabla de `docs/01-arquitectura.md` §3 —que a su vez viene del
manual del ISA— y la proyecta sobre los 65 536 opcodes usando el mnemónico que
da **avr-objdump**. La identidad de cada opcode la fija binutils, no nuestro
decodificador: si el decodificador se equivocara al clasificar, la tabla de
ciclos NO heredaría el error.

Salida: `build/perf/cycles.bin`, que consume el arnés de co-simulación
diferencial (`sim/diff/diff.cpp`) para comprobar, instrucción a instrucción,
que el RTL tarda lo que dice el manual.

Tres clases de entrada:

    FIXED     el número de ciclos no depende de la ejecución
    BRANCH    1 si la rama NO se toma, 2 si se toma
    SKIP      1 sin salto, 2 saltando una palabra, 3 saltando dos
              (la trampa nº 1: depende del tamaño de la instrucción saltada)

Y una cuarta, UNCHECKED, para lo que no se puede afirmar todavía:

    spm       el manual no fija un número: depende del backend de progmem
    .word     codificaciones ilegales
    elpm, eicall, eijmp, des, xch, las, lac, lat
              las decodifica objdump -m avr5 pero NO existen en el ATmega328P

REGLA: todo mnemónico que aparezca en el desensamblado tiene que estar en la
tabla o en la lista de exclusiones EXPLÍCITA. Un mnemónico sin entrada es un
error, no un pase silencioso: si mañana binutils emite uno nuevo, este
generador falla en vez de dejar un hueco de cobertura.

Uso:  python3 sim/perf/cycles_ref.py build/decode/objdump.npz build/perf/cycles.bin
"""
import struct
import sys
from pathlib import Path

N = 65536

FIXED, BRANCH, SKIP, UNCHECKED = 0, 1, 2, 3

# --------------------------------------------------------------------------
# La tabla. Cada línea corresponde a una fila de docs/01-arquitectura.md §3.
# --------------------------------------------------------------------------
CYCLES = {}


def _c(n, *mnems):
    for m in mnems:
        CYCLES[m] = (n, FIXED)


# ALU registro / inmediato ................................................ 1
_c(1, "nop")
_c(1, "add", "adc", "sub", "sbc", "and", "or", "eor", "mov", "cp", "cpc")
_c(1, "subi", "sbci", "andi", "ori", "cpi", "ldi")
_c(1, "com", "neg", "swap", "inc", "dec", "asr", "lsr", "ror")

# MOVW ..................................................................... 1
_c(1, "movw")

# IN / OUT ................................................................. 1
_c(1, "in", "out")

# Bits del SREG y del registro ............................................. 1
_c(1, "bld", "bst")
_c(1, "sec", "sez", "sen", "sev", "ses", "seh", "set", "sei")
_c(1, "clc", "clz", "cln", "clv", "cls", "clh", "clt", "cli")

# Control del sistema ...................................................... 1
_c(1, "sleep", "wdr", "break")

# Multiplicaciones ......................................................... 2
_c(2, "mul", "muls", "mulsu", "fmul", "fmuls", "fmulsu")

# ADIW / SBIW .............................................................. 2
_c(2, "adiw", "sbiw")

# Memoria de datos ......................................................... 2
_c(2, "ld", "ldd", "st", "std")
_c(2, "lds", "sts")
_c(2, "push", "pop")

# Bits del espacio de I/O .................................................. 2
_c(2, "sbi", "cbi")

# Saltos ................................................................... 2/3/4
_c(2, "rjmp", "ijmp")
_c(3, "jmp")
_c(3, "rcall", "icall")
_c(4, "call")
_c(4, "ret", "reti")

# LPM ...................................................................... 3
_c(3, "lpm")

# Ramas condicionales ............................................. 1 no / 2 sí
for _m in ("brcc", "brcs", "breq", "brge", "brhc", "brhs", "brid", "brie",
           "brlt", "brmi", "brne", "brpl", "brtc", "brts", "brvc", "brvs"):
    CYCLES[_m] = (0, BRANCH)

# Saltos de instrucción .................................. 1 / 2 / 3 según tamaño
for _m in ("cpse", "sbrc", "sbrs", "sbic", "sbis"):
    CYCLES[_m] = (0, SKIP)

# --------------------------------------------------------------------------
# Exclusiones explícitas.
# --------------------------------------------------------------------------
UNCHECKED_MNEM = {
    # El manual del ISA no fija un número de ciclos para SPM: depende del
    # backend de memoria de programa. Ver docs/00-PLAN.md §5.5.
    "spm",
    # Codificaciones que no son instrucciones.
    ".word",
    # objdump -m avr5 las decodifica, pero NO existen en el ATmega328P; el
    # decodificador las rechaza y hace bien. Ver sim/decode/compare_decode.py.
    "elpm", "eicall", "eijmp", "des", "xch", "las", "lac", "lat",
}

KIND_NAME = {FIXED: "fija", BRANCH: "rama", SKIP: "salto", UNCHECKED: "sin comprobar"}


def main():
    if len(sys.argv) < 3:
        sys.exit("uso: cycles_ref.py <objdump.npz> <salida.bin>")
    import numpy as np

    npz, out = Path(sys.argv[1]), Path(sys.argv[2])
    mnem = np.load(npz, allow_pickle=False)["mnem"]
    assert len(mnem) == N, len(mnem)

    seen = sorted({str(x) for x in mnem})
    missing = [m for m in seen if m not in CYCLES and m not in UNCHECKED_MNEM]
    if missing:
        sys.exit("mnemónicos sin entrada en la tabla de ciclos: "
                 + ", ".join(missing)
                 + "\nAñádelos a CYCLES o a UNCHECKED_MNEM; un hueco silencioso no vale.")

    names = sorted(set(seen))
    idx = {m: i for i, m in enumerate(names)}

    base = bytearray(N)
    kind = bytearray(N)
    mid = bytearray(N)
    for op in range(N):
        m = str(mnem[op])
        b, k = CYCLES.get(m, (0, UNCHECKED))
        base[op], kind[op], mid[op] = b, k, idx[m]

    out.parent.mkdir(parents=True, exist_ok=True)
    with open(out, "wb") as f:
        f.write(b"AXCY1")
        f.write(struct.pack("<H", len(names)))
        for m in names:
            e = m.encode()
            f.write(struct.pack("<B", len(e)) + e)
        for op in range(N):
            f.write(bytes((base[op], kind[op], mid[op])))

    tally = {}
    for op in range(N):
        tally[kind[op]] = tally.get(kind[op], 0) + 1
    print("  Tabla de ciclos (contrato L3) proyectada sobre 65 536 opcodes")
    for k in (FIXED, BRANCH, SKIP, UNCHECKED):
        print(f"    {KIND_NAME[k]:<14} {tally.get(k, 0):6,} opcodes")
    print(f"    {len(CYCLES)} mnemónicos con ciclos, "
          f"{len(UNCHECKED_MNEM)} excluidos a propósito")
    print(f"  escrito {out}")


if __name__ == "__main__":
    main()
