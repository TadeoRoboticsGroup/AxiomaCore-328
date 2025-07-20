// AxiomaCore-328: Decodificador de Instrucciones AVR Extendido
// Archivo: axioma_decoder_v2.v
// Descripción: Decodificador expandido con 40+ instrucciones AVR críticas
//              Soporta modos de direccionamiento avanzados y stack operations
`default_nettype none

module axioma_decoder_v2 (
    input wire clk,                    // Reloj del sistema
    input wire reset_n,                // Reset activo bajo
    
    // Entrada de instrucción
    input wire [15:0] instruction,     // Instrucción de 16 bits del Flash
    input wire instruction_valid,      // Instrucción válida
    
    // Señales de control de registros
    output reg [4:0] rs1_addr,         // Dirección registro fuente 1
    output reg [4:0] rs2_addr,         // Dirección registro fuente 2
    output reg [4:0] rd_addr,          // Dirección registro destino
    output reg rd_write_en,            // Habilitar escritura registro
    
    // Señales de control ALU
    output reg [4:0] alu_op,           // Operación ALU
    output reg alu_use_immediate,      // Usar inmediato en lugar de rs2
    output reg [7:0] immediate,        // Valor inmediato
    
    // Señales de control de memoria
    output reg mem_read,               // Leer de memoria
    output reg mem_write,              // Escribir a memoria
    output reg [2:0] mem_mode,         // Modo de direccionamiento memoria
    output reg use_pointer,            // Usar puntero X/Y/Z
    output reg [1:0] pointer_sel,      // Selección de puntero (0=X, 1=Y, 2=Z)
    output reg pointer_post_inc,       // Post-incremento del puntero
    output reg pointer_pre_dec,        // Pre-decremento del puntero
    
    // Señales de control de stack
    output reg stack_push,             // Push al stack
    output reg stack_pop,              // Pop del stack
    output reg stack_push_pc,          // Push PC (para CALL/RCALL)
    output reg stack_pop_pc,           // Pop PC (para RET/RETI)
    
    // Señales de control de flujo
    output reg branch_en,              // Habilitar branch
    output reg [3:0] branch_condition, // Condición de branch (expandido)
    output reg [11:0] branch_offset,   // Offset del branch
    output reg jump_en,                // Habilitar jump
    output reg [21:0] jump_addr,       // Dirección de jump
    output reg call_en,                // Habilitar call
    output reg ret_en,                 // Habilitar return
    
    // Control de I/O y bits
    output reg io_read,                // Leer de I/O
    output reg io_write,               // Escribir a I/O
    output reg [5:0] io_addr,          // Dirección de I/O
    output reg bit_set,                // Set bit
    output reg bit_clear,              // Clear bit
    output reg [2:0] bit_num,          // Número de bit (0-7)
    
    // Control de Status Register
    output reg sreg_update,            // Actualizar SREG
    output reg [7:0] sreg_mask,        // Máscara de bits SREG a actualizar
    
    // Estado del decodificador
    output reg instruction_decoded,    // Instrucción decodificada exitosamente
    output reg unsupported_instruction, // Instrucción no soportada
    output reg is_16bit_instruction,   // Instrucción de 16 bits (para 32-bit)
    output reg [15:0] debug_opcode     // Opcode para debug
);

    // Campos de la instrucción (formato AVR)
    wire [3:0] opcode_h4 = instruction[15:12];  // 4 bits superiores
    wire [3:0] opcode_h3 = instruction[14:12];  // 3 bits superiores
    wire [7:0] opcode_h8 = instruction[15:8];   // 8 bits superiores
    
    // Decodificación de registros mejorada
    wire [4:0] rd_5bit = instruction[8:4];      // Rd completo (R0-R31)
    wire [4:0] rr_5bit = {instruction[9], instruction[3:0]}; // Rr completo
    wire [3:0] rd_4bit = instruction[7:4];      // Rd reducido (R16-R31)
    wire [3:0] rr_4bit = instruction[3:0];      // Rr reducido (R16-R31)
    
    // Inmediatos para diferentes formatos
    wire [7:0] k8_imm = {instruction[11:8], instruction[3:0]}; // K8 para LDI/CPI
    wire [5:0] k6_imm = instruction[9:4];       // K6 para ADIW/SBIW
    wire [11:0] k12_imm = instruction[11:0];    // K12 para RJMP/RCALL
    wire [6:0] k7_imm = instruction[9:3];       // K7 para branches
    wire [4:0] k5_imm = instruction[8:4];       // K5 para SBRC/SBRS
    
    // Modos de direccionamiento memoria
    localparam MEM_DIRECT = 3'b000;     // Directo
    localparam MEM_INDIRECT = 3'b001;   // Indirecto
    localparam MEM_POST_INC = 3'b010;   // Post-incremento
    localparam MEM_PRE_DEC = 3'b011;    // Pre-decremento
    localparam MEM_DISP = 3'b100;       // Con desplazamiento
    localparam MEM_IO = 3'b101;         // I/O directo
    
    // Branch conditions expandidas
    localparam BRANCH_EQ  = 4'b0001;   // Z=1
    localparam BRANCH_NE  = 4'b0010;   // Z=0
    localparam BRANCH_CS  = 4'b0011;   // C=1
    localparam BRANCH_CC  = 4'b0100;   // C=0
    localparam BRANCH_MI  = 4'b0101;   // N=1
    localparam BRANCH_PL  = 4'b0110;   // N=0
    localparam BRANCH_VS  = 4'b0111;   // V=1
    localparam BRANCH_VC  = 4'b1000;   // V=0
    localparam BRANCH_LT  = 4'b1001;   // S=1
    localparam BRANCH_GE  = 4'b1010;   // S=0
    
    // ALU operations (importados de axioma_alu.v)
    localparam ALU_ADD  = 5'b00000;
    localparam ALU_ADC  = 5'b00001;
    localparam ALU_SUB  = 5'b00010;
    localparam ALU_SBC  = 5'b00011;
    localparam ALU_AND  = 5'b00100;
    localparam ALU_OR   = 5'b00101;
    localparam ALU_EOR  = 5'b00110;
    localparam ALU_COM  = 5'b00111;
    localparam ALU_NEG  = 5'b01000;
    localparam ALU_INC  = 5'b01001;
    localparam ALU_DEC  = 5'b01010;
    localparam ALU_LSL  = 5'b01011;
    localparam ALU_LSR  = 5'b01100;
    localparam ALU_ROL  = 5'b01101;
    localparam ALU_ROR  = 5'b01110;
    localparam ALU_ASR  = 5'b01111;
    localparam ALU_SWAP = 5'b10000;
    localparam ALU_CP   = 5'b10001;
    localparam ALU_CPC  = 5'b10010;
    localparam ALU_TST  = 5'b10011;
    localparam ALU_PASS = 5'b11111;
    
    // Lógica de decodificación principal expandida
    always @(*) begin
        // Valores por defecto
        rs1_addr = 5'b00000;
        rs2_addr = 5'b00000;
        rd_addr = 5'b00000;
        rd_write_en = 1'b0;
        alu_op = ALU_PASS;
        alu_use_immediate = 1'b0;
        immediate = 8'h00;
        
        mem_read = 1'b0;
        mem_write = 1'b0;
        mem_mode = MEM_DIRECT;
        use_pointer = 1'b0;
        pointer_sel = 2'b00;
        pointer_post_inc = 1'b0;
        pointer_pre_dec = 1'b0;
        
        stack_push = 1'b0;
        stack_pop = 1'b0;
        stack_push_pc = 1'b0;
        stack_pop_pc = 1'b0;
        
        branch_en = 1'b0;
        branch_condition = 4'b0000;
        branch_offset = 12'h000;
        jump_en = 1'b0;
        jump_addr = 22'h000000;
        call_en = 1'b0;
        ret_en = 1'b0;
        
        io_read = 1'b0;
        io_write = 1'b0;
        io_addr = 6'h00;
        bit_set = 1'b0;
        bit_clear = 1'b0;
        bit_num = 3'b000;
        
        sreg_update = 1'b0;
        sreg_mask = 8'h00;
        
        instruction_decoded = 1'b0;
        unsupported_instruction = 1'b0;
        is_16bit_instruction = 1'b1;
        debug_opcode = instruction;
        
        if (instruction_valid) begin
            casez (instruction)
                // =============== NOP ===============
                16'h0000: begin
                    instruction_decoded = 1'b1;
                end
                
                // =============== ARITHMETIC INSTRUCTIONS ===============
                16'b000011??_??????? : begin // ADD Rd, Rr
                    rs1_addr = rd_5bit;
                    rs2_addr = rr_5bit;
                    rd_addr = rd_5bit;
                    rd_write_en = 1'b1;
                    alu_op = ALU_ADD;
                    sreg_update = 1'b1;
                    sreg_mask = 8'b00111111; // C,Z,N,V,S,H
                    instruction_decoded = 1'b1;
                end
                
                16'b000111??_??????? : begin // ADC Rd, Rr
                    rs1_addr = rd_5bit;
                    rs2_addr = rr_5bit;
                    rd_addr = rd_5bit;
                    rd_write_en = 1'b1;
                    alu_op = ALU_ADC;
                    sreg_update = 1'b1;
                    sreg_mask = 8'b00111111;
                    instruction_decoded = 1'b1;
                end
                
                16'b000110??_???????: begin // SUB Rd, Rr
                    rs1_addr = rd_5bit;
                    rs2_addr = rr_5bit;
                    rd_addr = rd_5bit;
                    rd_write_en = 1'b1;
                    alu_op = ALU_SUB;
                    sreg_update = 1'b1;
                    sreg_mask = 8'b00111111;
                    instruction_decoded = 1'b1;
                end
                
                16'b000010??_???????: begin // SBC Rd, Rr
                    rs1_addr = rd_5bit;
                    rs2_addr = rr_5bit;
                    rd_addr = rd_5bit;
                    rd_write_en = 1'b1;
                    alu_op = ALU_SBC;
                    sreg_update = 1'b1;
                    sreg_mask = 8'b00111111;
                    instruction_decoded = 1'b1;
                end
                
                // =============== LOGICAL INSTRUCTIONS ===============
                16'b001000??_???????: begin // AND Rd, Rr
                    rs1_addr = rd_5bit;
                    rs2_addr = rr_5bit;
                    rd_addr = rd_5bit;
                    rd_write_en = 1'b1;
                    alu_op = ALU_AND;
                    sreg_update = 1'b1;
                    sreg_mask = 8'b00011110; // Z,N,V,S (V=0)
                    instruction_decoded = 1'b1;
                end
                
                16'b001010??_???????: begin // OR Rd, Rr
                    rs1_addr = rd_5bit;
                    rs2_addr = rr_5bit;
                    rd_addr = rd_5bit;
                    rd_write_en = 1'b1;
                    alu_op = ALU_OR;
                    sreg_update = 1'b1;
                    sreg_mask = 8'b00011110;
                    instruction_decoded = 1'b1;
                end
                
                16'b001001??_???????: begin // EOR Rd, Rr
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
                16'b001011??_???????: begin // MOV Rd, Rr
                    rs1_addr = rr_5bit;
                    rd_addr = rd_5bit;
                    rd_write_en = 1'b1;
                    alu_op = ALU_PASS;
                    instruction_decoded = 1'b1;
                end
                
                16'b1110????_????????: begin // LDI Rd, K
                    rd_addr = {1'b1, rd_4bit}; // R16-R31
                    rd_write_en = 1'b1;
                    alu_op = ALU_PASS;
                    alu_use_immediate = 1'b1;
                    immediate = k8_imm;
                    instruction_decoded = 1'b1;
                end
                
                // =============== LOAD/STORE INSTRUCTIONS ===============
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
                
                16'b1001001?_????1100: begin // ST X, Rr
                    rs1_addr = rr_5bit;
                    mem_write = 1'b1;
                    use_pointer = 1'b1;
                    pointer_sel = 2'b00;
                    mem_mode = MEM_INDIRECT;
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
                
                16'b1101????_????????: begin // RCALL k
                    call_en = 1'b1;
                    stack_push_pc = 1'b1;
                    jump_addr = {{10{k12_imm[11]}}, k12_imm};
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
                
                16'b111100??_????0000: begin // BRCS k
                    branch_en = 1'b1;
                    branch_condition = BRANCH_CS;
                    branch_offset = {{5{k7_imm[6]}}, k7_imm};
                    instruction_decoded = 1'b1;
                end
                
                16'b111101??_????0000: begin // BRCC k
                    branch_en = 1'b1;
                    branch_condition = BRANCH_CC;
                    branch_offset = {{5{k7_imm[6]}}, k7_imm};
                    instruction_decoded = 1'b1;
                end
                
                // =============== COMPARE INSTRUCTIONS ===============
                16'b000101??_???????: begin // CP Rd, Rr
                    rs1_addr = rd_5bit;
                    rs2_addr = rr_5bit;
                    alu_op = ALU_CP;
                    sreg_update = 1'b1;
                    sreg_mask = 8'b00111111;
                    instruction_decoded = 1'b1;
                end
                
                16'b000001??_???????: begin // CPC Rd, Rr
                    rs1_addr = rd_5bit;
                    rs2_addr = rr_5bit;
                    alu_op = ALU_CPC;
                    sreg_update = 1'b1;
                    sreg_mask = 8'b00111111;
                    instruction_decoded = 1'b1;
                end
                
                16'b0011????_????????: begin // CPI Rd, K
                    rs1_addr = {1'b1, rd_4bit}; // R16-R31
                    alu_op = ALU_CP;
                    alu_use_immediate = 1'b1;
                    immediate = k8_imm;
                    sreg_update = 1'b1;
                    sreg_mask = 8'b00111111;
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
                
                // =============== SHIFT/ROTATE INSTRUCTIONS ===============
                16'b0000110?_????0000: begin // LSL Rd (same as ADD Rd,Rd)
                    rs1_addr = rd_5bit;
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
                
                16'b1001010?_????0111: begin // ROL Rd
                    rs1_addr = rd_5bit;
                    rd_addr = rd_5bit;
                    rd_write_en = 1'b1;
                    alu_op = ALU_ROL;
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
                
                default: begin
                    unsupported_instruction = 1'b1;
                end
            endcase
        end
    end

endmodule

`default_nettype wire