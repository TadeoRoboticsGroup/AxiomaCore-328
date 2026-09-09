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
  4. rd / rr    Operandos de registro.
  5. alu_op     Qué operación pide a la ALU.
  6. puntero    Selección X/Y/Z, modo (ninguno, post-inc, pre-dec, desplaza-
                miento) y valor del desplazamiento.
  7. io_addr    Dirección del espacio de I/O en IN, OUT, SBI, CBI, SBIC, SBIS.
  8. bit_num    Número de bit en las instrucciones de bit.
  9. imm        Inmediato en LDI, CPI, SUBI, SBCI, ORI, ANDI, ADIW, SBIW.
 10. rel_addr   Desplazamiento relativo de RJMP, RCALL y las ramas.

Las comprobaciones 5 a 10 se añadieron después de que la prueba de mutación
demostrara que sin ellas el banco NO detectaba tres fallos reales: confundir
ADD con ADC (misma clase, distinta operación de ALU), intercambiar los punteros
Y y Z en LDD, y perder los bits altos de la dirección de I/O en IN y OUT.

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
HEX = re.compile(r'0x([0-9a-fA-F]+)')
REL = re.compile(r'\.([+-]\d+)')
PTR = re.compile(r'(?<![\w])(-)?([XYZ])(\+)?(\d+)?(?![\w])')

# Códigos de rtl/core/axioma_alu_ops.vh
A = dict(ADD=0, ADC=1, SUB=2, SBC=3, AND=4, OR=5, EOR=6, COM=7, NEG=8, INC=9,
         DEC=10, LSR=11, ROR=12, ASR=13, SWAP=14, MOV=15, ADIW=16, SBIW=17,
         MUL=18, MULS=19, MULSU=20, FMUL=21, FMULS=22, FMULSU=23)

MNEM2ALU = {
    "add": A["ADD"], "lsl": A["ADD"], "adc": A["ADC"], "rol": A["ADC"],
    "sub": A["SUB"], "subi": A["SUB"], "cp": A["SUB"], "cpi": A["SUB"],
    "sbc": A["SBC"], "sbci": A["SBC"], "cpc": A["SBC"], "cpse": A["SUB"],
    "and": A["AND"], "andi": A["AND"], "tst": A["AND"],
    "or": A["OR"], "ori": A["OR"],
    "eor": A["EOR"], "clr": A["EOR"],
    "com": A["COM"], "neg": A["NEG"], "inc": A["INC"], "dec": A["DEC"],
    "lsr": A["LSR"], "ror": A["ROR"], "asr": A["ASR"], "swap": A["SWAP"],
    "mov": A["MOV"], "ldi": A["MOV"], "ser": A["MOV"],
    "adiw": A["ADIW"], "sbiw": A["SBIW"],
    "mul": A["MUL"], "muls": A["MULS"], "mulsu": A["MULSU"],
    "fmul": A["FMUL"], "fmuls": A["FMULS"], "fmulsu": A["FMULSU"],
}

PTR_SEL  = {"X": 0, "Y": 1, "Z": 2}
M_NONE, M_POSTINC, M_PREDEC, M_DISP = 0, 1, 2, 3

# Mnemónicos con inmediato de 8 bits, y su posición en la cadena de operandos.
IMM8 = {"ldi", "cpi", "subi", "sbci", "ori", "andi"}
IMM6 = {"adiw", "sbiw"}
IO_FIRST  = {"out", "sbi", "cbi", "sbic", "sbis"}   # la dirección va primero
IO_SECOND = {"in"}                                   # la dirección va segunda
BITNUM    = {"bld", "bst", "sbrc", "sbrs", "sbi", "cbi", "sbic", "sbis"}
RELATIVE  = {"rjmp", "rcall"}


def parse_ptr(a):
    """Devuelve (sel, modo, desplazamiento) del operando de puntero, o None."""
    m = PTR.search(a)
    if not m:
        return None
    pre, reg, plus, disp = m.groups()
    sel = PTR_SEL[reg]
    if pre:
        return (sel, M_PREDEC, 0)
    if plus and disp:
        return (sel, M_DISP, int(disp))
    if plus:
        return (sel, M_POSTINC, 0)
    return (sel, M_NONE, 0)


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

    # ---- 4 a 10. operandos completos ----
    for op in range(65536):
        m = str(mnem[op])
        a = str(args[op])
        r = rtl[op]
        cls_rtl = CLASS[r["op_class"]] if r["op_class"] < len(CLASS) else "?"
        if cls_rtl in ("ILLEGAL", "NOP") or m in NOT_ON_328P:
            continue
        regs = [int(x) for x in REG.findall(a)]
        hexes = [int(h, 16) for h in HEX.findall(a)]

        # --- registros ---
        if regs:
            if cls_rtl in ("ALU_RR", "MUL", "CPSE", "MOVW"):
                if len(regs) >= 2 and (regs[0] != r["rd"] or regs[1] != r["rr"]):
                    note("operandos", op, f"{m} {a} -> objdump rd={regs[0]} rr={regs[1]}, "
                                          f"RTL rd={r['rd']} rr={r['rr']}")
            elif cls_rtl in ("ALU_RI", "ALU_1", "IW", "LD", "LDS", "POP", "IN",
                             "BLD", "BST", "LPM"):
                if regs[0] != r["rd"]:
                    note("operandos", op, f"{m} {a} -> objdump rd={regs[0]}, RTL rd={r['rd']}")
            elif cls_rtl in ("ST", "STS", "PUSH", "OUT", "SBRC", "SBRS"):
                if regs[-1] != r["rr"]:
                    note("operandos", op, f"{m} {a} -> objdump rr={regs[-1]}, RTL rr={r['rr']}")

        # --- operación de ALU ---
        if m in MNEM2ALU and MNEM2ALU[m] != r["alu_op"]:
            note("alu_op", op, f"{m} {a} -> objdump {MNEM2ALU[m]}, RTL {r['alu_op']}")

        # --- puntero: selección, modo y desplazamiento ---
        if cls_rtl in ("LD", "ST"):
            pt = parse_ptr(a)
            if pt is None:
                note("puntero", op, f"{m} {a} -> objdump no da puntero")
            else:
                sel, mode, disp = pt
                g_sel, g_mode, g_disp = r["ptr"] & 3, (r["ptr"] >> 2) & 3, r["disp"]
                # Un desplazamiento de 0 y "sin modo" son la misma cosa.
                if g_mode == M_DISP and g_disp == 0:
                    g_mode = M_NONE
                if mode == M_DISP and disp == 0:
                    mode = M_NONE
                if (sel, mode) != (g_sel, g_mode) or (mode == M_DISP and disp != g_disp):
                    note("puntero", op,
                         f"{m} {a} -> objdump sel={sel} modo={mode} q={disp}, "
                         f"RTL sel={g_sel} modo={g_mode} q={g_disp}")

        # --- dirección de I/O ---
        if m in IO_FIRST and hexes and hexes[0] != r["io_addr"]:
            note("io_addr", op, f"{m} {a} -> objdump 0x{hexes[0]:02X}, RTL 0x{r['io_addr']:02X}")
        if m in IO_SECOND and len(hexes) >= 1 and hexes[-1] != r["io_addr"]:
            note("io_addr", op, f"{m} {a} -> objdump 0x{hexes[-1]:02X}, RTL 0x{r['io_addr']:02X}")

        # --- número de bit ---
        if m in BITNUM:
            tail = a.split(",")[-1].strip()
            if tail.isdigit() and int(tail) != r["bit_num"]:
                note("bit_num", op, f"{m} {a} -> objdump {tail}, RTL {r['bit_num']}")

        # --- inmediato ---
        if m in IMM8 and hexes and hexes[-1] != r["imm"]:
            note("imm", op, f"{m} {a} -> objdump 0x{hexes[-1]:02X}, RTL 0x{r['imm']:02X}")
        if m in IMM6 and hexes and hexes[-1] != r["imm"]:
            note("imm", op, f"{m} {a} -> objdump 0x{hexes[-1]:02X}, RTL 0x{r['imm']:02X}")

        # --- desplazamiento relativo (objdump lo da en BYTES, el RTL en palabras) ---
        if m in RELATIVE or (cls_rtl == "BRANCH"):
            mm = REL.search(a)
            if mm:
                words = int(mm.group(1)) // 2
                bits = 12
                exp = words & ((1 << bits) - 1)
                if exp != r["rel_addr"]:
                    note("rel_addr", op, f"{m} {a} -> objdump {words} palabras "
                                         f"(0x{exp:03X}), RTL 0x{r['rel_addr']:03X}")

    # ---- informe ----
    print("  Decodificador contra avr-objdump — 65 536 opcodes\n")
    checks = [("is_32bit", "tamaño de instrucción"),
              ("no_en_328p", "instrucciones ajenas al ATmega328P"),
              ("mnemonico_desconocido", "mnemónicos sin mapear"),
              ("clase", "clasificación"),
              ("operandos", "operandos de registro"),
              ("alu_op", "operación de ALU"),
              ("puntero", "puntero: selección, modo, desplazamiento"),
              ("io_addr", "dirección de I/O"),
              ("bit_num", "número de bit"),
              ("imm", "inmediato"),
              ("rel_addr", "desplazamiento relativo")]
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
