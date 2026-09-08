#!/usr/bin/env python3
"""
Contraste del modelo de referencia contra simavr — el tercer oráculo.

El modelo de sim/alu/alu_ref.py y el RTL de rtl/core/axioma_alu.v los escribió
la misma persona leyendo el mismo manual. Que coincidan demuestra que no hay
erratas de transcripción, pero no descarta un error conceptual cometido dos
veces.

simavr es una implementación independiente y de terceros del núcleo AVR. Si
nuestro modelo coincide con él ejecutando las instrucciones reales, la
interpretación del manual es correcta, no solo consistente consigo misma.

Comprueba dos cosas:
  1. Que ambos recorren la MISMA enumeración de entradas (si no, la comparación
     no significaría nada).
  2. Que el estado resultante coincide: registro destino, SREG completo y, donde
     aplica, el par de 16 bits.

El SREG esperado se calcula aplicando la máscara:
      sreg_final = (sreg_in & ~mask) | (sreg_out & mask)
lo que verifica de paso la semántica de la máscara, no solo los valores.

Uso:  python3 sim/alu/compare_simavr.py [dir-simavr] [dir-vectores]
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import alu_ref as R  # noqa: E402

REC = np.dtype([("a", "u1"), ("b", "u1"), ("sreg_in", "u1"), ("k6", "u1"),
                ("a16", "<u2"), ("result", "u1"), ("sreg_out", "u1"),
                ("wide", "<u2")])


def expected_inputs(name, n):
    """Reconstruye las entradas que DEBERÍA haber recorrido simavr, según la
    enumeración de alu_ref. Si no coinciden, los dos lados están mirando cosas
    distintas y la comparación sería vacía."""
    cls = R.CLASS_OF[name]
    i = np.arange(n, dtype=np.uint32)
    if cls == R.CLS_2OP:
        return dict(a=(i >> 8) & 0xFF, b=i & 0xFF, sreg_in=(i >> 16) & 0xFF,
                    k6=np.zeros(n, np.uint8), a16=np.zeros(n, np.uint16))
    if cls == R.CLS_1OP:
        return dict(a=i & 0xFF, b=np.zeros(n, np.uint8), sreg_in=(i >> 8) & 0xFF,
                    k6=np.zeros(n, np.uint8), a16=np.zeros(n, np.uint16))
    if cls == R.CLS_IW:
        return dict(a=np.zeros(n, np.uint8), b=np.zeros(n, np.uint8),
                    sreg_in=np.zeros(n, np.uint8), k6=(i >> 16) & 0xFF,
                    a16=(i & 0xFFFF).astype(np.uint16))
    return dict(a=(i >> 8) & 0xFF, b=i & 0xFF, sreg_in=np.zeros(n, np.uint8),
                k6=np.zeros(n, np.uint8), a16=np.zeros(n, np.uint16))


def main():
    sim_dir = sys.argv[1] if len(sys.argv) > 1 else "build/simavr_vec"
    print("  Contraste contra simavr — implementación independiente del núcleo AVR\n")
    print(f"  {'OP':<8} {'CASOS':>10}   RESULTADO")
    print(f"  {'--------':<8} {'----------':>10}   ---------")

    total = 0
    failed_ops = []
    for name in R.OPS:
        path = os.path.join(sim_dir, f"{name}.simavr")
        if not os.path.exists(path):
            print(f"  {name:<8} {'-':>10}   falta {path}")
            failed_ops.append(name)
            continue
        d = np.fromfile(path, dtype=REC)
        n = len(d)

        # 1. ¿recorren lo mismo?
        exp_in = expected_inputs(name, n)
        drift = [k for k in ("a", "b", "sreg_in", "k6", "a16")
                 if not np.array_equal(d[k].astype(np.uint32),
                                       exp_in[k].astype(np.uint32))]
        if drift:
            print(f"  {name:<8} {n:>10}   ENUMERACIONES DISTINTAS en {drift}")
            failed_ops.append(name)
            continue

        # 2. ¿coincide el estado resultante?
        ref = R.GEN_OF[R.CLASS_OF[name]](name)
        assert len(ref) == n, (name, len(ref), n)
        si = d["sreg_in"].astype(np.uint16)
        sm = ref["sm"].astype(np.uint16)
        so = ref["so"].astype(np.uint16)
        exp_sreg = ((si & (~sm & 0xFF)) | (so & sm)).astype(np.uint8)

        bad_r = d["result"] != ref["r"]
        bad_s = d["sreg_out"] != exp_sreg
        bad_w = d["wide"] != ref["w"]
        bad = bad_r | bad_s | bad_w
        nbad = int(bad.sum())
        total += n

        if nbad:
            failed_ops.append(name)
            print(f"  {name:<8} {n:>10}   FALLA ({nbad})")
            idx = np.flatnonzero(bad)[:3]
            for i in idx:
                print(f"      caso {i}: a={d['a'][i]:02X} b={d['b'][i]:02X} "
                      f"a16={d['a16'][i]:04X} k6={d['k6'][i]:02X} "
                      f"sreg_in={d['sreg_in'][i]:02X}")
                print(f"        simavr:   r={d['result'][i]:02X} "
                      f"sreg={d['sreg_out'][i]:02X} wide={d['wide'][i]:04X}")
                print(f"        nuestro:  r={ref['r'][i]:02X} "
                      f"sreg={exp_sreg[i]:02X} wide={ref['w'][i]:04X}")
        else:
            print(f"  {name:<8} {n:>10}   ok")

    print(f"\n  {total:,} instrucciones AVR contrastadas contra simavr")
    if failed_ops:
        print(f"  DISCREPANCIAS en: {', '.join(failed_ops)}")
        return 1
    print("  0 discrepancias — la interpretación del manual coincide con una")
    print("  implementación independiente del núcleo AVR")
    return 0


if __name__ == "__main__":
    sys.exit(main())
