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
DBUS    = "rtl/bus/axioma_dbus.v"
GPIO    = "rtl/periph/axioma_gpio.v"
PRESC   = "rtl/periph/axioma_prescaler.v"
TIMER0  = "rtl/periph/axioma_timer0.v"
TIMER1  = "rtl/periph/axioma_timer1.v"
TIMER2  = "rtl/periph/axioma_timer2.v"
TIMER8  = "rtl/periph/axioma_timer8.v"
IRQ     = "rtl/periph/axioma_irq.v"
GPIOR   = "rtl/periph/axioma_gpior.v"
USART   = "rtl/periph/axioma_usart.v"
EXTINT  = "rtl/periph/axioma_extint.v"
SPI     = "rtl/periph/axioma_spi.v"
TWI     = "rtl/periph/axioma_twi.v"
ADC     = "rtl/periph/axioma_adc.v"
SOC     = "rtl/soc/axioma328_soc.v"

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

# ------------------------------------------------------ puerto de E/S
("gpio", GPIO, "sim-gpio", "escribir PINx lo escribe en vez de conmutar PORTx (trampa 5)",
 "if (hit_pin)  port_q <= (port_q ^ io_wdata) & BITS;",
 "if (hit_pin)  port_q <= io_wdata & BITS;"),
# Este SOLO lo caza el banco propio: simavr no modela el sincronizador, asi que
# el contraste contra el pasaria igualmente.
("gpio", GPIO, "sim-gpio", "el sincronizador de PINx desaparece (simavr no lo veria)",
 "            sync1 <= pad_in & BITS;", "            sync1 <= sync1;"),
("gpio", GPIO, "sim-gpio", "no se enmascaran los bits que no existen, como PC7",
 "                if (hit_ddr)  ddr_q  <= io_wdata & BITS;",
 "                if (hit_ddr)  ddr_q  <= io_wdata;"),
("gpio", GPIO, "sim-gpio", "PINx y PORTx intercambiados en la lectura",
 """    assign io_rdata = hit_pin  ? sync1  :
                      hit_ddr  ? ddr_q  :
                      hit_port ? port_q : 8'h00;""",
 """    assign io_rdata = hit_pin  ? port_q :
                      hit_ddr  ? ddr_q  :
                      hit_port ? sync1  : 8'h00;"""),
("gpio", GPIO, "sim-gpio", "no se declara el pull-up: un pin de entrada leeria 0",
 "assign pad_pullup = ~pad_oe & port_q;", "assign pad_pullup = 8'h00;"),
# El pull-up mira la direccion EFECTIVA, la de despues de la anulacion: un SS de
# esclavo forzado a entrada con su PORTB2 a uno lleva pull-up, y es lo que evita
# que un esclavo sin maestro se quede seleccionado por ruido.
("gpio", GPIO, "sim-gpio", "el pull-up mira DDRx y no la direccion ya anulada",
 "assign pad_pullup = ~pad_oe & port_q;", "assign pad_pullup = ~ddr_q & port_q;"),

# ------------------------------------------------------ bus de datos
("dbus", DBUS, "sim-dbus", "la SRAM no traduce la dirección: no resta la base",
 "assign sram_addr  = {addr[10:8] - 3'd1, addr[7:0]};",
 "assign sram_addr  = addr[10:0];"),
("dbus", DBUS, "sim-dbus", "el rango de I/O se come el de la SRAM",
 "wire hit_io   = (addr >= IO_BASE)   && (addr <  SRAM_BASE);",
 "wire hit_io   = (addr >= IO_BASE);"),
("dbus", DBUS, "sim-dbus", "se lee de un periférico que no reclamó la dirección",
 "io_rdata_q <= (hit_io && io_sel) ? io_rdata : 8'h00;",
 "io_rdata_q <= io_rdata;"),
("dbus", DBUS, "sim-dbus", "por encima de RAMEND se sigue leyendo la SRAM",
 "wire hit_sram = (addr >= SRAM_BASE) && (addr <= RAMEND);",
 "wire hit_sram = (addr >= SRAM_BASE);"),
("dbus", DBUS, "sim-dbus", "una escritura activa el periférico aunque no toque",
 "assign io_we    = hit_io & we;", "assign io_we    = we;"),
# Este es el que justifica el ADR 0001 en el bus: sin registrar la selección,
# el segundo ciclo de LD elige la región de la dirección NUEVA.
("dbus", DBUS, "sim-dbus", "la selección de región se vuelve combinacional (ADR 0001)",
 """    assign rdata = hit_sram_q ? sram_rdata :
                   hit_io_q   ? io_rdata_q : 8'h00;""",
 """    assign rdata = hit_sram ? sram_rdata :
                   hit_io     ? io_rdata_q : 8'h00;"""),

# ------------------------------------------------------------ secuenciador
# Estos solo los puede cazar la co-simulación diferencial: son fallos de
# secuencia y de temporización, no de una función combinacional.
("seq", SEQ, "sim-diff", "el salto ignora si la siguiente instrucción es de 32 bits",
 "next_fpc = skip_target;", "next_fpc = pc + 14'd2;"),
("seq", SEQ, "sim-diff", "ADIW y SBIW operan siempre sobre R25:R24",
 "OPC_IW: begin\n            rf_a16_pair = d_rd[4:1];",
 "OPC_IW: begin\n            rf_a16_pair = 4'd12;"),
("seq", SEQ, "sim-diff", "PUSH incrementa la pila en vez de decrementarla",
 """                next_dm_addr = sp;  next_dm_we = 1'b1;
                next_dm_wdata = rf_rr_data;
                next_sp = sp - 16'd1;""",
 """                next_dm_addr = sp;  next_dm_we = 1'b1;
                next_dm_wdata = rf_rr_data;
                next_sp = sp + 16'd1;"""),
("seq", SEQ, "sim-diff", "el post-incremento de puntero suma 2 en vez de 1",
 "wire [15:0] ptr_wb   = (d_ptr_mode == PTR_POSTINC) ? (ptr_base + 16'd1) :",
 "wire [15:0] ptr_wb   = (d_ptr_mode == PTR_POSTINC) ? (ptr_base + 16'd2) :"),
("seq", SEQ, "sim-diff", "MUL escribe el resultado fuera de R1:R0",
 "rf_a16_pair = 4'd0;          // R1:R0", "rf_a16_pair = 4'd1;"),
("seq", SEQ, "sim-diff", "RET no captura el byte alto de la pila",
 """                next_tmp16 = {8'h00, dm_rdata};            // se captura AQUÍ""",
 """                next_tmp16 = tmp16;"""),
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
# ------------------------------------------- prescaler compartido (trampa 12)
("timer0", PRESC, "sim-timer0", "PSRSYNC deja de poner el prescaler a cero",
 "            cnt <= psr_now ? 10'd0 : (cnt + 10'd1);",
 "            cnt <= cnt + 10'd1;"),
("timer0", PRESC, "sim-timer0", "TSM no retiene el reset: el prescaler no se puede parar",
 "            end else if (!tsm_q) begin", "            end else begin"),
("timer0", PRESC, "sim-timer0", "la toma de /64 se desfasa un ciclo",
 "assign tick_64   = (cnt[5:0] == 6'b111111)     && !psr_now;",
 "assign tick_64   = (cnt[5:0] == 6'b111110)     && !psr_now;"),

# ---------------------------------------------------------------- Timer0
# Ninguno de estos lo puede cazar el contraste contra simavr: su temporizador
# interpola TCNT0 desde su propio contador de ciclos y ni siquiera modela GTCCR.
("timer0", TIMER8, "sim-timer0", "en CTC el desbordamiento se marca en TOP y no en MAX",
 """    wire ev_tov = ck && (mode_pc   ? (dir_down && at_bottom) :
                         mode_fast ? at_top :
                                     at_max);""",
 """    wire ev_tov = ck && (mode_pc   ? (dir_down && at_bottom) :
                         mode_fast ? at_top :
                                     at_top);"""),
("timer0", TIMER8, "sim-timer0", "OCR0x pierde el doble búfer y cambia a mitad de periodo",
 """            if (we_ocra) begin
                ocra_buf <= wdata;
                if (!mode_pwm) ocra_act <= wdata;
            end""",
 """            if (we_ocra) begin
                ocra_buf <= wdata;
                ocra_act <= wdata;
            end"""),
("timer0", TIMER8, "sim-timer0", "escribir TCNT0 ya no tapa la comparación siguiente",
 "wire ev_compa = ck && !tcnt_block && (tcnt_q == ocra_act);",
 "wire ev_compa = ck && (tcnt_q == ocra_act);"),
("timer0", TIMER8, "sim-timer0", "atender el vector no limpia la bandera en su origen",
 """            if (ev_tov)                                  tifr_q[0] <= 1'b1;
            else if (ack_ovf   || (we_tifr && wdata[0])) tifr_q[0] <= 1'b0;""",
 """            if (ev_tov)                                  tifr_q[0] <= 1'b1;
            else if (we_tifr && wdata[0])                tifr_q[0] <= 1'b0;"""),
("timer0", TIMER8, "sim-timer0", "TIFR0 se limpia escribiendo cualquier cosa, no un uno",
 "            else if (ack_compa || (we_tifr && wdata[1])) tifr_q[1] <= 1'b0;",
 "            else if (ack_compa || we_tifr)               tifr_q[1] <= 1'b0;"),
("timer0", TIMER8, "sim-timer0", "la petición ignora la habilitación de TIMSK0",
 "assign irq_ovf   = tifr_q[0] & timsk_q[0];", "assign irq_ovf   = tifr_q[0];"),
# Este es el fallo que se cometió al escribir el MODELO de este mismo banco: en
# PWM de fase correcta el pin se decide con el sentido de la cuenta ANTERIOR al
# flanco, no con el que queda. Sólo se nota en el modo 5, donde TOP es OCR0A y
# la comparación cae justo en el ciclo en que la cuenta da la vuelta.
("timer0", TIMER8, "sim-timer0", "el pin de PWM de fase correcta usa el sentido nuevo",
 "                    else if (com_a == 2'd2) oca_q <= dir_down;",
 "                    else if (com_a == 2'd2) oca_q <= dir_next;"),
# EL MOTOR ES COMPARTIDO, y estos mutantes lo demuestran: los de arriba se
# inyectan en axioma_timer8.v y los caza el banco del Timer0; el del doble
# bufer del grupo «timer2» se inyecta en el MISMO fichero y lo caza el banco
# del Timer2. Si el dia de manana alguien vuelve a copiar el motor en dos
# ficheros, la mitad de estos mutantes dejara de aplicarse y la mutacion lo
# dira en el mismo commit.
("timer0", TIMER0, "sim-timer0", "el selector de reloj del Timer0 pierde la toma de /1024",
 """            3'd5:    ck = tick_1024;""",
 """            3'd5:    ck = tick_256;"""),
("timer0", TIMER0, "sim-timer0", "el reloj externo T0 cuenta los dos flancos",
 """            3'd6:    ck = t0_fall;""",
 """            3'd6:    ck = t0_fall | t0_rise;"""),

# ------------------------------------------ controlador de interrupciones
("irq", IRQ, "sim-irq", "gana el vector de número más ALTO en vez del más bajo",
 "        for (i = 25; i >= 1; i = i - 1)", "        for (i = 1; i <= 25; i = i + 1)"),
("irq", IRQ, "sim-irq", "el vector 0 (RESET) cuenta como interrupción",
 "        for (i = 25; i >= 1; i = i - 1)", "        for (i = 25; i >= 0; i = i - 1)"),
("irq", IRQ, "sim-irq", "el reconocimiento vuelve a todos los que piden a la vez",
 "assign ack[g] = irq_ack && any && (vec == g[4:0]);",
 "assign ack[g] = irq_ack && src[g];"),

# ------------------------------------------- entrada a ISR del secuenciador
# La ruta que estuvo escrita y sin ejercer desde la fase 1. Los dos primeros
# mutantes son los dos fallos REALES que tenía cuando por fin se disparó.
("seq", SEQ, "sim-diff", "el vector se calcula por cuatro en vez de por dos",
 "                next_tmp16     = {10'b0, irq_vector, 1'b0};",
 "                next_tmp16     = {9'b0, irq_vector, 2'b00};"),
("seq", SEQ, "sim-diff", "la entrada a ISR no se sostiene y se cae al case de instrucciones",
 "    wire irq_go = irq_take | in_irq;", "    wire irq_go = irq_take;"),
("seq", SEQ, "sim-diff", "SEI pierde su ciclo de gracia (trampa 2)",
 "            next_irq_hold = (d_class == OPC_BSET) && (d_bit_num == 3'd7);",
 "            next_irq_hold = 1'b0;"),
("seq", SEQ, "sim-diff", "la entrada a ISR apila el byte alto primero",
 """                next_dm_wdata = pc[7:0];""",
 """                next_dm_wdata = {2'b00, pc[13:8]};"""),
# La peticion registrada tiene que durar UN ciclo. Se muta la ESCRITURA y no
# la lectura a proposito: una lectura pegada relee una direccion vieja y no
# deja rastro observable —seria un mutante equivalente—, mientras que una
# escritura pegada corrompe la memoria en cada ciclo.
("seq", SEQ, "sim-diff", "la escritura a memoria se queda pegada un ciclo de mas",
 """        next_dm_we    = 1'b0;""",
 """        next_dm_we    = dm_we_q;"""),
("seq", SEQ, "sim-diff", "la interrupción se atiende en mitad de una instrucción",
 "    wire irq_take = irq_req && sreg[SREG_I] && !irq_hold && (cyc == 2'd0);",
 "    wire irq_take = irq_req && sreg[SREG_I] && !irq_hold;"),
# ------------------------------------------------- integracion: el mapa de I/O
# La integracion era la unica parte del chip sin banco propio, y es donde ya
# habia aparecido un fallo. Estos mutantes son colocaciones equivocadas, no
# errores de logica: el periferico funciona, pero no esta donde debe.
("soc", SOC, "sim-soc", "dos puertos de E/S en la misma direccion",
 "axioma_gpio #(.IO_PIN(8'h06), .BITS(8'h7F)) gpio_c (",
 "axioma_gpio #(.IO_PIN(8'h03), .BITS(8'h7F)) gpio_c ("),
("soc", SOC, "sim-soc", "un puerto de E/S movido a una direccion libre",
 "axioma_gpio #(.IO_PIN(8'h09), .BITS(8'hFF)) gpio_d (",
 "axioma_gpio #(.IO_PIN(8'h0C), .BITS(8'hFF)) gpio_d ("),
("soc", GPIOR, "sim-soc", "GPIOR0 responde tambien en la direccion de al lado",
 "wire hit0 = (io_addr == A_GPIOR0);",
 "wire hit0 = (io_addr[7:1] == A_GPIOR0[7:1]);"),
("soc", TIMER0, "sim-soc", "TIMSK0 colocado una direccion mas alla",
 "localparam [7:0] A_TIMSK0 = 8'h4E;",
 "localparam [7:0] A_TIMSK0 = 8'h4F;"),
# LOS ANCHOS DE ESTA CONCATENACION SON EL MAPA DE VECTORES, y un bit de mas en
# cualquier campo convierte un vector en otro. El patron hay que reapuntarlo
# cada vez que el campo cambia -paso al meter el TWI, que partio el `5'b0` de
# arriba en tres trozos-, y la propia mutacion lo dice: «patron no encontrado».
("soc", SOC, "sim-diff", "el mapa de vectores se desplaza un bit",
 """                       3'b0,          // 23..21  comparador, EEPROM, ADC""",
 """                       4'b0,          // 23..21  comparador, EEPROM, ADC"""),
# ------------------------------------------------------- USART0 y el bus
# El mutante del bus es el mas importante del catalogo: reproduce un fallo que
# estuvo escondido desde la fase 1 y que rompia TODA lectura de periferico con
# LD o LDD, que es la unica forma de llegar a la I/O extendida.
("dbus", DBUS, "sim-diff", "el bus deja de registrar el dato del periferico",
 """            io_rdata_q <= (hit_io && io_sel) ? io_rdata : 8'h00;""",
 """            io_rdata_q <= io_rdata_q;"""),
("usart", USART, "sim-usart", "los bits salen con el mas significativo primero",
 """                            txd_q  <= tx_sh[0];
                            tx_par <= tx_par ^ tx_sh[0];
                            tx_sh  <= {1'b0, tx_sh[8:1]};""",
 """                            txd_q  <= tx_sh[8];
                            tx_par <= tx_par ^ tx_sh[8];
                            tx_sh  <= {tx_sh[7:0], 1'b0};"""),
("usart", USART, "sim-usart", "el receptor mira una sola muestra, sin votar",
 """    wire       rx_voto_ahora = (rx_vota[0] & rx_vota[1]) | (rx_vota[0] & rxd_s)
                             | (rx_vota[1] & rxd_s);""",
 """    wire       rx_voto_ahora = rxd_s;"""),
("usart", USART, "sim-usart", "el divisor no cuenta el +1 de la formula",
 """        else if (brg_tick)   brg <= ubrr;""",
 """        else if (brg_tick)   brg <= ubrr - 12'd1;"""),
("usart", USART, "sim-usart", "escribir UBRR0L ya no recarga el prescaler",
 """        else if (carga_brr)  brg <= {ubrr[11:8], io_wdata};""",
 """        else if (1'b0)       brg <= {ubrr[11:8], io_wdata};"""),
("usart", USART, "sim-usart", "la paridad impar arranca en cero",
 """                        tx_par      <= par_odd;      // impar arranca en 1""",
 """                        tx_par      <= 1'b0;"""),
("usart", USART, "sim-usart", "leer UDR0 deja de sacar del bufer (trampa 11)",
 """    wire       rx_pop = io_re && hit_udr && !rx_vacio;""",
 """    wire       rx_pop = 1'b0;"""),
("usart", USART, "sim-usart", "el bufer de recepcion se queda en un nivel",
 """    wire       rx_lleno = (rx_n == 2'd2);""",
 """    wire       rx_lleno = (rx_n >= 2'd1);"""),
# El patron llevaba `rx_voto_ahora` y dejo de encontrarse al cerrar la deuda D3:
# el voto por mayoria es del modo asincrono, y el motor de trama pasa a usar
# `rx_muestra`, que en sincrono es el pin. El catalogo se reapunta EN EL MISMO
# COMMIT que mueve el RTL, que es la regla.
("usart", USART, "sim-usart", "el error de trama no se registra",
 """                                rx_fifo0 <= {!rx_muestra, rx_upe,""",
 """                                rx_fifo0 <= {1'b0, rx_upe,"""),
# Este solo lo caza el banco de extremo a extremo: tb_usart mira el pin TXD
# directamente, sin pasar por la habilitacion, asi que un transmisor que nunca
# se adueña del pin le parece correcto. Al otro lado de un cable, en cambio, no
# sale nada.
("usart", USART, "sim-hello", "el transmisor nunca se adueña del pin",
 "assign txd_en = txen;", "assign txd_en = 1'b0;"),
# ------------------------------------------------- SPM y el opcode ilegal
# Los tres fallos que tenia SPM, y el que colgaria el nucleo con un opcode
# corrupto. Ninguno era visible antes: la cobertura demostro que NADIE
# ejecutaba estos caminos.
("spm", SEQ, "sim-robust", "SPM duplica un byte en vez de escribir R1:R0",
 """            pm_d_wdata = {rf_rr_data, rf_rd_data};      // R1:R0""",
 """            pm_d_wdata = {rf_rd_data, rf_rd_data};"""),
("spm", SEQ, "sim-robust", "SPM Z+ avanza un byte en vez de una palabra",
 """                rf_w16_data = rf_a16_rdata + 16'd2;""",
 """                rf_w16_data = rf_a16_rdata + 16'd1;"""),
("spm", SEQ, "sim-robust", "un opcode ilegal cuelga el nucleo",
 """        default: begin       // OPC_ILLEGAL: se trata como NOP y se señala fuera
            next_fpc = fpc + 14'd1;  next_pc = pc + 14'd1;  retire = 1'b1;""",
 """        default: begin       // OPC_ILLEGAL: se trata como NOP y se señala fuera
            next_fpc = fpc;  next_pc = pc;  retire = 1'b0;"""),
# ------------------------------------------------------- Timer1 de 16 bits
# La trampa numero 4 entera: el registro TEMP. simavr no lo modela, asi que
# estos SOLO los puede cazar el banco propio.
("timer1", TIMER1, "sim-timer1", "escribir el byte bajo ignora el TEMP",
 """                if (hit_cntl)  begin tcnt <= {temp, io_wdata}; tcnt_block <= 1'b1; end""",
 """                if (hit_cntl)  begin tcnt <= {8'h00, io_wdata}; tcnt_block <= 1'b1; end"""),
("timer1", TIMER1, "sim-timer1", "leer el byte bajo no captura el alto en TEMP",
 """                if (hit_cntl)  temp <= tcnt[15:8];""",
 """                if (hit_cntl)  temp <= temp;"""),
("timer1", TIMER1, "sim-timer1", "cada registro de 16 bits tiene su propio TEMP",
 """                if (hit_icrl)  temp <= icr[15:8];""",
 """                if (hit_icrl)  temp <= temp;"""),
("timer1", TIMER1, "sim-timer1", "el cancelador de ruido mira dos muestras, no cuatro",
 """    wire cuatro_altas = (icp_sync[3:0] == 4'b1111);""",
 """    wire cuatro_altas = (icp_sync[1:0] == 2'b11);"""),
("timer1", TIMER1, "sim-timer1", "la captura se dispara en el flanco contrario",
 """            if (icp_filtrado != icp_prev && (icp_filtrado == ices)) begin""",
 """            if (icp_filtrado != icp_prev && (icp_filtrado != ices)) begin"""),
("timer1", TIMER1, "sim-timer1", "fase y frecuencia correctas refresca OCR en TOP",
 """    wire ev_update = ck && (mode_pc   ? at_top :
                            mode_pfc  ? (dir_down && at_bottom) :
                            mode_fast ? at_top : 1'b0);""",
 """    wire ev_update = ck && (mode_pc   ? at_top :
                            mode_pfc  ? at_top :
                            mode_fast ? at_top : 1'b0);"""),
("timer1", TIMER1, "sim-timer1", "en CTC el desbordamiento se marca en TOP y no en MAX",
 """    wire ev_tov = ck && (cuenta_ad ? (dir_down && at_bottom) :
                         mode_fast ? at_top :
                                     at_max);""",
 """    wire ev_tov = ck && (cuenta_ad ? (dir_down && at_bottom) :
                         mode_fast ? at_top :
                                     at_top);"""),
("timer1", TIMER1, "sim-timer1", "la captura se lleva la cuenta ya incrementada",
 """                icr <= tcnt;""",
 """                icr <= tcnt_next;"""),
# DUDA LEGITIMA, resuelta como mutante en vez de por intuicion: si dos vectores
# del mismo periferico se intercambian y los dos estan habilitados, ¿lo ve
# alguien? El arnes le DICE a simavr que vector tomo el RTL, asi que simavr no
# puede desmentirlo mientras la habilitacion este puesta.
("soc", SOC, "sim-diff", "dos vectores del Timer1 intercambiados",
 """                       t1_ovf,        // 13      TIMER1_OVF
                       t1_compb,      // 12      TIMER1_COMPB""",
 """                       t1_compb,      // 13      TIMER1_OVF
                       t1_ovf,        // 12      TIMER1_COMPB"""),
# ------------------------------- la anulacion de pin por un periferico (D1)
("gpio", GPIO, "sim-hello", "el canal PWM no llega al pad",
 """    assign pad_out = (port_q & ~ovr_en) | (ovr_val & ovr_en);""",
 """    assign pad_out = port_q;"""),
# LOS DOS MECANISMOS DE ANULACION NO SE PUEDEN MEZCLAR. El de VALOR es el de los
# canales de comparacion y no toca la direccion: un analogWrite() sin pinMode()
# no saca nada, ni aqui ni en el chip. El de DIRECCION es el del SPI, y ese si.
("gpio", GPIO, "sim-gpio", "la anulacion de VALOR tambien fuerza la direccion",
 """    assign pad_oe  = (ddr_q & ~dir_ovr_en) | (dir_ovr_val & dir_ovr_en);""",
 """    assign pad_oe  = (ddr_q & ~dir_ovr_en) | (dir_ovr_val & dir_ovr_en) | ovr_en;"""),
("gpio", GPIO, "sim-gpio", "la anulacion de DIRECCION no hace nada",
 """    assign pad_oe  = (ddr_q & ~dir_ovr_en) | (dir_ovr_val & dir_ovr_en);""",
 """    assign pad_oe  = ddr_q;"""),
# Los tres canales salen con ciclos de trabajo DISTINTOS a proposito: 25 %,
# 75 % y 12,5 %. Por eso cruzar el mapa de pines se ve, y no hay que creerse
# que «algo saca forma de onda» en el pin correcto.
# El patron cambio al meter XCK en PD4, que ocupa el bit 4 de la anulacion del
# puerto D. Se reapunta EN EL MISMO COMMIT que mueve el RTL, que es la regla.
("soc", SOC, "sim-hello", "los dos canales del Timer0 salen por el pin del otro",
 """    wire [7:0] ovr_d_val = {1'b0, oc0a,    oc0b,    us_xck,     oc2b,
                            1'b0, us_txd,  1'b0};""",
 """    wire [7:0] ovr_d_val = {1'b0, oc0b,    oc0a,    us_xck,     oc2b,
                            1'b0, us_txd,  1'b0};"""),
# ----------------------------------------------------------- Timer2
# EL FALLO QUE HABRIA COMETIDO CUALQUIERA: copiar la tabla de CS del Timer0.
# El Timer2 tiene dos tomas mas y el orden esta corrido —CS=4 es clk/64, no
# clk/256—, asi que un temporizador copiado cuenta cuatro veces mas lento y
# ninguna otra cosa falla.
("timer2", TIMER2, "sim-timer2", "la tabla de CS es la del Timer0, sin /32 ni /128",
 """            3'd3:    ck = tk_32;
            3'd4:    ck = tk_64;
            3'd5:    ck = tk_128;
            3'd6:    ck = tk_256;
            default: ck = tk_1024;""",
 """            3'd3:    ck = tk_64;
            3'd4:    ck = tk_256;
            3'd5:    ck = tk_1024;
            3'd6:    ck = tk_256;
            default: ck = tk_1024;"""),
("timer2", TIMER2, "sim-timer2", "PSRASY no pone a cero el prescaler del Timer2",
 """        else if (presc_reset) pcnt <= 10'd0;""",
 """        else if (1'b0)        pcnt <= 10'd0;"""),
("timer2", TIMER2, "sim-timer2", "el modo asincrono sigue contando el reloj del sistema",
 """    wire src = as2_q ? tosc_rise : 1'b1;""",
 """    wire src = 1'b1;"""),
("timer2", TIMER2, "sim-timer2", "TOSC1 cuenta por nivel y no por flanco",
 """    wire tosc_rise = (tosc_sync[2:1] == 2'b01);""",
 """    wire tosc_rise = tosc_sync[2];"""),
("timer2", TIMER2, "sim-timer2", "ASSR se lee con los bits de ocupado a uno",
 """                      hit_assr  ? {1'b0, exclk_q, as2_q, 5'b00000} : 8'h00;""",
 """                      hit_assr  ? {1'b0, exclk_q, as2_q, 5'b11111} : 8'h00;"""),
# El motor es COMPARTIDO: este mutante tiene que morir en los DOS bancos. Se
# apunta al del Timer2 a proposito, para demostrar que ese banco ejercita el
# motor de verdad y no solo la carcasa.
("timer2", TIMER8, "sim-timer2", "el motor compartido pierde el doble bufer de OCRx",
 """            if (ev_update) begin
                ocra_act <= ocra_buf;
                ocrb_act <= ocrb_buf;
            end""",
 """            if (1'b0) begin
                ocra_act <= ocra_buf;
                ocrb_act <= ocrb_buf;
            end"""),
("timer2", SOC, "sim-diff", "dos vectores del Timer2 intercambiados",
 """                       t2_ovf,        // 9       TIMER2_OVF
                       t2_compb,      // 8       TIMER2_COMPB
                       t2_compa,      // 7       TIMER2_COMPA""",
 """                       t2_ovf,        // 9       TIMER2_OVF
                       t2_compa,      // 8       TIMER2_COMPB
                       t2_compb,      // 7       TIMER2_COMPA"""),
# ----------------------------------------------------------------- SPI
# LOS TRES PRIMEROS SON FALLOS QUE ESTUVIERON DE VERDAD EN EL RTL, y los tres
# los encontro el banco la primera vez que corrio. Se quedan para que no puedan
# volver.
("spi", SPI, "sim-spi", "el maestro mira MISO por el sincronizador de dos etapas",
 """    wire bit_in  = maestro ? miso_pin : mosi_s[2];""",
 """    wire bit_in  = maestro ? mosi_s[2] : mosi_s[2];"""),
("spi", SPI, "sim-spi", "el reloj del maestro no vuelve al reposo: se come medio periodo",
 """                if (!maestro || sck_q != cpol_q) begin
                    busy_q <= 1'b0;
                    spif_q <= 1'b1;
                end else begin
                    cerrando_q <= 1'b1;
                end""",
 """                begin
                    busy_q <= 1'b0;
                    spif_q <= 1'b1;
                end"""),
("spi", SPI, "sim-spi", "SPIF se levanta antes de terminar: el modismo de siempre da WCOL",
 """            if (cerrando_q && medio_periodo) begin
                busy_q     <= 1'b0;
                cerrando_q <= 1'b0;
                spif_q     <= 1'b1;
            end""",
 """            if (cerrando_q) begin
                busy_q     <= 1'b0;
                cerrando_q <= 1'b0;
                spif_q     <= 1'b1;
            end"""),
("spi", SPI, "sim-spi", "la colision de maestros ignora que SS sea salida (mata a Arduino)",
 """    wire colision_maestro = maestro && ss_bajo && !ss_es_salida;""",
 """    wire colision_maestro = maestro && ss_bajo;"""),
("spi", SPI, "sim-spi", "CPHA=0 no presenta el primer bit al cargar",
 """                    if (cpha_q) begin
                        tx_q  <= io_wdata;
                    end else begin""",
 """                    if (1'b1) begin
                        tx_q  <= io_wdata;
                    end else begin"""),
("spi", SPI, "sim-spi", "DORD no invierte el orden de los bits",
 """    wire       tx_msb  = dord_q ? tx_q[0] : tx_q[7];""",
 """    wire       tx_msb  = tx_q[7];"""),
("spi", SPI, "sim-spi", "la tabla de divisiones se corre una fila",
 """            2'd1: div_top = spi2x_q ? 7'd3  : 7'd7;    // /8  o /16""",
 """            2'd1: div_top = spi2x_q ? 7'd7  : 7'd15;"""),
("spi", SPI, "sim-spi", "SPI2X deja de doblar la velocidad",
 """            2'd0: div_top = spi2x_q ? 7'd0  : 7'd1;    // /2  o /4""",
 """            2'd0: div_top = 7'd1;"""),
("spi", SPI, "sim-spi", "escribir SPDR en marcha pisa la transferencia en vez de dar WCOL",
 """                if (busy_q) begin
                    // COLISION: no se carga nada y la transferencia sigue.
                    wcol_q <= 1'b1;
                end else begin""",
 """                if (1'b0) begin
                    wcol_q <= 1'b1;
                end else begin"""),
("spi", SPI, "sim-spi", "acceder a SPDR limpia SPIF sin haber leido SPSR (trampa 11)",
 """            if (spsr_leido && acc_spdr) begin""",
 """            if (acc_spdr) begin"""),
("spi", SOC, "sim-hello", "el SPI no se adueña de SCK: el reloj no sale al pin",
 """    wire [7:0] ovr_b_en  = {2'b0, spi_sck_oe,""",
 """    wire [7:0] ovr_b_en  = {2'b0, 1'b0,"""),
("spi", SPI, "sim-spi", "el esclavo conduce MISO aunque no este seleccionado",
 """    assign miso_oe  = esclavo && ss_bajo;   // sólo conduce si está seleccionado""",
 """    assign miso_oe  = esclavo;"""),
# Este solo lo caza el diferencial: el banco propio no sabe de vectores.
("spi", SOC, "sim-diff", "el vector del SPI apunta al de la USART",
 """                       sp_irq,        // 17      SPI_STC""",
 """                       1'b0,          // 17      SPI_STC"""),
# Y estos dos, el mapa de pines del SoC: quien manda en PB3 y quien fuerza la
# direccion. Los caza el banco del SPI solo si el SoC esta de por medio, asi
# que van contra el programa de co-simulacion.
# Lo caza sim-hello, que es el unico que MIRA EL PIN: el firmware manda tres
# bytes por MOSI en el arranque y el banco los decodifica con el reloj de SCK.
# El mutante ataca el MULTIPLEXOR DE VALOR y no el de habilitacion, y eso no es
# un detalle: con el Timer2 sacando PWM por OC2A, quitar `spi_mosi_oe` de la
# habilitacion no cambia nada -el pin sigue anulado por el temporizador- y el
# mutante seria EQUIVALENTE. Lo que de verdad decide quien manda en PB3 es esta
# linea, y la hoja de datos dice que con SPE puesto manda el SPI.
("spi", SOC, "sim-hello", "en PB3 manda OC2A y no MOSI, con el SPI encendido",
 """                            spi_mosi_oe ? spi_mosi : oc2a,""",
 """                            oc2a,"""),
# ------------------------------------------- interrupciones externas
("extint", EXTINT, "sim-extint", "el nivel bajo interrumpe con el pin alto",
 """    wire int0_nivel = (isc0 == 2'b00) & ~int0_now;""",
 """    wire int0_nivel = (isc0 == 2'b00) & int0_now;"""),
("extint", EXTINT, "sim-extint", "el nivel bajo deja bandera, como si fuera flanco",
 """    wire [1:0] eifr_vis = { eifr_q[1] & (isc1 != 2'b00),
                            eifr_q[0] & (isc0 != 2'b00) };""",
 """    wire [1:0] eifr_vis = eifr_q;"""),
("extint", EXTINT, "sim-extint", "los dos flancos de INT0 intercambiados",
 """    wire int0_ev = (isc0 == 2'b01) ? (int0_now != int0_ant) :
                   (isc0 == 2'b10) ? (~int0_now &  int0_ant) :
                   (isc0 == 2'b11) ? ( int0_now & ~int0_ant) : 1'b0;""",
 """    wire int0_ev = (isc0 == 2'b01) ? (int0_now != int0_ant) :
                   (isc0 == 2'b10) ? ( int0_now & ~int0_ant) :
                   (isc0 == 2'b11) ? (~int0_now &  int0_ant) : 1'b0;"""),
("extint", EXTINT, "sim-extint", "EIMSK filtra tambien la bandera, no solo el vector",
 """            if (int0_ev)                                    eifr_q[0] <= 1'b1;""",
 """            if (int0_ev && eimsk_q[0])                      eifr_q[0] <= 1'b1;"""),
("extint", EXTINT, "sim-extint", "PCMSK deja de filtrar: cualquier pin marca la bandera",
 """    wire pc0_ev = |((syn_b ^ prv_b) & pcmsk0_q);""",
 """    wire pc0_ev = |(syn_b ^ prv_b);"""),
("extint", EXTINT, "sim-extint", "PCINT compara el pin consigo mismo: nunca hay cambio",
 """    wire pc2_ev = |((syn_d ^ prv_d) & pcmsk2_q);""",
 """    wire pc2_ev = 1'b0;"""),
("extint", EXTINT, "sim-extint", "escribir un cero en EIFR tambien limpia la bandera",
 """            else if (ack_int0 ||
                     (io_we && hit_eifr && io_wdata[0]))    eifr_q[0] <= 1'b0;""",
 """            else if (ack_int0 || (io_we && hit_eifr))      eifr_q[0] <= 1'b0;"""),
("extint", EXTINT, "sim-extint", "PCMSK1 se queda con el bit de PC7, que no existe",
 """                if (hit_pcmsk1) pcmsk1_q <= io_wdata & 8'h7F;  // PC7 no existe""",
 """                if (hit_pcmsk1) pcmsk1_q <= io_wdata;"""),
("extint", EXTINT, "sim-extint", "el sincronizador desaparece: el flanco se ve un ciclo antes",
 """            syn_b <= pin_b;  syn_c <= pin_c;  syn_d <= pin_d;
            prv_b <= syn_b;  prv_c <= syn_c;  prv_d <= syn_d;""",
 """            syn_b <= pin_b;  syn_c <= pin_c;  syn_d <= pin_d;
            prv_b <= pin_b;  prv_c <= pin_c;  prv_d <= pin_d;"""),
# Este NO lo caza el banco propio -su modelo no sabe de vectores-, lo caza el
# diferencial: simavr salta a otro sitio.
("extint", SOC, "sim-diff", "INT0 e INT1 intercambiados en el mapa de vectores",
 """                       ei_pc2,        // 5       PCINT2
                       ei_pc1,        // 4       PCINT1
                       ei_pc0,        // 3       PCINT0
                       ei_int1,       // 2       INT1
                       ei_int0,       // 1       INT0""",
 """                       ei_pc2,        // 5       PCINT2
                       ei_pc1,        // 4       PCINT1
                       ei_pc0,        // 3       PCINT0
                       ei_int0,       // 2       INT1
                       ei_int1,       // 1       INT0"""),
("soc", SOC, "sim-hello", "OC2A se queda sin pad: el sexto canal PWM no sale",
 """                            spi_mosi_oe | oc2a_en,""",
 """                            spi_mosi_oe,"""),
# Se mutan los VALORES y no las habilitaciones: con los dos canales encendidos,
# intercambiar las habilitaciones no cambia nada -las dos valen uno- y el
# mutante seria EQUIVALENTE. Lo que distingue un pin de otro es que cada uno
# lleve SU ciclo de trabajo.
("soc", SOC, "sim-hello", "el canal OC1A se lleva el pin de OC1B",
 """                            oc1b, oc1a, 1'b0};""",
 """                            oc1a, oc1b, 1'b0};"""),
# ---------------------------------------------------------------- TWI
# Los cuatro primeros son fallos que ESTUVIERON en el RTL y que solo caza un
# bus de verdad: con un banco de ondas perfectas y un solo maestro, los cuatro
# pasan sin decir nada.
("twi", TWI, "sim-twi", "el arbitraje mira tambien el noveno bit transmitiendo",
 "                   & ((tx_byte & (bit_q <= 4'd7)) | (~tx_byte & (bit_q == 4'd8)));",
 "                   & (tx_byte | (bit_q == 4'd8));"),
("twi", TWI, "sim-twi", "tras perder el arbitraje se sigue conduciendo SDA",
 "                    if (bit_q <= 4'd7)          sda_drv_q <= perdido_q ? 1'b1 : sh_q[7];",
 "                    if (bit_q <= 4'd7)          sda_drv_q <= sh_q[7];"),
("twi", TWI, "sim-twi", "el START pedido es de flanco y no de nivel",
 "                if (twsta_q & ~twint_q) begin",
 "                if (arranca & n_twsta) begin"),
("twi", TWI, "sim-twi", "el limite de trama se decide por estado y no por el contador de bits",
 "                if (bit_q == 4'd0) begin",
 "                if ((est_q == S_BIT_CAE) & (bit_q == 4'd0)) begin"),
# Temporizacion: el semiperiodo tiene que salir de la formula de la hoja de
# datos, y eso solo se ve MIDIENDO el pin.
("twi", TWI, "sim-twi", "el prescaler de TWPS escala por dos en vez de por cuatro",
 "    wire [14:0] twbr_esc = {7'b0, twbr_q} << {twps_q, 1'b0};",
 "    wire [14:0] twbr_esc = {7'b0, twbr_q} << twps_q;"),
("twi", TWI, "sim-twi", "el semiperiodo pierde el termino fijo de la formula",
 "    wire [14:0] semiper  = twbr_esc + 15'd8;",
 "    wire [14:0] semiper  = twbr_esc + 15'd4;"),
("twi", TWI, "sim-twi", "el alto no arranca al soltar SCL: se cuenta un semiperiodo de mas",
 "                        div_q     <= semiper - 15'd1;   // arranca el ALTO",
 "                        div_q     <= semiper + 15'd1;"),
# Reconocimiento de direccion.
("twi", TWI, "sim-twi", "la mascara TWAMR se aplica sin negar: tapa lo que deberia comparar",
 "    wire dir_coincide = ((sh_q[7:1] ^ twar_q[7:1]) & ~twamr_q[7:1]) == 7'd0;",
 "    wire dir_coincide = ((sh_q[7:1] ^ twar_q[7:1]) & twamr_q[7:1]) == 7'd0;"),
("twi", TWI, "sim-twi", "la llamada general se atiende sin mirar TWGCE",
 "    wire es_gencall   = (sh_q[7:1] == 7'd0) & ~sh_q[0] & twar_q[0];",
 "    wire es_gencall   = (sh_q[7:1] == 7'd0) & ~sh_q[0];"),
# Efectos laterales de escritura.
("twi", TWI, "sim-twi", "TWWC se levanta al escribir TWDR en el momento correcto",
 "                    if (twint_q) twdr_q <= io_wdata;\n                    else         twwc_q <= 1'b1;",
 "                    if (!twint_q) twdr_q <= io_wdata;\n                    else         twwc_q <= 1'b1;"),
("twi", TWI, "sim-twi", "TWSTO no se autolimpia al ejecutar el STOP",
 "                    twsto_q   <= 1'b0;          // TWSTO se limpia solo al ejecutarlo",
 "                    twsto_q   <= twsto_q;"),
# Estado devuelto.
("twi", TWI, "sim-twi", "el estado de lectura sale de TWEA y no del ACK que se mando",
 "                            status_q <= ack_tx_q ? ST_MR_DAT_A : ST_MR_DAT_N;",
 "                            status_q <= ST_MR_DAT_A;"),
# Este mutante estuvo inyectado en la rama de S_IDLE del `case` y SOBREVIVIA,
# y lo que senalaba era una LOGICA REPARTIDA ENTRE DOS SITIOS: el `case` ponia
# el estado y el manejador global -que corre despues- ponia el registro de
# desplazamiento, asi que romper el del `case` no cambiaba nada. Ninguno de los
# dos era codigo muerto y ninguno de los dos bastaba solo; quitar el primero a
# ciegas rompio las cuatro fases de esclavo. Ahora la transicion entera vive en
# el manejador global, que es el unico que manda.
("twi", TWI, "sim-twi", "el esclavo no suelta SDA al recibir: la tira durante la direccion",
 "                        bit_q <= 4'd0;  sh_q <= 8'hFF;  addr_fase_q <= 1'b1;",
 "                        bit_q <= 4'd0;  sh_q <= 8'h00;  addr_fase_q <= 1'b1;"),
# EL FILTRO DE PICOS. Sin el, el sincronizador propaga el pulso de un ciclo y
# un flanco falso de SDA con SCL alto es un START o un STOP inventado. Con
# ondas limpias el mutante no se nota: lo caza la fase de ruido.
("twi", TWI, "sim-twi", "sin filtro de picos: el sincronizador propaga el pulso",
 "            if (scl_s1 == scl_s2) scl_f <= scl_s2;\n            if (sda_s1 == sda_s2) sda_f <= sda_s2;",
 "            scl_f <= scl_s2;\n            sda_f <= sda_s2;"),
("twi", TWI, "sim-twi", "el esclavo no suelta SCL al contestar: el bus se queda estirado",
 "                        // Siguiente byte del esclavo. Soltar SCL es lo que\n                        // TERMINA el estiramiento: el reloj vuelve a ser del\n                        // maestro en cuanto el programa contesta.\n                        scl_drv_q <= 1'b1;",
 "                        // Siguiente byte del esclavo."),
# El mutante «quitar la puerta de TWEN de las salidas» se probo y SOBREVIVIA,
# y al mirarlo resulto ser EQUIVALENTE: la escritura que baja TWEN suelta las
# dos lineas en el mismo ciclo, asi que no hay forma de distinguirlo desde
# fuera. Esta anotado en el RTL para que nadie lo quite creyendo que sobra.
# Lo que si es observable es que apagar el TWI no lo devuelva a reposo.
("twi", TWI, "sim-twi", "apagar TWEN no devuelve el TWI a reposo: reanuda la trama vieja",
 "                    if (!io_wdata[2]) begin   // TWEN=0: el TWI suelta los pines\n                        est_q <= S_IDLE;",
 "                    if (!io_wdata[2]) begin   // TWEN=0: el TWI suelta los pines\n                        est_q <= est_q;"),
# Semantica de registros (nivel L2). Los bits de solo lectura y los que no
# existen son de lo que nadie se acuerda hasta que un programa escribe un
# registro entero con `|=` y se lleva por delante el estado del bus.
("twi", TWI, "sim-twi", "TWSR deja que se escriba el codigo de estado",
 "                if (hit_twsr)  twps_q  <= io_wdata[1:0];   // TWS7..3 son de solo lectura",
 "                if (hit_twsr)  begin twps_q <= io_wdata[1:0]; status_q <= io_wdata[7:3]; end"),
("twi", TWI, "sim-twi", "el bit 2 de TWSR, que no existe, devuelve algo",
 "                      hit_twsr  ? {status_q, 1'b0, twps_q} :",
 "                      hit_twsr  ? {status_q, twps_q[1], twps_q} :"),
("twi", TWI, "sim-twi", "TWAMR se queda con un bit 0 que no existe",
 "                if (hit_twamr) twamr_q <= io_wdata & 8'hFE; // el bit 0 no existe",
 "                if (hit_twamr) twamr_q <= io_wdata;"),
# ------------------------------------------- USART: modo sincrono y MPCM
# Ninguno de estos da error contra un banco asincrono: los ocho pasan la
# regresion entera de la USART tal como estaba antes de cerrar la deuda D3.
("usart", USART, "sim-usart", "UCPOL no invierte el pin: los dos flancos cambian de papel",
 "    assign xck_out = xck_gen ^ ucpol;",
 "    assign xck_out = xck_gen;"),
("usart", USART, "sim-usart", "el esclavo ignora UCPOL al leer el reloj",
 "    wire xck_i    = xck_maestro ? xck_gen : (xck_sync[1] ^ ucpol);",
 "    wire xck_i    = xck_maestro ? xck_gen : xck_sync[1];"),
("usart", USART, "sim-usart", "XCK conmuta sin mirar el generador: se va la frecuencia",
 "            if (xck_maestro && brg_tick && xck_corre) begin",
 "            if (xck_maestro && xck_corre) begin"),
("usart", USART, "sim-usart", "en sincrono se sigue sobremuestreando por dieciseis",
 "    wire [4:0] osr = reloj_xck ? 5'd1 : (u2x ? 5'd8 : 5'd16);  // muestras por bit",
 "    wire [4:0] osr = u2x ? 5'd8 : 5'd16;"),
("usart", USART, "sim-usart", "en sincrono se vota con muestras viejas en vez de mirar el pin",
 """    wire       rx_muestra = mspim    ? rx_sync[0] :
                            sincrono ? rxd_s      : rx_voto_ahora;""",
 """    wire       rx_muestra = mspim    ? rx_sync[0] :
                            rx_voto_ahora;"""),
("usart", USART, "sim-usart", "el arranque sincrono gasta un periodo de XCK de mas",
 "                        rx_bit    <= sincrono ? 4'd1 : 4'd0;",
 "                        rx_bit    <= 4'd0;"),
("usart", USART, "sim-usart", "MPCM no descarta las tramas de datos",
 "                        if (mpcm && !es_direccion) begin",
 "                        if (1'b0 && !es_direccion) begin"),
("usart", USART, "sim-usart", "MPCM busca el tipo de trama siempre en el bit de parada",
 "    wire       es_direccion = (databits_ef == 4'd9) ? rx_sh[8] : rx_muestra;",
 "    wire       es_direccion = rx_muestra;"),
# ------------------------------------------------- MSPIM, la USART como SPI
# NINGUNO DE ESTOS DA ERROR CONTRA UN SOLO MODO. Con los dos extremos
# equivocados de la misma manera la trama sale perfecta, que es la leccion que
# ya dejo UCPOL: por eso el esclavo del banco calcula sus flancos desde la tabla
# de la hoja de datos y no desde el DUT.
("usart", USART, "sim-usart", "XCK corre libre entre tramas, como en el sincrono",
 "    wire       xck_corre = sincrono | (mspim & tx_activo & (m_tog != 5'd16));",
 "    wire       xck_corre = sincrono | mspim;"),
("usart", USART, "sim-usart", "la trama de MSPIM dura un pulso de mas",
 "    wire m_fin = mspim & tx_activo & xck_baja & (m_tog == 5'd16);",
 "    wire m_fin = mspim & tx_activo & xck_baja & (m_tog == 5'd18);"),
("usart", USART, "sim-usart", "UDORD no se mira: siempre sale el bit 0 primero",
 "    wire [8:0] tx_carga = mspim ? {1'b0, (udord ? tx_lsb : tx_msb)} : tx_buf;",
 "    wire [8:0] tx_carga = mspim ? {1'b0, tx_lsb} : tx_buf;"),
("usart", USART, "sim-usart", "UDORD se mira al transmitir y no al recibir",
 """    wire [8:0] rx_guarda = mspim ? {1'b0, (udord ? rx_m_lsb : rx_m_msb)}
                                 : (rx_sh >> (4'd9 - databits_ef));""",
 """    wire [8:0] rx_guarda = mspim ? {1'b0, rx_m_lsb}
                                 : (rx_sh >> (4'd9 - databits_ef));"""),
("usart", USART, "sim-usart", "UCPHA no cambia el flanco de muestreo",
 """    wire tx_tick = !reloj_xck ? brg_tick : ((mspim & ucpha) ? xck_sube : xck_baja);
    wire rx_tick = !reloj_xck ? brg_tick : ((mspim & ucpha) ? xck_baja : xck_sube);""",
 """    wire tx_tick = !reloj_xck ? brg_tick : xck_baja;
    wire rx_tick = !reloj_xck ? brg_tick : xck_sube;"""),
("usart", USART, "sim-usart", "con UCPHA=0 el primer bit no se adelanta al primer flanco",
 "    wire       m_ya      = mspim & ~ucpha;                 // adelanta el bit 1",
 "    wire       m_ya      = 1'b0;"),
# EL DATO A TRAVES DEL SINCRONIZADOR DE TRES ETAPAS: a UBRR=0 son bit y medio de
# retraso. Sobrevive a cualquier banco que solo pruebe velocidades comodas, y
# por eso la fase de MSPIM barre UBRR=0 y 1.
("usart", USART, "sim-usart", "MSPIM muestrea el dato por el sincronizador entero",
 """    wire       rx_muestra = mspim    ? rx_sync[0] :
                            sincrono ? rxd_s      : rx_voto_ahora;""",
 """    wire       rx_muestra = mspim    ? rx_sync[2] :
                            sincrono ? rxd_s      : rx_voto_ahora;"""),
("usart", USART, "sim-usart", "XCK no vuelve a su reposo entre tramas",
 "            if (mspim && !tx_activo) xck_gen <= 1'b0;",
 "            if (1'b0 && !tx_activo) xck_gen <= 1'b0;"),
("usart", USART, "sim-usart", "MSPIM arranca sin DDR_XCK0 y pierde el byte en silencio",
 "    wire m_arranca = mspim & txen & xck_maestro & ~tx_activo & tx_buf_full;",
 "    wire m_arranca = mspim & txen & ~tx_activo & tx_buf_full;"),
("usart", USART, "sim-usart", "la trama de MSPIM no vacia el bufer y se repite sola",
 """                tx_sh       <= tx_sh_ini;
                tx_buf_full <= 1'b0;""",
 """                tx_sh       <= tx_sh_ini;
                tx_buf_full <= tx_buf_full;"""),
("usart", USART, "sim-usart", "MSPIM cuenta los bits de datos de UCSZ en vez de ocho",
 "    wire [3:0] databits_ef = mspim ? 4'd8 : databits;",
 "    wire [3:0] databits_ef = databits;"),
("usart", USART, "sim-usart", "la ultima muestra de MSPIM guarda el byte sin ella",
 "                            if (rx_n == 2'd0) rx_fifo0 <= {2'b00, rx_guarda};",
 "                            if (rx_n == 2'd0) rx_fifo0 <= {2'b00, rx_sh};"),
# ------------------------------------------- PD0 y PD1: el puerto serie
# Los tres se ven SOLO en el pin, y solo porque `hello.c` deja PD0 como salida
# a proposito antes de encender la USART: un pin encaminado y un pin que resulta
# que vale lo mismo son indistinguibles si nadie mira la DIRECCION.
# --------------------------------------------- SDA y SCL, los pines del TWI
# El banco del TWI cuelga de un bus propio y no ve el SoC, asi que tampoco puede
# decir por que pines sale. Y `twi.S` en el diferencial TAMPOCO: ahi el pad se
# realimenta, y un lazo sobre si mismo se cree cualquier cosa —los dos mutantes
# de abajo SOBREVIVIAN a la regresion entera—. Lo que los mata es mirar la
# LINEA en `sim-hello`: un START es SDA bajando con SCL alta, y eso solo ocurre
# si SDA es PC4 y SCL es PC5.
("soc", SOC, "sim-hello", "SDA y SCL salen intercambiados del SoC",
 "    wire [7:0] dir_c_val = {2'b0, twi_scl_pull, twi_sda_pull, 4'b0};",
 "    wire [7:0] dir_c_val = {2'b0, twi_sda_pull, twi_scl_pull, 4'b0};"),
("soc", SOC, "sim-hello", "el TWI se aduenia de dos pines del puerto C que no son suyos",
 "    wire [7:0] ovr_c_en  = twi_en ? 8'b0011_0000 : 8'h00;",
 "    wire [7:0] ovr_c_en  = twi_en ? 8'b0000_1100 : 8'h00;"),
# ------------------------------------------------- XCK, el reloj de MSPIM
# EL BANCO DEL PERIFERICO NO VE EL SOC, asi que no puede decir por que pin sale
# XCK. Estos dos SOLO los caza `sim-hello`, y solo porque hello.c hace una
# transaccion MSPIM y el banco la decodifica del PIN: XCK en PD4, MOSI en PD1.
("soc", SOC, "sim-hello", "XCK no se aduenia de PD4: el pin se queda con PORTD",
 """    wire [7:0] ovr_d_en  = {1'b0, oc0a_en, oc0b_en, us_xck_ovr, oc2b_en,
                            1'b0, us_txen, 1'b0};""",
 """    wire [7:0] ovr_d_en  = {1'b0, oc0a_en, oc0b_en, 1'b0, oc2b_en,
                            1'b0, us_txen, 1'b0};"""),
("soc", SOC, "sim-hello", "el modo maestro mira el DDR de otro pin, no el de XCK",
 "        .xck_pin(pd_in[4]), .xck_es_salida(pd_oe[4]),",
 "        .xck_pin(pd_in[4]), .xck_es_salida(pd_oe[7]),"),
("soc", SOC, "sim-hello", "TXD no llega al pad: PD1 se queda con lo que diga PORTD",
 """    wire [7:0] ovr_d_en  = {1'b0, oc0a_en, oc0b_en, us_xck_ovr, oc2b_en,
                            1'b0, us_txen, 1'b0};""",
 """    wire [7:0] ovr_d_en  = {1'b0, oc0a_en, oc0b_en, us_xck_ovr, oc2b_en,
                            1'b0, 1'b0, 1'b0};"""),
("soc", SOC, "sim-hello", "TXEN no fuerza PD1 a salida: hace falta poner DDRD1",
 """    wire [7:0] dir_d_en  = {6'b0, us_txen, us_rxen};""",
 """    wire [7:0] dir_d_en  = {6'b0, 1'b0, us_rxen};"""),
("soc", SOC, "sim-hello", "RXEN no fuerza PD0 a entrada: el programa puede conducir su propia RXD",
 """    wire [7:0] dir_d_val = {6'b0, 1'b1,    1'b0};   // PD1 salida, PD0 entrada""",
 """    wire [7:0] dir_d_val = {6'b0, 1'b1,    1'b1};"""),
# ===================================================================== ADC
# EL MUTANTE QUE HAY QUE TENER: «el ADC de simavr». Su avr_adc.c entrega el
# valor de golpe y programa la interrupcion a prescale*11 ciclos. Si un mutante
# que se salta la aproximacion sobrevive, es que el banco mira el RESULTADO y no
# el PROCESO — y entonces el DAC y el comparador podrian estar dentro del RTL,
# que es justo lo que el ADR 0002 decidio que no.
("adc", ADC, "sim-adc", "el SAR acepta todos los bits: no hay aproximacion, hay 0x3FF",
 "                    if (adc_cmp) sar_q <= dac_prueba;",
 "                    sar_q <= dac_prueba;"),
("adc", ADC, "sim-adc", "el comparador se lee al reves",
 "                    if (adc_cmp) sar_q <= dac_prueba;",
 "                    if (!adc_cmp) sar_q <= dac_prueba;"),
("adc", ADC, "sim-adc", "el SAR prueba los bits de menos a mas peso",
 "                    peso <= peso - 4'd1;",
 "                    peso <= peso + 4'd1;"),
("adc", ADC, "sim-adc", "la conversion arranca sin esperar al reloj de ADC",
 "                    mitad <= 6'd1;      // este flanco YA es el primer medio ciclo",
 "                    mitad <= 6'd0;"),
("adc", ADC, "sim-adc", "una conversion normal dura 12 ciclos y no 13",
 "    wire [5:0] total    = primera ? 6'd50 : 6'd26;",
 "    wire [5:0] total    = primera ? 6'd50 : 6'd24;"),
("adc", ADC, "sim-adc", "la primera conversion no es la larga",
 "    wire [5:0] sh_en    = primera ? 6'd27 : 6'd3;",
 "    wire [5:0] sh_en    = 6'd3;"),
("adc", ADC, "sim-adc", "el S/H cierra un ciclo tarde: se muestrea otra tension",
 "    wire [5:0] sh_en    = primera ? 6'd27 : 6'd3;",
 "    wire [5:0] sh_en    = primera ? 6'd27 : 6'd5;"),
("adc", ADC, "sim-adc", "ADPS=0 divide por uno, que es la tabla mal copiada",
 "    wire [6:0] medio_div = (adps == 3'd0) ? 7'd1  :",
 "    wire [6:0] medio_div = (adps == 3'd0) ? 7'd64 :"),
("adc", ADC, "sim-adc", "leer ADCL no echa el cerrojo: se mezclan dos conversiones",
 "            if (lee_l)      cerrojo <= 1'b1;",
 "            if (1'b0)       cerrojo <= 1'b1;"),
("adc", ADC, "sim-adc", "el cerrojo no impide que el dato nuevo entre",
 "                    if (!cerrojo) dato <= resultado;",
 "                    dato <= resultado;"),
("adc", ADC, "sim-adc", "ADLAR no alinea a la izquierda",
 "    wire [15:0] alineado = adlar ? {dato, 6'd0} : {6'd0, dato};",
 "    wire [15:0] alineado = {6'd0, dato};"),
("adc", ADC, "sim-adc", "apagar el ADC no para la conversion en marcha",
 "            if (!aden) adsc <= 1'b0;",
 "            if (1'b0) adsc <= 1'b0;"),
("adc", ADC, "sim-adc", "escribir un cero en ADSC para la conversion",
 "                if (io_wdata[6]) adsc <= 1'b1;",
 "                adsc <= io_wdata[6];"),
("adc", ADC, "sim-adc", "ADIF no se limpia escribiendo un uno",
 "                if (io_wdata[4]) adif <= 1'b0;",
 "                if (1'b0) adif <= 1'b0;"),
("adc", ADC, "sim-adc", "DIDR0 no apaga el bufer de entrada digital",
 "    assign didr_dis     = {2'b00, didr};",
 "    assign didr_dis     = 8'h00;"),
]

GREEN, RED, YELLOW, DIM, NC = "\033[0;32m", "\033[0;31m", "\033[0;33m", "\033[2m", "\033[0m"


# EL PYTHON DE LA OSS CAD SUITE ENVENENA A SUS HIJOS. Su `py3bin/python3` se
# pone `PYTHONHOME` a sí mismo en el propio entorno del proceso, y esa variable
# la hereda todo lo que lance. El Makefile usa OTRO intérprete —el del venv del
# proyecto, que es el que tiene numpy—, y ese intérprete arrancado con un
# PYTHONHOME ajeno muere con «No module named 'encodings'».
#
# No se nota al ejecutar `make mutation`, porque entonces quien lanza este
# script ya es el python del venv. Se nota al ejecutarlo a mano como
# `python3 sim/mutation.py`, que es justo lo que dice el modo de empleo de
# arriba: la mutación acababa con «tras restaurar, sim-decode NO pasa» sin que
# hubiera nada roto.
ENTORNO = {k: v for k, v in os.environ.items() if k != "PYTHONHOME"}


def run(target, quiet=True):
    r = subprocess.run(["make", target], cwd=ROOT, capture_output=True, text=True,
                       env=ENTORNO)
    if not quiet and r.returncode != 0:
        # Un fallo TRAS restaurar no es un mutante detectado: es que algo va mal
        # de verdad. Sin la salida no hay por dónde empezar a mirar.
        print(f"    --- salida de `make {target}` ---")
        for linea in (r.stdout + r.stderr).strip().splitlines()[-25:]:
            print(f"    {linea}")
    return r.returncode == 0


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
    solo_patrones = "--patrones" in want
    want.discard("--patrones")
    cat = [c for c in CATALOG if not want or c[0] in want]
    if not cat:
        sys.exit(f"grupos disponibles: {sorted({c[0] for c in CATALOG})}")

    # ---------------------------------------- los patrones, ANTES de nada
    # QUE UN PATRON NO SE ENCUENTRE NO ES «DETECTADO»: es un mutante que no se
    # inyecta, o sea un agujero silencioso. Pasa cada vez que se mueve el RTL
    # —van cinco— y hasta ahora se descubria al final, ocho minutos despues.
    # Comprobarlo cuesta un segundo, asi que se hace primero y se para aqui.
    # Con `--patrones` se hace SOLO esto, que es lo que puede correr el trabajo
    # rapido de la CI en cada push.
    fuentes = {f: (ROOT / f).read_text(encoding="utf-8") for f in {c[1] for c in CATALOG}}
    perdidos = [(g, d) for g, f, _t, d, old, _n in CATALOG if old not in fuentes[f]]
    if perdidos:
        print(f"  {RED}{len(perdidos)} patrones no encontrados{NC} — el catálogo se ha "
              f"desincronizado del RTL:")
        for g, d in perdidos:
            print(f"    [{g}] {d}")
        print("\n  El catálogo se reapunta EN EL MISMO COMMIT que mueve el RTL.")
        return 1
    if solo_patrones:
        print(f"  {GREEN}los {len(CATALOG)} patrones del catálogo siguen en su sitio{NC}")
        return 0

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
    rotos = [t for t in sorted({c[2] for c in cat}) if not run(t, quiet=False)]
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
