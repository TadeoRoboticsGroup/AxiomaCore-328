#!/usr/bin/env python3
"""
Convierte el binario de avr-gcc en el fichero que `$readmemh` precarga en la
memoria de programa del bitstream.

POR QUÉ NO SE USA EL .hex DIRECTAMENTE. El formato Intel HEX que produce
`avr-objcopy -O ihex` lleva direcciones, longitudes y sumas de comprobación, y
va por BYTES. `$readmemh` de Verilog quiere otra cosa: una palabra por línea, en
hexadecimal, sin más. Y la memoria de programa del AVR es de 16 bits, con la
palabra en little-endian dentro del fichero. Traducir eso a mano es exactamente
la clase de cosa que sale mal en silencio.

Uso:  python3 tools/bin2mem.py programa.bin salida.mem [palabras]
"""
import sys
from pathlib import Path


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__.strip())
    origen, destino = Path(sys.argv[1]), Path(sys.argv[2])
    palabras = int(sys.argv[3]) if len(sys.argv) > 3 else 16384

    raw = origen.read_bytes()
    if len(raw) & 1:
        raw += b"\x00"
    n = len(raw) // 2
    if n > palabras:
        sys.exit(f"el programa ocupa {n} palabras y la memoria tiene {palabras}")

    # La memoria se inicializa entera: lo que no ocupa el programa queda a
    # 0x0000, que es NOP. La flash de un AVR de verdad se borra a 0xFFFF, pero
    # aquí el arranque nunca sale del programa y un NOP es más benigno que una
    # instrucción inventada si alguna vez lo hiciera.
    with destino.open("w") as f:
        for i in range(palabras):
            if i < n:
                f.write(f"{raw[2 * i] | (raw[2 * i + 1] << 8):04x}\n")
            else:
                f.write("0000\n")

    print(f"  {destino}: {n} palabras de programa de {palabras} "
          f"({100.0 * n / palabras:.1f} % de la Flash)")


if __name__ == "__main__":
    main()
