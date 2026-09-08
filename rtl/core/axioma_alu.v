// AxiomaCore-328 - unidad aritmético-lógica
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 The AxiomaCore Project
//
// Combinacional pura. No tiene reloj ni estado.
//
// El multiplicador es único y compartido entre MUL, MULS, MULSU y las tres
// variantes fraccionales, con extensión de signo controlada por la operación.
// Sale por un puerto propio (`mul_result`) para que el camino crítico del
// resultado de 8 bits no lo atraviese: el secuenciador registra la
// multiplicación en su segundo ciclo.
//
// `sreg_mask` indica qué bits del SREG escribe esta operación. El módulo
// axioma_sreg aplica:  sreg <= (sreg & ~mask) | (sreg_out & mask)
// Eso resuelve limpiamente los casos en que un flag NO se toca: INC y DEC no
// afectan a C ni a H; SWAP y MOV no afectan a nada.

`default_nettype none

module axioma_alu (
    input  wire [4:0]  op,
    input  wire [7:0]  a,          // Rd
    input  wire [7:0]  b,          // Rr o inmediato
    input  wire [15:0] a16,        // Rd+1:Rd, para ADIW y SBIW
    input  wire [5:0]  k6,         // inmediato de 6 bits, para ADIW y SBIW
    input  wire [7:0]  sreg_in,    // I T H S V N Z C

    output reg  [7:0]  result,     // resultado de 8 bits
    output reg  [15:0] result16,   // resultado de 16 bits (ADIW, SBIW)
    output wire [15:0] mul_result, // R1:R0 de las multiplicaciones
    output reg  [7:0]  sreg_out,   // valores nuevos de los flags
    output reg  [7:0]  sreg_mask   // qué bits se escriben
);

`include "axioma_alu_ops.vh"

    // ------------------------------------------------------------ sumador
    // Un único sumador/restador de 9 bits da acarreo y préstamo directamente.
    wire carry_in  = (op == ALU_ADC) & sreg_in[SREG_C];
    wire borrow_in = (op == ALU_SBC) & sreg_in[SREG_C];

    wire [8:0] sum = {1'b0, a} + {1'b0, b} + {8'b0, carry_in};
    wire [8:0] dif = {1'b0, a} - {1'b0, b} - {8'b0, borrow_in};

    wire [7:0] r_add = sum[7:0];
    wire [7:0] r_sub = dif[7:0];

    // Medio acarreo (bit 3), según las expresiones del manual del ISA.
    wire h_add = (a[3] & b[3]) | (b[3] & ~r_add[3]) | (~r_add[3] & a[3]);
    wire h_sub = (~a[3] & b[3]) | (b[3] & r_sub[3]) | (r_sub[3] & ~a[3]);

    // Desbordamiento en complemento a dos.
    wire v_add = ( a[7] &  b[7] & ~r_add[7]) | (~a[7] & ~b[7] &  r_add[7]);
    wire v_sub = ( a[7] & ~b[7] & ~r_sub[7]) | (~a[7] &  b[7] &  r_sub[7]);

    // ------------------------------------------------------ 16 bits (IW)
    // ADIW y SBIW no usan el acarreo del sumador: su flag C lo define una
    // expresión sobre a16[15] y R15, así que 16 bits bastan.
    wire [15:0] r_adiw = a16 + {10'b0, k6};
    wire [15:0] r_sbiw = a16 - {10'b0, k6};

    // --------------------------------------------- multiplicador compartido
    wire a_signed = (op == ALU_MULS)  | (op == ALU_MULSU)
                  | (op == ALU_FMULS) | (op == ALU_FMULSU);
    wire b_signed = (op == ALU_MULS)  | (op == ALU_FMULS);

    wire signed [8:0]  mul_a = {a_signed & a[7], a};
    wire signed [8:0]  mul_b = {b_signed & b[7], b};
    wire signed [17:0] mul_p = mul_a * mul_b;
    wire        [15:0] mul_raw = mul_p[15:0];
    // El producto de dos operandos de 9 bits ocupa 18; R1:R0 sólo guarda los
    // 16 bajos y el flag C sale de mul_raw[15]. Los dos altos se descartan
    // a propósito.
    wire unused_mul_high = &{1'b0, mul_p[17:16]};

    wire mul_frac = (op == ALU_FMUL) | (op == ALU_FMULS) | (op == ALU_FMULSU);
    assign mul_result = mul_frac ? {mul_raw[14:0], 1'b0} : mul_raw;

    // ------------------------------------------------------- desplazamientos
    wire [7:0] r_lsr = {1'b0,            a[7:1]};
    wire [7:0] r_ror = {sreg_in[SREG_C], a[7:1]};
    wire [7:0] r_asr = {a[7],            a[7:1]};

    // ----------------------------------------------------------- máscaras
    localparam [7:0] M_NONE  = 8'b0000_0000;
    localparam [7:0] M_SVNZ  = 8'b0001_1110;  // S V N Z
    localparam [7:0] M_SVNZC = 8'b0001_1111;  // S V N Z C
    localparam [7:0] M_HSVNZC= 8'b0011_1111;  // H S V N Z C
    localparam [7:0] M_ZC    = 8'b0000_0011;  // Z C

    // ------------------------------------------------------------- núcleo
    // Un único bloque combinacional. Todas las salidas reciben valor por
    // defecto antes del case: sin defecto no hay latch, y un latch aquí es
    // exactamente el fallo que tenía la implementación anterior en flag_s.
    reg n, z, v, c, h;

    always @(*) begin
        result   = 8'h00;
        result16 = 16'h0000;
        sreg_mask = M_NONE;
        n = 1'b0;  z = 1'b0;  v = 1'b0;  c = 1'b0;  h = 1'b0;

        case (op)
        ALU_ADD, ALU_ADC: begin
            result = r_add;
            h = h_add;  v = v_add;  n = r_add[7];
            z = (r_add == 8'h00);   c = sum[8];
            sreg_mask = M_HSVNZC;
        end

        ALU_SUB: begin
            result = r_sub;
            h = h_sub;  v = v_sub;  n = r_sub[7];
            z = (r_sub == 8'h00);   c = dif[8];
            sreg_mask = M_HSVNZC;
        end

        ALU_SBC: begin
            result = r_sub;
            h = h_sub;  v = v_sub;  n = r_sub[7];
            // Z sólo se limpia, nunca se pone a 1: permite encadenar
            // comparaciones multibyte con CPC.
            z = (r_sub == 8'h00) & sreg_in[SREG_Z];
            c = dif[8];
            sreg_mask = M_HSVNZC;
        end

        ALU_AND: begin
            result = a & b;
            v = 1'b0;  n = result[7];  z = (result == 8'h00);
            sreg_mask = M_SVNZ;
        end

        ALU_OR: begin
            result = a | b;
            v = 1'b0;  n = result[7];  z = (result == 8'h00);
            sreg_mask = M_SVNZ;
        end

        ALU_EOR: begin
            result = a ^ b;
            v = 1'b0;  n = result[7];  z = (result == 8'h00);
            sreg_mask = M_SVNZ;
        end

        ALU_COM: begin
            result = ~a;
            v = 1'b0;  n = result[7];  z = (result == 8'h00);
            c = 1'b1;                       // COM siempre pone C
            sreg_mask = M_SVNZC;
        end

        ALU_NEG: begin
            result = 8'h00 - a;
            h = result[3] | ~a[3];
            v = (result == 8'h80);
            n = result[7];
            z = (result == 8'h00);
            c = (result != 8'h00);
            sreg_mask = M_HSVNZC;
        end

        ALU_INC: begin
            result = a + 8'd1;
            v = (result == 8'h80);          // desborda al pasar de 0x7F
            n = result[7];  z = (result == 8'h00);
            sreg_mask = M_SVNZ;             // C y H no se tocan
        end

        ALU_DEC: begin
            result = a - 8'd1;
            v = (result == 8'h7F);          // desborda al pasar de 0x80
            n = result[7];  z = (result == 8'h00);
            sreg_mask = M_SVNZ;             // C y H no se tocan
        end

        ALU_LSR: begin
            result = r_lsr;
            c = a[0];  n = 1'b0;  z = (r_lsr == 8'h00);
            v = n ^ c;
            sreg_mask = M_SVNZC;
        end

        ALU_ROR: begin
            result = r_ror;
            c = a[0];  n = r_ror[7];  z = (r_ror == 8'h00);
            v = n ^ c;
            sreg_mask = M_SVNZC;
        end

        ALU_ASR: begin
            result = r_asr;
            c = a[0];  n = r_asr[7];  z = (r_asr == 8'h00);
            v = n ^ c;
            sreg_mask = M_SVNZC;
        end

        ALU_SWAP: begin
            result = {a[3:0], a[7:4]};
            sreg_mask = M_NONE;             // SWAP no toca ningún flag
        end

        ALU_MOV: begin
            result = b;
            sreg_mask = M_NONE;
        end

        ALU_ADIW: begin
            result16 = r_adiw;
            v = ~a16[15] &  r_adiw[15];
            n =  r_adiw[15];
            z = (r_adiw == 16'h0000);
            c = ~r_adiw[15] & a16[15];
            sreg_mask = M_SVNZC;
        end

        ALU_SBIW: begin
            result16 = r_sbiw;
            v =  a16[15] & ~r_sbiw[15];
            n =  r_sbiw[15];
            z = (r_sbiw == 16'h0000);
            c =  r_sbiw[15] & ~a16[15];
            sreg_mask = M_SVNZC;
        end

        ALU_MUL, ALU_MULS, ALU_MULSU: begin
            c = mul_raw[15];
            z = (mul_raw == 16'h0000);
            sreg_mask = M_ZC;
        end

        ALU_FMUL, ALU_FMULS, ALU_FMULSU: begin
            c = mul_raw[15];                // el bit que se desplaza fuera
            z = (mul_result == 16'h0000);   // sobre el resultado ya desplazado
            sreg_mask = M_ZC;
        end

        default: begin
            result = a;
            sreg_mask = M_NONE;
        end
        endcase

        // S es siempre N xor V. No es un flag independiente.
        sreg_out = 8'h00;
        sreg_out[SREG_C] = c;
        sreg_out[SREG_Z] = z;
        sreg_out[SREG_N] = n;
        sreg_out[SREG_V] = v;
        sreg_out[SREG_S] = n ^ v;
        sreg_out[SREG_H] = h;
    end

endmodule

`default_nettype wire
