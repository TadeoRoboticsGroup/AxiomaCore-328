#!/usr/bin/env python3
"""
Prueba de mutación de todo el RTL de AxiomaCore-328.

Un banco de pruebas que no puede fallar no verifica nada. Este script inyecta
fallos deliberados y plausibles en cada módulo, uno cada vez, y comprueba que
la regresión los detecta TODOS. Si alguno SOBREVIVE, o hay un agujero de
cobertura o el mutante es equivalente; en ambos casos hay que mirarlo.

No es un adorno. Dos fallos reales de este proyecto salieron de aquí:

  - El arnés de memoria presentaba la dirección ANTES del flanco de subida, de
    modo que una memoria en flanco de subida pasaba el test igual que una en
    bajada. No comprobaba la decisión de temporización que decía comprobar.
  - El arnés del banco de registros dejaba el reloj en alto tras el reset, así
    que la escritura del primer ciclo se perdía en el DUT pero no en el modelo.
    Solo apareció al cambiar la secuencia aleatoria.

MUTANTES EQUIVALENTES: los del catálogo están escogidos para que ninguno
produzca exactamente el mismo comportamiento que el original. Ver la nota de
LSR, que es el ejemplo canónico.

Uso:
    python3 sim/mutation.py                # todos
    python3 sim/mutation.py alu decode     # solo esos módulos
"""
import hashlib
import os
import signal
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LOCK = ROOT / "build" / ".mutation.lock"

ALU     = "rtl/core/axioma_alu.v"
SREG    = "rtl/core/axioma_sreg.v"
REGFILE = "rtl/core/axioma_regfile.v"
DECODE  = "rtl/core/axioma_decode.v"
SEQ     = "rtl/core/axioma_seq.v"
DMEM    = "rtl/mem/axioma_dmem.v"
PROGMEM = "rtl/mem/axioma_progmem.v"

# (grupo, fichero, objetivo de make, descripción, original, mutado)
CATALOG = [
# ---------------------------------------------------------------- ALU
("alu", ALU, "sim-alu", "ADD/ADC: falta un término del medio acarreo",
 "wire h_add = (a[3] & b[3]) | (b[3] & ~r_add[3]) | (~r_add[3] & a[3]);",
 "wire h_add = (a[3] & b[3]) | (b[3] & ~r_add[3]);"),
("alu", ALU, "sim-alu", "SUB/SBC: polaridad invertida en el desbordamiento",
 "wire v_sub = ( a[7] & ~b[7] & ~r_sub[7]) | (~a[7] &  b[7] &  r_sub[7]);",
 "wire v_sub = (~a[7] & ~b[7] & ~r_sub[7]) | ( a[7] &  b[7] &  r_sub[7]);"),
("alu", ALU, "sim-alu", "SBC: Z se pone en vez de solo limpiarse (rompe CPC multibyte)",
 "z = (r_sub == 8'h00) & sreg_in[SREG_Z];", "z = (r_sub == 8'h00);"),
("alu", ALU, "sim-alu", "DEC: condición de desbordamiento equivocada",
 "v = (result == 8'h7F);          // desborda al pasar de 0x80", "v = (result == 8'h80);"),
("alu", ALU, "sim-alu", "NEG: medio acarreo con el operando negado (el fallo que halló simavr)",
 "h = result[3] | a[3];", "h = result[3] | ~a[3];"),
("alu", ALU, "sim-alu", "COM: no pone C",
 "c = 1'b1;                       // COM siempre pone C", "c = 1'b0;"),
# `n = r_lsr[7]` NO vale como mutante: r_lsr = {1'b0, a[7:1]} y su bit 7 es
# siempre 0, así que sería idéntico al original. Mutante equivalente.
("alu", ALU, "sim-alu", "LSR: N sale del operando en vez de ser 0",
 "c = a[0];  n = 1'b0;  z = (r_lsr == 8'h00);", "c = a[0];  n = a[7];  z = (r_lsr == 8'h00);"),
("alu", ALU, "sim-alu", "ROR: entra a[7] en vez del acarreo",
 "wire [7:0] r_ror = {sreg_in[SREG_C], a[7:1]};", "wire [7:0] r_ror = {a[7], a[7:1]};"),
("alu", ALU, "sim-alu", "ASR: no propaga el bit de signo",
 "wire [7:0] r_asr = {a[7],            a[7:1]};", "wire [7:0] r_asr = {1'b0,            a[7:1]};"),
("alu", ALU, "sim-alu", "SWAP: escribe flags que no debe tocar",
 "            result = {a[3:0], a[7:4]};\n            sreg_mask = M_NONE;             // SWAP no toca ningún flag",
 "            result = {a[3:0], a[7:4]};\n            sreg_mask = M_SVNZ;"),
("alu", ALU, "sim-alu", "ADIW: polaridad invertida en el desbordamiento",
 "v = ~a16[15] &  r_adiw[15];", "v =  a16[15] & ~r_adiw[15];"),
("alu", ALU, "sim-alu", "SBIW: polaridad invertida en el acarreo",
 "c =  r_sbiw[15] & ~a16[15];", "c = ~r_sbiw[15] &  a16[15];"),
("alu", ALU, "sim-alu", "MULSU: trata el segundo operando como con signo",
 "wire b_signed = (op == ALU_MULS)  | (op == ALU_FMULS);",
 "wire b_signed = (op == ALU_MULS)  | (op == ALU_FMULS) | (op == ALU_MULSU);"),
("alu", ALU, "sim-alu", "FMUL: C sale del resultado desplazado en vez del producto",
 "c = mul_raw[15];                // el bit que se desplaza fuera", "c = mul_result[15];"),
("alu", ALU, "sim-alu", "SREG: S calculado como N and V en vez de N xor V",
 "sreg_out[SREG_S] = n ^ v;", "sreg_out[SREG_S] = n & v;"),
("alu", ALU, "sim-alu", "ADIW: se pierde el acarreo entre los dos bytes",
 "wire [15:0] r_adiw = a16 + {10'b0, k6};",
 "wire [15:0] r_adiw = {a16[15:8], a16[7:0] + {2'b0, k6}};"),
("alu", ALU, "sim-alu", "MUL: producto sin extensión de signo del primer operando",
 "wire signed [8:0]  mul_a = {a_signed & a[7], a};", "wire signed [8:0]  mul_a = {1'b0, a};"),
("alu", ALU, "sim-alu", "INC: la máscara escribe C, que no debe tocarse",
 "            sreg_mask = M_SVNZ;             // C y H no se tocan\n        end\n\n        ALU_DEC:",
 "            sreg_mask = M_HSVNZC;\n        end\n\n        ALU_DEC:"),

# --------------------------------------------------------------- SREG
("sreg", SREG, "sim-sreg", "la máscara no protege los bits no escritos",
 "q <= (q & ~alu_mask) | (alu_value & alu_mask);", "q <= alu_value;"),
("sreg", SREG, "sim-sreg", "BSET/BCLR escribe el valor invertido",
 "q[bit_num] <= bit_val;", "q[bit_num] <= ~bit_val;"),
("sreg", SREG, "sim-sreg", "la entrada a ISR no limpia I",
 "end else if (irq_enter) begin\n            q[SREG_I] <= 1'b0;",
 "end else if (irq_enter) begin\n            q[SREG_I] <= 1'b1;"),
("sreg", SREG, "sim-sreg", "RETI no pone I",
 "end else if (irq_return) begin\n            q[SREG_I] <= 1'b1;",
 "end else if (irq_return) begin\n            q[SREG_I] <= 1'b0;"),
("sreg", SREG, "sim-sreg", "BST escribe en el bit equivocado",
 "q[SREG_T] <= t_val;", "q[SREG_C] <= t_val;"),
("sreg", SREG, "sim-sreg", "la escritura directa ignora los bits altos",
 "q <= wr_data;", "q <= {4'b0, wr_data[3:0]};"),
("sreg", SREG, "sim-sreg", "prioridad: la ALU gana a la entrada a ISR",
 "end else if (irq_enter) begin", "end else if (irq_enter && !alu_we) begin"),
("sreg", SREG, "sim-sreg", "prioridad: BSET gana a la escritura directa",
 "end else if (wr_en) begin", "end else if (wr_en && !bit_en) begin"),
("sreg", SREG, "sim-sreg", "prioridad: BST gana a BSET/BCLR",
 "end else if (bit_en) begin", "end else if (bit_en && !t_en) begin"),
("sreg", SREG, "sim-sreg", "RETI gana a la entrada a ISR",
 "        end else if (irq_enter) begin", "        end else if (irq_enter && !irq_return) begin"),

# ------------------------------------------------------------ regfile
("regfile", REGFILE, "sim-regfile", "prioridad de escritura invertida",
 "if (we && !(we16 && (w_addr[4:1] == w16_pair)))", "if (we)"),
("regfile", REGFILE, "sim-regfile", "lectura de 16 bits con los bytes intercambiados",
 "assign a16_rdata = {r[{a16_pair, 1'b1}], r[{a16_pair, 1'b0}]};",
 "assign a16_rdata = {r[{a16_pair, 1'b0}], r[{a16_pair, 1'b1}]};"),
("regfile", REGFILE, "sim-regfile", "lectura durante escritura devuelve el valor nuevo",
 "assign rd_data   = r[rd_addr];",
 "assign rd_data   = (we && w_addr==rd_addr) ? w_data : r[rd_addr];"),
("regfile", REGFILE, "sim-regfile", "la escritura de 16 bits solo pone el byte bajo",
 "r[{w16_pair, 1'b1}] <= w16_data[15:8];", "r[{w16_pair, 1'b1}] <= 8'h00;"),
# El par de escritura y el de lectura son independientes justo para que MOVW
# copie de un par a otro en un ciclo. Si la escritura cayera al par leído, MOVW
# se copiaría sobre sí mismo.
("regfile", REGFILE, "sim-regfile", "el par de escritura de 16 bits cae al de lectura",
 "r[{w16_pair, 1'b0}] <= w16_data[7:0];", "r[{a16_pair, 1'b0}] <= w16_data[7:0];"),
("regfile", REGFILE, "sim-regfile", "el reset no limpia el banco",
 "r[i] <= 8'h00;", "r[i] <= 8'hFF;"),
("regfile", REGFILE, "sim-regfile", "el tercer puerto lee la dirección de depuración",
 "assign ds_data   = r[ds_addr];", "assign ds_data   = r[dbg_addr];"),

# ----------------------------------------------------------- memorias
("mem", DMEM, "sim-mem", "dmem vuelve a flanco de subida (la decisión del ADR 0001)",
 "always @(negedge clk) begin", "always @(posedge clk) begin"),
("mem", DMEM, "sim-mem", "dmem: lectura-tras-escritura devuelve el valor viejo",
 "rdata     <= wdata;         // lectura-tras-escritura coherente", "rdata     <= mem[addr];"),
("mem", DMEM, "sim-mem", "dmem: la escritura no persiste",
 "mem[addr] <= wdata;", "mem[addr] <= mem[addr];"),
("mem", DMEM, "sim-mem", "dmem: se pierde el bit alto de la dirección",
 "mem[addr] <= wdata;", "mem[addr & 11'h3FF] <= wdata;"),
("mem", DMEM, "sim-mem", "dmem: en=0 no congela la salida",
 "        if (en) begin", "        if (1'b1) begin"),
("mem", PROGMEM, "sim-mem", "progmem: la búsqueda lee una dirección de más",
 "if_data <= mem[if_addr];", "if_data <= mem[if_addr + 1'b1];"),
("mem", PROGMEM, "sim-mem", "progmem: la escritura por SPM no persiste",
 "mem[d_addr] <= d_wdata;", "mem[d_addr] <= 16'h0000;"),
("mem", PROGMEM, "sim-mem", "progmem: el puerto de datos (LPM) devuelve basura",
 "d_rdata <= mem[d_addr];", "d_rdata <= 16'hDEAD;"),
("mem", PROGMEM, "sim-mem", "progmem: el puerto de datos no hace bypass de la escritura",
 "d_rdata     <= d_wdata;", "d_rdata     <= 16'h0000;"),
("mem", PROGMEM, "sim-mem", "progmem: los dos puertos comparten dirección",
 "            if_data <= mem[if_addr];", "            if_data <= mem[d_addr];"),

# ------------------------------------------------------------ secuenciador
# Estos solo los puede cazar la co-simulación diferencial: son fallos de
# secuencia y de temporización, no de una función combinacional.
("seq", SEQ, "sim-diff", "el salto ignora si la siguiente instrucción es de 32 bits",
 "next_fpc = skip_target;", "next_fpc = pc + 14'd2;"),
("seq", SEQ, "sim-diff", "ADIW y SBIW operan siempre sobre R25:R24",
 "OPC_IW: begin\n            rf_a16_pair = d_rd[4:1];",
 "OPC_IW: begin\n            rf_a16_pair = 4'd12;"),
("seq", SEQ, "sim-diff", "PUSH incrementa la pila en vez de decrementarla",
 "dm_addr = sp;  dm_we = 1'b1;  dm_wdata = rf_rr_data;\n                next_sp = sp - 16'd1;",
 "dm_addr = sp;  dm_we = 1'b1;  dm_wdata = rf_rr_data;\n                next_sp = sp + 16'd1;"),
("seq", SEQ, "sim-diff", "el post-incremento de puntero suma 2 en vez de 1",
 "wire [15:0] ptr_wb   = (d_ptr_mode == PTR_POSTINC) ? (ptr_base + 16'd1) :",
 "wire [15:0] ptr_wb   = (d_ptr_mode == PTR_POSTINC) ? (ptr_base + 16'd2) :"),
("seq", SEQ, "sim-diff", "MUL escribe el resultado fuera de R1:R0",
 "rf_a16_pair = 4'd0;          // R1:R0", "rf_a16_pair = 4'd1;"),
("seq", SEQ, "sim-diff", "RET consume la lectura del ciclo equivocado",
 "dm_addr = sp + 16'd1;  dm_re = 1'b1;       // byte alto\n                next_tmp16 = {8'h00, dm_rdata};            // se captura AQUÍ",
 "dm_addr = sp + 16'd1;  dm_re = 1'b1;       // byte alto"),
("seq", SEQ, "sim-diff", "las ramas condicionales invierten la polaridad",
 "wire cond_taken = (sreg[d_cond_bit] == d_cond_set);",
 "wire cond_taken = (sreg[d_cond_bit] != d_cond_set);"),
("seq", SEQ, "sim-diff", "el ciclo de calentamiento tras el reset desaparece",
 "warmup   <= 1'b1;", "warmup   <= 1'b0;"),
# Este es el fallo real que encontró la comprobación de ciclos: MOVW tardaba 2
# ciclos y el manual dice 1. Deja el ESTADO correcto, así que la comparación de
# registros lo da por bueno; sólo la capa 3 lo caza. Si algún día sobrevive, es
# que la comprobación de ciclos se ha apagado.
("seq", SEQ, "sim-diff", "MOVW vuelve a costar dos ciclos (sólo lo caza la capa 3)",
 """        OPC_MOVW: begin
            rf_a16_pair = d_rr[4:1];        // origen; el destino va por rf_w16_pair
            rf_we16     = 1'b1;
            rf_w16_data = rf_a16_rdata;
            next_fpc = fpc + 14'd1;  next_pc = pc + 14'd1;  retire = 1'b1;
        end""",
 """        OPC_MOVW: begin
            rf_a16_pair = d_rr[4:1];
            if (cyc == 2'd0) begin
                next_tmp16 = rf_a16_rdata;
                next_use_hold = 1'b1;  next_cyc = 2'd1;
            end else begin
                rf_we16     = 1'b1;
                rf_w16_data = tmp16;
                next_fpc = fpc + 14'd1;  next_pc = pc + 14'd1;  retire = 1'b1;
            end
        end"""),

# --------------------------------------------------------- decodificador
("decode", DECODE, "sim-decode", "LDS deja de marcarse como de 32 bits",
 "16'b1001_000?_????_0000: begin op_class = OPC_LDS;  rd = f_rd5; rd_we = 1'b1; is_32bit = 1'b1; end",
 "16'b1001_000?_????_0000: begin op_class = OPC_LDS;  rd = f_rd5; rd_we = 1'b1; is_32bit = 1'b0; end"),
("decode", DECODE, "sim-decode", "CALL deja de marcarse como de 32 bits",
 "16'b1001_010?_????_111?: begin op_class = OPC_CALL; is_32bit = 1'b1; end",
 "16'b1001_010?_????_111?: begin op_class = OPC_CALL; is_32bit = 1'b0; end"),
("decode", DECODE, "sim-decode", "ADD se decodifica como ADC",
 "op_class = OPC_ALU_RR;  alu_op = ALU_ADD;  rd = f_rd5;  rr = f_rr5;  rd_we = 1'b1;",
 "op_class = OPC_ALU_RR;  alu_op = ALU_ADC;  rd = f_rd5;  rr = f_rr5;  rd_we = 1'b1;"),
("decode", DECODE, "sim-decode", "el segundo operando pierde su bit alto",
 "wire [4:0] f_rr5   = {insn[9], insn[3:0]};", "wire [4:0] f_rr5   = {1'b0, insn[3:0]};"),
("decode", DECODE, "sim-decode", "los formatos con inmediato apuntan a R0..R15",
 "wire [4:0] f_rd_hi = {1'b1, insn[7:4]};          // R16..R31, formatos con inmediato",
 "wire [4:0] f_rd_hi = {1'b0, insn[7:4]};"),
("decode", DECODE, "sim-decode", "ADIW parte de R16 en vez de R24",
 "wire [4:0] f_adiw  = {2'b11, insn[5:4], 1'b0};   // R24, R26, R28, R30",
 "wire [4:0] f_adiw  = {2'b10, insn[5:4], 1'b0};"),
("decode", DECODE, "sim-decode", "LDD confunde el puntero Y con el Z",
 "            ptr_sel  = insn[3] ? PTR_Y : PTR_Z;\n            ptr_mode = PTR_DISP;  disp = f_disp;\n        end\n        16'b10?0_??1?_????_????:",
 "            ptr_sel  = insn[3] ? PTR_Z : PTR_Y;\n            ptr_mode = PTR_DISP;  disp = f_disp;\n        end\n        16'b10?0_??1?_????_????:"),
("decode", DECODE, "sim-decode", "IN y OUT pierden los bits altos de la dirección de I/O",
 "wire [5:0] f_ioa6  = {insn[10:9], insn[3:0]};    // A de IN y OUT",
 "wire [5:0] f_ioa6  = {2'b00, insn[3:0]};"),
("decode", DECODE, "sim-decode", "elpm deja de rechazarse",
 "        16'b1001_000?_????_0101: begin op_class = OPC_LPM;  rd = f_rd5; rd_we = 1'b1; ptr_sel = PTR_Z; ptr_mode = PTR_POSTINC; end",
 "        16'b1001_000?_????_0101: begin op_class = OPC_LPM;  rd = f_rd5; rd_we = 1'b1; ptr_sel = PTR_Z; ptr_mode = PTR_POSTINC; end\n        16'b1001_000?_????_0110: begin op_class = OPC_LPM;  rd = f_rd5; rd_we = 1'b1; ptr_sel = PTR_Z; end"),
]

GREEN, RED, YELLOW, DIM, NC = "\033[0;32m", "\033[0;31m", "\033[0;33m", "\033[2m", "\033[0m"


def run(target):
    return subprocess.run(["make", target], cwd=ROOT,
                          capture_output=True, text=True).returncode == 0


class Lock:
    """Cerrojo de exclusión mutua.

    Este script MODIFICA EL RTL EN SITIO mientras corre. Cualquier otra cosa que
    se ejecute a la vez —una regresión, una síntesis, otra mutación— verá
    ficheros mutados y dará resultados falsos. Ya pasó una vez: una regresión
    lanzada en paralelo reportó `sim-alu` en fallo sin que hubiera nada roto.
    """

    def __enter__(self):
        LOCK.parent.mkdir(parents=True, exist_ok=True)
        try:
            fd = os.open(LOCK, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        except FileExistsError:
            sys.exit(
                f"Ya hay una prueba de mutación en curso ({LOCK}).\n"
                "Modifica el RTL en sitio: no se puede ejecutar dos veces a la vez,\n"
                "ni a la vez que la regresión. Si sobró de una ejecución "
                "interrumpida, bórralo a mano."
            )
        os.write(fd, f"pid {os.getpid()}\n".encode())
        os.close(fd)
        return self

    def __exit__(self, *a):
        LOCK.unlink(missing_ok=True)


def main():
    want = set(sys.argv[1:])
    cat = [c for c in CATALOG if not want or c[0] in want]
    if not cat:
        sys.exit(f"grupos disponibles: {sorted({c[0] for c in CATALOG})}")

    originals = {f: (ROOT / f).read_text(encoding="utf-8")
                 for f in {c[1] for c in cat}}

    def restore(*_):
        """Devuelve el RTL a su estado original.

        Se instala también como manejador de SIGINT y SIGTERM: si el proceso
        muere por señal, el `finally` de Python NO se ejecuta y el árbol se
        queda con un mutante dentro. Ya ocurrió una vez y provocó que la
        regresión posterior diera `sim-decode` en fallo sin nada roto.
        """
        for path, src in originals.items():
            (ROOT / path).write_text(src, encoding="utf-8")
        LOCK.unlink(missing_ok=True)

    def die(sig, _frame):
        restore()
        print(f"\n  interrumpido (señal {sig}); RTL restaurado", file=sys.stderr)
        sys.exit(130)

    signal.signal(signal.SIGINT, die)
    signal.signal(signal.SIGTERM, die)
    signal.signal(signal.SIGHUP, die)

    detected, survived, skipped = 0, [], []
    group = None

    print(f"  Prueba de mutación — {len(cat)} mutantes\n")
    try:
        for grp, f, target, desc, old, new in cat:
            if grp != group:
                group = grp
                print(f"  {DIM}--- {grp} ---{NC}")
            src = originals[f]
            if old not in src:
                skipped.append((grp, desc))
                print(f"  {YELLOW}??       {NC} {desc}")
                continue
            (ROOT / f).write_text(src.replace(old, new, 1), encoding="utf-8")
            if run(target):
                survived.append((grp, desc))
                print(f"  {RED}SOBREVIVE{NC} {desc}")
            else:
                detected += 1
                print(f"  {GREEN}detectado{NC} {desc}")
            (ROOT / f).write_text(src, encoding="utf-8")
            sys.stdout.flush()
    finally:
        restore()

    # Comprobación de integridad: el árbol DEBE quedar como estaba.
    dirty = [f for f, src in originals.items()
             if hashlib.sha256((ROOT / f).read_bytes()).hexdigest()
             != hashlib.sha256(src.encode()).hexdigest()]
    if dirty:
        print("\n  ERROR: el RTL no quedó restaurado:", *dirty, sep="\n    ")
        return 2

    # El árbol quedaba con los BINARIOS del último mutante. Los ficheros se
    # restauran arriba, pero build/ no: quien después ejecutara
    # ./build/vdiff/diff a mano —que es justo lo que recomienda la guía para
    # depurar el núcleo— estaría corriendo un mutante sin saberlo. Ya pasó.
    # Se reconstruye y se exige que todo vuelva a estar en verde, lo que de
    # paso demuestra que la restauración fue buena.
    print("\n  reconstruyendo tras restaurar...")
    rotos = [t for t in sorted({c[2] for c in cat}) if not run(t)]
    if rotos:
        print("  ERROR: tras restaurar, estos objetivos NO pasan:", *rotos, sep="\n    ")
        return 2

    print(f"\n  {detected}/{len(cat)} mutantes detectados")
    if skipped:
        print(f"  {len(skipped)} patrones no encontrados — el catálogo se ha desincronizado del RTL:")
        for g, d in skipped:
            print(f"    [{g}] {d}")
    if survived:
        print("\n  AGUJERO DE COBERTURA — estos fallos no los detecta la regresión:")
        for g, d in survived:
            print(f"    [{g}] {d}")
    if survived or skipped:
        return 1
    print("  la regresión detecta todos los fallos inyectados")
    print("  árbol restaurado y reconstruido: los binarios de build/ ya no son de un mutante")
    return 0


if __name__ == "__main__":
    with Lock():
        sys.exit(main())
