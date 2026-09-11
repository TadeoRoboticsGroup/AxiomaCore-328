// AxiomaCore-328 - decodificador de instrucciones
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 The AxiomaCore Project
//
// Combinacional puro. Traduce una palabra de 16 bits a una CLASE de operación
// más sus operandos ya extraídos.
//
// Por qué una clase y no un conjunto de banderas: doce booleanos independientes
// pueden quedar en un estado incoherente (mem_read y mem_write a la vez, por
// ejemplo) y nada lo impide. Una clase, no.
//
// `is_32bit` es la salida más delicada del módulo. La usa el secuenciador para
// dos cosas distintas:
//   - saber que hay que traer una segunda palabra (LDS, STS, JMP, CALL);
//   - decidir cuánto avanza el PC al SALTAR una instrucción, porque
//     CPSE/SBRC/SBRS/SBIC/SBIS se saltan una o DOS palabras según el tamaño de
//     la instrucción siguiente. Por eso el secuenciador instancia un segundo
//     decodificador que mira la palabra prefetchada.

`default_nettype none

module axioma_decode (
    input  wire [15:0] insn,

    output reg  [5:0]  op_class,
    output reg  [4:0]  alu_op,

    // Operandos de registro
    output reg  [4:0]  rd,          // destino, o primer fuente
    output reg  [4:0]  rr,          // segundo fuente
    output reg         rd_we,       // escribe rd
    output reg         rd_we16,     // escribe el par rd+1:rd
    output reg         use_imm,     // el segundo operando es inmediato
    output reg  [7:0]  imm,

    // Memoria de datos
    output reg  [1:0]  ptr_sel,     // X / Y / Z
    output reg  [1:0]  ptr_mode,    // ninguno / post-inc / pre-dec / desplazamiento
    output reg  [5:0]  disp,        // q de LDD y STD

    // Espacio de I/O y bits
    output reg  [5:0]  io_addr,
    output reg  [2:0]  bit_num,

    // Control de flujo
    output reg  [11:0] rel_addr,    // k de RJMP y RCALL, o de BRxx con signo extendido
    output reg  [2:0]  cond_bit,    // s de BRBS y BRBC
    output reg         cond_set,    // 1 = saltar si el bit del SREG está puesto

    // Información estructural
    output reg         is_32bit,
    output reg         illegal
);

`include "axioma_alu_ops.vh"
`include "axioma_decode_ops.vh"

    // ------------------------------------------------- extracción de campos
    wire [4:0] f_rd5   = insn[8:4];                  // formato .... ..rd dddd rrrr
    wire [4:0] f_rr5   = {insn[9], insn[3:0]};
    wire [4:0] f_rd_hi = {1'b1, insn[7:4]};          // R16..R31, formatos con inmediato
    wire [4:0] f_rr_hi = {1'b1, insn[3:0]};
    wire [4:0] f_rd_lo = {2'b10, insn[6:4]};         // R16..R23, MULSU y FMUL*
    wire [4:0] f_rr_lo = {2'b10, insn[2:0]};
    wire [7:0] f_k8    = {insn[11:8], insn[3:0]};    // inmediato de 8 bits
    wire [5:0] f_k6    = {insn[7:6], insn[3:0]};     // K de ADIW y SBIW
    wire [4:0] f_adiw  = {2'b11, insn[5:4], 1'b0};   // R24, R26, R28, R30
    wire [4:0] f_movw_d= {insn[7:4], 1'b0};          // pares
    wire [4:0] f_movw_r= {insn[3:0], 1'b0};
    wire [5:0] f_ioa6  = {insn[10:9], insn[3:0]};    // A de IN y OUT
    wire [5:0] f_ioa5  = {1'b0, insn[7:3]};          // A de SBI, CBI, SBIC, SBIS
    wire [5:0] f_disp  = {insn[13], insn[11:10], insn[2:0]};  // q de LDD y STD
    wire [11:0] f_k12  = insn[11:0];                 // RJMP y RCALL
    wire [11:0] f_k7   = {{5{insn[9]}}, insn[9:3]};  // BRxx, 7 bits con signo extendido

    always @(*) begin
        // Valores por defecto. Sin ellos habría cerrojos inferidos.
        op_class = OPC_ILLEGAL;
        alu_op   = ALU_MOV;
        rd       = 5'd0;
        rr       = 5'd0;
        rd_we    = 1'b0;
        rd_we16  = 1'b0;
        use_imm  = 1'b0;
        imm      = 8'h00;
        ptr_sel  = PTR_X;
        ptr_mode = PTR_NONE;
        disp     = 6'd0;
        io_addr  = 6'd0;
        bit_num  = 3'd0;
        rel_addr = 12'd0;
        cond_bit = 3'd0;
        cond_set = 1'b0;
        is_32bit = 1'b0;
        illegal  = 1'b0;

        casez (insn)
        // ------------------------------------------------------- 0000 ....
        16'b0000_0000_0000_0000: op_class = OPC_NOP;

        16'b0000_0001_????_????: begin                       // MOVW
            op_class = OPC_MOVW;  rd = f_movw_d;  rr = f_movw_r;  rd_we16 = 1'b1;
        end
        16'b0000_0010_????_????: begin                       // MULS
            op_class = OPC_MUL;  alu_op = ALU_MULS;  rd = f_rd_hi;  rr = f_rr_hi;
        end
        16'b0000_0011_0???_0???: begin                       // MULSU
            op_class = OPC_MUL;  alu_op = ALU_MULSU;  rd = f_rd_lo;  rr = f_rr_lo;
        end
        16'b0000_0011_0???_1???: begin                       // FMUL
            op_class = OPC_MUL;  alu_op = ALU_FMUL;  rd = f_rd_lo;  rr = f_rr_lo;
        end
        16'b0000_0011_1???_0???: begin                       // FMULS
            op_class = OPC_MUL;  alu_op = ALU_FMULS;  rd = f_rd_lo;  rr = f_rr_lo;
        end
        16'b0000_0011_1???_1???: begin                       // FMULSU
            op_class = OPC_MUL;  alu_op = ALU_FMULSU;  rd = f_rd_lo;  rr = f_rr_lo;
        end
        16'b0000_01??_????_????: begin                       // CPC: sin escritura
            op_class = OPC_ALU_RR;  alu_op = ALU_SBC;  rd = f_rd5;  rr = f_rr5;
        end
        16'b0000_10??_????_????: begin                       // SBC
            op_class = OPC_ALU_RR;  alu_op = ALU_SBC;  rd = f_rd5;  rr = f_rr5;  rd_we = 1'b1;
        end
        16'b0000_11??_????_????: begin                       // ADD  (LSL = ADD Rd,Rd)
            op_class = OPC_ALU_RR;  alu_op = ALU_ADD;  rd = f_rd5;  rr = f_rr5;  rd_we = 1'b1;
        end

        // ------------------------------------------------------- 0001 ....
        16'b0001_00??_????_????: begin                       // CPSE
            op_class = OPC_CPSE;  alu_op = ALU_SUB;  rd = f_rd5;  rr = f_rr5;
        end
        16'b0001_01??_????_????: begin                       // CP: sin escritura
            op_class = OPC_ALU_RR;  alu_op = ALU_SUB;  rd = f_rd5;  rr = f_rr5;
        end
        16'b0001_10??_????_????: begin                       // SUB
            op_class = OPC_ALU_RR;  alu_op = ALU_SUB;  rd = f_rd5;  rr = f_rr5;  rd_we = 1'b1;
        end
        16'b0001_11??_????_????: begin                       // ADC  (ROL = ADC Rd,Rd)
            op_class = OPC_ALU_RR;  alu_op = ALU_ADC;  rd = f_rd5;  rr = f_rr5;  rd_we = 1'b1;
        end

        // ------------------------------------------------------- 0010 ....
        16'b0010_00??_????_????: begin                       // AND  (TST = AND Rd,Rd)
            op_class = OPC_ALU_RR;  alu_op = ALU_AND;  rd = f_rd5;  rr = f_rr5;  rd_we = 1'b1;
        end
        16'b0010_01??_????_????: begin                       // EOR  (CLR = EOR Rd,Rd)
            op_class = OPC_ALU_RR;  alu_op = ALU_EOR;  rd = f_rd5;  rr = f_rr5;  rd_we = 1'b1;
        end
        16'b0010_10??_????_????: begin                       // OR
            op_class = OPC_ALU_RR;  alu_op = ALU_OR;   rd = f_rd5;  rr = f_rr5;  rd_we = 1'b1;
        end
        16'b0010_11??_????_????: begin                       // MOV
            op_class = OPC_ALU_RR;  alu_op = ALU_MOV;  rd = f_rd5;  rr = f_rr5;  rd_we = 1'b1;
        end

        // ---------------------------------------- inmediatos: 0011 a 0111
        16'b0011_????_????_????: begin                       // CPI: sin escritura
            op_class = OPC_ALU_RI;  alu_op = ALU_SUB;  rd = f_rd_hi;
            use_imm = 1'b1;  imm = f_k8;
        end
        16'b0100_????_????_????: begin                       // SBCI
            op_class = OPC_ALU_RI;  alu_op = ALU_SBC;  rd = f_rd_hi;
            use_imm = 1'b1;  imm = f_k8;  rd_we = 1'b1;
        end
        16'b0101_????_????_????: begin                       // SUBI
            op_class = OPC_ALU_RI;  alu_op = ALU_SUB;  rd = f_rd_hi;
            use_imm = 1'b1;  imm = f_k8;  rd_we = 1'b1;
        end
        16'b0110_????_????_????: begin                       // ORI  (SBR)
            op_class = OPC_ALU_RI;  alu_op = ALU_OR;   rd = f_rd_hi;
            use_imm = 1'b1;  imm = f_k8;  rd_we = 1'b1;
        end
        16'b0111_????_????_????: begin                       // ANDI (CBR: el ensamblador complementa K)
            op_class = OPC_ALU_RI;  alu_op = ALU_AND;  rd = f_rd_hi;
            use_imm = 1'b1;  imm = f_k8;  rd_we = 1'b1;
        end

        // ------------------------------------------- LDD y STD con q (10q0..)
        16'b10?0_??0?_????_????: begin                       // LDD Rd, Y+q / Z+q  (q=0 -> LD)
            op_class = OPC_LD;   rd = f_rd5;  rd_we = 1'b1;
            ptr_sel  = insn[3] ? PTR_Y : PTR_Z;
            ptr_mode = PTR_DISP;  disp = f_disp;
        end
        16'b10?0_??1?_????_????: begin                       // STD Y+q / Z+q, Rr
            op_class = OPC_ST;   rr = f_rd5;
            ptr_sel  = insn[3] ? PTR_Y : PTR_Z;
            ptr_mode = PTR_DISP;  disp = f_disp;
        end

        // ------------------------------------------------------- 1001 000.
        16'b1001_000?_????_0000: begin op_class = OPC_LDS;  rd = f_rd5; rd_we = 1'b1; is_32bit = 1'b1; end
        16'b1001_000?_????_0001: begin op_class = OPC_LD;   rd = f_rd5; rd_we = 1'b1; ptr_sel = PTR_Z; ptr_mode = PTR_POSTINC; end
        16'b1001_000?_????_0010: begin op_class = OPC_LD;   rd = f_rd5; rd_we = 1'b1; ptr_sel = PTR_Z; ptr_mode = PTR_PREDEC;  end
        16'b1001_000?_????_0100: begin op_class = OPC_LPM;  rd = f_rd5; rd_we = 1'b1; ptr_sel = PTR_Z; end
        16'b1001_000?_????_0101: begin op_class = OPC_LPM;  rd = f_rd5; rd_we = 1'b1; ptr_sel = PTR_Z; ptr_mode = PTR_POSTINC; end
        16'b1001_000?_????_1001: begin op_class = OPC_LD;   rd = f_rd5; rd_we = 1'b1; ptr_sel = PTR_Y; ptr_mode = PTR_POSTINC; end
        16'b1001_000?_????_1010: begin op_class = OPC_LD;   rd = f_rd5; rd_we = 1'b1; ptr_sel = PTR_Y; ptr_mode = PTR_PREDEC;  end
        16'b1001_000?_????_1100: begin op_class = OPC_LD;   rd = f_rd5; rd_we = 1'b1; ptr_sel = PTR_X; end
        16'b1001_000?_????_1101: begin op_class = OPC_LD;   rd = f_rd5; rd_we = 1'b1; ptr_sel = PTR_X; ptr_mode = PTR_POSTINC; end
        16'b1001_000?_????_1110: begin op_class = OPC_LD;   rd = f_rd5; rd_we = 1'b1; ptr_sel = PTR_X; ptr_mode = PTR_PREDEC;  end
        16'b1001_000?_????_1111: begin op_class = OPC_POP;  rd = f_rd5; rd_we = 1'b1; end

        // ------------------------------------------------------- 1001 001.
        16'b1001_001?_????_0000: begin op_class = OPC_STS;  rr = f_rd5; is_32bit = 1'b1; end
        16'b1001_001?_????_0001: begin op_class = OPC_ST;   rr = f_rd5; ptr_sel = PTR_Z; ptr_mode = PTR_POSTINC; end
        16'b1001_001?_????_0010: begin op_class = OPC_ST;   rr = f_rd5; ptr_sel = PTR_Z; ptr_mode = PTR_PREDEC;  end
        16'b1001_001?_????_1001: begin op_class = OPC_ST;   rr = f_rd5; ptr_sel = PTR_Y; ptr_mode = PTR_POSTINC; end
        16'b1001_001?_????_1010: begin op_class = OPC_ST;   rr = f_rd5; ptr_sel = PTR_Y; ptr_mode = PTR_PREDEC;  end
        16'b1001_001?_????_1100: begin op_class = OPC_ST;   rr = f_rd5; ptr_sel = PTR_X; end
        16'b1001_001?_????_1101: begin op_class = OPC_ST;   rr = f_rd5; ptr_sel = PTR_X; ptr_mode = PTR_POSTINC; end
        16'b1001_001?_????_1110: begin op_class = OPC_ST;   rr = f_rd5; ptr_sel = PTR_X; ptr_mode = PTR_PREDEC;  end
        16'b1001_001?_????_1111: begin op_class = OPC_PUSH; rr = f_rd5; end

        // ------------------------ 1001 0101 .... 1000 : sistema (antes que 1 operando)
        16'b1001_0101_0000_1000: op_class = OPC_RET;
        16'b1001_0101_0001_1000: op_class = OPC_RETI;
        16'b1001_0101_1000_1000: op_class = OPC_SLEEP;
        16'b1001_0101_1001_1000: op_class = OPC_BREAK;
        16'b1001_0101_1010_1000: op_class = OPC_WDR;
        16'b1001_0101_1100_1000: begin op_class = OPC_LPM; rd = 5'd0; rd_we = 1'b1; ptr_sel = PTR_Z; end
        // SPM escribe la palabra R1:R0, así que necesita los DOS puertos de
        // lectura de 8 bits: el de 16 está ocupado leyendo Z para la dirección.
        16'b1001_0101_1110_1000: begin op_class = OPC_SPM; ptr_sel = PTR_Z;
                                       rd = 5'd0; rr = 5'd1; end
        // SPM Z+ (0x95F8). CUESTIÓN ABIERTA: no he podido confirmar con las
        // herramientas locales si el ATmega328P lo implementa. binutils lo
        // decodifica en TODAS las arquitecturas, incluso avr2, así que no es
        // device-aware y no sirve de prueba; boot.h de avr-libc no lo usa para
        // el 328P. Se acepta porque un superset solo puede añadir
        // compatibilidad, nunca quitarla: un programa que lo use funcionará y
        // uno que no, queda igual. Pendiente de confirmar contra la hoja de
        // datos; ver docs/01-arquitectura.md.
        16'b1001_0101_1111_1000: begin op_class = OPC_SPM; ptr_sel = PTR_Z;
                                       ptr_mode = PTR_POSTINC;
                                       rd = 5'd0; rr = 5'd1; end

        // ------------------------ 1001 0100 .sss 1000 : BSET y BCLR
        16'b1001_0100_0???_1000: begin op_class = OPC_BSET; bit_num = insn[6:4]; end
        16'b1001_0100_1???_1000: begin op_class = OPC_BCLR; bit_num = insn[6:4]; end

        // ------------------------ saltos indirectos
        16'b1001_0100_0000_1001: op_class = OPC_IJMP;
        16'b1001_0101_0000_1001: op_class = OPC_ICALL;

        // ------------------------ JMP y CALL, de 32 bits
        16'b1001_010?_????_110?: begin op_class = OPC_JMP;  is_32bit = 1'b1; end
        16'b1001_010?_????_111?: begin op_class = OPC_CALL; is_32bit = 1'b1; end

        // ------------------------ 1001 010d dddd .... : un operando
        16'b1001_010?_????_0000: begin op_class = OPC_ALU_1; alu_op = ALU_COM;  rd = f_rd5; rd_we = 1'b1; end
        16'b1001_010?_????_0001: begin op_class = OPC_ALU_1; alu_op = ALU_NEG;  rd = f_rd5; rd_we = 1'b1; end
        16'b1001_010?_????_0010: begin op_class = OPC_ALU_1; alu_op = ALU_SWAP; rd = f_rd5; rd_we = 1'b1; end
        16'b1001_010?_????_0011: begin op_class = OPC_ALU_1; alu_op = ALU_INC;  rd = f_rd5; rd_we = 1'b1; end
        16'b1001_010?_????_0101: begin op_class = OPC_ALU_1; alu_op = ALU_ASR;  rd = f_rd5; rd_we = 1'b1; end
        16'b1001_010?_????_0110: begin op_class = OPC_ALU_1; alu_op = ALU_LSR;  rd = f_rd5; rd_we = 1'b1; end
        16'b1001_010?_????_0111: begin op_class = OPC_ALU_1; alu_op = ALU_ROR;  rd = f_rd5; rd_we = 1'b1; end
        16'b1001_010?_????_1010: begin op_class = OPC_ALU_1; alu_op = ALU_DEC;  rd = f_rd5; rd_we = 1'b1; end

        // ------------------------ ADIW y SBIW
        16'b1001_0110_????_????: begin
            op_class = OPC_IW; alu_op = ALU_ADIW; rd = f_adiw; rd_we16 = 1'b1;
            use_imm = 1'b1; imm = {2'b00, f_k6};
        end
        16'b1001_0111_????_????: begin
            op_class = OPC_IW; alu_op = ALU_SBIW; rd = f_adiw; rd_we16 = 1'b1;
            use_imm = 1'b1; imm = {2'b00, f_k6};
        end

        // ------------------------ bits del espacio de I/O
        16'b1001_1000_????_????: begin op_class = OPC_CBI;  io_addr = f_ioa5; bit_num = insn[2:0]; end
        16'b1001_1001_????_????: begin op_class = OPC_SBIC; io_addr = f_ioa5; bit_num = insn[2:0]; end
        16'b1001_1010_????_????: begin op_class = OPC_SBI;  io_addr = f_ioa5; bit_num = insn[2:0]; end
        16'b1001_1011_????_????: begin op_class = OPC_SBIS; io_addr = f_ioa5; bit_num = insn[2:0]; end

        // ------------------------ MUL
        16'b1001_11??_????_????: begin
            op_class = OPC_MUL; alu_op = ALU_MUL; rd = f_rd5; rr = f_rr5;
        end

        // ------------------------ IN y OUT
        16'b1011_0???_????_????: begin op_class = OPC_IN;  rd = f_rd5; rd_we = 1'b1; io_addr = f_ioa6; end
        16'b1011_1???_????_????: begin op_class = OPC_OUT; rr = f_rd5; io_addr = f_ioa6; end

        // ------------------------ saltos relativos
        16'b1100_????_????_????: begin op_class = OPC_RJMP;  rel_addr = f_k12; end
        16'b1101_????_????_????: begin op_class = OPC_RCALL; rel_addr = f_k12; end

        // ------------------------ LDI  (SER Rd = LDI Rd, 0xFF)
        16'b1110_????_????_????: begin
            op_class = OPC_ALU_RI; alu_op = ALU_MOV; rd = f_rd_hi;
            use_imm = 1'b1; imm = f_k8; rd_we = 1'b1;
        end

        // ------------------------ ramas condicionales
        16'b1111_00??_????_????: begin                       // BRBS: saltar si el bit está puesto
            op_class = OPC_BRANCH; rel_addr = f_k7; cond_bit = insn[2:0]; cond_set = 1'b1;
        end
        16'b1111_01??_????_????: begin                       // BRBC: saltar si está limpio
            op_class = OPC_BRANCH; rel_addr = f_k7; cond_bit = insn[2:0]; cond_set = 1'b0;
        end

        // ------------------------ bits de registro
        16'b1111_100?_????_0???: begin op_class = OPC_BLD;  rd = f_rd5; rd_we = 1'b1; bit_num = insn[2:0]; end
        16'b1111_101?_????_0???: begin op_class = OPC_BST;  rd = f_rd5; bit_num = insn[2:0]; end
        16'b1111_110?_????_0???: begin op_class = OPC_SBRC; rr = f_rd5; bit_num = insn[2:0]; end
        16'b1111_111?_????_0???: begin op_class = OPC_SBRS; rr = f_rd5; bit_num = insn[2:0]; end

        default: begin
            op_class = OPC_ILLEGAL;
            illegal  = 1'b1;
        end
        endcase
    end

endmodule

`default_nettype wire
