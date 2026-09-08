#!/usr/bin/env python3
"""
Oráculo del decodificador: avr-objdump.

Genera un binario con los 65 536 opcodes posibles de 16 bits, cada uno seguido
de una palabra de relleno, y lo desensambla con `avr-objdump`. De la salida se
extrae, para cada opcode:

    tamaño     2 o 4 bytes  -> el oráculo de `is_32bit`, que es la salida más
                              delicada del decodificador (trampa nº 1: los
                              saltos CPSE/SBRC/SBRS/SBIC/SBIS saltan una o dos
                              palabras según el tamaño de la SIGUIENTE
                              instrucción)
    mnemónico  add, ldi, brne, .word (ilegal), ...
    operandos  registros e inmediatos, cuando se pueden parsear

avr-objdump viene de binutils y no tiene nada que ver con nuestro RTL ni con
nuestro modelo: es un tercero de verdad.

Uso:  python3 sim/decode/objdump_oracle.py <fichero-de-salida.npz>
"""
import re
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

N = 65536
PAD = 0x0000            # NOP como relleno tras cada opcode


def disassemble():
    with tempfile.TemporaryDirectory() as td:
        binp = Path(td) / "all.bin"
        with open(binp, "wb") as f:
            for op in range(N):
                f.write(struct.pack("<HH", op, PAD))
        r = subprocess.run(
            ["avr-objdump", "-D", "-b", "binary", "-m", "avr5", str(binp)],
            capture_output=True, text=True)
        if r.returncode != 0:
            sys.exit("avr-objdump falló:\n" + r.stderr)
        return r.stdout


# "   4:\t01 0f       \tadd\tr16, r17"
LINE = re.compile(r'^\s*([0-9a-f]+):\s*((?:[0-9a-f]{2} )+)\s*\t(.*)$')


def parse(text):
    """Devuelve {opcode: (size, mnemonic, operand_string)}."""
    out = {}
    for line in text.splitlines():
        m = LINE.match(line)
        if not m:
            continue
        addr = int(m.group(1), 16)
        nbytes = len(m.group(2).split())
        rest = m.group(3).strip()
        if addr % 4 != 0:          # las líneas en offset+2 son el relleno
            continue
        op = addr // 4
        if op >= N:
            continue
        parts = rest.split(None, 1)
        mnem = parts[0].strip()
        args = parts[1].split(';')[0].strip() if len(parts) > 1 else ""
        out[op] = (nbytes, mnem, args)
    return out


REG = re.compile(r'\br(\d{1,2})\b')


def main():
    if len(sys.argv) < 2:
        sys.exit("uso: objdump_oracle.py <salida.npz>")
    import numpy as np

    print("  desensamblando los 65 536 opcodes con avr-objdump...")
    table = parse(disassemble())
    missing = [i for i in range(N) if i not in table]
    if missing:
        print(f"  aviso: {len(missing)} opcodes sin línea de desensamblado "
              f"(primeros: {missing[:5]})")

    size = np.zeros(N, np.uint8)
    mnem = np.empty(N, dtype=object)
    args = np.empty(N, dtype=object)
    for i in range(N):
        s, m, a = table.get(i, (2, "?", ""))
        size[i] = s
        mnem[i] = m
        args[i] = a

    np.savez_compressed(sys.argv[1], size=size,
                        mnem=np.array(mnem, dtype="U12"),
                        args=np.array(args, dtype="U40"))

    from collections import Counter
    c = Counter(mnem)
    print(f"  {len(c)} mnemónicos distintos")
    print(f"  instrucciones de 32 bits: {int((size == 4).sum()):,}")
    print(f"  opcodes ilegales (.word): {c.get('.word', 0):,}")
    print(f"  guardado en {sys.argv[1]}")


if __name__ == "__main__":
    main()
