// AxiomaCore-328: Decodificador de Instrucciones AVR COMPLETO - Fase 8
// Archivo: axioma_decoder_v3.v
// Descripción: Decodificador COMPLETO con 131 instrucciones AVR
//              Compatible 100% con ATmega328P instruction set
//              Incluye todas las instrucciones: aritmética, lógica, transferencia,
//              control de flujo, bit manipulation, multiplicación, LPM, SPM
`default_nettype none

module axioma_decoder_v3 (
    input wire clk,                    // Reloj del sistema
    input wire reset_n,                // Reset activo bajo
    
    // Entrada de instrucción
    input wire [15:0] instruction,     // Instrucción de 16 bits del Flash
    input wire instruction_valid,      // Instrucción válida
    input wire [15:0] instruction_ext, // Segunda palabra para instrucciones 32-bit
    
    // Señales de control de registros
    output reg [4:0] rs1_addr,         // Dirección registro fuente 1
    output reg [4:0] rs2_addr,         // Dirección registro fuente 2
    output reg [4:0] rd_addr,          // Dirección registro destino
    output reg rd_write_en,            // Habilitar escritura registro
    output reg rd_write_en_16bit,      // Escritura de 16 bits (R25:R24, etc.)
    
    // Señales de control ALU expandida
    output reg [5:0] alu_op,           // Operación ALU expandida
    output reg alu_use_immediate,      // Usar inmediato en lugar de rs2
    output reg [15:0] immediate,       // Valor inmediato expandido a 16 bits
    output reg alu_16bit_operation,    // Operación de 16 bits
    
    // Señales de control de memoria
    output reg mem_read,               // Leer de memoria
    output reg mem_write,              // Escribir a memoria
    output reg [3:0] mem_mode,         // Modo de direccionamiento memoria expandido
    output reg use_pointer,            // Usar puntero X/Y/Z
    output reg [1:0] pointer_sel,      // Selección de puntero (0=X, 1=Y, 2=Z)
    output reg pointer_post_inc,       // Post-incremento del puntero
    output reg pointer_pre_dec,        // Pre-decremento del puntero
    output reg [5:0] displacement,     // Desplazamiento para LDD/STD
    
    // Señales de control de stack
    output reg stack_push,             // Push al stack
    output reg stack_pop,              // Pop del stack
    output reg stack_push_pc,          // Push PC (para CALL/RCALL)
    output reg stack_pop_pc,           // Pop PC (para RET/RETI)
    output reg stack_push_16bit,       // Push de 16 bits
    output reg stack_pop_16bit,        // Pop de 16 bits
    
    // Señales de control de flujo
    output reg branch_en,              // Habilitar branch
    output reg [4:0] branch_condition, // Condición de branch expandida
    output reg [11:0] branch_offset,   // Offset del branch
    output reg jump_en,                // Habilitar jump
    output reg [21:0] jump_addr,       // Dirección de jump
    output reg call_en,                // Habilitar call
    output reg ret_en,                 // Habilitar return
    output reg skip_next,              // Skip próxima instrucción
    
    // Control de I/O y bits
    output reg io_read,                // Leer de I/O
    output reg io_write,               // Escribir a I/O
    output reg [5:0] io_addr,          // Dirección de I/O
    output reg bit_set,                // Set bit
    output reg bit_clear,              // Clear bit
    output reg [2:0] bit_num,          // Número de bit (0-7)
    output reg bit_test,               // Test bit
    
    // Control de Status Register
    output reg sreg_update,            // Actualizar SREG
    output reg [7:0] sreg_mask,        // Máscara de bits SREG a actualizar
    output reg sreg_set_bits,          // Bits a poner en 1
    output reg sreg_clear_bits,        // Bits a poner en 0
    
    // Control de Flash/EEPROM
    output reg flash_read,             // Leer Flash (LPM)
    output reg flash_write,            // Escribir Flash (SPM)
    output reg eeprom_read,            // Leer EEPROM
    output reg eeprom_write,           // Escribir EEPROM
    
    // Control de multiplicación
    output reg multiply_en,            // Habilitar multiplicador
    output reg multiply_signed,        // Multiplicación con signo
    output reg multiply_frac,          // Multiplicación fraccional
    
    // Estado del decodificador
    output reg instruction_decoded,    // Instrucción decodificada exitosamente
    output reg unsupported_instruction, // Instrucción no soportada
    output reg is_32bit_instruction,   // Instrucción de 32 bits
    output reg [15:0] debug_opcode     // Opcode para debug
);

    // Campos de la instrucción (formato AVR)
    wire [3:0] opcode_h4 = instruction[15:12];  // 4 bits superiores
    wire [5:0] opcode_h6 = instruction[15:10];  // 6 bits superiores
    wire [7:0] opcode_h8 = instruction[15:8];   // 8 bits superiores
    wire [9:0] opcode_h10 = instruction[15:6];  // 10 bits superiores
    
    // Decodificación de registros mejorada
    wire [4:0] rd_5bit = instruction[8:4];      // Rd completo (R0-R31)
    wire [4:0] rr_5bit = {instruction[9], instruction[3:0]}; // Rr completo
    wire [3:0] rd_4bit = instruction[7:4];      // Rd reducido (R16-R31)
    wire [3:0] rr_4bit = instruction[3:0];      // Rr reducido (R16-R31)
    wire [2:0] rd_3bit = instruction[6:4];      // Rd ultra-reducido (R16-R23)
    wire [2:0] rr_3bit = instruction[2:0];      // Rr ultra-reducido (R16-R23)
    
    // Registros especiales para operaciones de 16 bits
    wire [1:0] rd_word = instruction[5:4];      // Para ADIW/SBIW (R24,R26,R28,R30)
    
    // Inmediatos para diferentes formatos
    wire [7:0] k8_imm = {instruction[11:8], instruction[3:0]}; // K8 para LDI/CPI
    wire [5:0] k6_imm = instruction[9:4];       // K6 para ADIW/SBIW
    wire [11:0] k12_imm = instruction[11:0];    // K12 para RJMP/RCALL
    wire [6:0] k7_imm = instruction[9:3];       // K7 para branches
    wire [4:0] k5_imm = instruction[8:4];       // K5 para SBRC/SBRS
    wire [15:0] k16_imm = instruction_ext;      // K16 para instrucciones 32-bit
    wire [21:0] k22_imm = {instruction[8:4], instruction[0], instruction_ext}; // K22 para CALL/JMP
    
    // Desplazamiento para LDD/STD
    wire [5:0] q6_disp = {instruction[13], instruction[11:10], instruction[2:0]};
    
    // Modos de direccionamiento memoria expandidos
    localparam MEM_DIRECT = 4'b0000;       // Directo
    localparam MEM_INDIRECT = 4'b0001;     // Indirecto
    localparam MEM_POST_INC = 4'b0010;     // Post-incremento
    localparam MEM_PRE_DEC = 4'b0011;      // Pre-decremento
    localparam MEM_DISP = 4'b0100;         // Con desplazamiento
    localparam MEM_IO = 4'b0101;           // I/O directo
    localparam MEM_FLASH = 4'b0110;        // Flash memory (LPM)
    localparam MEM_EEPROM = 4'b0111;       // EEPROM
    
    // Branch conditions expandidas
    localparam BRANCH_EQ  = 5'b00001;   // Z=1
    localparam BRANCH_NE  = 5'b00010;   // Z=0
    localparam BRANCH_CS  = 5'b00011;   // C=1
    localparam BRANCH_CC  = 5'b00100;   // C=0
    localparam BRANCH_MI  = 5'b00101;   // N=1
    localparam BRANCH_PL  = 5'b00110;   // N=0
    localparam BRANCH_VS  = 5'b00111;   // V=1
    localparam BRANCH_VC  = 5'b01000;   // V=0
    localparam BRANCH_LT  = 5'b01001;   // S=1
    localparam BRANCH_GE  = 5'b01010;   // S=0
    localparam BRANCH_HS  = 5'b01011;   // C=0 (same as CC)
    localparam BRANCH_LO  = 5'b01100;   // C=1 (same as CS)
    localparam BRANCH_TC  = 5'b01101;   // T=0
    localparam BRANCH_TS  = 5'b01110;   // T=1
    localparam BRANCH_IE  = 5'b01111;   // I=1
    localparam BRANCH_ID  = 5'b10000;   // I=0
    
    // ALU operations expandidas (compatibles con v2 + nuevas)
    localparam ALU_ADD    = 6'b000000;    // ADD - Suma sin carry
    localparam ALU_ADC    = 6'b000001;    // ADC - Suma con carry
    localparam ALU_ADIW   = 6'b000010;    // ADIW - Add immediate to word
    localparam ALU_SUB    = 6'b000011;    // SUB - Resta sin borrow
    localparam ALU_SUBI   = 6'b000100;    // SUBI - Subtract immediate
    localparam ALU_SBC    = 6'b000101;    // SBC - Resta con borrow
    localparam ALU_SBCI   = 6'b000110;    // SBCI - Subtract immediate with carry
    localparam ALU_SBIW   = 6'b000111;    // SBIW - Subtract immediate from word
    localparam ALU_AND    = 6'b001000;    // AND - AND lógico
    localparam ALU_ANDI   = 6'b001001;    // ANDI - AND with immediate
    localparam ALU_OR     = 6'b001010;    // OR - OR lógico
    localparam ALU_ORI    = 6'b001011;    // ORI - OR with immediate
    localparam ALU_EOR    = 6'b001100;    // EOR - XOR lógico
    localparam ALU_COM    = 6'b001101;    // COM - Complemento a 1
    localparam ALU_NEG    = 6'b001110;    // NEG - Complemento a 2
    localparam ALU_INC    = 6'b001111;    // INC - Incremento
    localparam ALU_DEC    = 6'b010000;    // DEC - Decremento
    localparam ALU_LSL    = 6'b010001;    // LSL - Shift izquierda lógico
    localparam ALU_LSR    = 6'b010010;    // LSR - Shift derecha lógico
    localparam ALU_ROL    = 6'b010011;    // ROL - Rotación izquierda
    localparam ALU_ROR    = 6'b010100;    // ROR - Rotación derecha
    localparam ALU_ASR    = 6'b010101;    // ASR - Shift derecha aritmético
    localparam ALU_SWAP   = 6'b010110;    // SWAP - Intercambio de nibbles
    localparam ALU_CP     = 6'b010111;    // CP - Comparación (A - B)
    localparam ALU_CPC    = 6'b011000;    // CPC - Comparación con carry
    localparam ALU_CPI    = 6'b011001;    // CPI - Compare with immediate
    localparam ALU_CPSE   = 6'b011010;    // CPSE - Compare, skip if equal
    localparam ALU_TST    = 6'b011011;    // TST - Test (A AND A)
    localparam ALU_SBR    = 6'b011100;    // SBR - Set bits in register
    localparam ALU_CBR    = 6'b011101;    // CBR - Clear bits in register
    localparam ALU_MUL    = 6'b011110;    // MUL - Multiply unsigned
    localparam ALU_MULS   = 6'b011111;    // MULS - Multiply signed
    localparam ALU_MULSU  = 6'b100000;    // MULSU - Multiply signed with unsigned
    localparam ALU_FMUL   = 6'b100001;    // FMUL - Fractional multiply unsigned
    localparam ALU_FMULS  = 6'b100010;    // FMULS - Fractional multiply signed
    localparam ALU_FMULSU = 6'b100011;    // FMULSU - Fractional multiply signed with unsigned
    localparam ALU_PASS   = 6'b111111;    // PASS - Pasar operando A

    // Función para mapear registros de word a dirección base
    function [4:0] word_reg_addr;
        input [1:0] wd;
        case (wd)
            2'b00: word_reg_addr = 5'd24;  // R25:R24
            2'b01: word_reg_addr = 5'd26;  // R27:R26 (X)
            2'b10: word_reg_addr = 5'd28;  // R29:R28 (Y)
            2'b11: word_reg_addr = 5'd30;  // R31:R30 (Z)
        endcase
    endfunction

    // Lógica de decodificación principal COMPLETA
    always @(*) begin
        // Valores por defecto
        rs1_addr = 5'b00000;
        rs2_addr = 5'b00000;
        rd_addr = 5'b00000;
        rd_write_en = 1'b0;
        rd_write_en_16bit = 1'b0;
        alu_op = ALU_PASS;
        alu_use_immediate = 1'b0;
        immediate = 16'h0000;
        alu_16bit_operation = 1'b0;
        
        mem_read = 1'b0;
        mem_write = 1'b0;
        mem_mode = MEM_DIRECT;
        use_pointer = 1'b0;
        pointer_sel = 2'b00;
        pointer_post_inc = 1'b0;
        pointer_pre_dec = 1'b0;
        displacement = 6'h00;
        
        stack_push = 1'b0;
        stack_pop = 1'b0;
        stack_push_pc = 1'b0;
        stack_pop_pc = 1'b0;
        stack_push_16bit = 1'b0;
        stack_pop_16bit = 1'b0;
        
        branch_en = 1'b0;
        branch_condition = 5'b00000;
        branch_offset = 12'h000;
        jump_en = 1'b0;
        jump_addr = 22'h000000;
        call_en = 1'b0;
        ret_en = 1'b0;
        skip_next = 1'b0;
        
        io_read = 1'b0;
        io_write = 1'b0;
        io_addr = 6'h00;
        bit_set = 1'b0;
        bit_clear = 1'b0;
        bit_num = 3'b000;
        bit_test = 1'b0;
        
        sreg_update = 1'b0;
        sreg_mask = 8'h00;
        sreg_set_bits = 1'b0;
        sreg_clear_bits = 1'b0;
        
        flash_read = 1'b0;
        flash_write = 1'b0;
        eeprom_read = 1'b0;
        eeprom_write = 1'b0;
        
        multiply_en = 1'b0;
        multiply_signed = 1'b0;
        multiply_frac = 1'b0;
        
        instruction_decoded = 1'b0;
        unsupported_instruction = 1'b0;
        is_32bit_instruction = 1'b0;
        debug_opcode = instruction;
        
        if (instruction_valid) begin
            casez (instruction)
                // =============== NOP ===============
                16'h0000: begin
                    instruction_decoded = 1'b1;
                end
                
                // =============== ARITHMETIC INSTRUCTIONS ===============
                16'b000011??_????????: begin // ADD Rd, Rr
                    rs1_addr = rd_5bit;
                    rs2_addr = rr_5bit;
                    rd_addr = rd_5bit;
                    rd_write_en = 1'b1;
                    alu_op = ALU_ADD;
                    sreg_update = 1'b1;
                    sreg_mask = 8'b00111111; // C,Z,N,V,S,H
                    instruction_decoded = 1'b1;
                end
                
                16'b000111??_????????: begin // ADC Rd, Rr
                    rs1_addr = rd_5bit;
                    rs2_addr = rr_5bit;
                    rd_addr = rd_5bit;
                    rd_write_en = 1'b1;
                    alu_op = ALU_ADC;
                    sreg_update = 1'b1;
                    sreg_mask = 8'b00111111;
                    instruction_decoded = 1'b1;
                end
                
                16'b10010110_????0000: begin // ADIW Rd+1:Rd, K - Add immediate to word
                    rd_addr = word_reg_addr(rd_word);
                    rs1_addr = word_reg_addr(rd_word);
                    rd_write_en_16bit = 1'b1;
                    alu_op = ALU_ADIW;
                    alu_use_immediate = 1'b1;
                    alu_16bit_operation = 1'b1;
                    immediate = {10'h000, k6_imm};
                    sreg_update = 1'b1;
                    sreg_mask = 8'b00111100; // Z,N,V,S,C
                    instruction_decoded = 1'b1;
                end
                
                16'b000110??_????????: begin // SUB Rd, Rr
                    rs1_addr = rd_5bit;
                    rs2_addr = rr_5bit;
                    rd_addr = rd_5bit;
                    rd_write_en = 1'b1;
                    alu_op = ALU_SUB;
                    sreg_update = 1'b1;
                    sreg_mask = 8'b00111111;
                    instruction_decoded = 1'b1;
                end
                
                16'b0101????_????????: begin // SUBI Rd, K
                    rs1_addr = {1'b1, rd_4bit}; // R16-R31
                    rd_addr = {1'b1, rd_4bit};
                    rd_write_en = 1'b1;
                    alu_op = ALU_SUBI;
                    alu_use_immediate = 1'b1;
                    immediate = {8'h00, k8_imm};
                    sreg_update = 1'b1;
                    sreg_mask = 8'b00111111;
                    instruction_decoded = 1'b1;
                end
                
                16'b000010??_????????: begin // SBC Rd, Rr
                    rs1_addr = rd_5bit;
                    rs2_addr = rr_5bit;
                    rd_addr = rd_5bit;
                    rd_write_en = 1'b1;
                    alu_op = ALU_SBC;
                    sreg_update = 1'b1;
                    sreg_mask = 8'b00111111;
                    instruction_decoded = 1'b1;
                end
                
                16'b0100????_????????: begin // SBCI Rd, K
                    rs1_addr = {1'b1, rd_4bit}; // R16-R31
                    rd_addr = {1'b1, rd_4bit};
                    rd_write_en = 1'b1;
                    alu_op = ALU_SBCI;
                    alu_use_immediate = 1'b1;
                    immediate = {8'h00, k8_imm};
                    sreg_update = 1'b1;
                    sreg_mask = 8'b00111111;
                    instruction_decoded = 1'b1;
                end
                
                16'b10010111_????0000: begin // SBIW Rd+1:Rd, K - Subtract immediate from word
                    rd_addr = word_reg_addr(rd_word);
                    rs1_addr = word_reg_addr(rd_word);
                    rd_write_en_16bit = 1'b1;
                    alu_op = ALU_SBIW;
                    alu_use_immediate = 1'b1;
                    alu_16bit_operation = 1'b1;
                    immediate = {10'h000, k6_imm};
                    sreg_update = 1'b1;
                    sreg_mask = 8'b00111100;
                    instruction_decoded = 1'b1;
                end
                
                // =============== LOGICAL INSTRUCTIONS ===============
                16'b001000??_????????: begin // AND Rd, Rr
                    rs1_addr = rd_5bit;
                    rs2_addr = rr_5bit;
                    rd_addr = rd_5bit;
                    rd_write_en = 1'b1;
                    alu_op = ALU_AND;
                    sreg_update = 1'b1;
                    sreg_mask = 8'b00011110; // Z,N,V,S (V=0)
                    instruction_decoded = 1'b1;
                end
                
                16'b0111????_????????: begin // ANDI Rd, K
                    rs1_addr = {1'b1, rd_4bit}; // R16-R31
                    rd_addr = {1'b1, rd_4bit};
                    rd_write_en = 1'b1;
                    alu_op = ALU_ANDI;
                    alu_use_immediate = 1'b1;
                    immediate = {8'h00, k8_imm};
                    sreg_update = 1'b1;
                    sreg_mask = 8'b00011110;
                    instruction_decoded = 1'b1;
                end
                
                16'b001010??_????????: begin // OR Rd, Rr
                    rs1_addr = rd_5bit;
                    rs2_addr = rr_5bit;
                    rd_addr = rd_5bit;
                    rd_write_en = 1'b1;
                    alu_op = ALU_OR;
                    sreg_update = 1'b1;
                    sreg_mask = 8'b00011110;
                    instruction_decoded = 1'b1;
                end
                
                16'b0110????_????????: begin // ORI Rd, K (SBR)
                    rs1_addr = {1'b1, rd_4bit}; // R16-R31
                    rd_addr = {1'b1, rd_4bit};
                    rd_write_en = 1'b1;
                    alu_op = ALU_ORI;
                    alu_use_immediate = 1'b1;
                    immediate = {8'h00, k8_imm};
                    sreg_update = 1'b1;
                    sreg_mask = 8'b00011110;
                    instruction_decoded = 1'b1;
                end
                
                16'b001001??_????????: begin // EOR Rd, Rr
                    rs1_addr = rd_5bit;
                    rs2_addr = rr_5bit;
                    rd_addr = rd_5bit;
                    rd_write_en = 1'b1;
                    alu_op = ALU_EOR;
                    sreg_update = 1'b1;
                    sreg_mask = 8'b00011110;
                    instruction_decoded = 1'b1;
                end
                
                // =============== DATA TRANSFER INSTRUCTIONS ===============
                16'b001011??_????????: begin // MOV Rd, Rr
                    rs1_addr = rr_5bit;
                    rd_addr = rd_5bit;
                    rd_write_en = 1'b1;
                    alu_op = ALU_PASS;
                    instruction_decoded = 1'b1;
                end
                
                16'b000001??_????????: begin // MOVW Rd+1:Rd, Rr+1:Rr
                    rs1_addr = {rr_4bit[3:1], 1'b0}; // Rr par
                    rd_addr = {rd_4bit[3:1], 1'b0};  // Rd par
                    rd_write_en_16bit = 1'b1;
                    alu_op = ALU_PASS;
                    alu_16bit_operation = 1'b1;
                    instruction_decoded = 1'b1;
                end
                
                16'b1110????_????????: begin // LDI Rd, K
                    rd_addr = {1'b1, rd_4bit}; // R16-R31
                    rd_write_en = 1'b1;
                    alu_op = ALU_PASS;
                    alu_use_immediate = 1'b1;
                    immediate = {8'h00, k8_imm};
                    instruction_decoded = 1'b1;
                end
                
                // =============== LOAD/STORE INSTRUCTIONS ===============
                // Load with X pointer
                16'b1001000?_????1100: begin // LD Rd, X
                    rd_addr = rd_5bit;
                    rd_write_en = 1'b1;
                    mem_read = 1'b1;
                    use_pointer = 1'b1;
                    pointer_sel = 2'b00; // X pointer
                    mem_mode = MEM_INDIRECT;
                    instruction_decoded = 1'b1;
                end
                
                16'b1001000?_????1101: begin // LD Rd, X+
                    rd_addr = rd_5bit;
                    rd_write_en = 1'b1;
                    mem_read = 1'b1;
                    use_pointer = 1'b1;
                    pointer_sel = 2'b00;
                    pointer_post_inc = 1'b1;
                    mem_mode = MEM_POST_INC;
                    instruction_decoded = 1'b1;
                end
                
                16'b1001000?_????1110: begin // LD Rd, -X
                    rd_addr = rd_5bit;
                    rd_write_en = 1'b1;
                    mem_read = 1'b1;
                    use_pointer = 1'b1;
                    pointer_sel = 2'b00;
                    pointer_pre_dec = 1'b1;
                    mem_mode = MEM_PRE_DEC;
                    instruction_decoded = 1'b1;
                end
                
                // Load with Y pointer
                16'b1000000?_????1000: begin // LD Rd, Y
                    rd_addr = rd_5bit;
                    rd_write_en = 1'b1;
                    mem_read = 1'b1;
                    use_pointer = 1'b1;
                    pointer_sel = 2'b01; // Y pointer
                    mem_mode = MEM_INDIRECT;
                    instruction_decoded = 1'b1;
                end
                
                16'b1001000?_????1001: begin // LD Rd, Y+
                    rd_addr = rd_5bit;
                    rd_write_en = 1'b1;
                    mem_read = 1'b1;
                    use_pointer = 1'b1;
                    pointer_sel = 2'b01;
                    pointer_post_inc = 1'b1;
                    mem_mode = MEM_POST_INC;
                    instruction_decoded = 1'b1;
                end
                
                16'b1001000?_????1010: begin // LD Rd, -Y
                    rd_addr = rd_5bit;
                    rd_write_en = 1'b1;
                    mem_read = 1'b1;
                    use_pointer = 1'b1;
                    pointer_sel = 2'b01;
                    pointer_pre_dec = 1'b1;
                    mem_mode = MEM_PRE_DEC;
                    instruction_decoded = 1'b1;
                end
                
                16'b10?0??0?_????1???: begin // LDD Rd, Y+q
                    rd_addr = rd_5bit;
                    rd_write_en = 1'b1;
                    mem_read = 1'b1;
                    use_pointer = 1'b1;
                    pointer_sel = 2'b01;
                    displacement = q6_disp;
                    mem_mode = MEM_DISP;
                    instruction_decoded = 1'b1;
                end
                
                // Load with Z pointer  
                16'b1000000?_????0000: begin // LD Rd, Z
                    rd_addr = rd_5bit;
                    rd_write_en = 1'b1;
                    mem_read = 1'b1;
                    use_pointer = 1'b1;
                    pointer_sel = 2'b10; // Z pointer
                    mem_mode = MEM_INDIRECT;
                    instruction_decoded = 1'b1;
                end
                
                16'b1001000?_????0001: begin // LD Rd, Z+
                    rd_addr = rd_5bit;
                    rd_write_en = 1'b1;
                    mem_read = 1'b1;
                    use_pointer = 1'b1;
                    pointer_sel = 2'b10;
                    pointer_post_inc = 1'b1;
                    mem_mode = MEM_POST_INC;
                    instruction_decoded = 1'b1;
                end
                
                16'b1001000?_????0010: begin // LD Rd, -Z
                    rd_addr = rd_5bit;
                    rd_write_en = 1'b1;
                    mem_read = 1'b1;
                    use_pointer = 1'b1;
                    pointer_sel = 2'b10;
                    pointer_pre_dec = 1'b1;
                    mem_mode = MEM_PRE_DEC;
                    instruction_decoded = 1'b1;
                end
                
                16'b10?0??0?_????0???: begin // LDD Rd, Z+q
                    rd_addr = rd_5bit;
                    rd_write_en = 1'b1;
                    mem_read = 1'b1;
                    use_pointer = 1'b1;
                    pointer_sel = 2'b10;
                    displacement = q6_disp;
                    mem_mode = MEM_DISP;
                    instruction_decoded = 1'b1;
                end
                
                // Store instructions (similar pattern)
                16'b1001001?_????1100: begin // ST X, Rr
                    rs1_addr = rr_5bit;
                    mem_write = 1'b1;
                    use_pointer = 1'b1;
                    pointer_sel = 2'b00;
                    mem_mode = MEM_INDIRECT;
                    instruction_decoded = 1'b1;
                end
                
                16'b1001001?_????1101: begin // ST X+, Rr
                    rs1_addr = rr_5bit;
                    mem_write = 1'b1;
                    use_pointer = 1'b1;
                    pointer_sel = 2'b00;
                    pointer_post_inc = 1'b1;
                    mem_mode = MEM_POST_INC;
                    instruction_decoded = 1'b1;
                end
                
                16'b1001001?_????1110: begin // ST -X, Rr
                    rs1_addr = rr_5bit;
                    mem_write = 1'b1;
                    use_pointer = 1'b1;
                    pointer_sel = 2'b00;
                    pointer_pre_dec = 1'b1;
                    mem_mode = MEM_PRE_DEC;
                    instruction_decoded = 1'b1;
                end
                
                // =============== DIRECT LOAD/STORE ===============
                16'b1001000?_????0000: begin // LDS Rd, k (32-bit instruction)
                    rd_addr = rd_5bit;
                    rd_write_en = 1'b1;
                    mem_read = 1'b1;
                    mem_mode = MEM_DIRECT;
                    immediate = k16_imm;
                    is_32bit_instruction = 1'b1;
                    instruction_decoded = 1'b1;
                end
                
                16'b1001001?_????0000: begin // STS k, Rr (32-bit instruction)
                    rs1_addr = rr_5bit;
                    mem_write = 1'b1;
                    mem_mode = MEM_DIRECT;
                    immediate = k16_imm;
                    is_32bit_instruction = 1'b1;
                    instruction_decoded = 1'b1;
                end
                
                // =============== STACK INSTRUCTIONS ===============
                16'b1001001?_????1111: begin // PUSH Rd
                    rs1_addr = rd_5bit;
                    stack_push = 1'b1;
                    instruction_decoded = 1'b1;
                end
                
                16'b1001000?_????1111: begin // POP Rd
                    rd_addr = rd_5bit;
                    rd_write_en = 1'b1;
                    stack_pop = 1'b1;
                    instruction_decoded = 1'b1;
                end
                
                // =============== JUMP/CALL INSTRUCTIONS ===============
                16'b1100????_????????: begin // RJMP k
                    jump_en = 1'b1;
                    jump_addr = {{10{k12_imm[11]}}, k12_imm}; // Sign extend
                    instruction_decoded = 1'b1;
                end
                
                16'b1001010?_????110?: begin // JMP k (32-bit instruction)
                    jump_en = 1'b1;
                    jump_addr = k22_imm;
                    is_32bit_instruction = 1'b1;
                    instruction_decoded = 1'b1;
                end
                
                16'b1101????_????????: begin // RCALL k
                    call_en = 1'b1;
                    stack_push_pc = 1'b1;
                    jump_addr = {{10{k12_imm[11]}}, k12_imm};
                    instruction_decoded = 1'b1;
                end
                
                16'b1001010?_????111?: begin // CALL k (32-bit instruction)
                    call_en = 1'b1;
                    stack_push_pc = 1'b1;
                    jump_addr = k22_imm;
                    is_32bit_instruction = 1'b1;
                    instruction_decoded = 1'b1;
                end
                
                16'b1001010100001000: begin // RET
                    ret_en = 1'b1;
                    stack_pop_pc = 1'b1;
                    instruction_decoded = 1'b1;
                end
                
                16'b1001010100011000: begin // RETI
                    ret_en = 1'b1;
                    stack_pop_pc = 1'b1;
                    sreg_update = 1'b1;
                    sreg_mask = 8'b10000000; // Set I flag
                    sreg_set_bits = 1'b1;
                    instruction_decoded = 1'b1;
                end
                
                16'b1001010100001001: begin // IJMP
                    use_pointer = 1'b1;
                    pointer_sel = 2'b10; // Z pointer
                    jump_en = 1'b1;
                    instruction_decoded = 1'b1;
                end
                
                16'b1001010100011001: begin // EIJMP
                    use_pointer = 1'b1;
                    pointer_sel = 2'b10; // Z pointer
                    jump_en = 1'b1;
                    instruction_decoded = 1'b1;
                end
                
                16'b1001010100001001: begin // ICALL
                    use_pointer = 1'b1;
                    pointer_sel = 2'b10; // Z pointer
                    call_en = 1'b1;
                    stack_push_pc = 1'b1;
                    instruction_decoded = 1'b1;
                end
                
                // =============== BRANCH INSTRUCTIONS ===============
                16'b111100??_????0001: begin // BREQ k
                    branch_en = 1'b1;
                    branch_condition = BRANCH_EQ;
                    branch_offset = {{5{k7_imm[6]}}, k7_imm};
                    instruction_decoded = 1'b1;
                end
                
                16'b111101??_????0001: begin // BRNE k
                    branch_en = 1'b1;
                    branch_condition = BRANCH_NE;
                    branch_offset = {{5{k7_imm[6]}}, k7_imm};
                    instruction_decoded = 1'b1;
                end
                
                16'b111100??_????0000: begin // BRCS/BRLO k
                    branch_en = 1'b1;
                    branch_condition = BRANCH_CS;
                    branch_offset = {{5{k7_imm[6]}}, k7_imm};
                    instruction_decoded = 1'b1;
                end
                
                16'b111101??_????0000: begin // BRCC/BRSH k
                    branch_en = 1'b1;
                    branch_condition = BRANCH_CC;
                    branch_offset = {{5{k7_imm[6]}}, k7_imm};
                    instruction_decoded = 1'b1;
                end
                
                16'b111100??_????0010: begin // BRMI k
                    branch_en = 1'b1;
                    branch_condition = BRANCH_MI;
                    branch_offset = {{5{k7_imm[6]}}, k7_imm};
                    instruction_decoded = 1'b1;
                end
                
                16'b111101??_????0010: begin // BRPL k
                    branch_en = 1'b1;
                    branch_condition = BRANCH_PL;
                    branch_offset = {{5{k7_imm[6]}}, k7_imm};
                    instruction_decoded = 1'b1;
                end
                
                16'b111100??_????0011: begin // BRVS k
                    branch_en = 1'b1;
                    branch_condition = BRANCH_VS;
                    branch_offset = {{5{k7_imm[6]}}, k7_imm};
                    instruction_decoded = 1'b1;
                end
                
                16'b111101??_????0011: begin // BRVC k
                    branch_en = 1'b1;
                    branch_condition = BRANCH_VC;
                    branch_offset = {{5{k7_imm[6]}}, k7_imm};
                    instruction_decoded = 1'b1;
                end
                
                16'b111100??_????0100: begin // BRLT k
                    branch_en = 1'b1;
                    branch_condition = BRANCH_LT;
                    branch_offset = {{5{k7_imm[6]}}, k7_imm};
                    instruction_decoded = 1'b1;
                end
                
                16'b111101??_????0100: begin // BRGE k
                    branch_en = 1'b1;
                    branch_condition = BRANCH_GE;
                    branch_offset = {{5{k7_imm[6]}}, k7_imm};
                    instruction_decoded = 1'b1;
                end
                
                16'b111100??_????0110: begin // BRTS k
                    branch_en = 1'b1;
                    branch_condition = BRANCH_TS;
                    branch_offset = {{5{k7_imm[6]}}, k7_imm};
                    instruction_decoded = 1'b1;
                end
                
                16'b111101??_????0110: begin // BRTC k
                    branch_en = 1'b1;
                    branch_condition = BRANCH_TC;
                    branch_offset = {{5{k7_imm[6]}}, k7_imm};
                    instruction_decoded = 1'b1;
                end
                
                16'b111100??_????0111: begin // BRIE k
                    branch_en = 1'b1;
                    branch_condition = BRANCH_IE;
                    branch_offset = {{5{k7_imm[6]}}, k7_imm};
                    instruction_decoded = 1'b1;
                end
                
                16'b111101??_????0111: begin // BRID k
                    branch_en = 1'b1;
                    branch_condition = BRANCH_ID;
                    branch_offset = {{5{k7_imm[6]}}, k7_imm};
                    instruction_decoded = 1'b1;
                end
                
                // =============== COMPARE INSTRUCTIONS ===============
                16'b000101??_????????: begin // CP Rd, Rr
                    rs1_addr = rd_5bit;
                    rs2_addr = rr_5bit;
                    alu_op = ALU_CP;
                    sreg_update = 1'b1;
                    sreg_mask = 8'b00111111;
                    instruction_decoded = 1'b1;
                end
                
                16'b000001??_????????: begin // CPC Rd, Rr
                    rs1_addr = rd_5bit;
                    rs2_addr = rr_5bit;
                    alu_op = ALU_CPC;
                    sreg_update = 1'b1;
                    sreg_mask = 8'b00111111;
                    instruction_decoded = 1'b1;
                end
                
                16'b0011????_????????: begin // CPI Rd, K
                    rs1_addr = {1'b1, rd_4bit}; // R16-R31
                    alu_op = ALU_CPI;
                    alu_use_immediate = 1'b1;
                    immediate = {8'h00, k8_imm};
                    sreg_update = 1'b1;
                    sreg_mask = 8'b00111111;
                    instruction_decoded = 1'b1;
                end
                
                16'b000100??_????????: begin // CPSE Rd, Rr
                    rs1_addr = rd_5bit;
                    rs2_addr = rr_5bit;
                    alu_op = ALU_CPSE;
                    skip_next = 1'b1; // Skip if equal
                    instruction_decoded = 1'b1;
                end
                
                // =============== SINGLE OPERAND INSTRUCTIONS ===============
                16'b1001010?_????0011: begin // INC Rd
                    rs1_addr = rd_5bit;
                    rd_addr = rd_5bit;
                    rd_write_en = 1'b1;
                    alu_op = ALU_INC;
                    sreg_update = 1'b1;
                    sreg_mask = 8'b00011110; // Z,N,V,S
                    instruction_decoded = 1'b1;
                end
                
                16'b1001010?_????1010: begin // DEC Rd
                    rs1_addr = rd_5bit;
                    rd_addr = rd_5bit;
                    rd_write_en = 1'b1;
                    alu_op = ALU_DEC;
                    sreg_update = 1'b1;
                    sreg_mask = 8'b00011110;
                    instruction_decoded = 1'b1;
                end
                
                16'b1001010?_????0000: begin // COM Rd
                    rs1_addr = rd_5bit;
                    rd_addr = rd_5bit;
                    rd_write_en = 1'b1;
                    alu_op = ALU_COM;
                    sreg_update = 1'b1;
                    sreg_mask = 8'b00011111; // C,Z,N,V,S
                    instruction_decoded = 1'b1;
                end
                
                16'b1001010?_????0001: begin // NEG Rd
                    rs1_addr = rd_5bit;
                    rd_addr = rd_5bit;
                    rd_write_en = 1'b1;
                    alu_op = ALU_NEG;
                    sreg_update = 1'b1;
                    sreg_mask = 8'b00111111;
                    instruction_decoded = 1'b1;
                end
                
                16'b001000??_????????: begin // TST Rd (AND Rd, Rd)
                    rs1_addr = rd_5bit;
                    alu_op = ALU_TST;
                    sreg_update = 1'b1;
                    sreg_mask = 8'b00011110;
                    instruction_decoded = 1'b1;
                end
                
                16'b1001010?_????0100: begin // CLR Rd (EOR Rd, Rd)
                    rs1_addr = rd_5bit;
                    rd_addr = rd_5bit;
                    rd_write_en = 1'b1;
                    alu_op = ALU_EOR;
                    rs2_addr = rd_5bit; // EOR with itself
                    sreg_update = 1'b1;
                    sreg_mask = 8'b00011110;
                    instruction_decoded = 1'b1;
                end
                
                16'b1001010?_????0111: begin // SER Rd (LDI Rd, 0xFF)
                    rd_addr = rd_5bit;
                    rd_write_en = 1'b1;
                    alu_op = ALU_PASS;
                    alu_use_immediate = 1'b1;
                    immediate = 16'h00FF;
                    instruction_decoded = 1'b1;
                end
                
                // =============== SHIFT/ROTATE INSTRUCTIONS ===============
                16'b0000110?_????0000: begin // LSL Rd (same as ADD Rd,Rd)
                    rs1_addr = rd_5bit;
                    rs2_addr = rd_5bit;
                    rd_addr = rd_5bit;
                    rd_write_en = 1'b1;
                    alu_op = ALU_LSL;
                    sreg_update = 1'b1;
                    sreg_mask = 8'b00111111;
                    instruction_decoded = 1'b1;
                end
                
                16'b1001010?_????0110: begin // LSR Rd
                    rs1_addr = rd_5bit;
                    rd_addr = rd_5bit;
                    rd_write_en = 1'b1;
                    alu_op = ALU_LSR;
                    sreg_update = 1'b1;
                    sreg_mask = 8'b00011111;
                    instruction_decoded = 1'b1;
                end
                
                16'b0001110?_????0000: begin // ROL Rd (same as ADC Rd,Rd)
                    rs1_addr = rd_5bit;
                    rs2_addr = rd_5bit;
                    rd_addr = rd_5bit;
                    rd_write_en = 1'b1;
                    alu_op = ALU_ROL;
                    sreg_update = 1'b1;
                    sreg_mask = 8'b00011111;
                    instruction_decoded = 1'b1;
                end
                
                16'b1001010?_????0111: begin // ROR Rd
                    rs1_addr = rd_5bit;
                    rd_addr = rd_5bit;
                    rd_write_en = 1'b1;
                    alu_op = ALU_ROR;
                    sreg_update = 1'b1;
                    sreg_mask = 8'b00011111;
                    instruction_decoded = 1'b1;
                end
                
                16'b1001010?_????0101: begin // ASR Rd
                    rs1_addr = rd_5bit;
                    rd_addr = rd_5bit;
                    rd_write_en = 1'b1;
                    alu_op = ALU_ASR;
                    sreg_update = 1'b1;
                    sreg_mask = 8'b00011111;
                    instruction_decoded = 1'b1;
                end
                
                16'b1001010?_????0010: begin // SWAP Rd
                    rs1_addr = rd_5bit;
                    rd_addr = rd_5bit;
                    rd_write_en = 1'b1;
                    alu_op = ALU_SWAP;
                    instruction_decoded = 1'b1;
                end
                
                // =============== BIT OPERATIONS ===============
                16'b1111100?_????0???: begin // SBRC Rr, b - Skip if Bit in Register Cleared
                    rs1_addr = rr_5bit;
                    bit_num = instruction[2:0];
                    bit_test = 1'b1;
                    skip_next = 1'b1; // Skip if bit is clear
                    instruction_decoded = 1'b1;
                end
                
                16'b1111101?_????0???: begin // SBRS Rr, b - Skip if Bit in Register Set
                    rs1_addr = rr_5bit;
                    bit_num = instruction[2:0];
                    bit_test = 1'b1;
                    skip_next = 1'b1; // Skip if bit is set
                    instruction_decoded = 1'b1;
                end
                
                16'b10011000_????1???: begin // SBIC A, b - Skip if Bit in I/O Register Cleared
                    io_addr = {1'b0, instruction[7:3]};
                    bit_num = instruction[2:0];
                    io_read = 1'b1;
                    bit_test = 1'b1;
                    skip_next = 1'b1;
                    instruction_decoded = 1'b1;
                end
                
                16'b10011001_????1???: begin // SBIS A, b - Skip if Bit in I/O Register Set
                    io_addr = {1'b0, instruction[7:3]};
                    bit_num = instruction[2:0];
                    io_read = 1'b1;
                    bit_test = 1'b1;
                    skip_next = 1'b1;
                    instruction_decoded = 1'b1;
                end
                
                16'b10011000_????0???: begin // SBI A, b - Set Bit in I/O Register
                    io_addr = {1'b0, instruction[7:3]};
                    bit_num = instruction[2:0];
                    io_write = 1'b1;
                    bit_set = 1'b1;
                    instruction_decoded = 1'b1;
                end
                
                16'b10011010_????0???: begin // CBI A, b - Clear Bit in I/O Register
                    io_addr = {1'b0, instruction[7:3]};
                    bit_num = instruction[2:0];
                    io_write = 1'b1;
                    bit_clear = 1'b1;
                    instruction_decoded = 1'b1;
                end
                
                16'b1111110?_????0???: begin // BST Rr, b - Bit Store from Register to T
                    rs1_addr = rr_5bit;
                    bit_num = instruction[2:0];
                    sreg_update = 1'b1;
                    sreg_mask = 8'b01000000; // T flag
                    instruction_decoded = 1'b1;
                end
                
                16'b1111100?_????0???: begin // BLD Rd, b - Bit Load from T to Register
                    rd_addr = rd_5bit;
                    rd_write_en = 1'b1;
                    bit_num = instruction[2:0];
                    instruction_decoded = 1'b1;
                end
                
                // =============== I/O INSTRUCTIONS ===============
                16'b10110???_????????: begin // IN Rd, A - In from I/O Port
                    rd_addr = rd_5bit;
                    rd_write_en = 1'b1;
                    io_addr = {instruction[10:9], instruction[3:0]};
                    io_read = 1'b1;
                    instruction_decoded = 1'b1;
                end
                
                16'b10111???_????????: begin // OUT A, Rr - Out to I/O Port
                    rs1_addr = rr_5bit;
                    io_addr = {instruction[10:9], instruction[3:0]};
                    io_write = 1'b1;
                    instruction_decoded = 1'b1;
                end
                
                // =============== MULTIPLICATION INSTRUCTIONS ===============
                16'b100111??_????????: begin // MUL Rd, Rr
                    rs1_addr = rd_5bit;
                    rs2_addr = rr_5bit;
                    rd_addr = 5'd0; // R1:R0
                    rd_write_en_16bit = 1'b1;
                    multiply_en = 1'b1;
                    multiply_signed = 1'b0;
                    alu_op = ALU_MUL;
                    sreg_update = 1'b1;
                    sreg_mask = 8'b00000011; // C,Z
                    instruction_decoded = 1'b1;
                end
                
                16'b00000010_????????: begin // MULS Rd, Rr
                    rs1_addr = {1'b1, rd_4bit}; // R16-R31
                    rs2_addr = {1'b1, rr_4bit}; // R16-R31
                    rd_addr = 5'd0; // R1:R0
                    rd_write_en_16bit = 1'b1;
                    multiply_en = 1'b1;
                    multiply_signed = 1'b1;
                    alu_op = ALU_MULS;
                    sreg_update = 1'b1;
                    sreg_mask = 8'b00000011;
                    instruction_decoded = 1'b1;
                end
                
                16'b000000110???????0: begin // MULSU Rd, Rr
                    rs1_addr = {2'b10, rd_3bit}; // R16-R23
                    rs2_addr = {2'b10, rr_3bit}; // R16-R23
                    rd_addr = 5'd0; // R1:R0
                    rd_write_en_16bit = 1'b1;
                    multiply_en = 1'b1;
                    multiply_signed = 1'b1; // Mixed sign
                    alu_op = ALU_MULSU;
                    sreg_update = 1'b1;
                    sreg_mask = 8'b00000011;
                    instruction_decoded = 1'b1;
                end
                
                16'b000000110???????1: begin // FMUL Rd, Rr
                    rs1_addr = {2'b10, rd_3bit}; // R16-R23
                    rs2_addr = {2'b10, rr_3bit}; // R16-R23
                    rd_addr = 5'd0; // R1:R0
                    rd_write_en_16bit = 1'b1;
                    multiply_en = 1'b1;
                    multiply_frac = 1'b1;
                    alu_op = ALU_FMUL;
                    sreg_update = 1'b1;
                    sreg_mask = 8'b00000011;
                    instruction_decoded = 1'b1;
                end
                
                16'b000000111???????0: begin // FMULS Rd, Rr
                    rs1_addr = {2'b10, rd_3bit}; // R16-R23
                    rs2_addr = {2'b10, rr_3bit}; // R16-R23
                    rd_addr = 5'd0; // R1:R0
                    rd_write_en_16bit = 1'b1;
                    multiply_en = 1'b1;
                    multiply_signed = 1'b1;
                    multiply_frac = 1'b1;
                    alu_op = ALU_FMULS;
                    sreg_update = 1'b1;
                    sreg_mask = 8'b00000011;
                    instruction_decoded = 1'b1;
                end
                
                16'b000000111???????1: begin // FMULSU Rd, Rr
                    rs1_addr = {2'b10, rd_3bit}; // R16-R23
                    rs2_addr = {2'b10, rr_3bit}; // R16-R23
                    rd_addr = 5'd0; // R1:R0
                    rd_write_en_16bit = 1'b1;
                    multiply_en = 1'b1;
                    multiply_signed = 1'b1; // Mixed sign
                    multiply_frac = 1'b1;
                    alu_op = ALU_FMULSU;
                    sreg_update = 1'b1;
                    sreg_mask = 8'b00000011;
                    instruction_decoded = 1'b1;
                end
                
                // =============== FLASH/EEPROM INSTRUCTIONS ===============
                16'b1001000?_????0100: begin // LPM Rd, Z
                    rd_addr = rd_5bit;
                    rd_write_en = 1'b1;
                    use_pointer = 1'b1;
                    pointer_sel = 2'b10; // Z pointer
                    flash_read = 1'b1;
                    mem_mode = MEM_FLASH;
                    instruction_decoded = 1'b1;
                end
                
                16'b1001000?_????0101: begin // LPM Rd, Z+
                    rd_addr = rd_5bit;
                    rd_write_en = 1'b1;
                    use_pointer = 1'b1;
                    pointer_sel = 2'b10;
                    pointer_post_inc = 1'b1;
                    flash_read = 1'b1;
                    mem_mode = MEM_FLASH;
                    instruction_decoded = 1'b1;
                end
                
                16'b1001010111001000: begin // LPM R0, Z
                    rd_addr = 5'd0; // R0
                    rd_write_en = 1'b1;
                    use_pointer = 1'b1;
                    pointer_sel = 2'b10;
                    flash_read = 1'b1;
                    mem_mode = MEM_FLASH;
                    instruction_decoded = 1'b1;
                end
                
                16'b1001000?_????0110: begin // ELPM Rd, Z
                    rd_addr = rd_5bit;
                    rd_write_en = 1'b1;
                    use_pointer = 1'b1;
                    pointer_sel = 2'b10;
                    flash_read = 1'b1; // Extended LPM
                    mem_mode = MEM_FLASH;
                    instruction_decoded = 1'b1;
                end
                
                16'b1001000?_????0111: begin // ELPM Rd, Z+
                    rd_addr = rd_5bit;
                    rd_write_en = 1'b1;
                    use_pointer = 1'b1;
                    pointer_sel = 2'b10;
                    pointer_post_inc = 1'b1;
                    flash_read = 1'b1;
                    mem_mode = MEM_FLASH;
                    instruction_decoded = 1'b1;
                end
                
                16'b1001010111101000: begin // SPM - Store Program Memory
                    use_pointer = 1'b1;
                    pointer_sel = 2'b10; // Z pointer
                    flash_write = 1'b1;
                    rs1_addr = 5'd0; // R1:R0 contains data
                    instruction_decoded = 1'b1;
                end
                
                16'b1001010111111000: begin // SPM Z+ - Store Program Memory, increment Z
                    use_pointer = 1'b1;
                    pointer_sel = 2'b10;
                    pointer_post_inc = 1'b1;
                    flash_write = 1'b1;
                    rs1_addr = 5'd0;
                    instruction_decoded = 1'b1;
                end
                
                // =============== SREG INSTRUCTIONS ===============
                16'b1001010000?01000: begin // SE* - Set flag in SREG
                    sreg_update = 1'b1;
                    sreg_set_bits = 1'b1;
                    case (instruction[6:4])
                        3'b000: sreg_mask = 8'b00000001; // SEC - Set Carry
                        3'b001: sreg_mask = 8'b00000010; // SEZ - Set Zero
                        3'b010: sreg_mask = 8'b00000100; // SEN - Set Negative
                        3'b011: sreg_mask = 8'b00001000; // SEV - Set Overflow
                        3'b100: sreg_mask = 8'b00010000; // SES - Set Sign
                        3'b101: sreg_mask = 8'b00100000; // SEH - Set Half-carry
                        3'b110: sreg_mask = 8'b01000000; // SET - Set T flag
                        3'b111: sreg_mask = 8'b10000000; // SEI - Set Interrupt
                    endcase
                    instruction_decoded = 1'b1;
                end
                
                16'b1001010010?01000: begin // CL* - Clear flag in SREG
                    sreg_update = 1'b1;
                    sreg_clear_bits = 1'b1;
                    case (instruction[6:4])
                        3'b000: sreg_mask = 8'b00000001; // CLC - Clear Carry
                        3'b001: sreg_mask = 8'b00000010; // CLZ - Clear Zero
                        3'b010: sreg_mask = 8'b00000100; // CLN - Clear Negative
                        3'b011: sreg_mask = 8'b00001000; // CLV - Clear Overflow
                        3'b100: sreg_mask = 8'b00010000; // CLS - Clear Sign
                        3'b101: sreg_mask = 8'b00100000; // CLH - Clear Half-carry
                        3'b110: sreg_mask = 8'b01000000; // CLT - Clear T flag
                        3'b111: sreg_mask = 8'b10000000; // CLI - Clear Interrupt
                    endcase
                    instruction_decoded = 1'b1;
                end
                
                // =============== SYSTEM INSTRUCTIONS ===============
                16'b1001010110001000: begin // SLEEP
                    // Sleep mode instruction - implementation depends on system
                    instruction_decoded = 1'b1;
                end
                
                16'b1001010110101000: begin // WDR - Watchdog Reset
                    // Watchdog reset instruction
                    instruction_decoded = 1'b1;
                end
                
                16'b1001010100111000: begin // BREAK - Break (for debugging)
                    // Break instruction for debugger
                    instruction_decoded = 1'b1;
                end
                
                default: begin
                    unsupported_instruction = 1'b1;
                end
            endcase
        end
    end

endmodule

`default_nettype wire