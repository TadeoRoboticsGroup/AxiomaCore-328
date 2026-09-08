// AxiomaCore-328 - clases de instrucción del decodificador
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 The AxiomaCore Project
//
// SIN GUARDA DE INCLUSIÓN: se incluye dentro del cuerpo de cada módulo y
// declara localparam, que tienen ámbito de módulo. Ver axioma_alu_ops.vh.
//
// El decodificador emite UNA clase, no un conjunto de banderas independientes.
// Una clase no puede ser incoherente consigo misma; doce banderas booleanas sí.

/* verilator lint_off UNUSEDPARAM */

localparam [5:0] OPC_ILLEGAL = 6'd0;   // codificación no válida en el ATmega328P
localparam [5:0] OPC_NOP     = 6'd1;

// Aritmética y lógica
localparam [5:0] OPC_ALU_RR  = 6'd2;   // ADD ADC SUB SBC AND OR EOR MOV CP CPC
localparam [5:0] OPC_ALU_RI  = 6'd3;   // SUBI SBCI ANDI ORI CPI LDI
localparam [5:0] OPC_ALU_1   = 6'd4;   // COM NEG SWAP INC DEC ASR LSR ROR
localparam [5:0] OPC_IW      = 6'd5;   // ADIW SBIW
localparam [5:0] OPC_MOVW    = 6'd6;
localparam [5:0] OPC_MUL     = 6'd7;   // MUL MULS MULSU FMUL FMULS FMULSU

// Memoria de datos
localparam [5:0] OPC_LD      = 6'd8;   // LD, LDD  (con modo de puntero)
localparam [5:0] OPC_ST      = 6'd9;   // ST, STD
localparam [5:0] OPC_LDS     = 6'd10;  // 32 bits
localparam [5:0] OPC_STS     = 6'd11;  // 32 bits
localparam [5:0] OPC_PUSH    = 6'd12;
localparam [5:0] OPC_POP     = 6'd13;

// Memoria de programa
localparam [5:0] OPC_LPM     = 6'd14;
localparam [5:0] OPC_SPM     = 6'd15;

// Espacio de I/O
localparam [5:0] OPC_IN      = 6'd16;
localparam [5:0] OPC_OUT     = 6'd17;
localparam [5:0] OPC_SBI     = 6'd18;
localparam [5:0] OPC_CBI     = 6'd19;

// Saltos condicionales de una instrucción
localparam [5:0] OPC_SBIC    = 6'd20;
localparam [5:0] OPC_SBIS    = 6'd21;
localparam [5:0] OPC_SBRC    = 6'd22;
localparam [5:0] OPC_SBRS    = 6'd23;
localparam [5:0] OPC_CPSE    = 6'd24;

// Bits del SREG
localparam [5:0] OPC_BLD     = 6'd25;
localparam [5:0] OPC_BST     = 6'd26;
localparam [5:0] OPC_BSET    = 6'd27;  // SEC SEZ SEN SEV SES SEH SET SEI
localparam [5:0] OPC_BCLR    = 6'd28;  // CLC CLZ CLN CLV CLS CLH CLT CLI

// Control de flujo
localparam [5:0] OPC_RJMP    = 6'd29;
localparam [5:0] OPC_RCALL   = 6'd30;
localparam [5:0] OPC_IJMP    = 6'd31;
localparam [5:0] OPC_ICALL   = 6'd32;
localparam [5:0] OPC_JMP     = 6'd33;  // 32 bits
localparam [5:0] OPC_CALL    = 6'd34;  // 32 bits
localparam [5:0] OPC_RET     = 6'd35;
localparam [5:0] OPC_RETI    = 6'd36;
localparam [5:0] OPC_BRANCH  = 6'd37;  // BRBS y BRBC, con sus 16 alias

// Control del sistema
localparam [5:0] OPC_SLEEP   = 6'd38;
localparam [5:0] OPC_WDR     = 6'd39;
localparam [5:0] OPC_BREAK   = 6'd40;

localparam [5:0] OPC_NUM     = 6'd41;

// Modos de puntero para LD y ST
localparam [1:0] PTR_NONE    = 2'd0;   // sin desplazamiento ni actualización
localparam [1:0] PTR_POSTINC = 2'd1;   // X+  Y+  Z+
localparam [1:0] PTR_PREDEC  = 2'd2;   // -X  -Y  -Z
localparam [1:0] PTR_DISP    = 2'd3;   // Y+q  Z+q

// Selección de puntero
localparam [1:0] PTR_X       = 2'd0;
localparam [1:0] PTR_Y       = 2'd1;
localparam [1:0] PTR_Z       = 2'd2;

/* verilator lint_on UNUSEDPARAM */
