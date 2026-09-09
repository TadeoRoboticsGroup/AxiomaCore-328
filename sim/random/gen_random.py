#!/usr/bin/env python3
"""
Generador de programas AVR aleatorios para la regresión de la fase 1.

Emite secuencias VÁLIDAS de instrucciones con operandos aleatorios, para que la
co-simulación diferencial las contraste contra simavr. Es el último requisito
del criterio de aceptación de la fase 1: 10^6 instrucciones sin divergencia.

Un generador de instrucciones aleatorias es fácil de escribir mal. Lo difícil
no es la aleatoriedad, es garantizar que el programa NUNCA hace nada cuyo
resultado no esté definido o que los dos lados no puedan modelar igual. Estas
son las restricciones, y cada una tiene su motivo:

  1. NADA DE PERIFÉRICOS. El espacio de I/O del RTL es memoria plana en la fase
     1 y simavr sí los modela. Sólo se tocan los tres GPIOR, que son
     almacenamiento puro en ambos lados, y el SREG, que el núcleo intercepta.

  2. LOS PUNTEROS NO SON DESTINOS ALEATORIOS. Si una instrucción cualquiera
     pudiera escribir R26..R31, el siguiente LD o ST iría a parar a cualquier
     sitio: a un periférico, o fuera de la SRAM. X, Y y Z sólo los mueven la
     secuencia de amarre y el post-incremento o pre-decremento de los propios
     accesos, que están acotados por el intervalo de amarre.

  3. AMARRE PERIÓDICO. Cada AMARRE instrucciones se rehace
     X = Y = Z = 0x0200..0x027F  y  SP = 0x0800. Con eso, la deriva máxima
     entre amarres es de AMARRE bytes, y todos los accesos —incluido `ldd Y+63`
     y el pre-decremento— caen dentro de la SRAM (0x0100..0x08FF).

  4. NADA DE TRANSFERENCIAS DE CONTROL ARBITRARIAS. Ni CALL, ni RET, ni saltos
     indirectos: un destino aleatorio caería en mitad de una instrucción de 32
     bits o fuera del programa. Las ramas van siempre a una etiqueta generada
     justo después de la instrucción siguiente, y los saltos de instrucción
     (CPSE, SBRC, SBRS, SBIC, SBIS) llevan detrás una instrucción elegida a
     propósito, de 16 o de 32 bits, para ejercitar las dos. El único salto es
     el JMP fijo que cierra el bucle, con destino conocido. Las llamadas y los
     retornos los cubren los programas dirigidos flow.S e isa_system.S.

  5. LPM SÓLO DENTRO DEL PROGRAMA. Z se usa como dirección de BYTE de flash.
     simavr inicializa la flash a 0xFF y axioma_progmem a 0x0000, así que leer
     flash sin programar hace divergir el contraste sin que haya nada roto. El
     amarre deja Z en 0x0200 y pico, que siempre cae dentro del programa porque
     el cuerpo generado es de miles de palabras.

  6. SPM Y SLEEP FUERA. SPM no tiene ciclos fijados en el manual y su emulación
     en simavr no es comparable. SLEEP detendría a simavr y con él al arnés.

Uso:
    python3 sim/random/gen_random.py --out build/random --n 8 --len 4000
"""
import argparse
import random
from pathlib import Path

# --------------------------------------------------------------------------
# Bancos de registros
# --------------------------------------------------------------------------
DEST = list(range(0, 26))          # destinos de 8 bits: nunca un puntero
DEST_HI = list(range(16, 26))      # destinos de las formas con inmediato
ANY = list(range(0, 32))           # cualquier registro, sólo como lectura
SRC = list(range(0, 26))           # fuentes que se almacenan o apilan
HI = list(range(16, 32))           # rango de MULS
LO = list(range(16, 24))           # rango de MULSU y FMUL*

# I/O que se comporta igual en el RTL y en simavr.
GPIOR0, GPIOR1, GPIOR2 = 0x1E, 0x2A, 0x2B   # direcciones de I/O
SREG_IO = 0x3F

AMARRE = 48                        # instrucciones entre dos amarres

# Ventana de SRAM sobre la que trabajan los punteros y LDS/STS.
SRAM_LO, SRAM_HI = 0x0200, 0x02FF


def clamp():
    """Devuelve X, Y, Z a la ventana de SRAM y el SP a 0x0800."""
    return [
        "ldi  r27, 0x02", "andi r26, 0x7F",       # X
        "ldi  r29, 0x02", "andi r28, 0x7F",       # Y
        "ldi  r31, 0x02", "andi r30, 0x7F",       # Z
        "ldi  r16, 0x00", "out  0x3D, r16",       # SPL
        "ldi  r16, 0x08", "out  0x3E, r16",       # SPH
    ]


class Gen:
    def __init__(self, rng):
        self.r = rng
        self.n = 0

    # ---- ayudas ----
    def d(self):   return self.r.choice(DEST)
    def dh(self):  return self.r.choice(DEST_HI)
    def a(self):   return self.r.choice(ANY)
    def s(self):   return self.r.choice(SRC)
    def k8(self):  return self.r.randrange(256)
    def bit(self): return self.r.randrange(8)

    def label(self):
        self.n += 1
        return f"Lr{self.n}"

    # ---- una instrucción simple de 16 bits, sin efectos raros ----
    def plain16(self):
        op = self.r.choice(["add", "adc", "sub", "sbc", "and", "or", "eor", "mov"])
        return f"{op}  r{self.d()}, r{self.a()}"

    def wide32(self):
        """Instrucción de 32 bits, para que los saltos descarten DOS palabras."""
        addr = self.r.randrange(SRAM_LO, SRAM_HI + 1)
        if self.r.random() < 0.5:
            return f"lds  r{self.d()}, 0x{addr:04X}"
        return f"sts  0x{addr:04X}, r{self.s()}"

    # ---- las familias ----
    def alu_rr(self):
        op = self.r.choice(["add", "adc", "sub", "sbc", "and", "or", "eor",
                            "mov", "cp", "cpc"])
        return [f"{op}  r{self.d() if op not in ('cp', 'cpc') else self.a()}, "
                f"r{self.a()}"]

    def alu_ri(self):
        op = self.r.choice(["subi", "sbci", "andi", "ori", "cpi", "ldi"])
        return [f"{op} r{self.dh()}, 0x{self.k8():02X}"]

    def alu_1(self):
        op = self.r.choice(["com", "neg", "swap", "inc", "dec", "asr", "lsr", "ror"])
        return [f"{op}  r{self.d()}"]

    def iw(self):
        # Sólo el par R25:R24. Los otros tres que admiten ADIW son punteros y
        # moverlos rompería el amarre; el programa dirigido basic.S los cubre.
        op = self.r.choice(["adiw", "sbiw"])
        return [f"{op} r24, 0x{self.r.randrange(64):02X}"]

    def movw(self):
        return [f"movw r{self.r.randrange(0, 13) * 2}, r{self.r.randrange(0, 16) * 2}"]

    def mul(self):
        # Todas escriben R1:R0, así que sus operandos son sólo de lectura.
        op = self.r.choice(["mul", "muls", "mulsu", "fmul", "fmuls", "fmulsu"])
        if op == "mul":
            return [f"mul  r{self.a()}, r{self.a()}"]
        if op == "muls":
            return [f"muls r{self.r.choice(HI)}, r{self.r.choice(HI)}"]
        return [f"{op} r{self.r.choice(LO)}, r{self.r.choice(LO)}"]

    def bits(self):
        c = self.r.random()
        if c < 0.3:
            return [f"bld  r{self.d()}, {self.bit()}"]
        if c < 0.6:
            return [f"bst  r{self.a()}, {self.bit()}"]
        return [self.r.choice(["sec", "sez", "sen", "sev", "ses", "seh", "set",
                               "clc", "clz", "cln", "clv", "cls", "clh", "clt",
                               "sei", "cli"])]

    def mem(self):
        p = self.r.choice("XYZ")
        c = self.r.random()
        if p in "YZ" and c < 0.3:
            q = self.r.randrange(64)
            if self.r.random() < 0.5:
                return [f"ldd  r{self.d()}, {p}+{q}"]
            return [f"std  {p}+{q}, r{self.s()}"]
        mode = self.r.choice(["", "+", "-"])
        ref = f"-{p}" if mode == "-" else f"{p}{mode}"
        if self.r.random() < 0.5:
            return [f"ld   r{self.d()}, {ref}"]
        return [f"st   {ref}, r{self.s()}"]

    def absmem(self):
        addr = self.r.randrange(SRAM_LO, SRAM_HI + 1)
        if self.r.random() < 0.5:
            return [f"lds  r{self.d()}, 0x{addr:04X}"]
        return [f"sts  0x{addr:04X}, r{self.s()}"]

    def stack(self):
        if self.r.random() < 0.5:
            return [f"push r{self.s()}"]
        return [f"pop  r{self.d()}"]

    def io(self):
        c = self.r.random()
        if c < 0.4:
            return [f"in   r{self.d()}, 0x{self.r.choice([GPIOR0, GPIOR1, GPIOR2]):02X}"]
        if c < 0.8:
            return [f"out  0x{self.r.choice([GPIOR0, GPIOR1, GPIOR2]):02X}, r{self.s()}"]
        # Escribir el SREG entero es una prueba en sí misma: los dos lados
        # tienen que aceptar combinaciones donde S no es N xor V.
        return [f"out  0x{SREG_IO:02X}, r{self.s()}"]

    def iobit(self):
        op = self.r.choice(["sbi", "cbi"])
        return [f"{op}  0x{GPIOR0:02X}, {self.bit()}"]

    def lpm(self):
        c = self.r.random()
        if c < 0.3:
            return ["lpm"]
        if c < 0.7:
            return [f"lpm  r{self.d()}, Z"]
        return [f"lpm  r{self.d()}, Z+"]

    def system(self):
        return [self.r.choice(["nop", "wdr", "break"])]

    def skip(self):
        """Salto de instrucción. Lo saltado es de 16 o de 32 bits a propósito."""
        op = self.r.choice(["cpse", "sbrc", "sbrs", "sbic", "sbis"])
        if op == "cpse":
            head = f"cpse r{self.a()}, r{self.a()}"
        elif op in ("sbrc", "sbrs"):
            head = f"{op} r{self.a()}, {self.bit()}"
        else:
            head = f"{op} 0x{GPIOR0:02X}, {self.bit()}"
        tail = self.wide32() if self.r.random() < 0.4 else self.plain16()
        return [head, tail]

    def branch(self):
        """Rama a una etiqueta puesta justo detrás de la instrucción siguiente."""
        op = self.r.choice(["brcs", "brcc", "breq", "brne", "brmi", "brpl",
                            "brge", "brlt", "brhs", "brhc", "brts", "brtc",
                            "brvs", "brvc", "brie", "brid"])
        lab = self.label()
        return [f"{op} {lab}", self.plain16(), f"{lab}:"]


# (peso, método). Los pesos reparten el corpus: la aritmética domina, como en
# código real, pero ninguna familia se queda sin salir.
MIX = [(26, "alu_rr"), (14, "alu_ri"), (10, "alu_1"), (4, "iw"), (3, "movw"),
       (5, "mul"), (7, "bits"), (12, "mem"), (4, "absmem"), (5, "stack"),
       (5, "io"), (3, "iobit"), (3, "lpm"), (2, "system"), (6, "skip"),
       (10, "branch")]


def body(rng, n_insn):
    """Cuerpo de n_insn instrucciones, con amarres intercalados."""
    g = Gen(rng)
    names = [m for w, m in MIX for _ in range(w)]
    out, since = [], 0
    emitted = 0
    while emitted < n_insn:
        if since >= AMARRE:
            out += ["", "    ; amarre: punteros y pila de vuelta a rango"]
            out += ["    " + i for i in clamp()]
            out.append("")
            emitted += len(clamp())
            since = 0
            continue
        chunk = getattr(g, rng.choice(names))()
        for line in chunk:
            out.append(line if line.endswith(":") else "    " + line)
        n = sum(1 for l in chunk if not l.endswith(":"))
        emitted += n
        since += n
    return out


HEADER = """; AxiomaCore-328 - programa aleatorio {idx} de la regresion de la fase 1
; SPDX-License-Identifier: Apache-2.0
;
; FICHERO GENERADO. No editar a mano.
; Generador: sim/random/gen_random.py   semilla: {seed}
;
; Instrucciones validas con operandos aleatorios, sin periferico alguno y sin
; transferencias de control arbitrarias. Las restricciones y su porque estan
; documentadas en la cabecera del generador.

    .section .text
    .global _start
_start:
    ldi  r16, 0x00
    out  0x3D, r16
    ldi  r16, 0x08
    out  0x3E, r16
"""

SEED_REGS = """
    ; siembra: valores variados para que la primera vuelta no arranque toda a cero
"""

# Se cierra con JMP y no con RJMP: el desplazamiento de RJMP es de 12 bits con
# signo (+-2048 palabras) y el cuerpo generado lo desborda en cuanto pasa de
# unos pocos miles de instrucciones. JMP direcciona la flash entera.
FOOTER = """
    jmp  bucle
"""


def program(idx, seed, n_insn):
    rng = random.Random(seed + idx * 7919)
    out = [HEADER.format(idx=idx, seed=seed).rstrip(), SEED_REGS.rstrip()]
    for r in range(16, 26):
        out.append(f"    ldi  r{r}, 0x{rng.randrange(256):02X}")
    out.append("")
    out.append("bucle:")
    out += ["    " + i for i in clamp()]
    out.append("")
    out += body(rng, n_insn)
    out.append(FOOTER.rstrip())
    return "\n".join(out) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="build/random")
    ap.add_argument("--n", type=int, default=8, help="número de programas")
    ap.add_argument("--len", type=int, default=4000, help="instrucciones por cuerpo")
    ap.add_argument("--seed", type=int, default=20260909)
    a = ap.parse_args()

    d = Path(a.out)
    d.mkdir(parents=True, exist_ok=True)
    for old in d.glob("rnd*.S"):
        old.unlink()
    for i in range(a.n):
        (d / f"rnd{i:02d}.S").write_text(program(i, a.seed, a.len), encoding="utf-8")
    print(f"  {a.n} programas de ~{a.len} instrucciones en {d}/  (semilla {a.seed})")


if __name__ == "__main__":
    main()
