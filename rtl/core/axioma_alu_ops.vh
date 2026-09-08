// AxiomaCore-328 - códigos de operación de la ALU
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 The AxiomaCore Project
//
// Estas son operaciones de la ALU, no instrucciones. Varias instrucciones AVR
// comparten operación y se distinguen fuera de la ALU:
//
//   SUBI, CPI  -> ALU_SUB      (CP/CPI no escriben el destino)
//   SBCI, CPC  -> ALU_SBC
//   ANDI, TST  -> ALU_AND      (TST = AND Rd,Rd)
//   ORI, SBR   -> ALU_OR
//   CLR        -> ALU_EOR      (CLR = EOR Rd,Rd)
//   LSL        -> ALU_ADD      (LSL = ADD Rd,Rd)
//   ROL        -> ALU_ADC      (ROL = ADC Rd,Rd)
//   CBR        -> ALU_AND      con el inmediato complementado
//   SER        -> ALU_MOV      con b = 0xFF

`ifndef AXIOMA_ALU_OPS_VH
`define AXIOMA_ALU_OPS_VH

// Cabecera de constantes compartida: cada módulo usa un subconjunto.
/* verilator lint_off UNUSEDPARAM */

localparam [4:0] ALU_ADD    = 5'd0;
localparam [4:0] ALU_ADC    = 5'd1;
localparam [4:0] ALU_SUB    = 5'd2;
localparam [4:0] ALU_SBC    = 5'd3;
localparam [4:0] ALU_AND    = 5'd4;
localparam [4:0] ALU_OR     = 5'd5;
localparam [4:0] ALU_EOR    = 5'd6;
localparam [4:0] ALU_COM    = 5'd7;
localparam [4:0] ALU_NEG    = 5'd8;
localparam [4:0] ALU_INC    = 5'd9;
localparam [4:0] ALU_DEC    = 5'd10;
localparam [4:0] ALU_LSR    = 5'd11;
localparam [4:0] ALU_ROR    = 5'd12;
localparam [4:0] ALU_ASR    = 5'd13;
localparam [4:0] ALU_SWAP   = 5'd14;
localparam [4:0] ALU_MOV    = 5'd15;   // pasa b sin tocar flags
localparam [4:0] ALU_ADIW   = 5'd16;
localparam [4:0] ALU_SBIW   = 5'd17;
localparam [4:0] ALU_MUL    = 5'd18;
localparam [4:0] ALU_MULS   = 5'd19;
localparam [4:0] ALU_MULSU  = 5'd20;
localparam [4:0] ALU_FMUL   = 5'd21;
localparam [4:0] ALU_FMULS  = 5'd22;
localparam [4:0] ALU_FMULSU = 5'd23;

localparam [4:0] ALU_NUM_OPS = 5'd24;

// Posiciones de los bits del SREG
localparam integer SREG_C = 0;
localparam integer SREG_Z = 1;
localparam integer SREG_N = 2;
localparam integer SREG_V = 3;
localparam integer SREG_S = 4;
localparam integer SREG_H = 5;
localparam integer SREG_T = 6;
localparam integer SREG_I = 7;

/* verilator lint_on UNUSEDPARAM */

`endif // AXIOMA_ALU_OPS_VH
