#!/usr/bin/env python3
"""
Contraste del decodificador contra avr-objdump, sobre los 65 536 opcodes.

avr-objdump es de binutils: no comparte una línea de código ni de criterio con
nuestro RTL. Comprueba cuatro cosas, de más a menos crítica:

  1. is_32bit   La salida más delicada del decodificador. De ella depende que
                CPSE/SBRC/SBRS/SBIC/SBIS salten una o dos palabras, y que el
                secuenciador traiga la segunda palabra de LDS/STS/JMP/CALL.
                objdump da el tamaño real de cada instrucción: oráculo exacto.
  2. illegal    Codificaciones que no son instrucciones válidas.
  3. op_class   Clasificación, vía el mnemónico que emite objdump.
  4. rd / rr    Operandos de registro, donde se pueden parsear sin ambigüedad.

Uso:  python3 sim/decode/compare_decode.py build/decode
"""
import re
import sys
from collections import Counter
from pathlib import Path

import numpy as np

REC = np.dtype([("op_class", "u1"), ("alu_op", "u1"), ("rd", "u1"), ("rr", "u1"),
                ("flags", "u1"), ("imm", "u1"), ("ptr", "u1"), ("disp", "u1"),
                ("io_addr", "u1"), ("bit_num", "u1"), ("rel_addr", "<u2")])

F_RD_WE, F_RD_WE16, F_USE_IMM, F_IS32, F_ILLEGAL, F_COND_SET = 1, 2, 4, 8, 16, 32

# Clases, en el mismo orden que rtl/core/axioma_decode_ops.vh
CLASS = ["ILLEGAL", "NOP", "ALU_RR", "ALU_RI", "ALU_1", "IW", "MOVW", "MUL",
         "LD", "ST", "LDS", "STS", "PUSH", "POP", "LPM", "SPM", "IN", "OUT",
         "SBI", "CBI", "SBIC", "SBIS", "SBRC", "SBRS", "CPSE", "BLD", "BST",
         "BSET", "BCLR", "RJMP", "RCALL", "IJMP", "ICALL", "JMP", "CALL",
         "RET", "RETI", "BRANCH", "SLEEP", "WDR", "BREAK"]

# mnemónico de objdump -> clase esperada
MNEM2CLASS = {}
def _m(cls, *names):
    for n in names:
        MNEM2CLASS[n] = cls

_m("NOP",    "nop")
_m("ALU_RR", "add", "adc", "sub", "sbc", "and", "or", "eor", "mov", "cp", "cpc",
             "lsl", "rol", "tst", "clr")
_m("ALU_RI", "subi", "sbci", "andi", "ori", "cpi", "ldi", "ser")
_m("ALU_1",  "com", "neg", "swap", "inc", "dec", "asr", "lsr", "ror")
_m("IW",     "adiw", "sbiw")
_m("MOVW",   "movw")
_m("MUL",    "mul", "muls", "mulsu", "fmul", "fmuls", "fmulsu")
_m("LD",     "ld", "ldd")
_m("ST",     "st", "std")
_m("LDS",    "lds")
_m("STS",    "sts")
_m("PUSH",   "push")
_m("POP",    "pop")
_m("LPM",    "lpm")
_m("SPM",    "spm")
_m("IN",     "in")
_m("OUT",    "out")
_m("SBI",    "sbi")
_m("CBI",    "cbi")
_m("SBIC",   "sbic")
_m("SBIS",   "sbis")
_m("SBRC",   "sbrc")
_m("SBRS",   "sbrs")
_m("CPSE",   "cpse")
_m("BLD",    "bld")
_m("BST",    "bst")
_m("BSET",   "bset", "sec", "sez", "sen", "sev", "ses", "seh", "set", "sei")
_m("BCLR",   "bclr", "clc", "clz", "cln", "clv", "cls", "clh", "clt", "cli")
_m("RJMP",   "rjmp")
_m("RCALL",  "rcall")
_m("IJMP",   "ijmp")
_m("ICALL",  "icall")
_m("JMP",    "jmp")
_m("CALL",   "call")
_m("RET",    "ret")
_m("RETI",   "reti")
_m("BRANCH", "brbs", "brbc", "breq", "brne", "brcs", "brcc", "brsh", "brlo",
             "brmi", "brpl", "brge", "brlt", "brhs", "brhc", "brts", "brtc",
             "brvs", "brvc", "brie", "brid")
_m("SLEEP",  "sleep")
_m("WDR",    "wdr")
_m("BREAK",  "break")
_m("ILLEGAL", ".word")

# Instrucciones que objdump -m avr5 decodifica pero que NO existen en el
# ATmega328P. Nuestro decodificador las marca ilegales, y hace bien.
NOT_ON_328P = {"elpm", "eijmp", "eicall", "des", "lac", "las", "lat", "xch"}

REG = re.compile(r'\br(\d{1,2})\b')


def main():
    d = Path(sys.argv[1] if len(sys.argv) > 1 else "build/decode")
    o = np.load(d / "objdump.npz", allow_pickle=False)
    size, mnem, args = o["size"], o["mnem"], o["args"]
    rtl = np.fromfile(d / "rtl.bin", dtype=REC)
    assert len(rtl) == 65536, len(rtl)

    fails = Counter()
    examples = {}

    def note(kind, op, detail):
        fails[kind] += 1
        examples.setdefault(kind, []).append((op, detail))

    rtl_is32 = (rtl["flags"] & F_IS32) != 0
    rtl_ill = (rtl["flags"] & F_ILLEGAL) != 0
    od_is32 = size == 4
    od_ill = mnem == ".word"

    # ---- 1. is_32bit ----
    for op in np.flatnonzero(rtl_is32 != od_is32):
        note("is_32bit", int(op),
             f"objdump={'32' if od_is32[op] else '16'} bits ({mnem[op]}), "
             f"RTL={'32' if rtl_is32[op] else '16'}")

    # ---- 2 y 3. ilegal y clase ----
    for op in range(65536):
        m = str(mnem[op])
        cls_rtl = CLASS[rtl[op]["op_class"]] if rtl[op]["op_class"] < len(CLASS) else "?"
        if m in NOT_ON_328P:
            if cls_rtl != "ILLEGAL":
                note("no_en_328p", op, f"{m}: RTL lo acepta como {cls_rtl}")
            continue
        exp = MNEM2CLASS.get(m)
        if exp is None:
            note("mnemonico_desconocido", op, f"{m} {args[op]}")
            continue
        if exp != cls_rtl:
            note("clase", op, f"{m} {args[op]} -> objdump={exp}, RTL={cls_rtl}")

    # ---- 4. operandos de registro ----
    for op in range(65536):
        m = str(mnem[op])
        cls_rtl = CLASS[rtl[op]["op_class"]] if rtl[op]["op_class"] < len(CLASS) else "?"
        if cls_rtl in ("ILLEGAL", "NOP") or m in NOT_ON_328P:
            continue
        regs = [int(x) for x in REG.findall(str(args[op]))]
        if not regs:
            continue
        if cls_rtl in ("ALU_RR", "MUL", "CPSE", "MOVW"):
            if len(regs) >= 2 and (regs[0] != rtl[op]["rd"] or regs[1] != rtl[op]["rr"]):
                note("operandos", op,
                     f"{m} {args[op]} -> objdump rd={regs[0]} rr={regs[1]}, "
                     f"RTL rd={rtl[op]['rd']} rr={rtl[op]['rr']}")
        elif cls_rtl in ("ALU_RI", "ALU_1", "IW", "LD", "LDS", "POP", "IN",
                         "BLD", "BST", "LPM"):
            if regs[0] != rtl[op]["rd"]:
                note("operandos", op,
                     f"{m} {args[op]} -> objdump rd={regs[0]}, RTL rd={rtl[op]['rd']}")
        elif cls_rtl in ("ST", "STS", "PUSH", "OUT", "SBRC", "SBRS"):
            if regs[-1] != rtl[op]["rr"]:
                note("operandos", op,
                     f"{m} {args[op]} -> objdump rr={regs[-1]}, RTL rr={rtl[op]['rr']}")

    # ---- informe ----
    print("  Decodificador contra avr-objdump — 65 536 opcodes\n")
    checks = [("is_32bit", "tamaño de instrucción"),
              ("no_en_328p", "instrucciones ajenas al ATmega328P"),
              ("mnemonico_desconocido", "mnemónicos sin mapear"),
              ("clase", "clasificación"),
              ("operandos", "operandos de registro")]
    total = 0
    for key, label in checks:
        n = fails[key]
        total += n
        print(f"  {label:<38} {'ok' if n == 0 else f'FALLA ({n:,})'}")
        for op, det in examples.get(key, [])[:4]:
            print(f"      0x{op:04X}  {det}")
    print(f"\n  32 bits detectadas: {int(rtl_is32.sum())}  "
          f"(objdump: {int(od_is32.sum())})")
    print(f"  ilegales: RTL {int(rtl_ill.sum()):,}  objdump {int(od_ill.sum()):,}")
    if total:
        print(f"\n  {total:,} discrepancias")
        return 1
    print("\n  0 discrepancias")
    return 0


if __name__ == "__main__":
    sys.exit(main())
