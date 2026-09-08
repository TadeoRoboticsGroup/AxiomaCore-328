// AxiomaCore-328 - registro de estado (SREG)
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 The AxiomaCore Project
//
//   bit 7  I  habilitación global de interrupciones
//   bit 6  T  bit de copia (BLD / BST)
//   bit 5  H  acarreo de medio byte
//   bit 4  S  signo. SIEMPRE N xor V; no es un flag independiente
//   bit 3  V  desbordamiento en complemento a dos
//   bit 2  N  negativo
//   bit 1  Z  cero
//   bit 0  C  acarreo
//
// La ALU entrega valores nuevos MÁS una máscara de qué bits escribe. Así se
// resuelven sin casos especiales las instrucciones que dejan flags intactos:
// INC y DEC no tocan C ni H, SWAP no toca nada.
//
// PRIORIDAD entre fuentes, de mayor a menor. En ejecución normal sólo una está
// activa a la vez; el orden fija el comportamiento si coincidieran.
//   1. irq_enter / irq_return   el hardware entra en una ISR o ejecuta RETI
//   2. wr_en                    OUT SREG,Rr  o  POP hacia SREG
//   3. bit_en                   BSET / BCLR  (SEI, CLC, SEV, ...)
//   4. t_en                     BST: copia un bit del registro a T
//   5. alu_we                   resultado de la ALU con su máscara

`default_nettype none

module axioma_sreg (
    input  wire       clk,
    input  wire       rst_n,

    input  wire       alu_we,        // la ALU escribe
    input  wire [7:0] alu_value,     // valores nuevos de los flags
    input  wire [7:0] alu_mask,      // qué bits escribe

    input  wire       wr_en,         // escritura directa de los 8 bits
    input  wire [7:0] wr_data,

    input  wire       bit_en,        // BSET / BCLR
    input  wire [2:0] bit_num,
    input  wire       bit_val,

    input  wire       t_en,          // BST
    input  wire       t_val,

    input  wire       irq_enter,     // entrada a ISR: limpia I
    input  wire       irq_return,    // RETI: pone I

    output wire [7:0] sreg
);

`include "axioma_alu_ops.vh"

    reg [7:0] q;
    assign sreg = q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q <= 8'h00;
        end else if (irq_enter) begin
            q[SREG_I] <= 1'b0;
        end else if (irq_return) begin
            q[SREG_I] <= 1'b1;
        end else if (wr_en) begin
            q <= wr_data;
        end else if (bit_en) begin
            q[bit_num] <= bit_val;
        end else if (t_en) begin
            q[SREG_T] <= t_val;
        end else if (alu_we) begin
            q <= (q & ~alu_mask) | (alu_value & alu_mask);
        end
    end

endmodule

`default_nettype wire
