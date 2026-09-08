#!/usr/bin/env python3
"""
Modelo de referencia de la ALU de AxiomaCore-328.

Transcripción directa del *AVR Instruction Set Manual*. Es INDEPENDIENTE del
RTL: aquí no se mira a `rtl/core/axioma_alu.v`, se mira al manual. Ése es el
sentido de un oráculo.

Contiene dos implementaciones:

  alu_scalar()   Escalar, legible, una operación por vez. Es la especificación
                 ejecutable: si hay duda sobre qué debe hacer el hardware, la
                 respuesta está aquí.

  gen_*()        Vectorizadas con numpy, para poder generar los ~10,9 millones
                 de vectores del barrido exhaustivo en segundos.

Las dos se contrastan entre sí sobre una muestra aleatoria más todos los casos
borde antes de emitir nada. Si divergen, el generador aborta: una versión rápida
que no coincide con la especificación legible no sirve de oráculo.

Uso:
    python3 sim/alu/alu_ref.py --self-test
    python3 sim/alu/alu_ref.py --gen build/alu_vec
"""
import argparse
import os
import sys

# --------------------------------------------------------------- bits SREG
C, Z, N, V, S, H, T, I = 0, 1, 2, 3, 4, 5, 6, 7

M_NONE   = 0
M_SVNZ   = (1 << S) | (1 << V) | (1 << N) | (1 << Z)
M_SVNZC  = M_SVNZ | (1 << C)
M_HSVNZC = M_SVNZC | (1 << H)
M_ZC     = (1 << Z) | (1 << C)

# ------------------------------------------------- códigos de operación
# Deben coincidir con rtl/core/axioma_alu_ops.vh
OPS = {
    "ADD": 0,  "ADC": 1,  "SUB": 2,  "SBC": 3,  "AND": 4,  "OR": 5,
    "EOR": 6,  "COM": 7,  "NEG": 8,  "INC": 9,  "DEC": 10, "LSR": 11,
    "ROR": 12, "ASR": 13, "SWAP": 14, "MOV": 15, "ADIW": 16, "SBIW": 17,
    "MUL": 18, "MULS": 19, "MULSU": 20, "FMUL": 21, "FMULS": 22, "FMULSU": 23,
}

# Clase de operación: determina el espacio de entrada que se barre.
CLS_2OP = "2op"   # a x b x (C,Z)         -> 4 * 65536 = 262144
CLS_1OP = "1op"   # a x (C,Z)             ->        4 * 256 =   1024
CLS_IW  = "iw"    # a16 x k6              -> 64 * 65536 = 4194304
CLS_MUL = "mul"   # a x b                 ->             65536

CLASS_OF = {
    "ADD": CLS_2OP, "ADC": CLS_2OP, "SUB": CLS_2OP, "SBC": CLS_2OP,
    "AND": CLS_2OP, "OR": CLS_2OP, "EOR": CLS_2OP, "MOV": CLS_2OP,
    "COM": CLS_1OP, "NEG": CLS_1OP, "INC": CLS_1OP, "DEC": CLS_1OP,
    "LSR": CLS_1OP, "ROR": CLS_1OP, "ASR": CLS_1OP, "SWAP": CLS_1OP,
    "ADIW": CLS_IW, "SBIW": CLS_IW,
    "MUL": CLS_MUL, "MULS": CLS_MUL, "MULSU": CLS_MUL,
    "FMUL": CLS_MUL, "FMULS": CLS_MUL, "FMULSU": CLS_MUL,
}
COUNT_OF = {CLS_2OP: 4 * 256 * 256, CLS_1OP: 4 * 256,
            CLS_IW: 64 * 65536, CLS_MUL: 256 * 256}


def _s8(x):
    """Interpreta un byte como entero con signo."""
    return x - 256 if x & 0x80 else x


# ============================================================== ESCALAR
def alu_scalar(op, a=0, b=0, a16=0, k6=0, sreg_in=0):
    """Devuelve (result, result16, mul_result, sreg_out, sreg_mask).

    Las expresiones de los flags son las del manual del ISA, literales.
    `nb(x)` es la negación de un bit; en Python `~1` vale -2, no 0.
    """
    def bit(x, i):
        return (x >> i) & 1

    def nb(x):
        return x ^ 1

    c_in = bit(sreg_in, C)
    z_in = bit(sreg_in, Z)

    r = r16 = mul = 0
    h = n = z = v = c = 0
    mask = M_NONE

    if op in (OPS["ADD"], OPS["ADC"]):
        cin = c_in if op == OPS["ADC"] else 0
        r = (a + b + cin) & 0xFF
        Rd3, Rr3, R3 = bit(a, 3), bit(b, 3), bit(r, 3)
        Rd7, Rr7, R7 = bit(a, 7), bit(b, 7), bit(r, 7)
        h = (Rd3 & Rr3) | (Rr3 & nb(R3)) | (nb(R3) & Rd3)
        v = (Rd7 & Rr7 & nb(R7)) | (nb(Rd7) & nb(Rr7) & R7)
        c = (Rd7 & Rr7) | (Rr7 & nb(R7)) | (nb(R7) & Rd7)
        n, z = R7, int(r == 0)
        mask = M_HSVNZC

    elif op in (OPS["SUB"], OPS["SBC"]):
        bin_ = c_in if op == OPS["SBC"] else 0
        r = (a - b - bin_) & 0xFF
        Rd3, Rr3, R3 = bit(a, 3), bit(b, 3), bit(r, 3)
        Rd7, Rr7, R7 = bit(a, 7), bit(b, 7), bit(r, 7)
        h = (nb(Rd3) & Rr3) | (Rr3 & R3) | (R3 & nb(Rd3))
        v = (Rd7 & nb(Rr7) & nb(R7)) | (nb(Rd7) & Rr7 & R7)
        c = (nb(Rd7) & Rr7) | (Rr7 & R7) | (R7 & nb(Rd7))
        n = R7
        # SBC y CPC sólo LIMPIAN Z; nunca lo ponen. Permite encadenar
        # comparaciones multibyte.
        z = int(r == 0) & z_in if op == OPS["SBC"] else int(r == 0)
        mask = M_HSVNZC

    elif op in (OPS["AND"], OPS["OR"], OPS["EOR"]):
        r = {OPS["AND"]: a & b, OPS["OR"]: a | b, OPS["EOR"]: a ^ b}[op]
        v, n, z = 0, bit(r, 7), int(r == 0)
        mask = M_SVNZ

    elif op == OPS["COM"]:
        r = (0xFF - a) & 0xFF
        v, n, z, c = 0, bit(r, 7), int(r == 0), 1     # COM siempre pone C
        mask = M_SVNZC

    elif op == OPS["NEG"]:
        r = (0x00 - a) & 0xFF
        h = bit(r, 3) | nb(bit(a, 3))
        v = int(r == 0x80)
        n, z = bit(r, 7), int(r == 0)
        c = int(r != 0x00)
        mask = M_HSVNZC

    elif op == OPS["INC"]:
        r = (a + 1) & 0xFF
        v = int(r == 0x80)                            # desborda desde 0x7F
        n, z = bit(r, 7), int(r == 0)
        mask = M_SVNZ                                 # C y H intactos

    elif op == OPS["DEC"]:
        r = (a - 1) & 0xFF
        v = int(r == 0x7F)                            # desborda desde 0x80
        n, z = bit(r, 7), int(r == 0)
        mask = M_SVNZ                                 # C y H intactos

    elif op in (OPS["LSR"], OPS["ROR"], OPS["ASR"]):
        if op == OPS["LSR"]:
            r = a >> 1
        elif op == OPS["ROR"]:
            r = (c_in << 7) | (a >> 1)
        else:
            r = (a & 0x80) | (a >> 1)
        c = bit(a, 0)
        n = bit(r, 7)
        z = int(r == 0)
        v = n ^ c                                     # V se evalúa TRAS el desplazamiento
        mask = M_SVNZC

    elif op == OPS["SWAP"]:
        r = ((a & 0x0F) << 4) | (a >> 4)
        mask = M_NONE                                 # SWAP no toca flags

    elif op == OPS["MOV"]:
        r = b
        mask = M_NONE

    elif op in (OPS["ADIW"], OPS["SBIW"]):
        r16 = (a16 + k6) & 0xFFFF if op == OPS["ADIW"] else (a16 - k6) & 0xFFFF
        Rdh7, R15 = bit(a16, 15), bit(r16, 15)
        if op == OPS["ADIW"]:
            v = nb(Rdh7) & R15
            c = nb(R15) & Rdh7
        else:
            v = Rdh7 & nb(R15)
            c = R15 & nb(Rdh7)
        n, z = R15, int(r16 == 0)
        mask = M_SVNZC

    elif op in (OPS["MUL"], OPS["MULS"], OPS["MULSU"],
                OPS["FMUL"], OPS["FMULS"], OPS["FMULSU"]):
        av = _s8(a) if op in (OPS["MULS"], OPS["MULSU"],
                              OPS["FMULS"], OPS["FMULSU"]) else a
        bv = _s8(b) if op in (OPS["MULS"], OPS["FMULS"]) else b
        p = (av * bv) & 0xFFFF
        frac = op in (OPS["FMUL"], OPS["FMULS"], OPS["FMULSU"])
        mul = ((p << 1) & 0xFFFF) if frac else p
        c = bit(p, 15)                                # el bit que se desplaza fuera
        z = int(mul == 0)
        mask = M_ZC

    sreg_out = (c << C) | (z << Z) | (n << N) | (v << V) | ((n ^ v) << S) | (h << H)
    return r, r16, mul, sreg_out, mask


# ============================================================ VECTORIZADO
def _np():
    import numpy as np
    return np


def gen_2op(name):
    np = _np()
    op = OPS[name]
    cz = np.repeat(np.arange(4, dtype=np.uint8), 65536)
    a = np.tile(np.repeat(np.arange(256, dtype=np.uint16), 256), 4)
    b = np.tile(np.arange(256, dtype=np.uint16), 4 * 256)
    c_in = (cz & 1).astype(np.uint16)
    z_in = ((cz >> 1) & 1).astype(np.uint16)

    zero = np.zeros_like(a)
    if name in ("ADD", "ADC"):
        cin = c_in if name == "ADC" else zero
        r = (a + b + cin) & 0xFF
        Rd3, Rr3, R3 = (a >> 3) & 1, (b >> 3) & 1, (r >> 3) & 1
        Rd7, Rr7, R7 = (a >> 7) & 1, (b >> 7) & 1, (r >> 7) & 1
        h = (Rd3 & Rr3) | (Rr3 & (R3 ^ 1)) | ((R3 ^ 1) & Rd3)
        v = (Rd7 & Rr7 & (R7 ^ 1)) | ((Rd7 ^ 1) & (Rr7 ^ 1) & R7)
        c = (Rd7 & Rr7) | (Rr7 & (R7 ^ 1)) | ((R7 ^ 1) & Rd7)
        n, z = R7, (r == 0).astype(np.uint16)
        mask = M_HSVNZC
    elif name in ("SUB", "SBC"):
        bin_ = c_in if name == "SBC" else zero
        r = (a - b - bin_) & 0xFF
        Rd3, Rr3, R3 = (a >> 3) & 1, (b >> 3) & 1, (r >> 3) & 1
        Rd7, Rr7, R7 = (a >> 7) & 1, (b >> 7) & 1, (r >> 7) & 1
        h = ((Rd3 ^ 1) & Rr3) | (Rr3 & R3) | (R3 & (Rd3 ^ 1))
        v = (Rd7 & (Rr7 ^ 1) & (R7 ^ 1)) | ((Rd7 ^ 1) & Rr7 & R7)
        c = ((Rd7 ^ 1) & Rr7) | (Rr7 & R7) | (R7 & (Rd7 ^ 1))
        n = R7
        z = (r == 0).astype(np.uint16)
        if name == "SBC":
            z = z & z_in
        mask = M_HSVNZC
    elif name in ("AND", "OR", "EOR"):
        r = {"AND": a & b, "OR": a | b, "EOR": a ^ b}[name] & 0xFF
        h = zero; v = zero; n = (r >> 7) & 1; c = zero
        z = (r == 0).astype(np.uint16)
        mask = M_SVNZ
    elif name == "MOV":
        r = b & 0xFF
        h = v = n = z = c = zero
        mask = M_NONE
    else:
        raise ValueError(name)
    return _pack(r, zero, zero, h, n, z, v, c, mask)


def gen_1op(name):
    np = _np()
    cz = np.repeat(np.arange(4, dtype=np.uint16), 256)
    a = np.tile(np.arange(256, dtype=np.uint16), 4)
    c_in = cz & 1
    zero = np.zeros_like(a)
    h = v = n = z = c = zero

    if name == "COM":
        r = (0xFF - a) & 0xFF
        v = zero; n = (r >> 7) & 1; z = (r == 0).astype(np.uint16)
        c = np.ones_like(a); mask = M_SVNZC
    elif name == "NEG":
        r = (0 - a) & 0xFF
        h = ((r >> 3) & 1) | (((a >> 3) & 1) ^ 1)
        v = (r == 0x80).astype(np.uint16)
        n = (r >> 7) & 1; z = (r == 0).astype(np.uint16)
        c = (r != 0).astype(np.uint16); mask = M_HSVNZC
    elif name == "INC":
        r = (a + 1) & 0xFF
        v = (r == 0x80).astype(np.uint16)
        n = (r >> 7) & 1; z = (r == 0).astype(np.uint16); mask = M_SVNZ
    elif name == "DEC":
        r = (a - 1) & 0xFF
        v = (r == 0x7F).astype(np.uint16)
        n = (r >> 7) & 1; z = (r == 0).astype(np.uint16); mask = M_SVNZ
    elif name in ("LSR", "ROR", "ASR"):
        if name == "LSR":
            r = a >> 1
        elif name == "ROR":
            r = ((c_in << 7) | (a >> 1)) & 0xFF
        else:
            r = ((a & 0x80) | (a >> 1)) & 0xFF
        c = a & 1
        n = (r >> 7) & 1
        z = (r == 0).astype(np.uint16)
        v = n ^ c
        mask = M_SVNZC
    elif name == "SWAP":
        r = (((a & 0x0F) << 4) | (a >> 4)) & 0xFF
        mask = M_NONE
    else:
        raise ValueError(name)
    return _pack(r, zero, zero, h, n, z, v, c, mask)


def gen_iw(name):
    np = _np()
    k6 = np.repeat(np.arange(64, dtype=np.uint32), 65536)
    a16 = np.tile(np.arange(65536, dtype=np.uint32), 64)
    r16 = ((a16 + k6) if name == "ADIW" else (a16 - k6)) & 0xFFFF
    Rdh7 = (a16 >> 15) & 1
    R15 = (r16 >> 15) & 1
    if name == "ADIW":
        v = (Rdh7 ^ 1) & R15
        c = (R15 ^ 1) & Rdh7
    else:
        v = Rdh7 & (R15 ^ 1)
        c = R15 & (Rdh7 ^ 1)
    n = R15
    z = (r16 == 0).astype(np.uint32)
    zero = np.zeros_like(a16)
    return _pack(zero, r16, zero, zero, n, z, v, c, M_SVNZC)


def gen_mul(name):
    np = _np()
    a = np.repeat(np.arange(256, dtype=np.int64), 256)
    b = np.tile(np.arange(256, dtype=np.int64), 256)
    av = np.where(a >= 128, a - 256, a) if name in ("MULS", "MULSU", "FMULS", "FMULSU") else a
    bv = np.where(b >= 128, b - 256, b) if name in ("MULS", "FMULS") else b
    p = (av * bv) & 0xFFFF
    frac = name in ("FMUL", "FMULS", "FMULSU")
    mul = ((p << 1) & 0xFFFF) if frac else p
    c = (p >> 15) & 1
    z = (mul == 0).astype(np.int64)
    zero = np.zeros_like(a)
    return _pack(zero, zero, mul, zero, zero, z, zero, c, M_ZC)


def _pack(r, r16, mul, h, n, z, v, c, mask):
    """Empaqueta en el formato del banco de vectores: 5 bytes por vector."""
    np = _np()
    size = len(r)
    sreg = ((c.astype(np.uint16) << C) | (z.astype(np.uint16) << Z)
            | (n.astype(np.uint16) << N) | (v.astype(np.uint16) << V)
            | ((n.astype(np.uint16) ^ v.astype(np.uint16)) << S)
            | (h.astype(np.uint16) << H))
    wide = (r16 + mul).astype(np.uint16)   # sólo una de las dos es no nula
    out = np.zeros(size, dtype=[("r", "u1"), ("so", "u1"),
                                ("sm", "u1"), ("w", "<u2")])
    out["r"] = r.astype(np.uint8)
    out["so"] = sreg.astype(np.uint8)
    out["sm"] = np.uint8(mask)
    out["w"] = wide
    return out


GEN_OF = {CLS_2OP: gen_2op, CLS_1OP: gen_1op, CLS_IW: gen_iw, CLS_MUL: gen_mul}


# ------------------------------------------------------------- contraste
def inputs_at(name, i):
    """Entradas del vector i-ésimo. El orden de enumeración es contrato con
    el arnés de Verilator: cualquier cambio aquí hay que replicarlo en
    sim/alu/tb_alu.cpp."""
    cls = CLASS_OF[name]
    if cls == CLS_2OP:
        cz, rem = divmod(i, 65536)
        a, b = divmod(rem, 256)
        return dict(a=a, b=b, sreg_in=cz)
    if cls == CLS_1OP:
        cz, a = divmod(i, 256)
        return dict(a=a, sreg_in=cz)
    if cls == CLS_IW:
        k6, a16 = divmod(i, 65536)
        return dict(a16=a16, k6=k6)
    a, b = divmod(i, 256)
    return dict(a=a, b=b)


def cross_check(samples=20000, seed=20260908):
    """Contrasta el modelo vectorizado con el escalar. Incluye todos los casos
    borde conocidos, no sólo muestras al azar."""
    import random
    rnd = random.Random(seed)
    edges8 = [0x00, 0x01, 0x0F, 0x10, 0x7E, 0x7F, 0x80, 0x81, 0xFE, 0xFF]
    bad = 0
    for name in OPS:
        cls = CLASS_OF[name]
        total = COUNT_OF[cls]
        vec = GEN_OF[cls](name)
        idx = set()
        # casos borde
        if cls == CLS_2OP:
            for cz in range(4):
                for a in edges8:
                    for b in edges8:
                        idx.add(cz * 65536 + a * 256 + b)
        elif cls == CLS_1OP:
            for cz in range(4):
                for a in edges8:
                    idx.add(cz * 256 + a)
        elif cls == CLS_IW:
            for k6 in (0, 1, 32, 63):
                for a16 in (0, 1, 0x7FFF, 0x8000, 0x8001, 0xFFFE, 0xFFFF, 0x00FF, 0x0100):
                    idx.add(k6 * 65536 + a16)
        else:
            for a in edges8:
                for b in edges8:
                    idx.add(a * 256 + b)
        # muestreo aleatorio
        for _ in range(samples // len(OPS)):
            idx.add(rnd.randrange(total))

        for i in sorted(idx):
            kw = inputs_at(name, i)
            r, r16, mul, so, sm = alu_scalar(OPS[name], **kw)
            e = vec[i]
            wide = r16 if cls == CLS_IW else (mul if cls == CLS_MUL else 0)
            got_r = r if cls not in (CLS_IW, CLS_MUL) else 0
            if (int(e["r"]) != got_r or int(e["so"]) != so
                    or int(e["sm"]) != sm or int(e["w"]) != wide):
                bad += 1
                if bad <= 5:
                    print(f"  DIVERGE {name} i={i} {kw}", file=sys.stderr)
                    print(f"    escalar: r={got_r:#04x} sreg={so:#04x} "
                          f"mask={sm:#04x} w={wide:#06x}", file=sys.stderr)
                    print(f"    numpy:   r={int(e['r']):#04x} sreg={int(e['so']):#04x} "
                          f"mask={int(e['sm']):#04x} w={int(e['w']):#06x}", file=sys.stderr)
    return bad


def generate(outdir):
    np = _np()
    os.makedirs(outdir, exist_ok=True)
    spec = []
    total = 0
    for name, code in OPS.items():
        cls = CLASS_OF[name]
        vec = GEN_OF[cls](name)
        assert len(vec) == COUNT_OF[cls], (name, len(vec), COUNT_OF[cls])
        vec.tofile(os.path.join(outdir, f"{name}.bin"))
        spec.append(f"{name} {code} {cls} {len(vec)}")
        total += len(vec)
    with open(os.path.join(outdir, "spec.txt"), "w") as f:
        f.write("\n".join(spec) + "\n")
    return total


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--gen", metavar="DIR")
    args = ap.parse_args()

    if args.self_test or args.gen:
        print("contrastando modelo escalar contra vectorizado...")
        bad = cross_check()
        if bad:
            sys.exit(f"FALLO: {bad} divergencias entre los dos modelos de referencia")
        print("  los dos modelos de referencia coinciden")

    if args.gen:
        n = generate(args.gen)
        print(f"generados {n:,} vectores en {args.gen}")


if __name__ == "__main__":
    main()
