#!/usr/bin/env python3
"""
Cobertura de la comprobación de ciclos (contrato L3).

«0 desviaciones» no dice nada sobre las instrucciones que ningún programa
ejecutó. Este script une los ficheros de cobertura que emite el arnés
diferencial y los contrasta con la tabla de `sim/perf/cycles_ref.py`, para que
lo que FALTA sea una lista y no una impresión.

Uso:  python3 sim/perf/cycle_coverage.py build/decode/objdump.npz build/diff/*.cov
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from cycles_ref import CYCLES, UNCHECKED_MNEM, BRANCH, SKIP   # noqa: E402


def main():
    if len(sys.argv) < 2:
        sys.exit("uso: cycle_coverage.py <objdump.npz> [cov...]")
    import numpy as np

    mnem = np.load(sys.argv[1], allow_pickle=False)["mnem"]
    # Sólo interesan los mnemónicos que el ATmega328P puede ejecutar de verdad.
    present = {str(x) for x in mnem} - UNCHECKED_MNEM
    total = sorted(m for m in present if m in CYCLES)

    seen = {}
    for f in sys.argv[2:]:
        pf = Path(f)
        if not pf.exists():
            continue
        for line in pf.read_text(encoding="utf-8").split("\n"):
            if not line.strip():
                continue
            m, _, n = line.rpartition(" ")
            seen[m] = seen.get(m, 0) + int(n)

    hit = [m for m in total if m in seen]
    miss = [m for m in total if m not in seen]

    print(f"  cobertura de ciclos: {len(hit)}/{len(total)} mnemónicos "
          f"con ciclos comprobados contra el manual")
    if miss:
        var = [m for m in miss if CYCLES[m][1] in (BRANCH, SKIP)]
        fix = [m for m in miss if CYCLES[m][1] not in (BRANCH, SKIP)]
        if fix:
            print(f"    sin ejecutar ({len(fix)}): " + " ".join(fix))
        if var:
            print(f"    sin ejecutar, de ciclos variables ({len(var)}): "
                  + " ".join(var))
        print("    Los cubre la suite dirigida: `make sim-diff`, los programas "
              "de sim/diff/tests/.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
