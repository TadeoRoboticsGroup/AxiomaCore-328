#!/usr/bin/env python3
"""
Prueba de mutación de la ALU de AxiomaCore-328.

Un banco de pruebas que no puede fallar no verifica nada. Este script inyecta
fallos deliberados en `rtl/core/axioma_alu.v`, uno cada vez, y comprueba que el
barrido exhaustivo los detecta TODOS.

Cada mutante es un error plausible: un término de menos en una expresión de
flags, una polaridad invertida, una máscara que escribe un bit que no debería,
un operando con el signo equivocado. Si alguno SOBREVIVE, hay un agujero de
cobertura y el script falla.

Los mutantes están curados para que ninguno sea *equivalente*, es decir, para
que ninguno produzca exactamente el mismo comportamiento que el original. Un
mutante equivalente sobrevive siempre y no indica nada; ver la nota de LSR.

Uso:  python3 sim/alu/mutation_test.py
"""
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
SRC = ROOT / "rtl/core/axioma_alu.v"

# (descripción, texto original, texto mutado)
MUTANTS = [
    ("ADD: falta un término en el medio acarreo",
     "h = (Rd3 & Rr3) | (Rr3 & nb(R3)) | (nb(R3) & Rd3);", None),  # marcador, ver abajo
]

# Se definen sobre el Verilog real, no sobre el modelo de referencia.
MUTANTS = [
    ("ADD/ADC: falta un término del medio acarreo",
     "wire h_add = (a[3] & b[3]) | (b[3] & ~r_add[3]) | (~r_add[3] & a[3]);",
     "wire h_add = (a[3] & b[3]) | (b[3] & ~r_add[3]);"),

    ("SUB/SBC: polaridad invertida en el desbordamiento",
     "wire v_sub = ( a[7] & ~b[7] & ~r_sub[7]) | (~a[7] &  b[7] &  r_sub[7]);",
     "wire v_sub = (~a[7] & ~b[7] & ~r_sub[7]) | ( a[7] &  b[7] &  r_sub[7]);"),

    ("SBC: Z se pone en vez de solo limpiarse (rompe CPC multibyte)",
     "z = (r_sub == 8'h00) & sreg_in[SREG_Z];",
     "z = (r_sub == 8'h00);"),

    ("INC: la máscara escribe C, que no debe tocarse",
     "            v = (result == 8'h80);          // desborda al pasar de 0x7F\n"
     "            n = result[7];  z = (result == 8'h00);\n"
     "            sreg_mask = M_SVNZ;             // C y H no se tocan",
     "            v = (result == 8'h80);          // desborda al pasar de 0x7F\n"
     "            n = result[7];  z = (result == 8'h00);\n"
     "            sreg_mask = M_SVNZC;"),

    ("DEC: condición de desbordamiento equivocada",
     "v = (result == 8'h7F);          // desborda al pasar de 0x80",
     "v = (result == 8'h80);"),

    ("NEG: medio acarreo con el operando negado (el fallo real que\n      encontro el contraste contra simavr)",
     "h = result[3] | a[3];",
     "h = result[3] | ~a[3];"),

    ("COM: no pone C",
     "c = 1'b1;                       // COM siempre pone C",
     "c = 1'b0;"),

    # NOTA sobre mutantes equivalentes: `n = r_lsr[7]` NO vale como mutante,
    # porque r_lsr = {1'b0, a[7:1]} y su bit 7 es siempre 0. Sería idéntico a
    # `n = 1'b0` y sobreviviría sin que eso indique agujero alguno. Se usa
    # `n = a[7]`, que sí difiere siempre que a[7] valga 1.
    ("LSR: N sale del operando en vez de ser 0",
     "c = a[0];  n = 1'b0;  z = (r_lsr == 8'h00);",
     "c = a[0];  n = a[7];  z = (r_lsr == 8'h00);"),

    ("ROR: entra a[7] en vez del acarreo",
     "wire [7:0] r_ror = {sreg_in[SREG_C], a[7:1]};",
     "wire [7:0] r_ror = {a[7], a[7:1]};"),

    ("ASR: no propaga el bit de signo",
     "wire [7:0] r_asr = {a[7],            a[7:1]};",
     "wire [7:0] r_asr = {1'b0,            a[7:1]};"),

    ("SWAP: escribe flags que no debe tocar",
     "            result = {a[3:0], a[7:4]};\n"
     "            sreg_mask = M_NONE;             // SWAP no toca ningún flag",
     "            result = {a[3:0], a[7:4]};\n"
     "            sreg_mask = M_SVNZ;"),

    ("ADIW: polaridad invertida en el desbordamiento",
     "v = ~a16[15] &  r_adiw[15];",
     "v =  a16[15] & ~r_adiw[15];"),

    ("SBIW: polaridad invertida en el acarreo",
     "c =  r_sbiw[15] & ~a16[15];",
     "c = ~r_sbiw[15] &  a16[15];"),

    ("MULSU: trata el segundo operando como con signo",
     "wire b_signed = (op == ALU_MULS)  | (op == ALU_FMULS);",
     "wire b_signed = (op == ALU_MULS)  | (op == ALU_FMULS) | (op == ALU_MULSU);"),

    ("FMUL: C sale del resultado desplazado en vez del producto",
     "c = mul_raw[15];                // el bit que se desplaza fuera",
     "c = mul_result[15];"),

    ("SREG: S calculado como N and V en vez de N xor V",
     "sreg_out[SREG_S] = n ^ v;",
     "sreg_out[SREG_S] = n & v;"),

    ("ADIW: se pierde el acarreo entre los dos bytes",
     "wire [15:0] r_adiw = a16 + {10'b0, k6};",
     "wire [15:0] r_adiw = {a16[15:8], a16[7:0] + {2'b0, k6}};"),

    ("MUL: producto sin extensión de signo del primer operando",
     "wire signed [8:0]  mul_a = {a_signed & a[7], a};",
     "wire signed [8:0]  mul_a = {1'b0, a};"),
]


def run_alu_test():
    r = subprocess.run(["make", "sim-alu"], cwd=ROOT,
                       capture_output=True, text=True)
    return r.returncode == 0


def main():
    original = SRC.read_text(encoding="utf-8")
    detected, survived, skipped = 0, [], []

    print(f"  Prueba de mutación de la ALU — {len(MUTANTS)} mutantes\n")
    try:
        for desc, old, new in MUTANTS:
            if old not in original:
                skipped.append(desc)
                print(f"  \033[0;33m??\033[0m         patrón no encontrado: {desc}")
                continue
            SRC.write_text(original.replace(old, new, 1), encoding="utf-8")
            if run_alu_test():
                survived.append(desc)
                print(f"  \033[0;31mSOBREVIVE\033[0m  {desc}")
            else:
                detected += 1
                print(f"  \033[0;32mdetectado\033[0m  {desc}")
            sys.stdout.flush()
    finally:
        SRC.write_text(original, encoding="utf-8")

    print(f"\n  {detected}/{len(MUTANTS)} mutantes detectados")
    if skipped:
        print(f"  {len(skipped)} patrones no encontrados — revisar el script")
    if survived:
        print("\n  AGUJERO DE COBERTURA: estos fallos no los detecta el banco:")
        for d in survived:
            print(f"    - {d}")
        return 1
    if skipped:
        return 1
    print("  el banco de pruebas detecta todos los fallos inyectados")
    return 0


if __name__ == "__main__":
    sys.exit(main())
